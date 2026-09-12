import { Injectable, Logger } from '@nestjs/common';
import { execFileSync } from 'child_process';
import { mkdtempSync, rmSync } from 'fs';
import { readFile } from 'fs/promises';
import { tmpdir } from 'os';
import { join } from 'path';
import * as exifr from 'exifr';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { AuthService } from '../auth/auth.service';
import { conflict } from '../common/errors';
import { ZONE_PHOTOS } from '../common/zones';

export const IMAGE_MIMES = ['image/jpeg', 'image/heic', 'image/heif', 'image/png', 'image/webp', 'image/tiff', 'image/avif', 'image/gif'];
export const VIDEO_MIMES = ['video/mp4', 'video/quicktime', 'video/x-m4v', 'video/webm', 'video/x-matroska', 'video/avi', 'video/ogg', 'video/mpeg'];
/** PDF рендерим сами (poppler): в списке — миниатюра первой страницы, в деталке — все страницы. */
export const PDF_MIMES = ['application/pdf'];
/** Ширина превью страницы PDF. */
export const PDF_PAGE_WIDTH = 1080;
/** Сколько страниц рисует одна задача: большое PDF иначе держало бы воркер минутами. */
export const PDF_PAGES_PER_JOB = 40;

/** Вид задачи конвейера по MIME; null — для такого типа превью не собираются. */
export function mediaKindOf(mime: unknown): 'photo' | 'video' | 'pdf' | null {
  const m = String(mime ?? '').toLowerCase();
  if (IMAGE_MIMES.includes(m)) return 'photo';
  if (VIDEO_MIMES.includes(m)) return 'video';
  if (PDF_MIMES.includes(m)) return 'pdf';
  return null;
}
/**
 * Размер превью для списка (сетка галереи): квадрат 50×50. В сетке такое превью
 * никогда не растягивается больше 50 px, поэтому больше пикселей не нужно.
 * Ключ в S3 остался историческим `-512.webp`: у уже собранных ассетов там лежит
 * старое превью 512 px, и оно продолжает отдаваться без пересборки.
 */
export const GRID_SIZE = 50;
/**
 * Начало файла для EXIF. Для JPEG этого всегда хватает, а у HEIC/HEIF новых телефонов и у
 * файлов из архивов Takeout теги лежат глубже — тогда читаем объект целиком (см.
 * storeImageMetaFromObject): обрезанное начало exifr разбирает в пустой результат.
 */
const EXIF_HEAD_BYTES = 4 * 1024 * 1024;
/** Ширина полноэкранного превью фото (и превью страницы PDF — та же величина). */
export const FULL_SIZE = 1080;
/** Потолок одной страницы ленты: клиент листает курсором, но страницу ограничиваем. */
export const TIMELINE_MAX = 1000;
/** Сколько записей можно спросить одним запросом статусов превью. */
export const TIMELINE_STATUS_MAX = 500;
/** Сколько байт читаем из начала объекта, прежде чем тянуть его целиком. */
const HEAD_PARSE_BYTES = 4 * 1024 * 1024;
/**
 * Голова объекта для быстрого разбора метаданных: EXIF и GPS лежат в начале JPEG/HEIC/MP4.
 * 512 КБ вместо 4 МБ — на библиотеке в десятки тысяч фото это десятки гигабайт чтения из
 * хранилища, а если разбор не нашёл ничего, вызывающий читает объект целиком и пробует снова.
 */
const META_HEAD_BYTES = 512 * 1024;
const MAX_PARSE_BYTES = 150 * 1024 * 1024;
/**
 * Сколько готовы скачать из S3 ради тегов видео. Файл скачивается целиком: ffprobe по
 * presigned-ссылке на этом сервере не работает (внешний хост не резолвится), а метаданные
 * контейнера лежат и в конце файла. Разбор идёт один раз на ассет и кэшируется в БД.
 */
const VIDEO_META_MAX_BYTES = 2 * 1024 * 1024 * 1024;

/**
 * Разбор дал что-то полезное? В `raw` есть служебный `kind` и поля; если кроме `kind` ничего
 * нет — это не метаданные, а след неудачного разбора. Так выглядит обрезанное начало файла:
 * exifr на неполном HEIC/HEIF возвращает объект с одной ошибкой (`{errors:[…]}`), из которого
 * не извлекается ни одного поля. Раньше такой `raw` считался готовыми метаданными, и фото
 * навсегда оставалось без даты, камеры и кадра — ни запасной полный разбор, ни ленивый
 * разбор при открытии деталки больше не запускались.
 */
