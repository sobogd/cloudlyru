import { Injectable, Logger } from '@nestjs/common';
import * as exifr from 'exifr';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { ZONE_PHOTOS } from '../common/zones';

export const IMAGE_MIMES = ['image/jpeg', 'image/heic', 'image/heif', 'image/png', 'image/webp', 'image/tiff', 'image/avif', 'image/gif'];
export const VIDEO_MIMES = ['video/mp4', 'video/quicktime', 'video/x-m4v', 'video/webm', 'video/x-matroska', 'video/avi', 'video/ogg', 'video/mpeg'];
export const GRID_SIZE = 512;
export const FULL_SIZE = 2048;
const MAX_PARSE_BYTES = 150 * 1024 * 1024;

export interface TimelineItem {
  entryId: string;
  name: string;
  sha256?: string;
  capturedAt: string | null;
  latitude?: number;
  longitude?: number;
  mime: string;
  masterMime?: string | null;
  masterReady: boolean;
  jobState?: string | null;
  jobProgress?: number;
  jobError?: string | null;
  size: number;
}

export interface Trip {
  id: string;
  start: string;
  end: string;
  title: string;
  count: number;
  points: Array<{ capturedAt: string; latitude: number; longitude: number; entryId: string }>;
}

@Injectable()
export class MediaService {
  private readonly logger = new Logger(MediaService.name);
  private static gapMs = 36 * 60 * 60 * 1000;

  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
  ) {}

  static viewKey(sha256: string, suffix: string): string {
    return `view/${sha256}${suffix}`;
  }
  static gridKey(sha256: string): string {
    return MediaService.viewKey(sha256, '-512.webp');
  }
  static fullKey(sha256: string): string {
    return MediaService.viewKey(sha256, '-2048.webp');
  }
  static photoMasterKey(sha256: string): string {
    return MediaService.viewKey(sha256, '.avif');
  }
  static videoMasterKey(sha256: string): string {
    return MediaService.viewKey(sha256, '.mp4');
  }
  static videoPosterKey(sha256: string): string {
    return MediaService.viewKey(sha256, '-poster.webp');
  }
  static video720Key(sha256: string): string {
    return MediaService.viewKey(sha256, '-720.mp4');
  }

  /** EXIF → MediaMeta (дата/GPS/камера); тяжёлые производные делает очередь. */
  async captureMeta(assetId: string, sha256: string, size: number, mime: string): Promise<void> {
    if (size <= 0 || size > MAX_PARSE_BYTES) return;
    // видео: без EXIF — помечаем датой загрузки, чтобы попало в таймлайн
    if (VIDEO_MIMES.includes(mime)) {
      await this.prisma.mediaMeta
        .upsert({
          where: { assetId },
          create: { assetId, capturedAt: new Date() },
          update: {},
        })
        .catch(() => undefined);
      return;
    }
    if (!IMAGE_MIMES.includes(mime)) return;
    try {
      const buf = await this.s3.getObjectBytes(S3Service.assetKey(sha256), MAX_PARSE_BYTES);
      const [gps, core] = await Promise.all([
        exifr.gps(buf).catch(() => null),
        exifr.parse(buf, { segments: ['exif', 'ifd0'], mergeOutput: true } as never).catch(() => null),
      ]);
      const capturedAt = core?.DateTimeOriginal instanceof Date ? core.DateTimeOriginal : undefined;
      const width = Number(core?.ExifImageWidth ?? core?.ImageWidth) || undefined;
      const height = Number(core?.ExifImageHeight ?? core?.ImageHeight) || undefined;
      let latitude: number | undefined;
      let longitude: number | undefined;
      if (gps?.latitude != null && gps?.longitude != null) {
        const la = Number(gps.latitude);
        const lo = Number(gps.longitude);
        if (Number.isFinite(la) && Number.isFinite(lo) && Math.abs(la) <= 90 && Math.abs(lo) <= 180) {
          latitude = la;
          longitude = lo;
        }
      }
      await this.prisma.mediaMeta.upsert({
        where: { assetId },
        create: { assetId, capturedAt, latitude, longitude, make: core?.Make || null, model: core?.Model || null, width, height },
        update: {},
      });
    } catch (e) {
      this.logger.debug(`EXIF skip: ${(e as Error).message}`);
    }
  }

  // ============ Таймлайн ============

  async timeline(limit = 300, before?: string): Promise<TimelineItem[]> {
    const rows = (await this.prisma.fileEntry.findMany({
      where: {
        deletedAt: null,
        zone: ZONE_PHOTOS, // только медиа-зона: системная папка «Фото» и её поддеревья
        asset: { media: before ? { capturedAt: { lt: new Date(before) } } : { isNot: null } },
      },
      orderBy: { asset: { media: { capturedAt: 'desc' } } },
      take: Math.min(Math.max(limit, 1), 1000),
      select: {
        id: true,
        name: true,
        asset: {
          select: {
            sha256: true,
            masterMime: true,
            masterReadyAt: true,
            size: true,
            mime: true,
            media: { select: { capturedAt: true, latitude: true, longitude: true } },
            jobs: { orderBy: { createdAt: 'desc' }, take: 1, select: { state: true, progress: true, error: true } },
          },
        },
      },
    })) as any[];
    return rows.map((r: any) => ({
      entryId: r.id,
      name: r.name,
      sha256: r.asset?.sha256 ?? undefined,
      capturedAt: r.asset?.media?.capturedAt?.toISOString() ?? null,
      ...(r.asset?.media?.latitude != null ? { latitude: r.asset.media.latitude } : {}),
      ...(r.asset?.media?.longitude != null ? { longitude: r.asset.media.longitude } : {}),
      mime: r.asset?.mime,
      masterMime: r.asset?.masterMime ?? null,
      masterReady: Boolean(r.asset?.masterReadyAt),
      jobState: r.asset?.jobs?.[0]?.state ?? null,
      jobProgress: r.asset?.jobs?.[0]?.progress ?? 0,
      jobError: r.asset?.jobs?.[0]?.error ?? null,
      size: Number(r.asset?.size ?? 0),
    }));
  }

  async trips(): Promise<Trip[]> {
    const rows = (await this.prisma.fileEntry.findMany({
      where: { deletedAt: null, zone: ZONE_PHOTOS, asset: { media: { isNot: null } } },
      orderBy: { asset: { media: { capturedAt: 'asc' } } },
      select: {
        id: true,
        asset: {
          select: {
            media: { select: { capturedAt: true, latitude: true, longitude: true } },
            jobs: { orderBy: { createdAt: 'desc' }, take: 1, select: { state: true, progress: true, error: true } },
          },
        },
      },
    })) as any[];
    const trips: Trip[] = [];
    let current: Trip['points'] = [];
    let prevTs: number | null = null;
    for (const r of rows) {
      const m = r.asset?.media;
      if (!m || m.capturedAt == null || m.latitude == null || m.longitude == null) continue;
      const t = new Date(m.capturedAt).getTime();
      if (prevTs !== null && t - prevTs > MediaService.gapMs && current.length) {
        trips.push(this.finishTrip(trips.length, current));
        current = [];
      }
      current.push({ capturedAt: new Date(t).toISOString(), latitude: Number(m.latitude), longitude: Number(m.longitude), entryId: String(r.id) });
      prevTs = t;
    }
    if (current.length) trips.push(this.finishTrip(trips.length, current));
    return trips;
  }

  private finishTrip(index: number, points: Trip['points']): Trip {
    const start = new Date(points[0].capturedAt);
    const end = new Date(points[points.length - 1].capturedAt);
    const title = `${start.toISOString().slice(0, 10)} — ${end.toISOString().slice(0, 10)}`;
    return {
      id: `trip-${index + 1}-${start.getTime()}`,
      start: start.toISOString(),
      end: end.toISOString(),
      title,
      count: points.length,
      points,
    };
  }
}
