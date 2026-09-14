import { Injectable, Logger } from '@nestjs/common';
import { randomUUID } from 'crypto';
import MailComposer from 'nodemailer/lib/mail-composer';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { badRequest, notFound } from '../common/errors';
import { MailAccountsService, type MailAccountRow } from './mail-accounts.service';
import { MailIngestService, uidOfMessageId } from './mail-ingest.service';
import { parseMessage } from './mail-parse';
import { createSmtpTransport } from './mail-smtp';

/**
 * Отправка писем.
 *
 * Письмо отправляется через SMTP того аккаунта, с которого его пишут (пароль приложения
 * тот же, что и для IMAP), а его точная копия сразу сохраняется в «Исходящие» — теми же
 * байтами, что ушли получателю. Поэтому в интерфейсе письмо появляется мгновенно, а не
 * после следующей синхронизации.
 *
 * Копию на сервере аккаунта отдельно НЕ создаём: Gmail и iCloud сами сохраняют отправленное
 * через SMTP в свою папку «Отправленные». Второй APPEND дал бы там дубль. Наша копия и
 * серверная встречаются на следующем проходе синхронизации и схлопываются по Message-ID.
 */

/** Потолок размера письма: у Gmail предел 25 МБ на сообщение, у iCloud — 20 МБ. */
const MAX_MESSAGE_BYTES = 20 * 1024 * 1024;

/** Потолок вложений: у письма с двадцатью файлами вряд ли есть адресат, готовый их ждать. */
const MAX_ATTACHMENTS = 20;

export interface SendInput {
  accountId: string;
  to: string;
  cc?: string;
  subject?: string;
  text: string;
  /** Письмо, на которое отвечаем: оттуда берём Message-ID и References для треда. */
  inReplyToId?: string | null;
  /** Приложить файлы из хранилища (id записей дерева). */
  attachEntryIds?: string[];
}

export interface SendResult {
  /** id письма в «Исходящих». */
  id: string;
  messageId: string;
  accepted: string[];
  rejected: string[];
}

@Injectable()
export class MailSendService {
  private readonly logger = new Logger(MailSendService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly accounts: MailAccountsService,
    private readonly ingest: MailIngestService,
    private readonly s3: S3Service,
  ) {}

  /**
   * Собрать письмо в точные байты — до всякой отправки.
   *
   * Так у получателя и в «Исходящих» оказывается буквально одно и то же сообщение: если
   * сохранять копию пересборкой «по мотивам», она рано или поздно разойдётся с отправленной
   * (кодировки, границы MIME, переносы строк).
   */
  private async buildRaw(input: {
    from: { name: string; address: string };
    to: string[];
    cc: string[];
    subject: string;
    text: string;
    messageId: string;
    inReplyTo?: string | null;
    references?: string[];
    attachments: Array<{ filename: string; content: Buffer; contentType: string }>;
  }): Promise<Buffer> {
    const composer = new MailComposer({
      from: input.from,
      to: input.to,
      cc: input.cc.length ? input.cc : undefined,
      subject: input.subject,
      text: input.text,
      messageId: `<${input.messageId}>`,
      inReplyTo: input.inReplyTo ? `<${input.inReplyTo}>` : undefined,
      references: input.references?.length ? input.references.map((r) => `<${r}>`) : undefined,
      date: new Date(),
      attachments: input.attachments.map((a) => ({
        filename: a.filename,
        content: a.content,
        contentType: a.contentType,
      })),
    });
    return new Promise<Buffer>((resolve, reject) => {
      composer.compile().build((err, message) => (err ? reject(err) : resolve(message)));
    });
  }

