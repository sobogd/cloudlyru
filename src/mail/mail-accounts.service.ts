import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { decryptSecret } from './mail-crypto';
import { inBox } from './mail-scope';
import { notFound } from '../common/errors';

/**
 * Почтовые аккаунты: список и данные для подключения.
 *
 * Аккаунты заведены один раз на сервере и из приложения не редактируются: пароль приложения
 * хранится в БД зашифрованным (AES-256-GCM), в открытом виде он живёт только в памяти процесса
 * на время подключения к IMAP/SMTP и не попадает ни в ответы API, ни в логи.
 *
 * Провижининг — ручной и в репозитории не автоматизирован: строку `MailAccount` вставляет
 * оператор, а в поле `secretEnc` обязана попасть строка от `encryptSecret()` из
 * `mail-crypto.ts` (не пароль в открытом виде). Ни API, ни скрипта добавления аккаунта нет;
 * если такой скрипт появится, он должен сам вызывать `encryptSecret()`, а не просить строку
 * «уже зашифрованной».
 */

export type MailKind = 'gmail' | 'icloud' | 'imap' | 'smtp';
// 'trash' — отдельная корзина почты: письмо лежит в ней, пока не удалено навсегда.
// Это не физическая папка источника, а состояние deletedAt у записи.
export type MailBox = 'inbox' | 'sent' | 'trash';

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
  /** Шифрование с первого байта (IMAPS, порт 993). Читается при подключении к IMAP. */
  secure: boolean;
  smtpHost: string;
  smtpPort: number;
  folders: MailSourceFolder[];
  /**
   * Пароли приложений провайдеры показывают группами («abcd efgh ijkl mnop» у Google,
   * «abcd-efgh-ijkl-mnop» у Apple), а для входа нужны слитно. Иначе самая частая ошибка
   * выглядит как «неверный пароль» при внешне правильном.
   *
   * Флаг читается в `credentials()`/`smtpCredentials()`. У Gmail и iCloud это верно (у них
   * пароль приложения — только буквы), у чужого сервера и у ключа релея (Brevo) пароль может
   * содержать дефис осмысленно, поэтому там флаг снят.
   */
  stripSeparators: boolean;
}

/**
 * Пресеты провайдеров. У Gmail писем «по папкам» нет: есть одно хранилище и метки, поэтому
 * читаем `[Gmail]/All Mail` (в нём всё, кроме спама и корзины), `[Gmail]/Spam` и
 * `[Gmail]/Trash` — и спам, и корзину показываем во «Входящих», как и договаривались,
 * отдельных папок у почты нет. Отправленные отсекаем по системной метке `\Sent`, поэтому
 * в All Mail отдельная папка не нужна.
 *
 * Корзину забираем не из любопытства: провайдеры удаляют её содержимое сами (Gmail — через
 * 30 дней), и это единственное место, где письмо может исчезнуть без нашего участия.
 * Черновики не забираем: неотправленный черновик — не письмо. Заметки Apple и Google тоже
 * не трогаем, хотя они и видны по IMAP отдельными папками.
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
      { path: '[Gmail]/Trash', specialUse: '\\Trash', box: 'inbox' },
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
      { path: 'Deleted Messages', specialUse: '\\Trash', box: 'inbox' },
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

/**
 * Строка аккаунта из БД (для внутреннего использования).
 *
 * Внутренний тип, а не публичный: здесь лежит `secretEnc` — шифртекст пароля. Наружу (в ответ
 * API) отдаётся только `MailAccountView`, а секрет достаётся исключительно через
 * `credentials()`/`smtpCredentials()`: `return account` из контроллера или `JSON.stringify`
 * этой строки унесут шифртекст клиенту.
 */
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
  constructor(private readonly prisma: PrismaService) {}

  /** Провайдер по виду аккаунта: неизвестный вид — это imap с явными хостами. */
  presetOf(kind: string): MailKindPreset {
    return MAIL_PRESETS[(kind as MailKind) in MAIL_PRESETS ? (kind as MailKind) : 'imap'];
  }

  async list(userId: string): Promise<MailAccountView[]> {
    const accounts = await this.prisma.mailAccount.findMany({
      where: { userId },
      orderBy: { createdAt: 'asc' },
    });
    if (!accounts.length) return [];

    // Числа по нашим двум папкам (их всего две, поэтому два запроса, а не группировка по всем).
    // Письмо, лежащее сразу в двух папках, считается в обеих — как и в ленте.
    const [inbox, sent] = await Promise.all([
      this.prisma.mailMessage.groupBy({
        by: ['accountId'],
        where: { userId, ...inBox('inbox'), deletedAt: null },
        _count: { _all: true },
      }),
      this.prisma.mailMessage.groupBy({
        by: ['accountId'],
        where: { userId, ...inBox('sent'), deletedAt: null },
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
    return { login: account.login, password: this.unwrapPassword(account.kind, account.secretEnc) };
  }

  /**
   * Креды отправки: у аккаунта со своим релеем они свои (Brevo), у остальных — те же,
   * что для приёма. Пустой пароль означает «отправка не настроена».
   */
  smtpCredentials(account: MailAccountRow): { login: string; password: string } {
    if (account.smtpLogin && account.smtpSecretEnc) {
      return { login: account.smtpLogin, password: this.unwrapPassword(account.kind, account.smtpSecretEnc) };
    }
    return { login: account.login, password: this.unwrapPassword(account.kind, account.secretEnc) };
  }

  /** Расшифровать секрет и, если провайдер так показывает пароль, убрать разделители. */
  private unwrapPassword(kind: string, secretEnc: string): string {
    const password = decryptSecret(secretEnc);
    if (!this.presetOf(kind).stripSeparators) return password;
    // Пробелы и дефисы в пароле приложения — только форматирование выдачи провайдера:
    // у Gmail это «abcd efgh ijkl mnop», у Apple «abcd-efgh-ijkl-mnop».
    return password.replace(/[\s-]+/g, '');
  }
}
