import { Injectable, Logger } from '@nestjs/common';
import { execFileSync } from 'child_process';
import { mkdtempSync, rmSync } from 'fs';
import { readFile, statfs } from 'fs/promises';
import { tmpdir } from 'os';
import { join } from 'path';
import * as exifr from 'exifr';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';

/**
 * Фото, которые мы умеем конвертировать: `mediaKindOf` ставит на них задачу 'photo' (sharp).
 *
 * Это НЕ список того, что видно в ленте «Медиа»: лента строится по строкам `MediaMeta`
 * (`src/media-feed/media-feed.service.ts`), а их получает любой `image/*` — RAW камер,
 * BMP, JXL (см. captureAny). Такие файлы попадают в раздел «Медиа», просто без превью.
 */
export const IMAGE_MIMES = ['image/jpeg', 'image/heic', 'image/heif', 'image/png', 'image/webp', 'image/tiff', 'image/avif', 'image/gif'];
/**
 * Видео, которые считаем медиа и ставим на конвертацию. Тип объявляет клиент, и кроме mp4/mov
 * от телефонов приходят 3GP/3GP2 со старых аппаратов (`video/3gpp` — так его называет и наш
 * Flutter-клиент для `.3gp`): пока их тут не было, файл не считался медиа вообще — ни строки
 * `MediaMeta` (не появлялся в ленте), ни задачи (очередь помечала «превью не собираются»).
 */
export const VIDEO_MIMES = [
  'video/mp4', 'video/quicktime', 'video/x-m4v', 'video/webm', 'video/x-matroska', 'video/avi', 'video/ogg', 'video/mpeg',
  'video/3gpp', 'video/3gpp2', 'video/mp4v-es', 'video/mpeg4', 'video/x-msvideo',
];
/** PDF рендерим сами (poppler): в списке — миниатюра первой страницы, в деталке — все страницы. */
export const PDF_MIMES = ['application/pdf'];
/** Ширина превью страницы PDF. */
export const PDF_PAGE_WIDTH = 1080;
/** Сколько страниц рисует одна задача: большое PDF иначе держало бы воркер минутами. */
export const PDF_PAGES_PER_JOB = 40;

/** Это видео? Решаем по префиксу: контейнер ffmpeg всё равно определяет по содержимому файла. */
export function isVideoMime(mime: unknown): boolean {
  return String(mime ?? '').toLowerCase().startsWith('video/');
}

/** Это картинка? Любой `image/*`: RAW камер (DNG/CR2/NEF) и BMP sharp не конвертирует, но в ленте им быть. */
export function isImageMime(mime: unknown): boolean {
  return String(mime ?? '').toLowerCase().startsWith('image/');
}

/**
 * Вид задачи конвейера по MIME; null — конвертировать нечем (превью не будет, но в ленте файл
 * остаётся).
 *
 * Видео — по префиксу: объявленный клиентом тип бывает и `video/3gpp`, и `video/x-msvideo`,
 * а ffmpeg разбирает контейнер по содержимому. Для фото список остаётся точным: sharp умеет
 * не всё, и задача на BMP/JXL только занимала бы очередь заведомо провальной работой.
 */
export function mediaKindOf(mime: unknown): 'photo' | 'video' | 'pdf' | null {
  const m = String(mime ?? '').toLowerCase();
  if (IMAGE_MIMES.includes(m)) return 'photo';
  if (isVideoMime(m)) return 'video';
  if (PDF_MIMES.includes(m)) return 'pdf';
  return null;
}
/**
 * Размер превью для списка (сетка галереи): квадрат GRID_SIZE×GRID_SIZE.
 *
 * Число — про физические пиксели, а не логические. Сетка показывает четыре кадра в ряд: на
 * экране 360 dp клетка — это 88 dp, а на DPR 3 — 264 физических пикселя. Квадрат 256×256
 * покрывает клетку почти один в один (апскейла нет), и небольшой запас работает на экранах
 * с DPR выше среднего.
 *
 * Цена — вес: AVIF q60 в 256 px это ~10 КиБ на кадр против 2.4 КиБ в 100 px, то есть вся
 * библиотека в 51 700 кадров занимает 515 МиБ данных вместо 119 МиБ (627 МиБ на телефоне с
 * округлением до блока файловой системы). Это следствие размера сетки: четыре кадра в ряд
 * при 100 px означали бы растяжение картинки в 3.5 раза.
 *
 * Ключ в S3 не содержит фактического размера (`-512.avif` — историческое имя сетки), поэтому
 * смена размера не создаёт новых объектов: старые перезаписываются по тому же ключу скриптом
 * `scripts/rebuild-grid.mjs`, который сверяет фактическую ширину объекта с GRID_SIZE.
 */
