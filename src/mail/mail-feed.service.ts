import { Injectable, Logger } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { notFound } from '../common/errors';
import { S3Service } from '../s3/s3.service';
import { parseMessage } from './mail-parse';
import { htmlWithinLimit, sanitizeMailHtml, textToHtml } from './mail-html';
import { inBox, inBoxSql } from './mail-scope';
import type { MailBox } from './mail-accounts.service';

/**
 * Чтение почты для интерфейса: две папки, бесконечная лента по смещению и индекс по месяцам.
 *
 * Ровно та же схема, что у ленты «Медиа» (`MediaFeedService`): клиент знает общее число,
 * по нему считает высоту скролла целиком, а данные догружает куском видимой области.
 * OFFSET вместо keyset-курсора выбран по той же причине: он умеет прыгнуть в любую точку,
 * а это и нужно ползунку по датам. На десятках тысяч писем это дешево (индекс
 * (userId, box, sortAt DESC, id DESC) отдаёт и порядок, и фильтр), на миллионах — уже нет.
 */

/** Сколько символов тела отдаём в списке: хватает на две строки превью. */
const PREVIEW_CHARS = 200;
/** Потолок одного среза ленты. */
export const MAIL_RANGE_MAX = 500;

export interface MailListItem {
  id: string;
  box: string;
  accountId: string;
  accountEmail: string;
  subject: string | null;
  fromName: string | null;
  fromAddr: string | null;
  preview: string;
  sortAt: string;
  seen: boolean;
  flagged: boolean;
  hasAttachments: boolean;
  size: number;
  /** Сколько писем в цепочке (1 — одиночное письмо). */
  threadCount: number;
}

export interface MailAttachmentView {
  id: string;
  entryId: string;
  filename: string;
  name: string;
  mime: string;
  size: number;
  inline: boolean;
  contentId: string | null;
}

export interface MailMessageView extends Omit<MailListItem, 'preview'> {
  toAddrs: string[];
  ccAddrs: string[];
  replyTo: string | null;
  messageId: string | null;
  inReplyTo: string | null;
  refs: string[];
  sentAt: string | null;
  receivedAt: string;
  bodyText: string | null;
  attachments: MailAttachmentView[];
}

@Injectable()
export class MailFeedService {
  private readonly logger = new Logger(MailFeedService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
  ) {}

  /** Общее число цепочек в папке — по нему клиент считает высоту скролла. */
  async count(userId: string, box: string, accountId?: string | null): Promise<number> {
    const rows = await this.prisma.$queryRaw<Array<{ n: number }>>(Prisma.sql`
      SELECT count(*)::int AS n FROM (
        SELECT 1
        FROM "MailMessage"
        WHERE "userId" = ${userId} AND "deletedAt" IS NULL AND ${inBoxSql(box as MailBox)}
          AND (${accountId ?? null}::text IS NULL OR "accountId" = ${accountId ?? null})
        GROUP BY COALESCE("threadKey", id)
      ) g
    `);
    return Number(rows[0]?.n ?? 0);
  }

