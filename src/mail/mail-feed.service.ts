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

/**
 * Условие «письмо лежит в папке» для сырого SQL.
 * Корзина почты — это не папка из box/alsoBoxes, а состояние `deletedAt`, поэтому у неё
 * своё условие; обычные папки фильтруются и по принадлежности, и по «не в корзине».
 */
function boxConditionSql(box: MailBox): Prisma.Sql {
  if (box === 'trash') return Prisma.sql`"deletedAt" IS NOT NULL`;
  return Prisma.sql`"deletedAt" IS NULL AND ${inBoxSql(box)}`;
}

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
        WHERE "userId" = ${userId} AND ${boxConditionSql(box as MailBox)}
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
    // Корзина сортируется по времени удаления, обычные папки — по дате письма.
    const headOrder = box === 'trash' ? Prisma.sql`"deletedAt" DESC, id DESC` : Prisma.sql`"sortAt" DESC, id DESC`;
    const listOrder = box === 'trash' ? Prisma.sql`m."deletedAt" DESC, m.id DESC` : Prisma.sql`m."sortAt" DESC, m.id DESC`;

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
        WHERE "userId" = ${userId} AND ${boxConditionSql(box as MailBox)}
          AND (${acc}::text IS NULL OR "accountId" = ${acc})
      ),
      heads AS (
        SELECT id FROM (
          SELECT id,
            row_number() OVER (
              PARTITION BY COALESCE("threadKey", id)
              ORDER BY ${headOrder}
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
      ORDER BY ${listOrder}
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
    // В корзине индекс месяцев считается по времени удаления (совпадает с порядком ленты).
    const timeCol = box === 'trash' ? Prisma.sql`"deletedAt"` : Prisma.sql`"sortAt"`;
    const orderBy = box === 'trash' ? Prisma.sql`"deletedAt" DESC, id DESC` : Prisma.sql`"sortAt" DESC, id DESC`;
    const rows = await this.prisma.$queryRaw<Array<{ month: string; n: bigint | number }>>(Prisma.sql`
      WITH heads AS (
        SELECT t FROM (
          SELECT ${timeCol} AS t,
            row_number() OVER (
              PARTITION BY COALESCE("threadKey", id)
              ORDER BY ${orderBy}
            ) AS rn
          FROM "MailMessage"
          WHERE "userId" = ${userId} AND ${boxConditionSql(box as MailBox)}
            AND (${accountId ?? null}::text IS NULL OR "accountId" = ${accountId ?? null})
        ) h
        WHERE rn = 1
      )
      SELECT to_char(t, 'YYYY-MM') AS month, count(*)::int AS n
      FROM heads
      GROUP BY 1
      ORDER BY 1 DESC
    `);
    return rows.map((r) => ({ month: r.month, count: Number(r.n) }));
  }

  /** Письмо целиком: заголовки, превью тела и список частей (доступно и из корзины). */
  async get(userId: string, id: string): Promise<MailMessageView> {
    const row = await this.prisma.mailMessage.findFirst({
      where: { id, userId },
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
   *
   * `asText` — просьба клиента отдать текстовую версию даже у письма с разметкой: у части
   * рассылок вёрстка нечитаема ни в одном движке, и текстовый вариант — единственный выход.
   */
  async body(
    userId: string,
    id: string,
    allowRemote: boolean,
    asText = false,
  ): Promise<{ html: string; blockedRemote: number; kind: 'html' | 'text' }> {
    const row = await this.prisma.mailMessage.findFirst({
      where: { id, userId },
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

    if (!asText && parsed?.html && htmlWithinLimit(parsed.html)) {
      const { html, blockedRemote } = sanitizeMailHtml(parsed.html, allowRemote);
      return { html, blockedRemote, kind: 'html' };
    }
    return { html: textToHtml(parsed?.bodyText || row.bodyText || ''), blockedRemote: 0, kind: 'text' };
  }

  /** Сырой .eml: ключ объекта для отдачи файлом (содержимое письма как оно пришло). */
  async rawKey(userId: string, id: string): Promise<{ key: string; name: string }> {
    const row = await this.prisma.mailMessage.findFirst({
      where: { id, userId },
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
   * Удалить письмо: soft, в отдельную корзину почты. Вложения остаются при письме и в
   * файловую корзину не попадают — это и есть «отдельная корзина для почты». На сервере
   * аккаунта ничего не меняется: синхронизация в этой фазе только читает.
   */
  async deleteMessage(userId: string, id: string): Promise<{ ok: true }> {
    const res = await this.prisma.mailMessage.updateMany({
      where: { id, userId, deletedAt: null },
      data: { deletedAt: new Date() },
    });
    if (!res.count) throw notFound('mail message not found');
    return { ok: true };
  }

  /** Вернуть письмо из корзины почты: вложения никуда не девались, письмо снова в ленте. */
  async restoreMessage(userId: string, id: string): Promise<{ ok: true }> {
    const res = await this.prisma.mailMessage.updateMany({
      where: { id, userId, deletedAt: { not: null } },
      data: { deletedAt: null },
    });
    if (!res.count) throw notFound('mail message not found');
    return { ok: true };
  }

  /** Удалить письмо навсегда: только из корзины, вместе с вложениями и сырым .eml. */
  async purgeMessage(userId: string, id: string): Promise<{ ok: true; purged: number }> {
    const purged = await this.hardDelete(userId, [id]);
    if (!purged) throw notFound('mail message not found');
    return { ok: true, purged };
  }

  /** Очистить корзину почты целиком (или только старше N дней — для уборки по расписанию). */
  async purgeTrash(userId: string, olderThanDays?: number): Promise<{ purged: number }> {
    const days = Number.isFinite(olderThanDays) ? Math.max(0, Number(olderThanDays)) : undefined;
    const cutoff = days === undefined ? undefined : new Date(Date.now() - days * 24 * 60 * 60 * 1000);
    const rows = await this.prisma.mailMessage.findMany({
      where: { userId, deletedAt: { not: null }, ...(cutoff ? { deletedAt: { lt: cutoff } } : {}) },
      select: { id: true },
    });
    return { purged: await this.hardDelete(userId, rows.map((r) => r.id)) };
  }

  /**
   * Физическое удаление писем: сами письма, их вложения (записи дерева в скрытой зоне MAIL)
   * и осиротевшие объекты S3 (сырьё .eml и содержимое вложений, если на них больше нет ссылок).
   * Только письма из корзины: живое письмо этим путём не удалить.
   */
  private async hardDelete(userId: string, ids: string[]): Promise<number> {
    if (!ids.length) return 0;
    const rows = await this.prisma.mailMessage.findMany({
      where: { id: { in: ids }, userId, deletedAt: { not: null } },
      select: {
        id: true,
        rawAsset: { select: { id: true, sha256: true } },
        attachments: {
          select: { entry: { select: { id: true, asset: { select: { id: true, sha256: true } } } } },
        },
      },
    });
    if (!rows.length) return 0;
    const entryIds = rows.flatMap((r) => r.attachments.map((a) => a.entry.id));
    const assets = rows.flatMap((r) => [r.rawAsset, ...r.attachments.map((a) => a.entry.asset)]);
    await this.prisma.$transaction(
      async (tx) => {
        if (entryIds.length) await tx.fileEntry.deleteMany({ where: { id: { in: entryIds } } });
        await tx.mailMessage.deleteMany({ where: { id: { in: rows.map((r) => r.id) } } });
      },
      { timeout: 120_000, maxWait: 15_000 },
    );
    // Объекты S3 чистим после коммита и только у реально осиротевших ассетов: на тот же sha
    // может ссылаться обычный файл пользователя (дедуп), и его байты трогать нельзя.
    for (const a of assets) {
      const res = await this.prisma.asset.deleteMany({ where: { id: a.id, entries: { none: {} }, mailRaw: { none: {} } } });
      if (res.count > 0) {
        await this.s3.deleteObjects([S3Service.assetKey(a.sha256)]).catch((e: Error) => {
          this.logger.warn(`S3 не удалил объект письма ${a.sha256}: ${e.message}`);
        });
      }
    }
    return rows.length;
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