export const GRID_SIZE = 256;
/**
 * Качество AVIF для сетки. То же, что у полного превью (60): шкала AVIF не как у JPEG,
 * на глаз это ≈ JPEG 85–90, а на квадрате 100×100 разница между 50 и 60 видна слабо,
 * зато на трафике первой загрузки всей библиотеки она заметна.
 */
export const GRID_QUALITY = 60;
/**
 * Начало файла для EXIF. Для JPEG этого всегда хватает, а у HEIC/HEIF новых телефонов и у
 * файлов из архивов Takeout теги лежат глубже — тогда читаем объект целиком (см.
 * storeImageMetaFromObject): обрезанное начало exifr разбирает в пустой результат.
 */
const EXIF_HEAD_BYTES = 4 * 1024 * 1024;
/** Ширина полноэкранного превью фото (и превью страницы PDF — та же величина). */
export const FULL_SIZE = 1080;
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
 * Запас свободного места во временном каталоге, который оставляем после скачивания видео для
 * разбора тегов: параллельно в том же каталоге работает очередь конвертации, и забить диск
 * под ноль означает уронить и воркер, и всё остальное на VPS.
 */
const TMP_FREE_RESERVE_BYTES = 512 * 1024 * 1024;

/**
 * Разбор дал хоть что-то? В `raw` есть служебный `kind` и поля; если кроме `kind` ничего
 * нет — это не метаданные, а след неудачного разбора. Так выглядит обрезанное начало файла:
 * exifr на неполном HEIC/HEIF возвращает объект с одной ошибкой (`{errors:[…]}`), из которого
 * не извлекается ни одного поля. Раньше такой `raw` считался готовыми метаданными, и фото
 * навсегда оставалось без даты, камеры и кадра — ни запасной полный разбор, ни ленивый
 * разбор при открытии деталки больше не запускались.
 *
 * Этого ответа мало для вопроса «разбор закончен»: у HEIC голова отдаёт только Make/Model,
 * и такой частичный `raw` тоже непустой. См. hasCompleteRaw.
 */
export function hasUsefulRaw(raw: unknown): boolean {
  if (!raw || typeof raw !== 'object') return false;
  return Object.entries(raw as Record<string, unknown>).some(
    ([k, v]) => k !== 'kind' && v !== undefined && v !== null && v !== '',
  );
}

const rawFilled = (v: unknown): boolean => v !== undefined && v !== null && v !== '';

/**
 * Разбор ЗАКОНЧЕН? Проверяем не «в raw что-то есть», а «есть то, ради чего разбор делается»:
 * дата, координаты или размер кадра. Иначе частичный результат (например, из головы файла
 * достались только Make/Model/Software) закрывал бы дорогу к полному разбору — и фото из
 * архива Takeout оставалось без даты и без точки на карте навсегда.
 */
export function hasCompleteRaw(raw: unknown): boolean {
  if (!hasUsefulRaw(raw)) return false;
  const r = raw as Record<string, unknown>;
  if (r.kind === 'image') return rawFilled(r.dateTimeOriginal) || r.latitude != null || r.width != null;
  if (r.kind === 'video') return r.durationSec != null || r.width != null || rawFilled(r.createdAt);
  return true;
}