  /** Отправить письмо и сохранить его копию в «Исходящие». */
  async send(userId: string, input: SendInput): Promise<SendResult> {
    const account = await this.accounts.require(userId, String(input.accountId ?? ''));
    if (!(account as MailAccountRow & { enabled: boolean }).enabled) {
      throw badRequest('аккаунт выключен — отправка с него недоступна', 'mail_account_disabled');
    }
    const to = parseAddressList(input.to);
    const cc = parseAddressList(input.cc ?? '');
    if (!to.length) throw badRequest('не указан получатель', 'mail_no_recipient');
    const text = String(input.text ?? '');
    if (!text.trim() && !(input.attachEntryIds ?? []).length) {
      throw badRequest('письмо пустое', 'mail_empty');
    }

    // Ответ: берём тред из исходного письма — иначе у получателя ответ повиснет отдельно.
    let inReplyTo: string | null = null;
    let references: string[] = [];
    const original = input.inReplyToId ? await this.prisma.mailMessage.findFirst({
      where: { id: input.inReplyToId, userId, deletedAt: null },
      select: { messageId: true, refs: true, inReplyTo: true },
    }) : null;
    if (input.inReplyToId && !original) throw notFound('mail message not found');
    if (original?.messageId) {
      inReplyTo = original.messageId;
      // References — цепочка треда по порядку и без повторов: одно и то же письмо приходит
      // и из References, и из In-Reply-To, и дубль в заголовке выглядит как поломка у клиента.
      const chain = [...(original.refs ?? []), ...(original.inReplyTo ? [original.inReplyTo] : []), original.messageId];
      references = [...new Set(chain.filter(Boolean))].slice(-20);
    }

    const attachments = await this.loadAttachments(userId, input.attachEntryIds ?? []);
    const messageId = `${randomUUID()}@${account.email.split('@')[1] ?? 'cloudlyru'}`;
    const raw = await this.buildRaw({
      from: { name: account.email, address: account.email },
      to,
      cc,
      subject: String(input.subject ?? '').trim() || '(без темы)',
      text,
      messageId,
      inReplyTo,
      references,
      attachments,
    });
    if (raw.length > MAX_MESSAGE_BYTES) {
      throw badRequest(
        `письмо получилось ${Math.round(raw.length / 1024 / 1024)} МБ — сервер столько не примет`,
        'mail_too_large',
      );
    }

    if (!account.smtpHost) {
      throw badRequest('у этого аккаунта отправка не настроена: письма он только принимает', 'mail_send_not_configured');
    }
    const smtp = this.accounts.smtpCredentials(account);
    const transport = createSmtpTransport({
      smtpHost: account.smtpHost,
      smtpPort: account.smtpPort,
      login: smtp.login,
      password: smtp.password,
    });
    let accepted: string[] = [];
    let rejected: string[] = [];
    try {
      const info = await transport.sendMail({
        envelope: { from: account.email, to: [...to, ...cc] },
        // Отправляем ровно те байты, которые сохраним: никакой пересборки на стороне транспорта
        raw,
      });
      accepted = (info.accepted ?? []).map(String);
      rejected = (info.rejected ?? []).map(String);
    } finally {
      transport.close();
    }

    // Сохраняем копию тем же путём, что и входящие: сырьё — Asset, вложения — файлы в «Почте».
    // Folder path «local:sent» — не папка IMAP, а пометка «это наша отправка»: синхронизация
    // потом встретит письмо на сервере и перепишет координаты на настоящие (дедуп по Message-ID).
    const stored = await this.ingest.ingest({
      userId,
      account,
      box: 'sent',
      folderPath: 'local:sent',
      // uid из Message-ID: он должен быть уникальным среди наших отправок и одинаковым при
      // повторной обработке того же письма
      uid: uidOfMessageId(messageId),
      uidValidity: 0n,
      source: raw,
      seen: true,
      flagged: false,
      emailId: null,
      threadId: null,
      receivedAt: new Date(),
    });

    const message = await this.prisma.mailMessage.findFirst({
      where: { accountId: account.id, messageId: messageId.replace(/^<|>$/g, '') },
      select: { id: true, messageId: true },
    });
    this.logger.log(
      `письмо ${messageId} отправлено с ${account.email}: принято ${accepted.length}, отклонено ${rejected.length}, копия ${stored}`,
    );
    return { id: message?.id ?? '', messageId, accepted, rejected };
  }

