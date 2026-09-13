import { Injectable } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService } from '../auth/auth.service';
import { ZONE_PHOTOS } from '../common/zones';

/**
 * Лента раздела «Медиа» — полностью изолирована от таймлайна «Фото» (`MediaService`):
 * свои ручки, свой SQL. Показывает всё медиа зоны «Фото» (фото и видео) единым потоком
 * от свежих к старым.
 *
 * Клиент знает только общее число (`count`) и запрашивает элементы по смещению (`range`):
 * высота скролла считается на клиенте целиком, а данные грузятся куском видимой части.
 */

/** Потолок одного запроса range. */
export const MEDIA_RANGE_MAX = 1000;
/** Потолок одного запроса статусов превью. */
export const MEDIA_STATUS_MAX = 500;
/**
 * Потолок точек карты: на кадр приходится одна точка, и они уходят в браузер целиком
 * (тепловой слой считает клиент). 50 000 точек — это ~3 МБ JSON, 400–500 КБ по сети
 * с brotli, и хватает на библиотеку в десятки тысяч геотегированных кадров.
 */
export const MEDIA_MAP_MAX = 50_000;

/**
 * Точка на карте: запись с геометкой. Только то, что нужно карте, — ни имени, ни размера,
 * ни даты: миниатюра берётся по `entryId` (`/files/:id/thumb`), а дата и название — из
 * `/media/:entryId`, который запрашивается при открытии кадра. Координаты округлены до
 * пяти знаков (~1 м): лишние знаки только раздувают ответ.
 */
export interface MediaMapPoint {
  entryId: string;
  lat: number;
  lon: number;
}

/** Строка ленты «Медиа». */
export interface MediaItem {
  entryId: string;
  name: string;
  sha256?: string;
  capturedAt: string | null;
  mime: string;
  previewState: string;
  /** Состояние задачи конвертации (pending/processing/failed/null) — для иконки «в обработке». */
  jobState: string | null;
  size: number;
}

/**
 * Метаданные кадра для футера модалки «Медиа» (отдельная ручка /media/:entryId).
 *
 * Параметры съёмки берём из `MediaMeta.raw` — там лежит полный набор тегов: EXIF для фото
 * (диафрагма, выдержка, ISO, фокусное, объектив) и ffprobe для видео (длительность, fps,
 * кодеки). Отдельных колонок под них нет, поэтому поля «плоские» и nullable: у фото пусто
 * в видео-полях и наоборот, а у ассетов, разобранных до появления поля, — вообще везде.
 */
export interface MediaInfo {
  entryId: string;
  name: string;
  mime: string;
  size: number;
  sha256: string;
  capturedAt: string | null;
  width: number | null;
  height: number | null;
  make: string | null;
  model: string | null;
  latitude: number | null;
  longitude: number | null;
  /** Объектив (EXIF LensModel). */
  lens: string | null;
  /** Диафрагма, например 1.8 (показываем как f/1.8). */
  fNumber: number | null;
  /** Выдержка строкой из EXIF: «1/120» или «2.5 с». */
  exposureTime: string | null;
  iso: number | null;
  /** Фокусное расстояние, мм. */
  focalLength: number | null;
  /** Оно же в 35-мм эквиваленте, мм. */
  focalLength35: number | null;
  /** Видео: длительность, кадров в секунду, кодек. */
  durationSec: number | null;
  fps: number | null;
  videoCodec: string | null;
}

/** Число из raw: всё, что не конечное число (включая строки и null), — это «нет данных». */
const rawNum = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null);
/** Координата до пяти знаков: точнее метра карте не нужно, а хвост float только раздувает ответ. */
const round5 = (v: number): number => Math.round(v * 1e5) / 1e5;

/** Непустая строка из raw. */
const rawStr = (v: unknown): string | null => (typeof v === 'string' && v.trim() ? v : null);