export function hasUsefulRaw(raw: unknown): boolean {
  if (!raw || typeof raw !== 'object') return false;
  return Object.entries(raw as Record<string, unknown>).some(
    ([k, v]) => k !== 'kind' && v !== undefined && v !== null && v !== '',
  );
}

const MS_PER_MIN = 60_000;

/** Миллисекунды из EXIF SubSecTimeOriginal («381» → 381 мс). */
function subSecMs(v: unknown): number {
  const digits = typeof v === 'string' ? v.replace(/\D/g, '') : '';
  if (!digits) return 0;
  return Math.round(Number(`0.${digits}`) * 1000) || 0;
}

/**
 * Корректный UTC-момент съёмки из EXIF-даты.
 *
 * EXIF хранит «настенное» время камеры без зоны, а exifr возвращает Date, у которого
 * локальные поля равны этому wall-clock (то есть на UTC-проде он трактует его как UTC).
 * Без поправки на OffsetTime* момент уезжает ровно на часовой пояс съёмки: фото с
 * OffsetTimeOriginal=+03:00 попадало в таймлайн на 3 часа позже — ломая порядок ленты
 * и группировку поездок.
 */
export function exifInstant(revived: unknown, offset: unknown, subSec?: unknown): Date | undefined {
  const off = typeof offset === 'string' ? /^([+-])(\d{2}):?(\d{2})$/.exec(offset.trim()) : null;
  if (off && revived instanceof Date && !Number.isNaN(revived.getTime())) {
    const sign = off[1] === '-' ? -1 : 1;
    const offsetMin = sign * (Number(off[2]) * 60 + Number(off[3]));
    const wall = Date.UTC(
      revived.getFullYear(),
      revived.getMonth(),
      revived.getDate(),
      revived.getHours(),
      revived.getMinutes(),
      revived.getSeconds(),
      subSecMs(subSec),
    );
    return new Date(wall - offsetMin * MS_PER_MIN);
  }
  return revived instanceof Date && !Number.isNaN(revived.getTime()) ? revived : undefined;
}

/** ISO 6709 из Apple Keys видео: «+36.9150+030.8025+076.387/» → широта/долгота. */
export function parseIso6709(v: unknown): { latitude: number; longitude: number } | undefined {
  if (typeof v !== 'string' || !v.trim()) return undefined;
  const m = /^([+-]\d{1,2}(?:\.\d+)?)([+-]\d{1,3}(?:\.\d+)?)/.exec(v.trim());
  if (!m) return undefined;
  const latitude = Number(m[1]);
  const longitude = Number(m[2]);
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return undefined;
  if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return undefined;
  return { latitude, longitude };
}

/** Дата видео: com.apple.quicktime.creationdate (со смещением) либо utc creation_time. */
export function videoInstant(tags: Record<string, string> | undefined): Date | undefined {
  if (!tags) return undefined;
  const apple = tags['com.apple.quicktime.creationdate'];
  if (apple) {
    // «2023-11-18T12:24:00+0300» → «...+03:00» (не всякий движок парсит смещение без двоеточия)
    const d = new Date(apple.replace(/([+-]\d{2})(\d{2})$/, '$1:$2'));
    if (!Number.isNaN(d.getTime())) return d;
  }
  const utc = tags['creation_time'];
  if (utc) {
    const d = new Date(utc);
    if (!Number.isNaN(d.getTime())) return d;
  }
  return undefined;
}

function asNum(v: unknown): number | undefined {
  const n = Number(v);
  return Number.isFinite(n) ? n : undefined;
}

function asStr(v: unknown): string | undefined {
  const t = typeof v === 'string' ? v.trim() : v == null ? '' : String(v);
  return t ? t.slice(0, 300) : undefined;
}

/**
 * Строка ленты. Координаты и прогресс задачи из ответа убраны: карта снята из продукта,
 * а состояние задачи клиент узнаёт ручкой статусов только про те снимки, которые ещё не
 * готовы — тянуть его для каждой записи каждой страницы (LATERAL по Job) значило платить
 * ~15 мс на страницу в 500 снимков. previewState — состояние превью (см. Asset).
 */
export interface TimelineItem {
  entryId: string;
  name: string;
  sha256?: string;
  capturedAt: string | null;
  mime: string;
  previewState: string;
  size: number;
}

