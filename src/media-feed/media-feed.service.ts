import { Injectable } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService } from '../auth/auth.service';
import { conflict } from '../common/errors';
import { ZONE_PHOTOS } from '../common/zones';

/**
 * Лента раздела «Медиа» — полностью изолирована от таймлайна «Фото» (`MediaService`):
 * свои ручки, свой SQL, свой порядок сортировки. Показывает всё медиа зоны «Фото»
 * (фото и видео) единым потоком от свежих к старым, курсором по (capturedAt, id).
 */

/** Потолок одной страницы ленты (клиент листает курсором). */
export const MEDIA_TIMELINE_MAX = 1000;
/** Потолок окна просмотра: сколько записей можно попросить в одну сторону от кадра. */
export const MEDIA_WINDOW_MAX = 50;

/** Строка ленты «Медиа» — тот же контракт, что у «Фото», но это отдельная сущность. */
export interface MediaItem {
  entryId: string;
  name: string;
  sha256?: string;
  capturedAt: string | null;
  mime: string;
  previewState: string;
  size: number;
}

/** Сырые строки запросов: Postgres отдаёт timestamptz как Date, bigint как BigInt. */
interface MediaRow {
  id: string;
  name: string;
  sha256: string | null;
  mime: string;
  previewState: string;
  size: bigint | number | null;
  capturedAt: Date | null;
}

