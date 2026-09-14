import { Injectable, Logger } from '@nestjs/common';
import { ImapFlow } from 'imapflow';
import { PrismaService } from '../prisma/prisma.service';
import { decryptSecret, encryptSecret, mailCryptoReady } from './mail-crypto';
import { verifySmtpAccess } from './mail-smtp';
import { badRequest, conflict, notFound } from '../common/errors';

/**
 * Почтовые аккаунты: список, добавление, включение/выключение, удаление.
 *
 * Пароль (app password) приходит только сюда, проверяется живым подключением к IMAP
 * и сразу шифруется — в открытом виде он не попадает ни в БД, ни в ответы API, ни в логи.
 * Проверка при добавлении важна не для красоты: без неё опечатка в пароле всплыла бы
 * через пять минут в статусе синхронизации, где уже непонятно, пароль виноват или сеть.
 */

export type MailKind = 'gmail' | 'icloud' | 'imap' | 'smtp';
export type MailBox = 'inbox' | 'sent';

/**
 * Папка источника: откуда читаем письма и в какую из наших двух корзин их класть.
 *
 * `specialUse` — стандартная метка папки (RFC 6154): \All, \Junk, \Sent. Ищем папку по ней,
 * а `path` — только запасной вариант. Причина простая: у Gmail и iCloud имена системных папок
 * ЛОКАЛИЗОВАНЫ, и в русском ящике All Mail называется «[Gmail]/Вся почта», а Sent —
 * «Отправленные». Строка пути на таком аккаунте не нашлась бы, и синхронизация молча
 * не забрала бы ничего.
 */
export interface MailSourceFolder {
  path: string;
  box: MailBox;
  specialUse?: string;
}

export interface MailKindPreset {
  label: string;
  imapHost: string;
  imapPort: number;
  secure: boolean;
  smtpHost: string;
  smtpPort: number;
  folders: MailSourceFolder[];
  /**
   * Пароли приложений провайдеры показывают группами («abcd efgh ijkl mnop» у Google,
   * «abcd-efgh-ijkl-mnop» у Apple), а для входа нужны слитно. Иначе самая частая ошибка
   * выглядит как «неверный пароль» при внешне правильном.
   */
  stripSeparators: boolean;
}

/**
 * Пресеты провайдеров. У Gmail писем «по папкам» нет: есть одно хранилище и метки, поэтому
 * читаем `[Gmail]/All Mail` (в нём всё, кроме спама и корзины) и `[Gmail]/Spam` — спам
 * показываем во «Входящих», как и договаривались, отдельных папок у почты нет. Отправленные
 * отсекаем по системной метке `\Sent`, поэтому в All Mail отдельная папка не нужна.
 */
export const MAIL_PRESETS: Record<MailKind, MailKindPreset> = {
  gmail: {
    label: 'Gmail / Google Workspace',
    imapHost: 'imap.gmail.com',
    imapPort: 993,
    secure: true,
    smtpHost: 'smtp.gmail.com',
    smtpPort: 465,
    folders: [
      // All Mail — всё, кроме спама и корзины; отправленные внутри него отсекаем по метке \Sent
      { path: '[Gmail]/All Mail', specialUse: '\\All', box: 'inbox' },
      { path: '[Gmail]/Spam', specialUse: '\\Junk', box: 'inbox' },
    ],
    stripSeparators: true,
  },
  icloud: {
    label: 'iCloud Mail',
    imapHost: 'imap.mail.me.com',
    imapPort: 993,
    secure: true,
    smtpHost: 'smtp.mail.me.com',
    smtpPort: 587,
    folders: [
      // INBOX — единственное имя, которое в IMAP не локализуется и не переименовывается
      { path: 'INBOX', box: 'inbox' },
      { path: 'Junk', specialUse: '\\Junk', box: 'inbox' },
      { path: 'Sent Messages', specialUse: '\\Sent', box: 'sent' },
    ],
    stripSeparators: true,
  },
  /**
   * Почта на своём сервере: принимаем её мы сами (Postfix на нашем VPS отдаёт письмо
   * в приложение), а отправляем через внешний релей — у Brevo своя репутация IP и DKIM.
   * IMAP-папок у такого аккаунта нет вовсе, поэтому расписание его не трогает.
   */
  smtp: {
    label: 'Свой сервер: приём у нас, отправка через релей',
    imapHost: '',
    imapPort: 993,
    secure: true,
    smtpHost: '',
    smtpPort: 587,
    folders: [],
    stripSeparators: false,
  },
  imap: {
    label: 'Другой IMAP-сервер',
    imapHost: '',
    imapPort: 993,
    secure: true,
    smtpHost: '',
    smtpPort: 465,
    folders: [
      { path: 'INBOX', box: 'inbox' },
      { path: 'Sent', specialUse: '\\Sent', box: 'sent' },
    ],
    stripSeparators: false,
  },
};