/**
 * Дата в `raw` пришла из тегов файла (EXIF `DateTimeOriginal` / теги контейнера видео), а не
 * поставлена «на глаз» при загрузке или распаковке? Именно эти ключи и только они попадают
 * в колонку `capturedAt` (см. storeImageMeta / storeVideoMeta).
 */
export function rawHasCapturedDate(raw: unknown): boolean {
  if (!raw || typeof raw !== 'object') return false;
  const r = raw as Record<string, unknown>;
  return rawFilled(r.dateTimeOriginal) || rawFilled(r.createdAt);
}

/**
 * Смещение пояса съёмки в минутах на восток от UTC или null, если в файле его не было.
 *
 * Фото: EXIF `OffsetTimeOriginal` («+03:00»). Видео: `com.apple.quicktime.creationdate`
 * («2023-11-18T12:24:00+0300») — в нём пояс записи; `creation_time` всегда UTC и пояса
 * съёмки не знает, поэтому «Z» даёт null (неизвестно), а не 0.
 *
 * Нужно клиенту: `capturedAt` — истинный UTC-момент, и чтобы показать «время как в файле»,
 * приложению нужен именно этот сдвиг, а не пояс устройства.
 */
export function parseTzOffsetMin(v: unknown): number | null {
  if (typeof v !== 'string') return null;
  const m = /([+-])(\d{2}):?(\d{2})$/.exec(v.trim());
  if (!m) return null;
  const hours = Number(m[2]);
  const minutes = Number(m[3]);
  if (!Number.isFinite(hours) || !Number.isFinite(minutes) || hours > 14 || minutes > 59) return null;
  const total = hours * 60 + minutes;
  return m[1] === '-' ? -total : total;
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
 *
 * ВАЖНО про пояс процесса: fallback (когда OffsetTime* в файле нет) возвращает Date как есть,
 * а он читается в поясе сервера — прод обязан работать с TZ=UTC, иначе у фото без OffsetTime*
 * (сканер, старый телефон) и у `raw.dateTimeOriginal` (он пишется как ISO этого же Date)
 * уезжает время. Пояс нигде в репозитории не выставляется — его нужно задать в окружении.
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
 * Выдержка строкой для деталки: «1/120» короче секунды, иначе «2.5 с».
 * Ноль и мусор отдаём как «нет данных»: `1/ExposureTime` при нуле давал «1/Infinity».
 */
function exposureText(v: unknown): string | undefined {
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) return undefined;
  return n < 1 ? `1/${Math.round(1 / n)}` : `${n} с`;
}

/**
 * Свободно байт во временном каталоге (null — не смогли узнать: тогда скачивание не
 * блокируем, разбор тегов важнее консервативной проверки).
 */
async function freeTmpBytes(): Promise<number | null> {
  try {
    const st = await statfs(tmpdir());
    return Number(st.bsize) * Number(st.bavail);
  } catch {
    return null;
  }
}

/**
 * Ключи производных в S3 и разбор метаданных (EXIF фото / ffprobe видео).
 *
 * Владелец разбора — этот сервис: и путь загрузки (`captureAny` — читает объект из S3),
 * и путь архива (`captureMetaFromFile` — читает локальный файл воркера), и ленивый разбор
 * при открытии деталки (`extractDetail`) ходят в одни и те же `storeImageMeta`/
 * `storeVideoMeta`, поэтому и колонки, и `raw` заполняются одинаково.
 *
 * Очередь (`src/queue/queue.service.ts`) — второй автор `MediaMeta`: она пишет дату загрузки
 * при постановке задачи и умеет разобрать теги видео сама (свой ffprobe, `raw` не пишет).
 * Пока это дублирование не устранено, «разбор закончен» считается здесь и по `hasCompleteRaw`,
 * а не по «в raw что-то есть».
 */
@Injectable()
export class MediaService {
  private readonly logger = new Logger(MediaService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
  ) {}