  /**
   * Срез ленты по абсолютному смещению — но уже по цепочкам, а не по письмам.
   *
   * Каждая строка — самая свежая письмо цепочки (`row_number` внутри группы по threadKey),
   * плюс сколько писем в цепочке. Письмо без threadKey — цепочка из одного письма, поэтому
   * группируем по COALESCE(threadKey, id), чтобы одиночные письма не слиплись в одну кучу.
   * Порядок — от свежих к старым, как и прежде.
   */
  async range(userId: string, box: string, offset = 0, limit = 100, accountId?: string | null): Promise<MailListItem[]> {
    const take = Math.min(Math.max(Math.floor(limit) || 1, 1), MAIL_RANGE_MAX);
    const skip = Math.max(0, Math.floor(offset) || 0);
    const acc = accountId ?? null;

    const rows = await this.prisma.$queryRaw<
      Array<{
        id: string;
        box: string;
        accountId: string;
        accountEmail: string;
        subject: string | null;
        fromName: string | null;
        fromAddr: string | null;
        bodyText: string | null;
        sortAt: Date;
        seen: boolean;
        flagged: boolean;
        hasAttachments: boolean;
        size: number;
        threadCount: number;
      }>
    >(Prisma.sql`
      WITH base AS (
        SELECT *
        FROM "MailMessage"
        WHERE "userId" = ${userId} AND "deletedAt" IS NULL AND ${inBoxSql(box as MailBox)}
          AND (${acc}::text IS NULL OR "accountId" = ${acc})
      ),
      heads AS (
        SELECT id FROM (
          SELECT id,
            row_number() OVER (
              PARTITION BY COALESCE("threadKey", id)
              ORDER BY "sortAt" DESC, id DESC
            ) AS rn
          FROM base
        ) h
        WHERE rn = 1
      ),
      grouped AS (
        SELECT COALESCE("threadKey", id) AS grp, count(*)::int AS cnt
        FROM base
        GROUP BY 1
      )
      SELECT
        m.id, m.box, m."accountId", m.subject, m."fromName", m."fromAddr",
        m."bodyText", m."sortAt", m.seen, m.flagged, m."hasAttachments", m.size,
        a.email AS "accountEmail",
        g.cnt AS "threadCount"
      FROM "MailMessage" m
      JOIN "MailAccount" a ON a.id = m."accountId"
      JOIN grouped g ON g.grp = COALESCE(m."threadKey", m.id)
      WHERE m.id IN (SELECT id FROM heads)
      ORDER BY m."sortAt" DESC, m.id DESC
      LIMIT ${take} OFFSET ${skip}
    `);

    return rows.map((r) => ({
      id: r.id,
      box: r.box,
      accountId: r.accountId,
      accountEmail: r.accountEmail,
      subject: r.subject,
      fromName: r.fromName,
      fromAddr: r.fromAddr,
      preview: previewOf(r.bodyText),
      sortAt: r.sortAt.toISOString(),
      seen: r.seen,
      flagged: r.flagged,
      hasAttachments: r.hasAttachments,
      size: r.size,
      threadCount: Number(r.threadCount),
    }));
  }

  /**
   * Индекс по месяцам для подписи у ползунка: строка на месяц в порядке ленты.
   * Считаем по цепочкам (по их голове), чтобы высота скролла совпадала со списком.
   */
  async months(userId: string, box: string, accountId?: string | null): Promise<Array<{ month: string; count: number }>> {
    const rows = await this.prisma.$queryRaw<Array<{ month: string; n: bigint | number }>>(Prisma.sql`
      WITH heads AS (
        SELECT "sortAt" FROM (
          SELECT "sortAt",
            row_number() OVER (
              PARTITION BY COALESCE("threadKey", id)
              ORDER BY "sortAt" DESC, id DESC
            ) AS rn
          FROM "MailMessage"
          WHERE "userId" = ${userId} AND ${inBoxSql(box as MailBox)} AND "deletedAt" IS NULL
            AND (${accountId ?? null}::text IS NULL OR "accountId" = ${accountId ?? null})
        ) h
        WHERE rn = 1
      )
      SELECT to_char("sortAt", 'YYYY-MM') AS month, count(*)::int AS n
      FROM heads
      GROUP BY 1
      ORDER BY 1 DESC
    `);
    return rows.map((r) => ({ month: r.month, count: Number(r.n) }));
  }

  /** Письмо целиком: заголовки, превью тела и список частей. */
  async get(userId: string, id: string): Promise<MailMessageView> {
    const row = await this.prisma.mailMessage.findFirst({
      where: { id, userId, deletedAt: null },
      select: {
        id: true,
        box: true,
        accountId: true,
        subject: true,
        fromName: true,
        fromAddr: true,
        toAddrs: true,
        ccAddrs: true,
        replyTo: true,
        messageId: true,
        inReplyTo: true,
        refs: true,
        threadKey: true,
        sentAt: true,
        receivedAt: true,
        sortAt: true,
        bodyText: true,
        seen: true,
        flagged: true,
        hasAttachments: true,
        size: true,
        account: { select: { email: true } },
        attachments: {
          orderBy: { partIndex: 'asc' },
          select: {
            id: true,
            entryId: true,
            filename: true,
            mime: true,
            size: true,
            inline: true,
            contentId: true,
            entry: { select: { name: true } },
          },
        },
      },
    });
    if (!row) throw notFound('mail message not found');
    // Сколько писем в цепочке этого письма — для бейджа при просмотре (1 — одиночное).
    const threadCount = await this.prisma.mailMessage.count({
      where: row.threadKey ? { userId, threadKey: row.threadKey, deletedAt: null } : { id: row.id },
    });
    return {
      id: row.id,
      box: row.box,
      accountId: row.accountId,
      accountEmail: row.account.email,
      subject: row.subject,
      fromName: row.fromName,
      fromAddr: row.fromAddr,
      toAddrs: row.toAddrs,
      ccAddrs: row.ccAddrs,
      replyTo: row.replyTo,
      messageId: row.messageId,
      inReplyTo: row.inReplyTo,
      refs: row.refs,
      sentAt: row.sentAt ? row.sentAt.toISOString() : null,
      receivedAt: row.receivedAt.toISOString(),
      sortAt: row.sortAt.toISOString(),
      bodyText: row.bodyText,
      seen: row.seen,
      flagged: row.flagged,
      hasAttachments: row.hasAttachments,
      size: row.size,
      threadCount,
      attachments: row.attachments.map((a) => ({
        id: a.id,
        entryId: a.entryId,
        filename: a.filename,
        name: a.entry.name,
        mime: a.mime,
        size: a.size,
        inline: a.inline,
        contentId: a.contentId,
      })),
    };
  }