/** Статус сборки превью одной записи (см. MediaService.timelineStatus). */
export interface TimelineStatusItem {
  entryId: string;
  previewState: string;
  /** Причина, по которой превью собрать нельзя (previewState='impossible'). */
  previewError: string | null;
  jobState: string | null;
  jobError: string | null;
}

/** Сырые строки запросов: Postgres отдаёт timestamptz как Date, bigint как BigInt. */
interface TimelineRow {
  id: string;
  name: string;
  sha256: string | null;
  mime: string;
  previewState: string;
  size: bigint | number | null;
  capturedAt: Date | null;
}

interface TimelineStatusRow {
  id: string;
  previewState: string;
  previewError: string | null;
  jobState: string | null;
  jobError: string | null;
}

@Injectable()
export class MediaService {
  private readonly logger = new Logger(MediaService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly auth: AuthService,
  ) {}

  static viewKey(sha256: string, suffix: string): string {
    return `view/${sha256}${suffix}`;
  }
  /** Превью для списка (сетка галереи): квадрат 50×50, фото и видео одинаково. */
  static gridKey(sha256: string): string {
    return MediaService.viewKey(sha256, '-512.webp');
  }
  /** Полноэкранное превью фото (1080, AVIF; у анимированных источников — WebP). */
  static photoFullKey(sha256: string): string {
    return MediaService.viewKey(sha256, `-${FULL_SIZE}.avif`);
  }
  /** Постер видео для списка (тот же квадрат 50×50). */
  static videoPosterKey(sha256: string): string {
    return MediaService.viewKey(sha256, '-poster.webp');
  }
  /** Полноэкранное превью видео (1080, AV1). */
  static video1080Key(sha256: string): string {
    return MediaService.viewKey(sha256, '-1080.mp4');
  }
  /** Превью страницы PDF (1080 px по ширине, WebP): номер страницы с единицы. */
  static pdfPageKey(sha256: string, page: number): string {
    return MediaService.viewKey(sha256, `-p${page}-${PDF_PAGE_WIDTH}.webp`);
  }
  private static readonly EXIF_HEAD_BYTES = EXIF_HEAD_BYTES;

  // ===== Устаревшие ключи: мастер-версии старого пайплайна =====
  // Больше не создаются (оригинал и есть мастер), но остаются в derivativeKeys(),
  // чтобы purge корзины вычистил производные, сделанные прежним кодом.
  static legacyPhotoMasterKey(sha256: string): string {
    return MediaService.viewKey(sha256, '.avif');
  }
  static legacyVideoMasterKey(sha256: string): string {
    return MediaService.viewKey(sha256, '.mp4');
  }
  static legacyVideo720Key(sha256: string): string {
    return MediaService.viewKey(sha256, '-720.mp4');
  }
  static legacyPhotoFullWebpKey(sha256: string): string {
    return MediaService.viewKey(sha256, '-2048.webp');
  }
  /** Прежний размер полноэкранного превью фото: у части ассетов оно ещё лежит под этим ключом. */
  static legacyPhotoFull2048Key(sha256: string): string {
    return MediaService.viewKey(sha256, '-2048.avif');
  }