/** Сырые строки запросов: Postgres отдаёт timestamptz как Date, bigint как BigInt. */
interface MediaRow {
  id: string;
  name: string;
  sha256: string | null;
  mime: string;
  previewState: string;
  jobState: string | null;
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
   * Все геометки ленты для вкладки «Карта»: по точке на кадр, порядок — как в ленте
   * (от свежих к старым), чтобы индекс точки совпадал с порядком листания в модалке.
   *
   * Отдаём минимум полей: имена, размеры и sha256 карте не нужны — миниатюра берётся по
   * `entryId` (`/files/:id/thumb`), а детали кадра подтягиваются при открытии. Потолок —
   * MEDIA_MAP_MAX: `total` и `truncated` показывают, влезла ли библиотека целиком.
   */
  async mapPoints(userId: string): Promise<{ total: number; truncated: boolean; points: MediaMapPoint[] }> {
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return { total: 0, truncated: false, points: [] };
    const rows = await this.prisma.$queryRaw<Array<{ id: string; lat: number; lon: number; n: bigint | number }>>(Prisma.sql`
      SELECT f."id", mm."latitude" AS lat, mm."longitude" AS lon,
             count(*) OVER () AS n
      FROM "MediaMeta" mm
      JOIN "Asset" a ON a."id" = mm."assetId"
      JOIN "FileEntry" f ON f."assetId" = a."id"
      WHERE f."deletedAt" IS NULL
        AND f."zone" = ${ZONE_PHOTOS}
        AND f."folderId" = ANY(${tree})
        -- Только кадры с собранным превью: на карте точка — это миниатюра, а тап открывает
        -- кадр. Без превью и то и другое мертво (миниатюра 404, просмотрщик — «не открылось»);
        -- в ленте такие кадры и так помечены как «Превью не собрано».
        AND a."previewState" = 'done'
        AND mm."latitude" IS NOT NULL
        AND mm."longitude" IS NOT NULL
      ORDER BY mm."capturedAt" DESC NULLS LAST, f."id" DESC
      LIMIT ${MEDIA_MAP_MAX}
    `);
    const total = Number(rows[0]?.n ?? 0);
    return {
      total,
      truncated: total > rows.length,
      points: rows.map((r) => ({
        entryId: r.id,
        lat: round5(Number(r.lat)),
        lon: round5(Number(r.lon)),
      })),
    };
  }

  /** Общее число медиа зоны «Фото» — по нему клиент считает высоту скролла. */
  async count(userId: string): Promise<number> {
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return 0;
    const rows = await this.prisma.$queryRaw<Array<{ n: bigint | number }>>(Prisma.sql`
      SELECT count(*) AS n
      FROM "MediaMeta" mm
      JOIN "Asset" a ON a."id" = mm."assetId"
      JOIN "FileEntry" f ON f."assetId" = a."id"
      WHERE f."deletedAt" IS NULL
        AND f."zone" = ${ZONE_PHOTOS}
        AND f."folderId" = ANY(${tree})
    `);
    return Number(rows[0]?.n ?? 0);
  }

  /**
   * Срез ленты по абсолютному смещению: элементы [offset, offset+limit) в порядке ленты.
   * OFFSET умеет прыгнуть в любую точку (в отличие от keyset-курсора) — это и нужно клиенту,
   * чтобы после остановки скролла забрать ровно видимый кусок.
   */
  async range(userId: string, offset = 0, limit = 300): Promise<MediaItem[]> {
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return [];
    const take = Math.min(Math.max(limit, 1), MEDIA_RANGE_MAX);
    const skip = Math.max(0, Math.floor(offset));
    const rows = await this.prisma.$queryRaw<MediaRow[]>(Prisma.sql`
      SELECT f."id", f."name", a."sha256", a."mime", a."previewState", a."size", mm."capturedAt",
             j."state" AS "jobState"
      FROM "MediaMeta" mm
      JOIN "Asset" a ON a."id" = mm."assetId"
      JOIN "FileEntry" f ON f."assetId" = a."id"
      LEFT JOIN LATERAL (
        SELECT "state" FROM "Job" WHERE "assetId" = a."id" ORDER BY "createdAt" DESC LIMIT 1
      ) j ON TRUE
      WHERE f."deletedAt" IS NULL
        AND f."zone" = ${ZONE_PHOTOS}
        AND f."folderId" = ANY(${tree})
      ORDER BY mm."capturedAt" DESC NULLS LAST, f."id" DESC
      LIMIT ${take} OFFSET ${skip}
    `);
    return rows.map(MediaFeedService.mapRow);
  }