  /**
   * Тело письма для показа: HTML (почищенный) либо текст в обёртке.
   *
   * Разбираем сырое письмо из S3 при каждом открытии: тело в БД не храним, чтобы не держать
   * две версии одного и того же и не расходиться с .eml, который и есть источник истины.
   * Разбор одного письма — миллисекунды; тяжёлые письма с картинками в data: ограничены
   * потолком размера (иначе ответ раздувается в разы).
   */
  async body(userId: string, id: string, allowRemote: boolean): Promise<{ html: string; blockedRemote: number; kind: 'html' | 'text' }> {
    const row = await this.prisma.mailMessage.findFirst({
      where: { id, userId, deletedAt: null },
      select: { id: true, bodyText: true, rawAsset: { select: { sha256: true } } },
    });
    if (!row) throw notFound('mail message not found');

    let parsed: { html: string | null; bodyText: string } | null = null;
    try {
      const source = await this.s3.getObjectBytes(S3Service.assetKey(row.rawAsset.sha256));
      const full = await parseMessage(source);
      parsed = { html: full.html, bodyText: full.bodyText };
    } catch (e) {
      // Содержимого нет в хранилище или письмо не разобралось — отдаём превью из БД:
      // пустой экран тут хуже, чем текст без оформления.
      this.logger.warn(`тело письма ${id} не разобрано: ${(e as Error).message}`);
    }

    if (parsed?.html && htmlWithinLimit(parsed.html)) {
      const { html, blockedRemote } = sanitizeMailHtml(parsed.html, allowRemote);
      return { html, blockedRemote, kind: 'html' };
    }
    return { html: textToHtml(parsed?.bodyText || row.bodyText || ''), blockedRemote: 0, kind: 'text' };
  }

