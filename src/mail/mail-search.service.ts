import { Injectable } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { badRequest } from '../common/errors';
import { previewOf } from './mail-parse';
import { boxConditionSql } from './mail-scope';
import type { MailListItem } from './mail-feed.service';
import type { MailBox } from './mail-accounts.service';

/**
 * Поиск по почте: полнотекстовый, по всему телу письма.
 *
 * Почему так, а не «пробежать по .eml»: полного тела в БД нет (там только превью в 2000
 * символов), а само письмо лежит в S3. Искать перебором означало бы скачать и разобрать весь
 * архив на каждый запрос. Поэтому текст для поиска хранится в `MailMessage.searchText`
 * (заголовки и полное тело) и ищется GIN-индексом; письма, сохранённые до появления поиска,
 * добирает фоновый проход (`mail-index.service.ts`), а до его конца результаты неполные —
 * поэтому в ответе есть `pending`.
 *
 * Порядок выдачи — по дате, от свежих к старым: так решил владелец. Ранжирование по
 * релевантности (`ts_rank_cd`) сознательно не используется, поэтому в ответе нет ни счёта
 * релевантности, ни подсветки совпадений.
 */

/**
 * Выражение поискового вектора — ОДНО на весь сервис.
 *
 * Оно обязано совпадать символ в символ с выражением индекса `MailMessage_search_idx`
 * (миграция 20260917140000_mail_search_text). Postgres узнаёт индекс по выражению запроса:
 * разойдётся хоть на `coalesce` — индекс останется лежать мёртвым, а поиск молча пойдёт
 * перебором всех писем пользователя. Поэтому выражение вынесено в константу, а не набрано
 * заново в каждом запросе.
 *
 * Конфигурация `russian` одна на индекс и на запрос: она глобит и латиницу (invoice → invoic),
 * но одинаково с обеих сторон, поэтому английские слова ищутся, а адреса и домены остаются
 * цельными токенами (`ivan@example.com`).
 */
const SEARCH_VECTOR_SQL = Prisma.sql`to_tsvector('russian', coalesce("searchText", ''))`;

/**
 * Запрос поиска в терминах tsquery. `websearch_to_tsquery` разбирает то, что человек и правда
 * печатает: кавычки — фраза, `OR` — альтернатива, `-слово` — исключение. Мусорный ввод
 * (одни знаки препинания) даёт пустой tsquery: он не ошибка и ни с чем не совпадает,
 * поэтому в таком случае честно возвращается пустая выдача.
 */
const SEARCH_QUERY_SQL = (q: string): Prisma.Sql => Prisma.sql`websearch_to_tsquery('russian', ${q})`;

/** Потолок одной страницы выдачи. Клиент просит 50 — меньше и потолка, и веса строки. */
export const MAIL_SEARCH_MAX = 50;

/** Границы запроса: короче двух символов искать нечего, длиннее — уже не запрос, а вставка. */
const MIN_QUERY_CHARS = 2;
const MAX_QUERY_CHARS = 200;

/** Ответ ручки: страница выдачи, сколько всего нашлось и сколько писем ещё не проиндексировано. */
export interface MailSearchResult {
  total: number;
  items: MailListItem[];
  /** Письма папки, по которым поиск ещё не работает (бэкфилл индекса не дошёл). */
  pending: number;
}

/** Строка выдачи так, как её вернул SQL: до преобразования в `MailListItem`. */
interface SearchRow {
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
  threadKey: string | null;
}

@Injectable()
export class MailSearchService {
  constructor(private readonly prisma: PrismaService) {}