@Injectable()
export class MediaFeedService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
  ) {}

  /**
   * Страница ленты «Медиа»: только зона «Фото», свежие сверху.
   *
   * Запрос написан на SQL, а не через Prisma, по той же причине, что у «Фото»: orderBy
   * по связи превращается в LEFT JOIN с сортировкой по алиасу, и Postgres читает все медиа
   * пользователя. INNER JOIN + курсор по (capturedAt, id) идёт по индексу и останавливается
   * на нужной странице.
   *
   * `cursorEntryId` — запись, до которой клиент долистал: отдаём строго следующее за ней.
   * Курсора уже нет (запись удалили или вынесли из зоны) — 409 `cursor_stale`: клиент по
   * этому коду откатывается на предыдущую запись, а не считает, что лента кончилась.
   */
  async timeline(userId: string, limit = 300, cursorEntryId?: string): Promise<MediaItem[]> {
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return [];
    const cursor = cursorEntryId ? await this.cursor(tree, cursorEntryId) : null;
    if (cursorEntryId && !cursor) throw conflict('media cursor is gone', 'cursor_stale');
    const take = Math.min(Math.max(limit, 1), MEDIA_TIMELINE_MAX);
    const after = !cursor
      ? Prisma.empty
      : cursor.capturedAt
        ? Prisma.sql`AND (mm."capturedAt" < ${MediaFeedService.sqlTimestamp(cursor.capturedAt)}::timestamp
             OR (mm."capturedAt" = ${MediaFeedService.sqlTimestamp(cursor.capturedAt)}::timestamp AND f."id" < ${cursor.id})
             OR mm."capturedAt" IS NULL)`
        : Prisma.sql`AND mm."capturedAt" IS NULL AND f."id" < ${cursor.id}`;
    const rows = await this.prisma.$queryRaw<MediaRow[]>(Prisma.sql`
      SELECT f."id", f."name", a."sha256", a."mime", a."previewState", a."size", mm."capturedAt"
      FROM "MediaMeta" mm
      JOIN "Asset" a ON a."id" = mm."assetId"
      JOIN "FileEntry" f ON f."assetId" = a."id"
      WHERE f."deletedAt" IS NULL
        AND f."zone" = ${ZONE_PHOTOS}
        AND f."folderId" = ANY(${tree})
        ${after}
      ORDER BY mm."capturedAt" DESC NULLS LAST, f."id" DESC
      LIMIT ${take}
    `);
    return rows.map(MediaFeedService.mapRow);
  }

  /**
   * Окно вокруг кадра для просмотра: `before` записей новее и `after` старее, сам кадр в
   * середине. Три выборки одним запросом (две keyset-ветки + сам кадр), внешний ORDER BY
   * склеивает всё в ленточный порядок: следующий кадр лежит правее по массиву.
   */
  async window(userId: string, entryId?: string, before?: unknown, after?: unknown): Promise<MediaItem[]> {
    if (!entryId) return [];
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return [];
    const cursor = await this.cursor(tree, entryId);
    if (!cursor) return [];
    const nBefore = MediaFeedService.windowSize(before);
    const nAfter = MediaFeedService.windowSize(after);
    const cols = Prisma.sql`f."id", f."name", a."sha256", a."mime", a."previewState", a."size", mm."capturedAt"`;
    const from = Prisma.sql`
      FROM "MediaMeta" mm
      JOIN "Asset" a ON a."id" = mm."assetId"
      JOIN "FileEntry" f ON f."assetId" = a."id"
      WHERE f."deletedAt" IS NULL
        AND f."zone" = ${ZONE_PHOTOS}
        AND f."folderId" = ANY(${tree})`;
    const rows = await this.prisma.$queryRaw<MediaRow[]>(Prisma.sql`
      SELECT * FROM (
        (SELECT ${cols} ${from}
           AND ${MediaFeedService.keyset(cursor, 'prev')}
         ORDER BY mm."capturedAt" ASC NULLS FIRST, f."id" ASC
         LIMIT ${nBefore})
        UNION ALL
        (SELECT ${cols} ${from} AND f."id" = ${cursor.id} LIMIT 1)
        UNION ALL
        (SELECT ${cols} ${from}
           AND ${MediaFeedService.keyset(cursor, 'next')}
         ORDER BY mm."capturedAt" DESC NULLS LAST, f."id" DESC
         LIMIT ${nAfter})
      ) w
      ORDER BY w."capturedAt" DESC NULLS LAST, w."id" DESC
    `);
    return rows.map(MediaFeedService.mapRow);
  }

  private static mapRow(r: MediaRow): MediaItem {
    return {
      entryId: r.id,
      name: r.name,
      sha256: r.sha256 ?? undefined,
      capturedAt: r.capturedAt ? new Date(r.capturedAt).toISOString() : null,
      mime: r.mime,
      previewState: r.previewState,
      size: Number(r.size ?? 0),
    };
  }

  /** Размер окна из query: 0..MEDIA_WINDOW_MAX, мусор — 0 (за эту сторону ничего не просим). */
  private static windowSize(v: unknown): number {
    const n = Number(v);
    if (!Number.isFinite(n) || n <= 0) return 0;
    return Math.min(Math.floor(n), MEDIA_WINDOW_MAX);
  }

  /**
   * Предикат «строго до/после курсора» в порядке ленты (capturedAt DESC NULLS LAST, id DESC).
   * Дату курсора передаём строкой без пояса и приводим к timestamp явно: Date Prisma биндит
   * как timestamptz, и на сервере с ненулевым часовым поясом граница уезжала бы на час.
   */
  private static keyset(cursor: { capturedAt: Date | null; id: string }, dir: 'next' | 'prev'): Prisma.Sql {
    const at = cursor.capturedAt ? MediaFeedService.sqlTimestamp(cursor.capturedAt) : null;
    if (dir === 'next') {
      return Prisma.sql`(
        (mm."capturedAt" IS NULL AND ${at}::timestamp IS NOT NULL)
        OR (mm."capturedAt" IS NOT NULL AND ${at}::timestamp IS NOT NULL
            AND (mm."capturedAt" < ${at}::timestamp
                 OR (mm."capturedAt" = ${at}::timestamp AND f."id" < ${cursor.id})))
        OR (mm."capturedAt" IS NULL AND ${at}::timestamp IS NULL AND f."id" < ${cursor.id})
      )`;
    }
    return Prisma.sql`(
      (mm."capturedAt" IS NOT NULL AND ${at}::timestamp IS NULL)
      OR (mm."capturedAt" IS NOT NULL AND ${at}::timestamp IS NOT NULL
          AND (mm."capturedAt" > ${at}::timestamp
               OR (mm."capturedAt" = ${at}::timestamp AND f."id" > ${cursor.id})))
      OR (mm."capturedAt" IS NULL AND ${at}::timestamp IS NULL AND f."id" > ${cursor.id})
    )`;
  }

  /** Naive-timestamp 'YYYY-MM-DD HH:MM:SS.mmm' для сравнения с колонкой timestamp без пояса. */
  private static sqlTimestamp(value: Date): string {
    return value.toISOString().slice(0, 23).replace('T', ' ');
  }

  /** Дата и id записи, от которой продолжать ленту. Чужая/вне зоны «Фото» — не курсор. */
  private async cursor(
    tree: string[],
    entryId: string,
  ): Promise<{ capturedAt: Date | null; id: string } | null> {
    const row = (await this.prisma.fileEntry.findFirst({
      where: {
        id: entryId,
        deletedAt: null,
        zone: ZONE_PHOTOS,
        folderId: { in: tree },
        asset: { media: { isNot: null } },
      },
      select: { id: true, asset: { select: { media: { select: { capturedAt: true } } } } },
    })) as unknown as { id: string; asset: { media: { capturedAt: Date | null } | null } } | null;
    if (!row) return null;
    return { capturedAt: row.asset?.media?.capturedAt ?? null, id: String(row.id) };
  }
}