  /** Сырой .eml: ключ объекта для отдачи файлом (содержимое письма как оно пришло). */
  async rawKey(userId: string, id: string): Promise<{ key: string; name: string }> {
    const row = await this.prisma.mailMessage.findFirst({
      where: { id, userId, deletedAt: null },
      select: { subject: true, rawAsset: { select: { sha256: true } } },
    });
    if (!row) throw notFound('mail message not found');
    const subject = (row.subject ?? 'message').replace(/[\\/:*?"<>|]/g, ' ').trim().slice(0, 80);
    return { key: S3Service.assetKey(row.rawAsset.sha256), name: `${subject || 'message'}.eml` };
  }

  /**
   * Часть письма по её id (инлайн-картинка тела или вложение): id записи дерева и mime,
   * чтобы ручка отдала файл теми же механизмами, что и обычные файлы.
   */
  async attachment(userId: string, messageId: string, attachmentId: string): Promise<MailAttachmentView> {
    const row = await this.prisma.mailAttachment.findFirst({
      where: { id: attachmentId, messageId, message: { userId } },
      select: {
        id: true,
        entryId: true,
        filename: true,
        mime: true,
        size: true,
        inline: true,
        contentId: true,
        entry: { select: { name: true } },
      },
    });
    if (!row) throw notFound('attachment not found');
    return {
      id: row.id,
      entryId: row.entryId,
      filename: row.filename,
      name: row.entry.name,
      mime: row.mime,
      size: row.size,
      inline: row.inline,
      contentId: row.contentId,
    };
  }

  /** Отметить прочитанным/непрочитанным (локально; сервер не трогаем — это фаза чистки). */
  async setSeen(userId: string, id: string, seen: boolean): Promise<{ ok: true; seen: boolean }> {
    const res = await this.prisma.mailMessage.updateMany({ where: { id, userId, deletedAt: null }, data: { seen } });
    if (!res.count) throw notFound('mail message not found');
    return { ok: true, seen };
  }

  /** Флаг «важное» — единственная метка, которую мы себе позволяем. */
  async setFlagged(userId: string, id: string, flagged: boolean): Promise<{ ok: true; flagged: boolean }> {
    const res = await this.prisma.mailMessage.updateMany({ where: { id, userId, deletedAt: null }, data: { flagged } });
    if (!res.count) throw notFound('mail message not found');
    return { ok: true, flagged };
  }

  /** Сколько непрочитанных — для значка раздела. */
  async unread(userId: string): Promise<{ inbox: number; sent: number }> {
    const [inbox, sent] = await Promise.all([
      this.prisma.mailMessage.count({ where: { userId, ...inBox('inbox'), deletedAt: null, seen: false } }),
      this.prisma.mailMessage.count({ where: { userId, ...inBox('sent'), deletedAt: null, seen: false } }),
    ]);
    return { inbox, sent };
  }

  /**
   * Удалить письмо: soft, вместе с его вложениями — в общую с файлами корзину.
   *
   * Вложения удаляются тем же моментом, а не отдельным правилом: файл без письма в скрытой
   * папке не нужен никому, а после восстановления письма он возвращается на место. Прямые
   * ручки файлов этого сделать не могут — они такие записи намеренно не трогают.
   *
   * Флаги на сервере аккаунта не меняются: синхронизация в этой фазе только читает.
   */
  async deleteMessage(userId: string, id: string): Promise<{ ok: true }> {
    const message = await this.prisma.mailMessage.findFirst({
      where: { id, userId, deletedAt: null },
      select: { id: true, attachments: { select: { entryId: true } } },
    });
    if (!message) throw notFound('mail message not found');
    await this.softDeleteMessages([message]);
    return { ok: true };
  }

  /** Общий код удаления: письма плюс их вложения (одной транзакцией — не бывает половины). */
  private async softDeleteMessages(messages: Array<{ id: string; attachments: Array<{ entryId: string }> }>): Promise<void> {
    const at = new Date();
    const entryIds = messages.flatMap((m) => m.attachments.map((a) => a.entryId));
    await this.prisma.$transaction(async (tx) => {
      await tx.mailMessage.updateMany({ where: { id: { in: messages.map((m) => m.id) } }, data: { deletedAt: at } });
      if (entryIds.length) {
        await tx.fileEntry.updateMany({ where: { id: { in: entryIds }, deletedAt: null }, data: { deletedAt: at } });
      }
    });
  }

  /**
   * Вернуть письмо из корзины вместе с вложениями.
   *
   * Вложения возвращаем только те, что ушли вместе с письмом (в пределах секунды от его
   * отметки): если файл удалили раньше отдельно, воскрешать его нельзя — иначе из корзины
   * возвращалось бы то, чего пользователь не просил.
   */
  async restoreMessage(userId: string, id: string): Promise<{ ok: true }> {
    const message = await this.prisma.mailMessage.findFirst({
      where: { id, userId, deletedAt: { not: null } },
      select: { id: true, deletedAt: true, attachments: { select: { entryId: true } } },
    });
    if (!message) throw notFound('mail message not found');
    const cutoff = new Date((message.deletedAt as Date).getTime() - 1000);
    const entryIds = message.attachments.map((a) => a.entryId);
    await this.prisma.$transaction(async (tx) => {
      await tx.mailMessage.update({ where: { id }, data: { deletedAt: null } });
      if (entryIds.length) {
        await tx.fileEntry.updateMany({
          where: { id: { in: entryIds }, deletedAt: { gte: cutoff } },
          data: { deletedAt: null },
        });
      }
    });
    return { ok: true };
  }
}

/** Превью: тело письма в одну строку, без переносов. */
function previewOf(bodyText: string | null): string {
  if (!bodyText) return '';
  const line = bodyText
    .replace(/[ \t\u00a0]+/g, ' ')
    .split('\n')
    .map((s) => s.trim())
    .filter(Boolean)
    .join(' · ');
  return line.length > PREVIEW_CHARS ? line.slice(0, PREVIEW_CHARS) : line;
}
