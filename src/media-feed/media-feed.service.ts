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

/** Строка ленты «Медиа». */
export interface MediaItem {
  entryId: string;
  name: string;
  sha256?: string;
  capturedAt: string | null;
  mime: string;
  previewState: string;
  size: number;
}

/** Метаданные кадра для панели «Инфо» (отдельная ручка /media/:entryId). */
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
      SELECT f."id", f."name", a."sha256", a."mime", a."previewState", a."size", mm."capturedAt"
      FROM "MediaMeta" mm
      JOIN "Asset" a ON a."id" = mm."assetId"
      JOIN "FileEntry" f ON f."assetId" = a."id"
      WHERE f."deletedAt" IS NULL
        AND f."zone" = ${ZONE_PHOTOS}
        AND f."folderId" = ANY(${tree})
      ORDER BY mm."capturedAt" DESC NULLS LAST, f."id" DESC
      LIMIT ${take} OFFSET ${skip}
    `);
    return rows.map(MediaFeedService.mapRow);
  }

  /** Метаданные кадра для панели «Инфо». Чужое/удалённое/вне зоны «Фото» — null (404). */
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
              select: { capturedAt: true, width: true, height: true, make: true, model: true, latitude: true, longitude: true },
            },
          },
        },
      },
    });
    if (!row) return null;
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
      size: Number(r.size ?? 0),
    };
  }
}