/** Публичное описание аккаунта: ни пароля, ни его шифртекста здесь нет и быть не может. */
export interface MailAccountView {
  id: string;
  kind: string;
  label: string;
  email: string;
  enabled: boolean;
  status: string;
  statusError: string | null;
  lastSyncAt: Date | null;
  createdAt: Date;
  counts: { inbox: number; sent: number };
}

/** Строка аккаунта из БД (для внутреннего использования). */
export interface MailAccountRow {
  id: string;
  userId: string;
  kind: string;
  email: string;
  imapHost: string;
  imapPort: number;
  smtpHost: string;
  smtpPort: number;
  login: string;
  secretEnc: string;
  smtpLogin: string | null;
  smtpSecretEnc: string | null;
  enabled: boolean;
}

@Injectable()
export class MailAccountsService {
  private readonly logger = new Logger(MailAccountsService.name);

  constructor(private readonly prisma: PrismaService) {}

  /** Провайдер по виду аккаунта: неизвестный вид — это imap с явными хостами. */
  presetOf(kind: string): MailKindPreset {
    return MAIL_PRESETS[(kind as MailKind) in MAIL_PRESETS ? (kind as MailKind) : 'imap'];
  }

  /** Читать почту можно только с ключом шифрования: без него пароль негде хранить. */
  assertCryptoReady(): void {
    if (!mailCryptoReady()) {
      throw badRequest('MAIL_SECRET_KEY не задан на сервере — пароли аккаунтов хранить негде', 'mail_crypto_unavailable');
    }
  }

  /**
   * Пароль приложения в пригодном для входа виде: у Gmail и iCloud убираем разделители,
   * у произвольного IMAP-сервера не трогаем ничего — там это обычный пароль пользователя.
   */
  normalizeSecret(kind: string, raw: string): string {
    const value = String(raw ?? '').trim();
    return this.presetOf(kind).stripSeparators ? value.replace(/[\s-]+/g, '') : value;
  }

  /**
   * Живая проверка доступа: подключаемся и сразу выходим (verifyOnly). Возвращает текст
   * ошибки провайдера или null. Пароль сюда приходит уже нормализованным и отсюда не уходит.
   */
  async verifyAccess(input: {
    host: string;
    port: number;
    secure: boolean;
    login: string;
    password: string;
  }): Promise<string | null> {
    const client = new ImapFlow({
      host: input.host,
      port: input.port,
      secure: input.secure,
      auth: { user: input.login, pass: input.password },
      // verifyOnly: сервер сам разорвёт соединение после успешной проверки
      verifyOnly: true,
      // Логгер imapflow пишет в том числе команды: с ним в лог уехал бы и пароль
      logger: false,
      clientInfo: { name: 'CloudlyRu', version: '0.1.0' },
      // Почтовые серверы бывают медленными на TLS-хендшейке; минуты ожидания тут не нужны
      socketTimeout: 30_000,
      greetingTimeout: 20_000,
    });
    try {
      await client.connect();
      return null;
    } catch (e) {
      const err = e as Error & { response?: string; responseText?: string; authenticationFailed?: boolean };
      const text = err.responseText || err.response || err.message || String(e);
      return String(text).slice(0, 300);
    } finally {
      try {
        client.close();
      } catch {
        /* соединение уже закрыто verifyOnly-выходом */
      }
    }
  }