  /**
   * Найти письма папки [box] по запросу [q].
   *
   * Область поиска — ровно та папка, которую смотрит пользователь: во «Входящих» ищутся
   * входящие, в «Исходящих» — исходящие, в «Корзине» — удалённые. Это поведение владельца,
   * и оно же снимает вопрос «почему в выдаче письмо из другой папки».
   *
   * Побочно: ни `searchText`, ни `bodyText` в ответ не попадают — строка выдачи весит столько
   * же, сколько строка ленты.
   */
  async search(
    userId: string,
    opts: { q: string; box: string; accountId?: string | null; offset?: number; limit?: number },
  ): Promise<MailSearchResult> {
    const q = normalizeQuery(opts.q);
    const box = opts.box as MailBox;
    const take = Math.min(Math.max(Math.floor(opts.limit ?? MAIL_SEARCH_MAX) || 1, 1), MAIL_SEARCH_MAX);
    const skip = Math.max(0, Math.floor(opts.offset ?? 0) || 0);
    const acc = opts.accountId ?? null;

    // Общее условие выборки: пользователь, папка и (необязательно) аккаунт. Одно на все
    // запросы ниже намеренно: счётчик, страница и хвост папки обязаны считаться по одной
    // и той же выборке, иначе «нашлось 300» не сойдётся с тем, что листается.
    const scope = Prisma.sql`m."userId" = ${userId} AND ${boxConditionSql(box)} AND (${acc}::text IS NULL OR m."accountId" = ${acc})`;
    const match = Prisma.sql`${SEARCH_VECTOR_SQL} @@ ${SEARCH_QUERY_SQL(q)}`;

    const [rows, totalRows, pendingRows] = await Promise.all([
      this.prisma.$queryRaw<SearchRow[]>(Prisma.sql`
        SELECT m.id, m.box, m."accountId", m.subject, m."fromName", m."fromAddr", m."bodyText",
               m."threadKey", m."sortAt", m.seen, m.flagged, m."hasAttachments", m.size,
               a.email AS "accountEmail"
        FROM "MailMessage" m
        JOIN "MailAccount" a ON a.id = m."accountId"
        WHERE ${scope} AND ${match}
        ORDER BY m."sortAt" DESC, m.id DESC
        LIMIT ${take} OFFSET ${skip}
      `),
      this.prisma.$queryRaw<Array<{ n: number }>>(Prisma.sql`
        SELECT count(*)::int AS n FROM "MailMessage" m WHERE ${scope} AND ${match}
      `),
      // Письма, по которым поиска ещё нет: они не находятся, и без этой цифры «поиск не видит
      // старое письмо» выглядит как поломка поиска, а не как незаконченный бэкфилл.
      this.prisma.$queryRaw<Array<{ n: number }>>(Prisma.sql`
        SELECT count(*)::int AS n FROM "MailMessage" m
        WHERE m."userId" = ${userId} AND ${boxConditionSql(box)} AND m."searchIndexedAt" IS NULL
      `),
    ]);

    // Счётчики цепочек — одним запросом на всю страницу. Так же, как в ленте, цепочка считается
    // внутри папки: иначе один и тот же бейдж означал бы в списке и в выдаче поиска разное.
    const threadKeys = [...new Set(rows.map((r) => r.threadKey).filter((k): k is string => Boolean(k)))];
    const threadCounts = threadKeys.length
      ? await this.prisma.$queryRaw<Array<{ threadKey: string; n: number }>>(Prisma.sql`
          SELECT m."threadKey", count(*)::int AS n
          FROM "MailMessage" m
          WHERE m."userId" = ${userId} AND ${boxConditionSql(box)}
            AND m."threadKey" IN (${Prisma.join(threadKeys)})
          GROUP BY 1
        `)
      : [];
    const threads = new Map(threadCounts.map((t) => [t.threadKey, Number(t.n)]));

    return {
      total: Number(totalRows[0]?.n ?? 0),
      pending: Number(pendingRows[0]?.n ?? 0),
      items: rows.map((r) => ({
        id: r.id,
        box: r.box,
        accountId: r.accountId,
        accountEmail: r.accountEmail,
        subject: r.subject,
        fromName: r.fromName,
        fromAddr: r.fromAddr,
        // Превью считаем и отдаём так же, как лента: у клиента одна модель строки на оба списка.
        preview: previewOf(r.bodyText),
        sortAt: r.sortAt.toISOString(),
        seen: r.seen,
        flagged: r.flagged,
        hasAttachments: r.hasAttachments,
        size: r.size,
        threadCount: r.threadKey ? (threads.get(r.threadKey) ?? 1) : 1,
      })),
    };
  }
}

/**
 * Запрос из строки URL: схлопнутые пробелы и проверка длины.
 *
 * Пустой после обрезки запрос — это ошибка вызова, а не «ничего не нашлось»: клиент не должен
 * дёргать поиск на пустой строке, а если дёрнул — лучше сказать об этом прямо. Слишком длинный
 * запрос отсекаем тоже: поиск по нему всё равно не имеет смысла, а индекс по нему гуляет зря.
 */
function normalizeQuery(raw: string): string {
  const q = String(raw ?? '').replace(/\s+/g, ' ').trim();
  if (q.length < MIN_QUERY_CHARS) {
    throw badRequest('mail search query is too short', 'mail_search_query_short');
  }
  if (q.length > MAX_QUERY_CHARS) {
    throw badRequest('mail search query is too long', 'mail_search_query_long');
  }
  return q;
}