  /**
   * Индекс по месяцам для подписи у ползунка: строка на месяц (в порядке ленты, от свежих),
   * плюс «хвост» без даты съёмки (month = null) — он в ленте идёт самым последним. Кумулятивным
   * счётчиком клиент сопоставляет позицию скролла с точным месяцем/годом без загрузки самих фото.
   */
  async months(userId: string): Promise<Array<{ month: string | null; count: number }>> {
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return [];
    const rows = await this.prisma.$queryRaw<Array<{ month: string | null; n: bigint | number }>>(Prisma.sql`
      SELECT to_char(mm."capturedAt", 'YYYY-MM') AS month, count(*) AS n
      FROM "MediaMeta" mm
      JOIN "Asset" a ON a."id" = mm."assetId"
      JOIN "FileEntry" f ON f."assetId" = a."id"
      WHERE f."deletedAt" IS NULL
        AND f."zone" = ${ZONE_PHOTOS}
        AND f."folderId" = ANY(${tree})
        AND mm."capturedAt" IS NOT NULL
      GROUP BY 1
      UNION ALL
      SELECT NULL AS month, count(*) AS n
      FROM "MediaMeta" mm
      JOIN "Asset" a ON a."id" = mm."assetId"
      JOIN "FileEntry" f ON f."assetId" = a."id"
      WHERE f."deletedAt" IS NULL
        AND f."zone" = ${ZONE_PHOTOS}
        AND f."folderId" = ANY(${tree})
        AND mm."capturedAt" IS NULL
      ORDER BY month DESC NULLS LAST
    `);
    return rows.map((r) => ({ month: r.month, count: Number(r.n) }));
  }

  /** Метаданные кадра для футера модалки. Чужое/удалённое/вне зоны «Фото» — null (404). */
  async info(userId: string, entryId: string): Promise<MediaInfo | null> {
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return null;
    const row = await this.prisma.fileEntry.findFirst({
      where: { id: entryId, deletedAt: null, zone: ZONE_PHOTOS, folderId: { in: tree } },
      select: {
        id: true,
        name: true,
        asset: {
          select: {
            sha256: true,
            mime: true,
            size: true,
            media: {
              select: {
                capturedAt: true,
                width: true,
                height: true,
                make: true,
                model: true,
                latitude: true,
                longitude: true,
                raw: true,
              },
            },
          },
        },
      },
    });
    if (!row) return null;
    const raw = (row.asset.media?.raw ?? null) as Record<string, unknown> | null;
    return {
      entryId: row.id,
      name: row.name,
      mime: row.asset.mime,
      size: Number(row.asset.size),
      sha256: row.asset.sha256,
      capturedAt: row.asset.media?.capturedAt ? new Date(row.asset.media.capturedAt).toISOString() : null,
      width: row.asset.media?.width ?? null,
      height: row.asset.media?.height ?? null,
      make: row.asset.media?.make ?? null,
      model: row.asset.media?.model ?? null,
      latitude: row.asset.media?.latitude ?? null,
      longitude: row.asset.media?.longitude ?? null,
      lens: rawStr(raw?.lens),
      fNumber: rawNum(raw?.fNumber),
      exposureTime: rawStr(raw?.exposureTime),
      iso: rawNum(raw?.iso),
      focalLength: rawNum(raw?.focalLength),
      focalLength35: rawNum(raw?.focalLength35),
      durationSec: rawNum(raw?.durationSec),
      fps: rawNum(raw?.fps),
      videoCodec: rawStr(raw?.videoCodec),
    };
  }

  private static mapRow(r: MediaRow): MediaItem {
    return {
      entryId: r.id,
      name: r.name,
      sha256: r.sha256 ?? undefined,
      capturedAt: r.capturedAt ? new Date(r.capturedAt).toISOString() : null,
      mime: r.mime,
      previewState: r.previewState,
      jobState: r.jobState ?? null,
      size: Number(r.size ?? 0),
    };
  }

  /** Статусы превью по списку записей — клиент переспрашивает только неготовые снимки. */
  async status(userId: string, entryIds: unknown): Promise<Array<{ entryId: string; previewState: string; jobState: string | null }>> {
    const ids = [...new Set(Array.isArray(entryIds) ? entryIds : [])]
      .filter((id): id is string => typeof id === 'string' && id.length > 0)
      .slice(0, MEDIA_STATUS_MAX);
    if (!ids.length) return [];
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return [];
    const rows = await this.prisma.$queryRaw<Array<{ id: string; previewState: string; jobState: string | null }>>(Prisma.sql`
      SELECT f."id", a."previewState", j."state" AS "jobState"
      FROM "FileEntry" f
      JOIN "Asset" a ON a."id" = f."assetId"
      LEFT JOIN LATERAL (
        SELECT "state" FROM "Job" WHERE "assetId" = a."id" ORDER BY "createdAt" DESC LIMIT 1
      ) j ON TRUE
      WHERE f."id" = ANY(${ids})
        AND f."deletedAt" IS NULL
        AND f."zone" = ${ZONE_PHOTOS}
        AND f."folderId" = ANY(${tree})
    `);
    return rows.map((r) => ({ entryId: r.id, previewState: r.previewState, jobState: r.jobState ?? null }));
  }
}