  async list(userId: string): Promise<MailAccountView[]> {
    const accounts = await this.prisma.mailAccount.findMany({
      where: { userId },
      orderBy: { createdAt: 'asc' },
      include: { _count: { select: { messages: true } } },
    });
    if (!accounts.length) return [];

    // Числа по нашим двум папкам (их всего две, поэтому два запроса, а не группировка по всем).
    const [inbox, sent] = await Promise.all([
      this.prisma.mailMessage.groupBy({
        by: ['accountId'],
        where: { userId, box: 'inbox', deletedAt: null },
        _count: { _all: true },
      }),
      this.prisma.mailMessage.groupBy({
        by: ['accountId'],
        where: { userId, box: 'sent', deletedAt: null },
        _count: { _all: true },
      }),
    ]);
    const inboxBy = new Map(inbox.map((r) => [r.accountId, r._count._all]));
    const sentBy = new Map(sent.map((r) => [r.accountId, r._count._all]));

    return accounts.map((a) => ({
      id: a.id,
      kind: a.kind,
      label: (MAIL_PRESETS[a.kind as MailKind] ?? MAIL_PRESETS.imap).label,
      email: a.email,
      enabled: a.enabled,
      status: a.status,
      statusError: a.statusError,
      lastSyncAt: a.lastSyncAt,
      createdAt: a.createdAt,
      counts: { inbox: inboxBy.get(a.id) ?? 0, sent: sentBy.get(a.id) ?? 0 },
    }));
  }

  /** Аккаунт по id с проверкой владельца (чужой неотличим от несуществующего). */
  async require(userId: string, id: string): Promise<MailAccountRow> {
    const account = await this.prisma.mailAccount.findUnique({ where: { id } });
    if (!account || account.userId !== userId) throw notFound('mail account not found');
    return account;
  }

  /** Расшифрованные данные для подключения: живут только внутри процесса синхронизации. */
  credentials(account: MailAccountRow): { login: string; password: string } {
    return { login: account.login, password: decryptSecret(account.secretEnc) };
  }

  /**
   * Креды отправки: у аккаунта со своим релеем они свои (Brevo), у остальных — те же,
   * что для приёма. Пустой пароль означает «отправка не настроена».
   */
  smtpCredentials(account: MailAccountRow): { login: string; password: string } {
    if (account.smtpLogin && account.smtpSecretEnc) {
      return { login: account.smtpLogin, password: decryptSecret(account.smtpSecretEnc) };
    }
    return { login: account.login, password: decryptSecret(account.secretEnc) };
  }