  /** Вложения из хранилища: читаем байты по sha256, имя берём из записи дерева. */
  private async loadAttachments(
    userId: string,
    entryIds: string[],
  ): Promise<Array<{ filename: string; content: Buffer; contentType: string }>> {
    const ids = [...new Set(entryIds)].slice(0, MAX_ATTACHMENTS);
    if (!ids.length) return [];
    const entries = await this.prisma.fileEntry.findMany({
      where: { id: { in: ids }, deletedAt: null },
      select: { id: true, name: true, asset: { select: { sha256: true, mime: true } } },
    });
    const out: Array<{ filename: string; content: Buffer; contentType: string }> = [];
    let total = 0;
    for (const entry of entries) {
      // Проверку владельца делает вызывающий: сюда попадают id из письма, а письмо уже своё
      const content = await this.s3.getObjectBytes(S3Service.assetKey(entry.asset.sha256));
      total += content.length;
      if (total > MAX_MESSAGE_BYTES) throw badRequest('вложения не помещаются в письмо', 'mail_too_large');
      out.push({ filename: entry.name, content, contentType: entry.asset.mime });
    }
    void userId;
    return out;
  }

  /**
   * Заготовка ответа или пересылки: получатели, тема и цитата исходного письма.
   *
   * Считаем на сервере, а не в браузере: правила тут неочевидные (reply-all не должен
   * подставлять себя в получатели, тема не должна накапливать «Re: Re:», цитата собирается
   * из текста письма) и должны быть одинаковыми везде, где есть кнопка «ответить».
   */
  async replyContext(userId: string, id: string, mode: 'reply' | 'replyAll' | 'forward') {
    const message = await this.prisma.mailMessage.findFirst({
      where: { id, userId, deletedAt: null },
      select: {
        id: true,
        box: true,
        subject: true,
        fromName: true,
        fromAddr: true,
        toAddrs: true,
        ccAddrs: true,
        sortAt: true,
        account: { select: { id: true, email: true } },
        attachments: { where: { inline: false }, select: { entryId: true, filename: true, size: true } },
      },
    });
    if (!message) throw notFound('mail message not found');

    const self = message.account.email.toLowerCase();
    const baseSubject = (message.subject ?? '').replace(/^((re|fwd?|fw|ответ|пересл)\s*(\[\d+\])?\s*:\s*)+/i, '').trim();
    const from = message.fromAddr ?? '';
    const quoteHeader = `${new Date(message.sortAt).toLocaleString('ru-RU')}, ${message.fromName || from}:`;
    const quoted = await this.quotedText(userId, id);

    if (mode === 'forward') {
      return {
        accountId: message.account.id,
        to: '',
        cc: '',
        subject: `Fwd: ${baseSubject}`.trim(),
        body: `\n\n--- пересланное письмо ---\n${quoteHeader}\n${quoted}`,
        inReplyToId: null,
        attachments: message.attachments,
      };
    }

    // «Ответить» — только отправителю; «ответить всем» — ещё и остальным получателям.
    // Себя в списке быть не должно: иначе копия ответа придёт себе же.
    const others = (mode === 'replyAll' ? [...message.toAddrs, ...message.ccAddrs] : [])
      .map((a) => a.trim())
      .filter((a) => a && a.toLowerCase() !== self);
    const to = from && from.toLowerCase() !== self ? [from, ...others] : others;
    return {
      accountId: message.account.id,
      to: [...new Set(to)].join(', '),
      cc: '',
      subject: `Re: ${baseSubject}`.trim(),
      body: `\n\n${quoteHeader}\n${quoted.split('\n').map((l) => `> ${l}`).join('\n')}`,
      inReplyToId: message.id,
      attachments: [],
    };
  }

  /** Текст исходного письма для цитаты: из превью письма (оно и есть начало тела). */
  private async quotedText(userId: string, id: string): Promise<string> {
    const row = await this.prisma.mailMessage.findFirst({
      where: { id, userId },
      select: { bodyText: true, rawAsset: { select: { sha256: true } } },
    });
    if (!row) return '';
    // Превью короткое (2 КБ) — для цитаты этого мало, поэтому пробуем разобрать само письмо
    try {
      const source = await this.s3.getObjectBytes(S3Service.assetKey(row.rawAsset.sha256));
      const parsed = await parseMessage(source);
      return (parsed.bodyText || '').trim() || (row.bodyText ?? '');
    } catch {
      return (row.bodyText ?? '').trim();
    }
  }
}

/** Список адресов из строки «a@b, Имя <c@d>»: пустые и мусорные отбрасываем. */
export function parseAddressList(raw: string): string[] {
  return String(raw ?? '')
    .split(/[,;\n]/)
    .map((s) => {
      const angle = /<([^>]+)>/.exec(s);
      return (angle ? angle[1] : s).trim();
    })
    .filter((s) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s));
}