  /**
   * Все производные ассета — актуальные и устаревшие. Нужно для полного удаления:
   * до этого осиротевшие view/* не удалял никто, и они оставались в S3 навсегда.
   * Лишние ключи безвредны: удаление несуществующего объекта S3 игнорирует.
   *
   * pageCount нужен только для PDF: страничные превью — это переменный набор ключей,
   * и перечислить их можно лишь по числу страниц из БД (оно там после рендера).
   */
  static derivativeKeys(sha256: string, pageCount?: number | null): string[] {
    const pages = pageCount && pageCount > 0
      ? Array.from({ length: pageCount }, (_, i) => MediaService.pdfPageKey(sha256, i + 1))
      : [];
    return [
      MediaService.gridKey(sha256),
      MediaService.photoFullKey(sha256),
      MediaService.videoPosterKey(sha256),
      MediaService.video1080Key(sha256),
      ...pages,
      MediaService.legacyPhotoMasterKey(sha256),
      MediaService.legacyVideoMasterKey(sha256),
      MediaService.legacyVideo720Key(sha256),
      MediaService.legacyPhotoFullWebpKey(sha256),
      MediaService.legacyPhotoFull2048Key(sha256),
    ];
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
      // Метаданные лежат в начале файла, поэтому сначала читаем только голову: полный объект
      // (до 150 МБ) на каждое фото — это лишний трафик из S3 и память на VPS, а на пути complete
      // клиент ещё и ждёт ответа.
      const head = await this.s3.readRange(S3Service.assetKey(sha256), 0, HEAD_PARSE_BYTES - 1).catch(() => null);
      if (head && (await this.parseAndStoreImageMeta(assetId, head))) return;
      // не получилось из головы (метаданные в конце или формат хитрый) — читаем целиком
      const buf = await this.s3.getObjectBytes(S3Service.assetKey(sha256), MAX_PARSE_BYTES);
      await this.parseAndStoreImageMeta(assetId, buf);
    } catch (e) {
      this.logger.debug(`EXIF skip: ${(e as Error).message}`);
    }
  }

  /**
   * То же, но из ЛОКАЛЬНОГО файла. Воркер очереди уже скачал сырьё, поэтому повторный
   * трафик S3 не нужен. Нужно для медиа из архивов: при распаковке captureMeta() не
   * вызывается, и без этого фото из ZIP не попадали бы в таймлайн.
   */
  async captureMetaFromFile(assetId: string, filePath: string, size: number, mime: string): Promise<void> {
    if (size <= 0 || size > MAX_PARSE_BYTES) return;
    if (!IMAGE_MIMES.includes(mime)) return; // видео разберёт воркер (storeVideoMeta из ffprobe)
    try {
      const buf = await readFile(filePath);
      await this.parseAndStoreImageMeta(assetId, buf);

    } catch (e) {
      this.logger.debug(`EXIF skip (local): ${(e as Error).message}`);
    }
  }

  /** EXIF фото → MediaMeta. Первичный проход: существующие значения не перетираем. */
  private async parseAndStoreImageMeta(assetId: string, buf: Buffer): Promise<boolean> {
    const [gps, core] = await Promise.all([
      exifr.gps(buf).catch(() => null),
      exifr.parse(buf, { segments: ['exif', 'ifd0'], mergeOutput: true } as never).catch(() => null),
    ]);
    const capturedAt = exifInstant(
      core?.DateTimeOriginal,
      core?.OffsetTimeOriginal ?? core?.OffsetTime,
      core?.SubSecTimeOriginal,
    );
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
    // «что-то нашли» — сигнал вызывающему, что читать объект целиком не нужно
    return Boolean(capturedAt || latitude != null || width != null || core?.Make || core?.Model);
  }

  /**
   * Метаданные любого фото и видео — независимо от зоны.
   *
   * Зона решает, где файл лежит и строятся ли для него превью, но не то, знаем ли мы дату
   * съёмки, координаты, камеру и параметры кадра. Раньше разбор шёл только для «Фото», и треть
   * библиотеки в «Файлах» оставалась вообще без метаданных.
   *
   * Фото разбираем на месте (читается только начало объекта). Видео — фоном: ffprobe ходит
   * в хранилище, и заставлять клиента ждать этого на complete незачем.
   *
   * Разбираем ЛЮБОЙ image/*, а не только те типы, что умеет sharp: RAW камер (DNG, CR2, NEF,
   * ARW) не конвертируется, но exifr читает его TIFF-производные теги, а без строки MediaMeta
   * такой файл вообще не появлялся в ленте «Фото» — владелец видел «часть фото пропала».
   */
  async captureAny(assetId: string, sha256: string, size: number, mime: string): Promise<void> {
    if (size <= 0 || size > MAX_PARSE_BYTES) return;
    const isVideo = VIDEO_MIMES.includes(mime);
    const isImage = mime.startsWith('image/');
    if (!isVideo && !isImage) return;
    if (await this.hasDetailedMeta(assetId)) return;
    if (isVideo) {
      // дата загрузки сразу: видео должно быть в ленте, даже если ffprobe не ответит
      await this.prisma.mediaMeta
        .upsert({ where: { assetId }, create: { assetId, capturedAt: new Date() }, update: {} })
        .catch(() => undefined);
      void this.extractDetail(assetId, sha256, size, mime).catch(() => undefined);
      return;
    }
    // Быстрый путь: EXIF почти всегда в первых килобайтах, поэтому сначала читаем маленькую
    // голову, а полный разбор (4 МБ) оставляем на случай, когда метаданные лежат дальше
    const head = await this.s3
      .readRange(S3Service.assetKey(sha256), 0, Math.min(size, META_HEAD_BYTES) - 1)
      .catch(() => null);
    if (head && (await this.storeImageMeta(assetId, head))) return;
    await this.extractDetail(assetId, sha256, size, mime).catch(() => undefined);
  }

  /**
   * Проставить дату съёмки и координаты, если разбор их не нашёл. Нужно для файлов без EXIF
   * (скриншоты, картинки из мессенджеров) и для видео без creation_time: иначе у них нет даты
   * вообще, и в ленте они не появляются. Уже найденные значения не перетираем: EXIF и ffprobe
   * точнее, чем дата из архива или сайдкара.
   */
  async fillDateAndGeo(
    assetId: string,
    capturedAt: Date | null,
    geo?: { latitude: number; longitude: number } | null,
  ): Promise<void> {
    if (!capturedAt && !geo) return;
    const known = await this.prisma.mediaMeta
      .findUnique({ where: { assetId }, select: { capturedAt: true, latitude: true, longitude: true } })
      .catch(() => null);
    const patch = {
      ...(known?.capturedAt || !capturedAt ? {} : { capturedAt }),
      ...(known?.latitude != null || !geo ? {} : { latitude: geo.latitude, longitude: geo.longitude }),
    };
    if (!Object.keys(patch).length) return;
    await this.prisma.mediaMeta
      .upsert({ where: { assetId }, create: { assetId, capturedAt, ...(geo ?? {}) }, update: patch })
      .catch(() => undefined);
  }

  /**
   * Разбор уже дал подробности: `raw` есть и в нём есть поля, кроме `kind`.
   *
   * Проверять только `raw != null` нельзя: пустой `raw` остаётся после неудачного разбора
   * обрезанного начала файла, и тогда и повторная загрузка того же содержимого, и ленивый
   * разбор при открытии деталки решали, что ходить в хранилище незачем.
   */
  async hasDetailedMeta(assetId: string): Promise<boolean> {
    const known = await this.prisma.mediaMeta
      .findUnique({ where: { assetId }, select: { raw: true } })
      .catch(() => null);
    return hasUsefulRaw(known?.raw);
  }

  /**
   * Подробные метаданные для деталки файла: EXIF фото или ffprobe видео. Результат
   * кэшируется в MediaMeta, поэтому в хранилище ходим только пока разбор не удался.
   */
  async extractDetail(assetId: string, sha256: string, size: number, mime: string): Promise<void> {
    try {
      if (IMAGE_MIMES.includes(mime)) {
        await this.storeImageMetaFromObject(assetId, sha256, size);
        return;
      }

      if (VIDEO_MIMES.includes(mime)) {
        await this.captureVideoFromObject(assetId, sha256, size);
      }
    } catch (e) {
      this.logger.debug(`extractDetail skip: ${(e as Error).message}`);
    }
  }

  /**
   * EXIF фото из объекта. Сначала читаем начало файла, а если его не хватило — объект целиком.
   *
   * Одной головы мало: у HEIC/HEIF новых телефонов (проверено на Samsung S25 Ultra) EXIF лежит
   * глубже 512 КБ, а у файлов из архивов Takeout — и глубже 4 МБ. На обрезанном начале exifr
   * не находит ни одного поля, и фото остаётся без даты, камеры и кадра.
   */
  private async storeImageMetaFromObject(assetId: string, sha256: string, size: number): Promise<void> {
    const key = S3Service.assetKey(sha256);
    const head = await this.s3.readRange(key, 0, Math.min(size, MediaService.EXIF_HEAD_BYTES) - 1);
    if (await this.storeImageMeta(assetId, head)) return;
    if (size <= head.length) return; // голова была всем файлом — читать больше нечего
    const whole = await this.s3.getObjectBytes(key, MAX_PARSE_BYTES);
    if (whole.length > head.length) await this.storeImageMeta(assetId, whole);
  }

  /**
   * Видео: ffprobe по ЛОКАЛЬНОМУ файлу. По presigned-ссылке он на этом сервере не работает
   * (внешний хост S3 не резолвится), из-за чего видео оставалось без длительности и кодеков
   * в деталке. Уже скачанное сырьё воркер отдаёт через captureVideoFromFile — без второго
   * скачивания из S3.
   */
  private async captureVideoFromObject(assetId: string, sha256: string, size: number): Promise<void> {
    if (size <= 0 || size > VIDEO_META_MAX_BYTES) {
      this.logger.debug(`видео ${sha256.slice(0, 8)}: ${size} байт — теги не читаем, слишком большой файл`);
      return;
    }
    const dir = mkdtempSync(join(tmpdir(), 'clq-vmeta-'));
    const path = join(dir, 'raw');
    try {
      await this.s3.downloadToFile(S3Service.assetKey(sha256), path);
      await this.storeVideoMeta(assetId, path);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }

  /** Теги видео из уже скачанного файла (воркер очереди качает сырьё под конвертацию). */
  async captureVideoFromFile(assetId: string, filePath: string): Promise<void> {
    if (await this.hasDetailedMeta(assetId)) return;
    await this.storeVideoMeta(assetId, filePath);
  }

  /**
   * EXIF из начала объекта (или из распакованного файла) → MediaMeta с полным набором тегов.
   * Источник — буфер, а не ключ S3: тот же разбор нужен и архивам, где объект уже на диске.
   */
  private async storeImageMeta(assetId: string, head: Buffer): Promise<boolean> {
    const core: Record<string, unknown> | null = await exifr
      .parse(head, {
        tiff: true, ifd0: true, exif: true, gps: true, interop: true,
        translateKeys: true, translateValues: true, reviveValues: true,
        mergeOutput: true, sanitize: true,
      } as never)
      .catch(() => null);
    const gps = await exifr.gps(head).catch(() => null);
    if (!core) return false;

    const num = asNum;
    const str = asStr;
    const latitude = gps?.latitude != null && Math.abs(Number(gps.latitude)) <= 90 ? Number(gps.latitude) : undefined;
    const longitude = gps?.longitude != null && Math.abs(Number(gps.longitude)) <= 180 ? Number(gps.longitude) : undefined;

    const raw: Record<string, unknown> = {
      kind: 'image',
      dateTimeOriginal: core.DateTimeOriginal instanceof Date ? core.DateTimeOriginal.toISOString() : str(core.DateTimeOriginal),
      createDate: core.CreateDate instanceof Date ? core.CreateDate.toISOString() : str(core.CreateDate),
      modifyDate: core.ModifyDate instanceof Date ? core.ModifyDate.toISOString() : str(core.ModifyDate),
      offsetTime: str(core.OffsetTimeOriginal) ?? str(core.OffsetTime),
      make: str(core.Make),
      model: str(core.Model),
      lens: str(core.LensModel) ?? str(core.Lens),
      software: str(core.Software),
      fNumber: num(core.FNumber),
      exposureTime: core.ExposureTime != null ? (Number(core.ExposureTime) < 1 ? `1/${Math.round(1 / Number(core.ExposureTime))}` : `${num(core.ExposureTime)} с`) : undefined,
      iso: num(core.ISO),
      focalLength: num(core.FocalLength),
      focalLength35: num(core.FocalLengthIn35mmFormat),
      exposureProgram: str(core.ExposureProgram),
      orientation: num(core.Orientation),
      colorSpace: str(core.ColorSpace),
      width: num(core.ExifImageWidth ?? core.ImageWidth),
      height: num(core.ExifImageHeight ?? core.ImageHeight),
      latitude,
      longitude,
      altitude: num((gps as { altitude?: number } | null)?.altitude),
      description: str(core.ImageDescription) ?? str(core['Caption-Abstract']),
      artist: str(core.Artist),
      copyright: str(core.Copyright),
    };

    // capturedAt считаем через exifInstant (с поправкой на OffsetTime*): exifr отдаёт
    // EXIF-время как локальное для сервера, из-за чего момент уезжал на пояс съёмки.
    const capturedAt = exifInstant(
      core.DateTimeOriginal,
      core.OffsetTimeOriginal ?? core.OffsetTime,
      core.SubSecTimeOriginal,
    );
    const width = num(core.ExifImageWidth ?? core.ImageWidth);
    const height = num(core.ExifImageHeight ?? core.ImageHeight);
    const make = str(core.Make) ?? null;
    const model = str(core.Model) ?? null;

    await this.prisma.mediaMeta.upsert({
      where: { assetId },
      create: { assetId, capturedAt, latitude, longitude, make, model, width, height, raw: raw as never },
      // update тоже правит колонки: строку мог создать captureMeta/enqueue (дата загрузки,
      // без GPS), и тогда таймлайн оставался с неверным моментом съёмки навсегда.
      update: { raw: raw as never, capturedAt, latitude, longitude, make, model, width, height },
    });
    // Нашли ли что-то по-настоящему: пустой raw вызывающему нужно трактовать как «не разобрали»
    // и читать файл дальше или целиком (см. hasUsefulRaw).
    return hasUsefulRaw(raw);
  }

  /** ffprobe по локальному файлу: длительность, кодек, GPS, дата съёмки. */
  private async storeVideoMeta(assetId: string, filePath: string): Promise<void> {
    const out = execFileSync(
      'ffprobe',
      ['-v', 'quiet', '-print_format', 'json', '-show_format', '-show_streams', filePath],
      { encoding: 'utf8', timeout: 120_000, maxBuffer: 16 * 1024 * 1024 },
    );
    const parsed = JSON.parse(out) as {
      format?: { duration?: string; bit_rate?: string; format_name?: string; tags?: Record<string, string> };
      streams?: Array<Record<string, unknown>>;
    };
    const video = (parsed.streams ?? []).find((st) => st.codec_type === 'video');
    const audio = (parsed.streams ?? []).find((st) => st.codec_type === 'audio');
    const fpsRaw = typeof video?.r_frame_rate === 'string' ? video.r_frame_rate.split('/') : [];
    const fps = fpsRaw.length === 2 && Number(fpsRaw[1]) ? Number(fpsRaw[0]) / Number(fpsRaw[1]) : undefined;
    const tags = parsed.format?.tags ?? {};
    const created = videoInstant(tags);
    // iPhone/Samsung держат геолокацию, камеру и идентификатор Live Photo в Apple Keys (mdta),
    // а не в EXIF — без этого видео не попадало на карту и в поездки.
    const pos = parseIso6709(tags['com.apple.quicktime.location.ISO6709']);
    const make = asStr(tags['com.apple.quicktime.make']) ?? asStr(tags.make) ?? null;
    const model = asStr(tags['com.apple.quicktime.model']) ?? asStr(tags.model) ?? null;
    const width = asNum(video?.width);
    const height = asNum(video?.height);

    const raw: Record<string, unknown> = {
      kind: 'video',
      durationSec: parsed.format?.duration ? Number(parsed.format.duration) : undefined,
      bitrate: parsed.format?.bit_rate ? Number(parsed.format.bit_rate) : undefined,
      container: parsed.format?.format_name,
      videoCodec: video?.codec_name,
      width,
      height,
      fps,
      audioCodec: audio?.codec_name,
      audioChannels: audio?.channels,
      audioSampleRate: audio?.sample_rate ? Number(audio.sample_rate) : undefined,
      createdAt: tags['com.apple.quicktime.creationdate'] ?? tags['creation_time'],
      make,
      model,
      latitude: pos?.latitude,
      longitude: pos?.longitude,
    };

    await this.prisma.mediaMeta.upsert({
      where: { assetId },
      create: { assetId, capturedAt: created, latitude: pos?.latitude, longitude: pos?.longitude, make, model, width, height, raw: raw as never },
      // update тоже правит колонки: строку уже создал queue.enqueue с датой загрузки,
      // поэтому create-ветка не выполнялась и видео навсегда оставалось в конце ленты.
      update: {
        raw: raw as never,
        capturedAt: created,
        latitude: pos?.latitude,
        longitude: pos?.longitude,
        make,
        model,
        width,
        height,
      },
    });
  }

  // ============ Таймлайн ============

  /**
   * Лента медиа: только зона «Фото», свежие сверху.
   *
   * Запрос написан на SQL, а не через Prisma. `orderBy` по связи Prisma превращает в LEFT JOIN
   * с сортировкой по алиасу, и тогда Postgres читает и сортирует все медиа пользователя: на
   * 100k это ~90 мс на страницу и внешняя сортировка на диск, а индекс по дате в таком плане
   * не используется вообще. С INNER JOIN и курсором по (capturedAt, id) план идёт по
   * MediaMeta_capturedAt_idx и останавливается на нужной странице: 2.6 мс (замер на 100k).
   *
   * `cursorEntryId` — запись, до которой клиент уже долистал: отдаём то, что идёт строго после
   * неё. Курсор — пара «дата съёмки + id», а не одна дата: серия кадров пишется в одну секунду,
   * и по дате часть снимков пропускалась или повторялась. Записи без даты съёмки идут в конце
   * ленты — так же, как их сортирует `NULLS LAST`.
   *
   * Курсора уже нет (запись удалили или она ушла из зоны «Фото» посреди прокрутки) — отвечаем
   * 409 `cursor_stale`: пустая страница означала бы «лента кончилась», и клиент перестал бы
   * догружать то, что осталось.
   */
  async timeline(userId: string, limit = 300, cursorEntryId?: string): Promise<TimelineItem[]> {
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return [];
    const cursor = cursorEntryId ? await this.timelineCursor(tree, cursorEntryId) : null;
    if (cursorEntryId && !cursor) throw conflict('timeline cursor is gone', 'cursor_stale');
    const take = Math.min(Math.max(limit, 1), TIMELINE_MAX);
    // «Строго после курсора» в том же порядке, что и ORDER BY: сначала по дате, внутри одной
    // секунды — по id, а хвост без даты (он в самом конце) — тоже по id.
    const after = !cursor
      ? Prisma.empty
      : cursor.capturedAt
        ? Prisma.sql`AND (mm."capturedAt" < ${MediaService.sqlTimestamp(cursor.capturedAt)}::timestamp
             OR (mm."capturedAt" = ${MediaService.sqlTimestamp(cursor.capturedAt)}::timestamp AND f."id" < ${cursor.id})
             OR mm."capturedAt" IS NULL)`
        : Prisma.sql`AND mm."capturedAt" IS NULL AND f."id" < ${cursor.id}`;
    const rows = await this.prisma.$queryRaw<TimelineRow[]>(Prisma.sql`
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
    return rows.map((r) => ({
      entryId: r.id,
      name: r.name,
      sha256: r.sha256 ?? undefined,
      capturedAt: r.capturedAt ? new Date(r.capturedAt).toISOString() : null,
      mime: r.mime,
      previewState: r.previewState,
      size: Number(r.size ?? 0),
    }));
  }

  /**
   * Статусы сборки превью по списку записей. Нужны, чтобы клиент обновлял именно те снимки,
   * которые ещё собираются, а не перечитывал из-за них всю ленту (на страницу в 1000 записей
   * это сотни килобайт каждые несколько секунд).
   *
   * Чужие и удалённые записи молча отбрасываем: ответ не должен подтверждать их существование.
   */
  async timelineStatus(userId: string, entryIds: unknown): Promise<TimelineStatusItem[]> {
    const ids = [...new Set(Array.isArray(entryIds) ? entryIds : [])]
      .filter((id): id is string => typeof id === 'string' && id.length > 0)
      .slice(0, TIMELINE_STATUS_MAX);
    if (!ids.length) return [];
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return [];
    const rows = await this.prisma.$queryRaw<TimelineStatusRow[]>(Prisma.sql`
      SELECT f."id", a."previewState", a."previewError", j."state" AS "jobState", j."error" AS "jobError"
      FROM "FileEntry" f
      JOIN "Asset" a ON a."id" = f."assetId"
      LEFT JOIN LATERAL (
        SELECT "state", "error" FROM "Job"
        WHERE "assetId" = a."id"
        ORDER BY "createdAt" DESC
        LIMIT 1
      ) j ON TRUE
      WHERE f."id" = ANY(${ids})
        AND f."deletedAt" IS NULL
        AND f."zone" = ${ZONE_PHOTOS}
        AND f."folderId" = ANY(${tree})
    `);
    return rows.map((r) => ({
      entryId: r.id,
      previewState: r.previewState,
      previewError: r.previewError ?? null,
      jobState: r.jobState ?? null,
      jobError: r.jobError ?? null,
    }));
  }

  /**
   * Колонки `capturedAt` у нас — `timestamp without time zone`, и Prisma пишет в них UTC-время
   * «как есть» (Date 2024-01-08T00:00Z остаётся 2024-01-08 00:00). А вот параметром Prisma
   * передаёт Date как timestamptz, и Postgres, сравнивая naive-колонку с timestamptz,
   * пересчитывает её в часовой пояс сессии: на сервере с Europe/Madrid граница уезжала на час,
   * и запись-курсор попадала в следующую страницу (проверено scripts/timeline-check.mjs).
   * Поэтому дату передаём строкой и приводим к timestamp явно — без часового пояса.
   */
  private static sqlTimestamp(value: Date): string {
    return value.toISOString().slice(0, 23).replace('T', ' ');
  }

  /** Дата и id записи, от которой продолжать ленту. Чужая/вне зоны «Фото» — не курсор. */  private async timelineCursor(
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
    })) as any;
    if (!row) return null;
    return { capturedAt: row.asset?.media?.capturedAt ?? null, id: String(row.id) };
  }
}