  async create(
    userId: string,
    input: {
      kind?: unknown;
      email?: unknown;
      password?: unknown;
      imapHost?: unknown;
      smtpHost?: unknown;
      smtpPort?: unknown;
      smtpLogin?: unknown;
      smtpPassword?: unknown;
    },
  ): Promise<MailAccountView> {
    this.assertCryptoReady();
    const kind = String(input.kind ?? 'gmail') as MailKind;
    if (!(kind in MAIL_PRESETS)) throw badRequest('unknown mail account kind', 'mail_kind_unknown');
    const email = String(input.email ?? '').trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw badRequest('invalid email', 'mail_email_invalid');

    // Свой сервер: приём делает Postfix, поэтому пароля ящика и IMAP-хоста не спрашиваем,
    // а для отправки нужны отдельные креды релея (Brevo) — они не связаны с ящиком.
    const inboundOnly = kind === 'smtp';

    const preset = MAIL_PRESETS[kind];
    const imapHost = kind === 'imap' ? String(input.imapHost ?? '').trim() : preset.imapHost;
    const smtpHost = kind === 'imap' || inboundOnly ? String(input.smtpHost ?? '').trim() : preset.smtpHost;
    if (!inboundOnly && !imapHost) throw badRequest('imapHost is required for generic imap', 'mail_host_required');
    // У своего сервера релей необязателен: приём работает и без возможности отправки.
    if (kind === 'imap' && !smtpHost) throw badRequest('smtpHost is required for generic imap', 'mail_host_required');

    const password = this.normalizeSecret(kind, String(input.password ?? ''));
    if (!inboundOnly && password.length < 8) {
      throw badRequest('похоже на обычный пароль, а нужен пароль приложения', 'mail_password_too_short');
    }

    const existing = await this.prisma.mailAccount.findFirst({ where: { userId, email } });
    if (existing) throw conflict('такой аккаунт уже добавлен', 'mail_account_exists');

    // Отправка через релей: свои логин и ключ, не связанные с ящиком
    const smtpLogin = inboundOnly
      ? String(input.smtpLogin ?? '').trim() || email
      : email;
    const smtpPassword = inboundOnly
      ? this.normalizeSecret('smtp', String(input.smtpPassword ?? ''))
      : password;

    const error = inboundOnly
      ? null
      : await this.verifyAccess({
      host: imapHost,
      port: preset.imapPort,
      secure: preset.secure,
      login: email,
      password,
    });
    if (error) {
      // Ошибку провайдера отдаём как есть: «Application-specific password required» или
      // «Invalid credentials» — это ровно то, что нужно человеку, чтобы починить доступ.
      throw badRequest(`не удалось войти в ${imapHost}: ${error}`, 'mail_login_failed');
    }
    // Отправку проверяем отдельно: SMTP и IMAP — разные серверы и разные разрешения, и
    // «почта читается, а письма не уходят» выяснять при первом отправленном письме поздно.
    // Проверка заодно подбирает рабочий порт (465 или 587) — его и сохраняем: иначе отправка
    // потом стучалась бы в тот, который в этой сети не проходит.
    // Отправку проверяем, если её настроили: у приёмного аккаунта релей может быть ещё
    // не заведён, и это не повод отказывать в приёме.
    const wantedPort = inboundOnly ? Number(input.smtpPort) || preset.smtpPort : preset.smtpPort;
    let smtpPort = wantedPort;
    if (smtpHost && (smtpPassword || !inboundOnly)) {
      const smtp = await verifySmtpAccess({ smtpHost, smtpPort: wantedPort, login: smtpLogin, password: smtpPassword });
      if (smtp.error) {
        throw badRequest(
          inboundOnly ? `отправка через ${smtpHost} не работает: ${smtp.error}` : `IMAP доступен, а отправка через ${smtpHost} нет: ${smtp.error}`,
          'mail_smtp_login_failed',
        );
      }
      smtpPort = smtp.port;
    } else if (inboundOnly) {
      this.logger.log(`аккаунт ${email}: приём своим сервером, отправка не настроена`);
    }

    const created = await this.prisma.mailAccount.create({
      data: {
        userId,
        kind,
        email,
        imapHost,
        imapPort: preset.imapPort,
        smtpHost,
        smtpPort,
        login: email,
        // У приёмного аккаунта пароля ящика нет вовсе: ставим заглушку, чтобы колонка
        // осталась непустой, а расшифровывать её никто не станет.
        secretEnc: encryptSecret(password || 'inbound-only'),
        ...(inboundOnly && smtpPassword ? { smtpLogin, smtpSecretEnc: encryptSecret(smtpPassword) } : {}),
        status: 'idle',
      },
    });
    this.logger.log(`аккаунт ${email} (${kind}) добавлен: ${imapHost}`);
    const view = await this.list(userId);
    return view.find((a) => a.id === created.id)!;
  }