  static viewKey(sha256: string, suffix: string): string {
    return `view/${sha256}${suffix}`;
  }
  /**
   * Превью для списка (сетка галереи): квадрат GRID_SIZE×GRID_SIZE, фото и видео одинаково.
   *
   * Формат — AVIF, как у полноэкранного превью: один формат на все производные проще в
   * обслуживании, а AVIF при том же качестве легче WebP (замер на библиотеке: 2425 против
   * 2788 байт на кадр 100×100). На месте в кэше телефона это выигрыша не даёт — файл короче
   * 4 КиБ всё равно занимает блок, — но трафик первой загрузки меньше: 120 МиБ против 137 МиБ
   * на 51 700 кадров.
   *
   * «512» в имени — историческое обозначение сетки, а не сторона квадрата: сторона — GRID_SIZE.
   * Ключ намеренно не содержит фактического размера, иначе смена GRID_SIZE плодила бы объекты.
   */
  static gridKey(sha256: string): string {
    return MediaService.viewKey(sha256, '-512.avif');
  }
  /**
   * Сетка прежнего пайплайна в WebP. Больше не создаётся, но читается запасным вариантом:
   * пока библиотека не пересобрана (`scripts/rebuild-grid.mjs`), под этим ключом лежит
   * рабочее превью, и отдавать вместо него 404 нельзя.
   */
  static legacyGridKey(sha256: string): string {
    return MediaService.viewKey(sha256, '-512.webp');
  }
  /** Полноэкранное превью фото (1080, AVIF; у анимированных источников — WebP). */
  static photoFullKey(sha256: string): string {
    return MediaService.viewKey(sha256, `-${FULL_SIZE}.avif`);
  }
  /** Постер видео для списка (тот же квадрат GRID_SIZE×GRID_SIZE). */
  static videoPosterKey(sha256: string): string {
    return MediaService.viewKey(sha256, '-poster.webp');
  }
  /** Полноэкранное превью видео (1080; H.264, у старых ассетов — AV1). */
  static video1080Key(sha256: string): string {
    return MediaService.viewKey(sha256, '-1080.mp4');
  }
  /** Превью страницы PDF (1080 px по ширине, WebP): номер страницы с единицы. */
  static pdfPageKey(sha256: string, page: number): string {
    return MediaService.viewKey(sha256, `-p${page}-${PDF_PAGE_WIDTH}.webp`);
  }

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
   * pageCount нужен только для PDF: страничные превью — это переменный набор ключей, и
   * перечислить их по числу страниц можно лишь тогда, когда рендер дошёл до конца (`pageCount`
   * пишет только finishPdf в очереди). Если задача PDF упала на середине, уже нарисованные
   * страницы тут не перечислятся и останутся в бакете — их подберёт ручной sweep-orphans.
   * Чтобы удалять их сразу, вызывающему нужно перечислять ключи по префиксу
   * (`S3Service.listKeys('view/<sha>-p')` — так это делает convertPdf).
   */
  static derivativeKeys(sha256: string, pageCount?: number | null): string[] {
    const pages = pageCount && pageCount > 0
      ? Array.from({ length: pageCount }, (_, i) => MediaService.pdfPageKey(sha256, i + 1))
      : [];
    return [
      MediaService.gridKey(sha256),
      MediaService.legacyGridKey(sha256),
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

  /**
   * То же, но из ЛОКАЛЬНОГО файла: воркер очереди уже скачал сырьё под конвертацию, поэтому
   * повторный трафик S3 не нужен. Нужно для медиа, у которого строки `MediaMeta` ещё нет —
   * прежде всего для фото из архивов (при распаковке разбор идёт фоном и может не успеть).
   *
   * Разбор здесь тот же, что и для объекта из S3 (`storeImageMeta`), вместе с записью `raw`:
   * раньше этот путь писал только колонки, и в деталке кадра не было ни объектива, ни
   * диафрагмы, ни ISO — хотя EXIF был прочитан (деталка читает параметры из `raw`).
   */
  async captureMetaFromFile(assetId: string, filePath: string, size: number, mime: string): Promise<void> {
    if (size <= 0 || size > MAX_PARSE_BYTES) return;
    if (!IMAGE_MIMES.includes(mime)) return; // видео разберёт воркер (captureVideoFromFile → ffprobe)
    try {
      const buf = await readFile(filePath);
      await this.storeImageMeta(assetId, buf);
    } catch (e) {
      this.logger.debug(`EXIF skip (local): ${(e as Error).message}`);
    }
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
   * Разбираем ЛЮБОЙ image/* и ЛЮБОЙ video/*, а не только те типы, что умеет sharp: RAW камер
   * (DNG, CR2, NEF, ARW) не конвертируется, но exifr читает его TIFF-производные теги, а
   * 3GP/BMP/JXL не попадали в ленту «Медиа» вообще — и владелец видел «часть фото пропала».
   *
   * Про дату: `capturedAt` — истинный UTC-момент съёмки, а не «время как в файле». Если даты
   * в файле нет (видео без creation_time, скриншот), сюда попадает дата загрузки или архива,
   * и отличить её от настоящей съёмки в контракте нечем. Такая «на глаз» поставленная дата
   * не блокирует настоящую: см. fillDateAndGeo.
   */
  async captureAny(assetId: string, sha256: string, size: number, mime: string): Promise<void> {
    if (size <= 0 || size > MAX_PARSE_BYTES) return;
    const isVideo = isVideoMime(mime);
    const isImage = isImageMime(mime);
    if (!isVideo && !isImage) return;
    if (await this.hasDetailedMeta(assetId)) return;
    if (isVideo) {
      // Строка MediaMeta нужна сразу: лента «Медиа» строится по ней, и без строки видео не
      // видно в разделе, пока воркер не соберёт теги. Дата — дата загрузки: настоящую дату
      // съёмки она не блокирует (fillDateAndGeo перетирает дату, не подтверждённую тегами).
      await this.ensureMediaRow(assetId, new Date());
      void this.extractDetail(assetId, sha256, size, mime).catch(() => undefined);
      return;
    }
    // Быстрый путь: EXIF почти всегда в первых килобайтах, поэтому сначала читаем маленькую
    // голову, а полный разбор (4 МБ) оставляем на случай, когда метаданные лежат дальше
    const head = await this.s3
      .readRange(S3Service.assetKey(sha256), 0, Math.min(size, META_HEAD_BYTES) - 1)
      .catch(() => null);
    if (head && (await this.storeImageMeta(assetId, head))) return;
    if (IMAGE_MIMES.includes(mime)) {
      // метаданные лежат дальше головы — читаем 4 МБ, потом объект целиком
      await this.extractDetail(assetId, sha256, size, mime).catch(() => undefined);
    }
    // Строка MediaMeta обязана быть у любого фото: у BMP/JXL/PNG без EXIF разбирать нечего,
    // но лента «Медиа» строится по MediaMeta — без строки файл из «Фото» просто исчезает
    // из раздела (превью у него всё равно не будет: mediaKindOf скажет «не собираются»).
    await this.ensureMediaRow(assetId);
  }

  /** Строка MediaMeta есть? Создаём минимальную: лента «Медиа» строится по ней (см. captureAny). */
  private async ensureMediaRow(assetId: string, capturedAt?: Date): Promise<void> {
    await this.prisma.mediaMeta
      .upsert({ where: { assetId }, create: { assetId, capturedAt }, update: {} })
      .catch(() => undefined);
  }

  /**
   * Проставить дату съёмки и координаты, если разбор их не нашёл. Нужно для файлов без EXIF
   * (скриншоты, картинки из мессенджеров) и для видео без creation_time: иначе у них нет даты
   * вообще, и в ленте они не появляются.
   *
   * Дату из тегов не перетираем: EXIF и ffprobe точнее, чем дата из архива или сайдкара.
   * Но перетираем дату, которой в файле не было: видео, залитое в 2024-м, получает на загрузке
   * `capturedAt = new Date()` (иначе его нет в ленте), и раньше этот «сейчас» навсегда
   * закрывал дорогу настоящей дате съёмки из Takeout-архива — ролик 2015 года вставал первым
   * в ленте, в текущем месяце индекса и в начале выдачи карты. Признак «дата пришла из тегов»
   * — сам `raw` (его пишут только storeImageMeta/storeVideoMeta), см. rawHasCapturedDate.
   */
  async fillDateAndGeo(
    assetId: string,
    capturedAt: Date | null,
    geo?: { latitude: number; longitude: number } | null,
  ): Promise<void> {
    if (!capturedAt && !geo) return;
    const known = await this.prisma.mediaMeta
      .findUnique({
        where: { assetId },
        select: { capturedAt: true, latitude: true, longitude: true, raw: true },
      })
      .catch(() => null);
    const keepDate = Boolean(known?.capturedAt) && rawHasCapturedDate(known?.raw);
    const patch = {
      ...(keepDate || !capturedAt ? {} : { capturedAt }),
      ...(known?.latitude != null || !geo ? {} : { latitude: geo.latitude, longitude: geo.longitude }),
    };
    if (!Object.keys(patch).length) return;
    await this.prisma.mediaMeta
      .upsert({ where: { assetId }, create: { assetId, capturedAt, ...(geo ?? {}) }, update: patch })
      .catch(() => undefined);
  }

  /**
   * Разбор уже дал подробности — те, ради которых он и делается (дата, координаты, кадр).
   *
   * Проверять только `raw != null` нельзя: пустой `raw` остаётся после неудачного разбора
   * обрезанного начала файла, и тогда и повторная загрузка того же содержимого, и ленивый
   * разбор при открытии деталки решали, что ходить в хранилище незачем. Одного «в raw что-то
   * есть» тоже мало (hasUsefulRaw): частичный результат из головы файла так же закрывает
   * дорогу полному разбору — см. hasCompleteRaw.
   */
  async hasDetailedMeta(assetId: string): Promise<boolean> {
    const known = await this.prisma.mediaMeta
      .findUnique({ where: { assetId }, select: { raw: true } })
      .catch(() => null);
    return hasCompleteRaw(known?.raw);
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

      if (isVideoMime(mime)) {
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
    const head = await this.s3.readRange(key, 0, Math.min(size, EXIF_HEAD_BYTES) - 1);
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
   *
   * Объект скачивается целиком (потолок VIDEO_META_MAX_BYTES): метаданные контейнера лежат
   * и в конце файла, а читать их head/tail-диапазонами — угадывать, где именно. Поэтому перед
   * скачиванием проверяем свободное место: вызов прилетает фоном с пути загрузки, и пачка
   * больших видео иначе выедала бы диск у воркера конвертации.
   */
  private async captureVideoFromObject(assetId: string, sha256: string, size: number): Promise<void> {
    if (size <= 0 || size > VIDEO_META_MAX_BYTES) {
      this.logger.debug(`видео ${sha256.slice(0, 8)}: ${size} байт — теги не читаем, слишком большой файл`);
      return;
    }
    const free = await freeTmpBytes();
    if (free != null && free < size + TMP_FREE_RESERVE_BYTES) {
      this.logger.warn(
        `видео ${sha256.slice(0, 8)}: ${Math.round(size / 1024 / 1024)} МБ тегов пропущено — свободно ${Math.round(free / 1024 / 1024)} МБ во временном каталоге`,
      );
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
      // Выдержка строкой: при ExposureTime = 0 «1/∞» превращалось в «1/Infinity».
      exposureTime: exposureText(core.ExposureTime),
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
      // update тоже правит колонки: строку мог создать captureAny/enqueue (дата загрузки,
      // без GPS), и тогда лента оставалась с неверным моментом съёмки навсегда.
      update: { raw: raw as never, capturedAt, latitude, longitude, make, model, width, height },
    });
    // Нашли ли что-то по-настоящему: и пустой raw, и частичный (только Make/Model) вызывающему
    // нужно трактовать как «не разобрали» и читать файл дальше или целиком (см. hasCompleteRaw).
    return hasCompleteRaw(raw);
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

}