  /**
   * Правка аккаунта: включение, смена пароля и переезд на свой сервер.
   *
   * Переезд — это смена вида на «свой сервер» плюс креды релея для отправки. Он нужен,
   * когда почта перестаёт ходить через чужой ящик: приём с этого момента делает наш Postfix,
   * а отправка идёт через релей, и старый IMAP-пароль больше не нужен.
   */
  async patch(
    userId: string,
    id: string,
    body: {
      enabled?: unknown;
      password?: unknown;
      kind?: unknown;
      smtpHost?: unknown;
      smtpPort?: unknown;
      smtpLogin?: unknown;
      smtpPassword?: unknown;
    },
  ): Promise<MailAccountView> {
    const account = await this.require(userId, id);
    const data: {
      enabled?: boolean;
      kind?: string;
      imapHost?: string;
      secretEnc?: string;
      status?: string;
      statusError?: string | null;
      smtpHost?: string;
      smtpPort?: number;
      smtpLogin?: string;
      smtpSecretEnc?: string;
    } = {};

    if (typeof body.enabled === 'boolean') data.enabled = body.enabled;

    // Переезд на свой сервер: IMAP больше не нужен, папок у такого вида аккаунта нет
    const wantedKind =
      typeof body.kind === 'string' && body.kind in MAIL_PRESETS ? (body.kind as MailKind) : null;
    if (wantedKind && wantedKind !== account.kind) data.kind = wantedKind;

    // Креды релея: если заданы — проверяем живым подключением, как при добавлении
    const smtpHost = typeof body.smtpHost === 'string' ? body.smtpHost.trim() : null;
    const smtpPassword = typeof body.smtpPassword === 'string' ? this.normalizeSecret('smtp', body.smtpPassword) : null;
    if (smtpHost && smtpPassword) {
      const smtpPort = Number(body.smtpPort) || account.smtpPort || 587;
      const smtpLogin = String(body.smtpLogin ?? '').trim() || smtpHost;
      const smtp = await verifySmtpAccess({ smtpHost, smtpPort, login: smtpLogin, password: smtpPassword });
      if (smtp.error) throw badRequest(`отправка через ${smtpHost} не работает: ${smtp.error}`, 'mail_smtp_login_failed');
      data.smtpHost = smtpHost;
      data.smtpPort = smtp.port;
      data.smtpLogin = smtpLogin;
      data.smtpSecretEnc = encryptSecret(smtpPassword);
    }

    // Пароль ящика проверяем только там, где почта всё ещё читается по IMAP
    const kindAfter = data.kind ?? account.kind;
    if (kindAfter !== 'smtp' && typeof body.password === 'string' && body.password.trim()) {
      this.assertCryptoReady();
      const password = this.normalizeSecret(account.kind, body.password);
      const error = await this.verifyAccess({
        host: account.imapHost,
        port: account.imapPort,
        secure: true,
        login: account.login,
        password,
      });
      if (error) throw badRequest(`не удалось войти в ${account.imapHost}: ${error}`, 'mail_login_failed');
      const smtp = await verifySmtpAccess({
        smtpHost: account.smtpHost,
        smtpPort: account.smtpPort,
        login: account.login,
        password,
      });
      if (smtp.error) {
        throw badRequest(`IMAP доступен, а отправка через ${account.smtpHost} нет: ${smtp.error}`, 'mail_smtp_login_failed');
      }
      // рабочий порт мог оказаться другим (465 против 587) — сохраняем его
      if (smtp.port !== account.smtpPort) data.smtpPort = smtp.port;
      data.secretEnc = encryptSecret(password);
      // сбрасываем прошлую ошибку: причина могла быть именно в пароле
      data.status = 'idle';
      data.statusError = null;
    }
    // Переезд на свой сервер: почта приходит не из IMAP, поэтому прошлые ошибки чтения
    // к новому состоянию отношения не имеют и только пугали бы в интерфейсе
    if (kindAfter === 'smtp' && account.kind !== 'smtp') {
      data.status = 'idle';
      data.statusError = null;
    }

    if (!Object.keys(data).length) throw badRequest('nothing to update', 'mail_nothing_to_update');
    await this.prisma.mailAccount.update({ where: { id }, data });
    const view = await this.list(userId);
    return view.find((a) => a.id === id)!;
  }

  /**
   * Удаление аккаунта. Письма уходят вместе с ним (cascade), а вложения остаются в скрытой
   * папке «Почта»: их уборка — дело почтовой корзины и очистки (фаза удаления), где у файла
   * есть связь с письмом и понятно, что именно удалять.
   */
  async remove(userId: string, id: string): Promise<void> {
    await this.require(userId, id);
    await this.prisma.mailAccount.delete({ where: { id } });
    this.logger.log(`аккаунт ${id} удалён (письма и курсоры — cascade)`);
  }
}
