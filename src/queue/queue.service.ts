import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { execFile as execFileCb, spawn } from 'child_process';
import { promisify } from 'util';
import { closeSync, existsSync, mkdirSync, openSync, readdirSync, readSync, rmSync, statfsSync, statSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import sharp from 'sharp';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import {
  FULL_SIZE,
  GRID_SIZE,
  MediaService,
  PDF_PAGES_PER_JOB,
  PDF_PAGE_WIDTH,
  mediaKindOf,
} from '../media/media.service';
import { ZONE_PHOTOS } from '../common/zones';
import { CONVERT_MAX_BYTES, env } from '../config/env';

/** Асинхронный запуск бинаря с захватом stdout: см. pdfPageCount/probeSource. */
const execFile = promisify(execFileCb);

/**
 * CONVERT_ENABLED читается как строка (в env у неё z.string(), а не booleanish, в отличие от
 * KEEP_ORIGINALS и MAIL_SYNC_ENABLED), поэтому раньше значение `1` молча выключало конвертер:
 * `'1' !== 'true'`. Здесь те же правила, что у остальных флагов окружения.
 */
const CONVERT_ENABLED = /^(true|1|yes|on)$/i.test(String(env.CONVERT_ENABLED ?? '').trim());
/** Лимит памяти на процесс задачи: `?? 1024` убран — у env есть собственный дефолт 3072. */
const WORKER_MEM_KB = env.CONVERT_MEM_MB * 1024; // виртуальная память на ffmpeg (по умолчанию 3 ГБ)
/** Кодек полноэкранного превью видео (см. videoEncodeArgs). */
const VIDEO_CODEC = env.CONVERT_VIDEO_CODEC;
/**
 * Preset и CRF превью. Шкалы у кодеков разные, и разницу видно только замером: на проде
 * 3 с 4K50-ролика (608×1080, 150 кадров) против lossless-референса дали
 *   AV1 crf 36 — SSIM 0.9693, PSNR 37.65 (1182 КБ)
 *   H.264 crf 26 — SSIM 0.9431, PSNR 34.38 (772 КБ)   ← заметно хуже
 *   H.264 crf 20 — SSIM 0.9720, PSNR 38.46 (2083 КБ)  ← как AV1 или лучше
 * Поэтому 20, а не 26: превью должно выглядеть как оригинал, а по времени качество тут
 * бесплатно — энкод упирается в декодер исходника (3.6 с против 3.8 с на все три CRF).
 * Цена — файл примерно в 1.7 раза тяжелее AV1-превью (и всё ещё в 9 раз легче оригинала
 * этого ролика: 5.5 Мбит/с против 48).
 */
const X264_PRESET = 'veryfast';
const X264_CRF = 20;
const AV1_CRF = 36;
/**
 * ffmpeg всегда с -hide_banner -loglevel error. Без них первое, что попадает в stderr, — баннер
 * сборки, и в Job.error (600 символов) уезжала версия с конфигурацией вместо причины сбоя:
 * у одного упавшего видео так и осталось «ffmpeg version 7.0.2-static … built with gcc 8».
 */
const FFMPEG = ['ffmpeg', '-hide_banner', '-loglevel', 'error'];
/** Опции sharp для чтения исходника: анимация сохраняется, предупреждения декодера не валят задачу. */
const SHARP_IN = { animated: true, failOn: 'truncated' } as const;
/**
 * HDR → SDR. 8-битный H.264 с BT.2020/PQ-источника выглядит выцветшим, поэтому кадр
 * переводится в линейный свет, тонапмапится (hable) и возвращается в BT.709.
 * Фильтры (zscale/tonemap) приходят с libzimg — проверено на проде: в сборке есть.
 */
const TONEMAP_SDR =
  'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p';

/**
 * Сколько ФОТО-задач считать одновременно. Фото упираются в ядра (AVIF-энкод и heif-convert),
 * поэтому на 2 ядрах смысл есть в 2 потоках, на 4 — в 3-4. Видео и PDF всегда идут по одному:
 * видео занимает ядра целиком (H.264 упирается в декодер, AV1-ветка — в сам энкодер), и второй
 * такой процесс лишь замедлил бы оба.
 */
const PHOTO_PARALLEL = Math.min(Math.max(Number(env.CONVERT_PHOTO_PARALLEL ?? 1) || 1, 1), 8);
/**
 * Пускать видео параллельно с фото. По умолчанию нет: видео занимает ядра целиком (H.264
 * упирается в декодер исходника, AV1-ветка — в сам энкодер), и фото рядом с ним идут в разы
 * медленнее (замер на libaom: 3,4 с против 19,4 с). Флаг имеет смысл на машине с большим
 * числом ядер, где фото-слоты не съедают всё.
 */
const VIDEO_ALONGSIDE_PHOTOS = (env.CONVERT_VIDEO_ALONGSIDE_PHOTOS ?? 'false') === 'true';
const MAX_ATTEMPTS = 3;
/**
 * Причина, по которой превью не собрать: оригинала нет в хранилище. Единственная из причин,
 * которая может перестать быть верной (файл залили снова), поэтому её и только её `enqueue`
 * умеет снимать; «слишком большой» и «тип не конвертируется» — свойства содержимого.
 */
const NO_ORIGINAL = 'оригинала нет в хранилище';
/** Задержка перед повтором временно упавшей задачи (умножается на номер попытки). */
const RETRY_BASE_DELAY_MS = 30_000;
/**
 * Временная ошибка: сеть/S3 могут отпустить сами — повтор осмыслен.
 * Всё остальное (таймаут энкода, память libaom, битый контейнер) повторится тем же
 * результатом, только займёт очередь: задача одна за раз, а энкод идёт часами.
 */
const TRANSIENT_ERR =
  /(NetworkingError|TimeoutError|RequestTimeout|ECONNRESET|ECONNREFUSED|EPIPE|ETIMEDOUT|EAI_AGAIN|ENOTFOUND|socket hang up|network|throttl|SlowDown|ServiceUnavailable|InternalError|reduce your request rate|(?:HTTP|Status Code): 5\d\d)/i;
/** Сколько символов stderr кладём в Job.error (раньше в БД уезжал дамп настроек libaom на 1.5 КБ). */
const MAX_ERROR_CHARS = 600;
/** Окно статистики для оценки срока: 6 часов — оценка успевает следовать за настройками. */
const STAT_WINDOW_MS = 6 * 60 * 60 * 1000;
/** Сколько последних задач вида берём для медианы: 500 хватает с запасом (это минуты работы). */
const STAT_SAMPLE = 500;
/** Сколько хранить статистику конвертации (чистится попутно, вероятность 1% на задачу). */
const STAT_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
/** Префикс временных каталогов задач — для чистки осиротевших после SIGKILL/pm2 reload. */
const TMP_PREFIX = 'clq-';
/** Файл задачи старше этого возраста считаем мусором (мастер 4K может идти часами). */
const TMP_STALE_MS = 12 * 60 * 60 * 1000;
/** Как часто подчищать осиротевшее, пока конвертер работает не перезапускаясь. */
const TMP_CLEAN_EVERY_MS = 10 * 60 * 1000;
/**
 * Меньше этого запаса на разделе с /tmp — новые задачи не берём. Диск на VPS общий: место
 * занимают и БД, и nginx, и другие сервисы, а «диск кончился» роняет всё сразу — API отвечает
 * 500, деплой падает на scp, Postgres не может писать. Превью не стоят такого риска.
 */
const MIN_FREE_BYTES = 5 * 1024 * 1024 * 1024;
/**
 * Сколько задача вида может висеть в `processing`, не числясь в `active`, до принудительного
 * возврата в очередь. Порог — заведомо больше самого долгого честного прогона вида:
 * фото (heif-convert 120 с и ffmpeg 180 с на кадр), PDF (до PDF_PAGES_PER_JOB страниц по 180 с),
 * видео (энкод с таймаутом 6 часов). Без этого утечка слота (исключение до try, зависший
 * S3-запрос) останавливает группу задач до ручного рестарта.
 */
const STUCK_MS: Record<JobGroup, number> = {
  photo: 30 * 60 * 1000,
  pdf: 6 * 60 * 60 * 1000,
  video: 13 * 60 * 60 * 1000,
};
/** Как часто сверяем `processing` с `active` (см. reapStuckJobs). */
const REAP_EVERY_MS = 60 * 1000;
/**
 * Через сколько видео перестаёт ждать пустой фото-очереди. Иначе непрерывный поток фото
 * (счётчик `pendingPhotos` глобальный — по всем пользователям) не даёт видео стартовать
 * никогда: в интерфейсе это «осталось видео: 700» с вечным сроком.
 */
const VIDEO_STARVE_MS = 2 * 60 * 60 * 1000;

/** Параметры источника, влияющие на команду ffmpeg (HDR/10 бит/каналы/длительность). */
interface SourceProbe {
  duration: number;
  width?: number;
  height?: number;
  pixFmt?: string;
  colorPrimaries?: string;
  colorTrc?: string;
  colorSpace?: string;
  colorRange?: string;
  channels?: number;
  /** Кодек аудиодорожки: AAC из исходника копируем, не перекодируя. */
  audioCodec?: string;
  /** Теги контейнера: com.apple.quicktime.* (GPS, камера, дата) и creation_time. */
  tags?: Record<string, string>;
  /** 10 бит и/или HDR-трансфер: 8-битный выход потеряет точность (полосы/пересветы). */
  hdr: boolean;
}

/** Результат конвертации: warn — мастер не собрался, keepRaw — оригинал обязателен. */
interface ConvertResult {
  warn?: string;
  keepRaw?: boolean;
  /**
   * Работа не закончена и не упала (PDF: отрисована порция страниц) — строку задачи не
   * удаляем, а возвращаем в очередь. Вторую строку на тот же ассет не создаём никогда:
   * именно из-за неё файл и выглядел в очереди задвоенным.
   */
  requeue?: boolean;
}

function truncErr(msg: string): string {
  const s = String(msg ?? '');
  return s.length > MAX_ERROR_CHARS ? `${s.slice(0, MAX_ERROR_CHARS)}…` : s;
}

/**
 * Человеческое объяснение известных постоянных сбоев. Приписывается в конец ошибки: UI
 * показывает хвост строки (shortErr), поэтому объяснение должно быть последним, а полный
 * текст инструмента остаётся в начале. Пользователю важно понимать, что файл не «завис»,
 * а не читается, и что оригинал при этом цел и скачивается.
 */
function humanHint(msg: string): string | null {
  if (/HEIF\/AVIF file: Invalid input|not an HEIF\/AVIF file|Too many auxiliary image/i.test(msg)) {
    return 'HEIC не читается системным libheif 1.12 (внутри сетка тайлов, gain map и aux-картинки) — оригинал цел';
  }
  if (/VipsJpeg: Invalid SOS parameters/i.test(msg)) {
    return 'в JPEG испорчено поле SOS (так его сохранил сторонний редактор) — оригинал цел';
  }
  if (/VipsJpeg: (Corrupt JPEG data|premature end)/i.test(msg)) {
    return 'JPEG повреждён внутри — превью по нему не собрать';
  }
  return null;
}

interface JobRow {
  id: string;
  assetId: string;
  kind: string;
  sha256: string;
  mime: string;
}

/**
 * Группы задач в очереди. Фото и PDF дешёвые (секунды-минуты), видео — минуты и больше
 * (4K-источник упирается в декодер, AV1-ветка — в энкодер), поэтому у него отдельное
 * правило: оно не идёт, пока в очереди есть фото.
 */
type JobGroup = 'photo' | 'pdf' | 'video';

@Injectable()
export class QueueService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger('Queue');
  private timer: NodeJS.Timeout | null = null;
  private stopped = false;
  /** Тик не перекрывается сам с собой (задачи внутри тика запускаются параллельно). */
  private ticking = false;
  /** Когда последний раз подчищали /tmp (см. TMP_CLEAN_EVERY_MS). */
  private tmpCleanedAt = Date.now();
  /** Когда последний раз сверяли `processing` с `active` (см. REAP_EVERY_MS). */
  private reapedAt = Date.now();
  /** Когда последний раз жаловались на кончающееся место: в лог, а не в спам каждые 2 секунды. */
  private lowDiskWarnedAt = 0;
  /**
   * Задачи в работе сейчас: id → { assetId, group, child } — по нему считаются свободные слоты
   * (фото идут параллельно) и убивается процесс задачи по таймауту.
   */
  private readonly active = new Map<string, { assetId: string; group: JobGroup; child: import('child_process').ChildProcess | null }>();
  /** Короткий кэш числа ожидающих фото: по нему решается, брать ли видео. */
  private photoPendingCache: { at: number; value: number } | null = null;
  /** Короткий кэш «видео голодает»: по нему видео берётся вне очереди за фото (VIDEO_STARVE_MS). */
  private videoStarveCache: { at: number; value: boolean } | null = null;
  /** Кэш средней длительности задач по видам (см. estimates): статус спрашивают часто. */
  private estCache: { at: number; value: Record<string, { avgMs: number | null; samples: number }> } | null = null;

  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly media: MediaService,
  ) {}

  async onModuleInit() {
    if (!CONVERT_ENABLED) return;
    // Дубли сначала: если на файл лежат две строки, перевод processing→pending падает на
    // частичном уникальном индексе (Job_one_pending_per_asset_kind) — одним запросом, то есть
    // молча оставляет ВСЕ прерванные задачи в processing, и очередь после рестарта встаёт.
    await this.dedupeJobs();
    // после рестарта все processing возвращаем в очередь (рестарт = прерванный воркер).
    // Это верно только для одного процесса (deploy/pm2 держит instances: 1): вторая реплика
    // на старте воскресила бы задачу, которую прямо сейчас считает первая.
    await this.prisma.job.updateMany({ where: { state: 'processing' }, data: { state: 'pending' } }).catch(() => undefined);
    this.cleanupTmp();
    this.timer = setInterval(() => void this.tick(), 2000);
    this.logger.log(
      `конвертер запущен (mem-limit ${WORKER_MEM_KB / 1024}MB, фото параллельно ${PHOTO_PARALLEL}, ` +
        `оригиналы ${env.KEEP_ORIGINALS ? 'храним' : 'удаляем'})`,
    );
  }

  /**
   * Схлопнуть дубли строк очереди: на файл и вид задачи остаётся ровно одна строка.
   *
   * Откуда дубли: PDF на длинный документ отрисовывал порцию страниц и заводил вторую задачу
   * на остаток, пока первая была ещё в работе. Файл висел в очереди дважды (ждёт + считается),
   * а если первый заход потом падал — ещё и в ошибках. Теперь остаток везёт та же строка
   * (requeue), а этот метод добирает то, что уже накопилось. Порядок предпочтения при
   * схлопывании: ожидающая строка > считающаяся > упавшая — ожидающая несёт работу, упавшая
   * только историю, и работа важнее.
   */
  async dedupeJobs(): Promise<number> {
    const removed = await this.prisma
      .$executeRaw`
      DELETE FROM "Job"
      WHERE id IN (
        SELECT id FROM (
          SELECT id, row_number() OVER (
            PARTITION BY "assetId", kind
            ORDER BY CASE state WHEN 'pending' THEN 0 WHEN 'processing' THEN 1 ELSE 2 END, "createdAt" DESC
          ) AS rn
          FROM "Job"
        ) ranked
        WHERE ranked.rn > 1
      )
    `
      .catch((e) => {
        // Ошибку не глотаем молча: сырой SQL может не пройти (например, поменялась схема),
        // и тогда дубли просто останутся — об этом должно быть видно в логе.
        this.logger.warn(`схлопнуть дубли не вышло: ${(e as Error).message}`);
        return 0;
      });
    if (removed) this.logger.warn(`схлопнуто дублей в очереди: ${removed}`);
    return removed;
  }

  /** Осиротевшие каталоги задач: процесс убит (SIGKILL/pm2 reload), поэтому finally не отработал. */
  private cleanupTmp(): void {
    try {
      const dir = tmpdir();
      let removed = 0;
      for (const name of readdirSync(dir)) {
        if (!name.startsWith(TMP_PREFIX)) continue;
        const full = join(dir, name);
        try {
          // активных задач на старте нет, поэтому старый каталог гарантированно мусорный
          if (Date.now() - statSync(full).mtimeMs < TMP_STALE_MS) continue;
          rmSync(full, { recursive: true, force: true });
          removed += 1;
        } catch {
          /* занят/нет прав — не повод падать */
        }
      }
      if (removed) this.logger.log(`очищено осиротевших временных файлов: ${removed}`);
    } catch (e) {
      this.logger.warn(`cleanup tmp: ${(e as Error).message}`);
    }
  }

  /**
   * Временные файлы задачи лежат не только в её каталоге: heif-convert кладёт рядом с ним PNG
   * (и exiftool — вытащенный gain map), ffmpeg — постер и превью видео, pdftoppm — страницы PDF.
   * Каталог убирается в finally, а эти файлы оставались в /tmp навсегда: ночь конвертации HEIC
   * накопила 53 ГБ, диск кончился — упали и деплой (scp), и API (500).
   * Префикс — `clq-<jobId>`: он же начало имён производных файлов задачи, чужие не задеваем.
   */
  private removeJobTmp(jobId: string): void {
    const prefix = `${TMP_PREFIX}${jobId}`;
    try {
      const dir = tmpdir();
      for (const name of readdirSync(dir)) {
        if (!name.startsWith(prefix)) continue;
        try {
          rmSync(join(dir, name), { recursive: true, force: true });
        } catch {
          /* занят — доберёт чистка устаревшего */
        }
      }
    } catch {
      /* нет доступа к /tmp — не повод ронять задачу */
    }
  }

  /**
   * Свободное место на разделе с временными файлами (байт); null — посчитать не вышло.
   * Показывается в статусе очереди, чтобы место было видно до того, как кончится.
   */
  freeBytes(): number | null {
    try {
      const st = statfsSync(tmpdir());
      return st.bavail * st.bsize;
    } catch {
      // нет statfs или нет доступа — не повод останавливать очередь
      return null;
    }
  }

  /** Место кончается — конвертация стоит (см. MIN_FREE_BYTES); null — посчитать не вышло. */
  diskLow(): boolean | null {
    const free = this.freeBytes();
    return free === null ? null : free < MIN_FREE_BYTES;
  }

  /** Места мало: очередь стоит, пока не освободится. В лог — не чаще раза в 10 минут. */
  private warnLowDisk(free: number): void {
    const now = Date.now();
    if (now - this.lowDiskWarnedAt < TMP_CLEAN_EVERY_MS) return;
    this.lowDiskWarnedAt = now;
    this.logger.warn(
      `на диске мало места: свободно ${Math.round(free / 1024 ** 2)} МБ — новые задачи не беру, ` +
        `пока не освободится (порог ${Math.round(MIN_FREE_BYTES / 1024 ** 3)} ГБ)`,
    );
  }

  onModuleDestroy() {
    this.stopped = true;
    if (this.timer) clearInterval(this.timer);
    // Незавершённые задачи прерываем вместе с их процессами: `void this.process(job)` при
    // остановке модуля не отменяется, и при pm2 reload ffmpeg/pdftoppm оставались сиротами —
    // жгли ядра и держали файлы в /tmp до следующей уборки. Строка Job остаётся `processing`
    // и на старте следующего процесса возвращается в очередь (onModuleInit).
    for (const a of this.active.values()) {
      try {
        a.child?.kill('SIGKILL');
      } catch {
        /* процесс уже завершился */
      }
    }
  }

  /**
   * Поставить задачу конвертации: файл попал в медиа-зону или его просит пересчёт.
   * Идемпотентно: строка одна на ассет, поэтому повторный вызов ничего не создаёт.
   */
  async enqueue(assetId: string, sha256: string, mime: string): Promise<void> {
    const kind = mediaKindOf(mime);
    const asset = await this.prisma.asset
      .findUnique({ where: { id: assetId }, select: { size: true, previewState: true, previewError: true } })
      .catch(() => null);
    // Превью для такого типа не собираются: помечаем, чтобы файл не числился в остатке.
    if (!kind) {
      await this.markImpossible(assetId, 'превью для такого типа файла не собираются');
      return;
    }
    if (asset?.previewState === 'done') return;
    // Слишком крупное не конвертируем: задача качает объект из S3 целиком во временный каталог,
    // и один огромный «скриншот» выедает диск и очередь (заявить можно любой тип файла).
    // Это свойство содержимого и оно не изменится — помечаем и больше не трогаем.
    if (asset && Number(asset.size) > CONVERT_MAX_BYTES) {
      this.logger.warn(`конвертация пропущена: файл больше ${Math.round(CONVERT_MAX_BYTES / 1024 / 1024)} МБ (${sha256.slice(0, 8)})`);
      await this.markImpossible(assetId, `файл больше ${Math.round(CONVERT_MAX_BYTES / 1024 / 1024)} МБ`);
      return;
    }
    // «Оригинала нет» — единственная причина, которая может перестать быть верной: файл залили
    // снова. Такой ассет возвращаем в работу, воркер проверит оригинал ещё раз.
    if (asset?.previewState === 'impossible') {
      if (asset.previewError !== NO_ORIGINAL) return;
      await this.setPreviewState(assetId, 'none', null);
    }
    if (kind === 'video') {
      // без MediaMeta видео не попадает в таймлайн — создаём сразу (дата = загрузка)
      await this.prisma.mediaMeta
        .upsert({ where: { assetId }, create: { assetId, capturedAt: new Date() }, update: {} })
        .catch(() => undefined);
    }
    // Строка задачи одна на ассет: есть в любом состоянии (ждёт, идёт, упала) — второй не будет.
    // Упавшую возвращает в работу «повторить», а не новый сигнал: иначе ошибка терялась бы молча.
    const exists = await this.prisma.job.findFirst({ where: { assetId }, select: { id: true } });
    if (!exists) {
      await this.prisma.job.create({ data: { assetId, kind, state: 'pending' } }).catch(() => undefined);
    }
  }

  /** Превью собрать нельзя: причина видна в деталке, из остатка файл выходит. */
  private async markImpossible(assetId: string, reason: string): Promise<void> {
    await this.setPreviewState(assetId, 'impossible', reason);
  }

  private async setPreviewState(assetId: string, state: 'none' | 'done' | 'impossible', error: string | null): Promise<void> {
    await this.prisma.asset
      .update({ where: { id: assetId }, data: { previewState: state, previewError: error } })
      .catch(() => undefined);
  }

  /** Временная ли ошибка: сеть/S3 могут отпустить сами, остальное повторится тем же. */
  private isTransient(msg: string): boolean {
    return TRANSIENT_ERR.test(msg);
  }

  /** Оригинала нет именно в этом объекте (а не S3 не ответил): NoSuchKey/404. */
  private isMissingObject(e: unknown): boolean {
    const err = e as { name?: string; message?: string; $metadata?: { httpStatusCode?: number } };
    if (err?.name === 'NoSuchKey' || err?.name === 'NotFound') return true;
    if (err?.$metadata?.httpStatusCode === 404) return true;
    return /NoSuchKey|does not exist/i.test(String(err?.message ?? ''));
  }

  /**
   * Пересобрать превью вручную: упавшую задачу сбрасываем в очередь с нуля.
   * Оригинала нет — собирать нечего, говорим об этом честно и помечаем ассет.
   */
  async retryPreview(assetId: string): Promise<{ ok: true } | { ok: false; reason: string }> {
    const asset = await this.prisma.asset
      .findUnique({ where: { id: assetId }, select: { sha256: true, mime: true, size: true } })
      .catch(() => null);
    if (!asset) return { ok: false, reason: 'файл не найден' };
    const kind = mediaKindOf(asset.mime);
    if (!kind) return { ok: false, reason: 'превью для такого типа файла не собираются' };
    if (Number(asset.size) > CONVERT_MAX_BYTES) {
      const maxMb = Math.round(CONVERT_MAX_BYTES / 1024 / 1024);
      await this.markImpossible(assetId, `файл больше ${maxMb} МБ`);
      return { ok: false, reason: `файл больше ${maxMb} МБ — конвертация пропускается` };
    }
    const rawAlive = await this.s3.headObject(S3Service.assetKey(asset.sha256)).catch(() => false);
    if (!rawAlive) {
      await this.markImpossible(assetId, NO_ORIGINAL);
      return { ok: false, reason: 'оригинала больше нет в хранилище — залейте файл заново' };
    }
    // Задачу возвращаем в работу, а прошлую ошибку снимаем: иначе строка осталась бы упавшей.
    await this.setPreviewState(assetId, 'none', null);
    const last = await this.prisma.job.findFirst({ where: { assetId }, orderBy: { createdAt: 'desc' } });
    if (last && (last.state === 'pending' || last.state === 'processing')) return { ok: true }; // уже собирается
    if (last) {
      this.retryAfter.delete(last.id);
      await this.prisma.job.update({
        where: { id: last.id },
        data: { state: 'pending', error: null, attempts: 0, startedAt: null, finishedAt: null },
      });
    } else {
      await this.prisma.job.create({ data: { assetId, kind, state: 'pending' } });
    }
    this.logger.log(`пересборка превью запущена вручную (${kind} ${asset.sha256.slice(0, 8)})`);
    return { ok: true };
  }

  /** Отложенные повторы временно упавших задач: id → время, раньше которого не брать. */
  private readonly retryAfter = new Map<string, number>();

  /**
   * Пауза конвертации. Мягкая: новые задачи не берутся, текущая докачивается —
   * прервать AV1-энкод на середине значит потерять часы работы (промежуточных
   * производных нет). PDF останавливается между страницами: там шаг меньше секунды.
   */
  async isPaused(): Promise<boolean> {
    const row = await this.prisma.queueState.findUnique({ where: { id: 1 } }).catch(() => null);
    return Boolean(row?.paused);
  }

  async setPaused(paused: boolean): Promise<boolean> {
    await this.prisma.queueState.upsert({
      where: { id: 1 },
      create: { id: 1, paused },
      update: { paused },
    });
    this.logger.log(paused ? 'конвертация поставлена на паузу' : 'конвертация продолжена');
    return paused;
  }

  private async tick() {
    if (this.stopped || this.ticking) return;
    this.ticking = true;
    try {
      // на паузе задачи просто ждут в БД: ничего не теряется, снятие паузы продолжит с места
      if (await this.isPaused()) return;
      // Кончается место — новые задачи не берём: незабранная задача ничего не стоит, а
      // добитый диск кладёт весь сервис. Уже начатые задачи досчитываются до конца.
      const diskFree = this.freeBytes();
      if (diskFree !== null && diskFree < MIN_FREE_BYTES) {
        this.warnLowDisk(diskFree);
        return;
      }
      // Фото берём пачкой по числу свободных слотов, задачи идут параллельно и не ждут друг друга.
      const free = PHOTO_PARALLEL - this.countActive('photo');
      for (let i = 0; i < free; i++) {
        const job = await this.next('photo');
        if (!job) break;
        void this.process(job).catch((e) => this.logger.error(`process ${job.id}: ${(e as Error).message}`));
      }
      // PDF — короткие задачи (постраничный рендер), один слот, идут вместе с фото.
      if (this.countActive('pdf') === 0) {
        const pdf = await this.next('pdf');
        if (pdf) void this.process(pdf).catch((e) => this.logger.error(`process ${pdf.id}: ${(e as Error).message}`));
      }
      // Видео — отдельное правило: энкод занимает ядра целиком, поэтому оно стартует только
      // когда фото-очередь разобрана. Иначе одно длинное видео растягивает превью всех фото.
      // Исключение — голодание: если самое старое видео ждёт дольше VIDEO_STARVE_MS, слот
      // отдаём ему, иначе при непрерывном потоке фото видео не начнётся никогда.
      if (
        this.countActive('video') === 0 &&
        (VIDEO_ALONGSIDE_PHOTOS || (await this.pendingPhotos()) === 0 || (await this.videoStarving()))
      ) {
        const video = await this.next('video');
        if (video) void this.process(video).catch((e) => this.logger.error(`process ${video.id}: ${(e as Error).message}`));
      }
    } catch (e) {
      this.logger.error(`tick: ${(e as Error).message}`);
    } finally {
      this.ticking = false;
      // Раз в 10 минут подчищаем осиротевшее: если процесс убили, finally не отработал, а
      // конвертер после этого может работать сутками без перезапуска (одной чистки на старте мало).
      const now = Date.now();
      if (now - this.tmpCleanedAt > TMP_CLEAN_EVERY_MS) {
        this.tmpCleanedAt = now;
        this.cleanupTmp();
      }
      // Раз в минуту сверяем `processing` с `active`: так освобождается слот, потерянный из-за
      // исключения не в том месте или зависшего внешнего вызова.
      if (now - this.reapedAt > REAP_EVERY_MS) {
        this.reapedAt = now;
        await this.reapStuckJobs();
      }
    }
  }

  /**
   * Задачи, застрявшие в `processing` без воркера: их нет в `active` (значит процесс задачи
   * не идёт), а с прошлого старта прошло больше STUCK_MS вида. Возвращаем их в очередь.
   *
   * `active` — единственный источник правды о занятых слотах и живёт в памяти процесса,
   * поэтому проверка корректна для одного процесса (`instances: 1`, как в проде). Вторая
   * реплика увидела бы чужие задачи как «застрявшие», но только по истечении STUCK_MS —
   * то есть когда честный прогон и так не мог бы длиться.
   */
  private async reapStuckJobs(): Promise<void> {
    try {
      const rows = await this.prisma.job.findMany({
        where: { state: 'processing' },
        select: { id: true, kind: true, startedAt: true },
      });
      const now = Date.now();
      const stuck = rows.filter((r) => {
        if (this.active.has(r.id)) return false;
        // startedAt всегда ставит next() при захвате; пустой означает неизвестность — считаем застрявшей
        const started = r.startedAt?.getTime() ?? 0;
        return started === 0 || now - started > (STUCK_MS[r.kind as JobGroup] ?? STUCK_MS.photo);
      });
      if (!stuck.length) return;
      for (const r of stuck) this.retryAfter.delete(r.id);
      // attempts не трогаем: его увеличит захват задачи в next() — иначе один сбой тратил бы
      // две попытки из MAX_ATTEMPTS
      await this.prisma.job.updateMany({
        where: { id: { in: stuck.map((r) => r.id) }, state: 'processing' },
        data: { state: 'pending', startedAt: null, error: null },
      });
      this.logger.warn(
        `застрявшие задачи возвращены в очередь: ${stuck.length} (${stuck.map((r) => r.kind).join(', ')})`,
      );
    } catch (e) {
      this.logger.warn(`проверка застрявших задач: ${(e as Error).message}`);
    }
  }

  /** Сколько задач группы сейчас в работе — по этому числу считаются свободные слоты. */
  private countActive(group: JobGroup): number {
    let n = 0;
    for (const a of this.active.values()) if (a.group === group) n++;
    return n;
  }

  /** Сколько фото ещё ждёт в очереди: пока хоть одно — видео не берём. Кэш на 5 секунд. */
  private async pendingPhotos(): Promise<number> {
    if (this.photoPendingCache && Date.now() - this.photoPendingCache.at < 5000) return this.photoPendingCache.value;
    const value = await this.prisma.job.count({ where: { state: 'pending', kind: 'photo' } }).catch(() => 0);
    this.photoPendingCache = { at: Date.now(), value };
    return value;
  }

  /**
   * Самое старое ожидающее видео ждёт дольше VIDEO_STARVE_MS — значит фото-очередь не
   * заканчивается и видео надо пустить вне очереди. Кэш на 5 секунд: тик идёт каждые 2 с.
   */
  private async videoStarving(): Promise<boolean> {
    if (this.videoStarveCache && Date.now() - this.videoStarveCache.at < 5000) return this.videoStarveCache.value;
    const oldest = await this.prisma.job
      .findFirst({ where: { state: 'pending', kind: 'video' }, orderBy: { createdAt: 'asc' }, select: { createdAt: true } })
      .catch(() => null);
    const value = Boolean(oldest && Date.now() - oldest.createdAt.getTime() > VIDEO_STARVE_MS);
    this.videoStarveCache = { at: Date.now(), value };
    return value;
  }

  /** Процесс конкретной задачи (ffmpeg/pdftoppm/heif-convert) — чтобы убить его по таймауту. */
  private setChild(jobId: string, child: import('child_process').ChildProcess): void {
    const a = this.active.get(jobId);
    if (a) a.child = child;
  }

  private async next(group: JobGroup): Promise<JobRow | null> {
    return this.prisma.$transaction(async (tx) => {
      const now = Date.now();
      // отложенные повторы пропускаем: пока их пауза не вышла, берём следующую задачу
      const delayed: string[] = [];
      for (const [id, at] of this.retryAfter) {
        if (at <= now) this.retryAfter.delete(id);
        else delayed.push(id);
      }
      // Приоритет по виду задачи: фото (секунды на кадр) обгоняют видео (минуты и больше),
      // иначе одно длинное видео держало бы превью всех фото, залитых после него, — а их ждёт телефон.
      const baseWhere = { state: 'pending', ...(delayed.length ? { id: { notIn: delayed } } : {}) };
      const row = await tx.job.findFirst({
        where: { ...baseWhere, kind: group },
        orderBy: { createdAt: 'asc' },
        include: { asset: true },
      });
      if (!row) return null;
      // Захват атомарный: условие по state перепроверяется после блокировки строки, поэтому
      // при параллельных тиках (и даже при нескольких процессах) задачу получит ровно один.
      // Проигравший гонку получает claim.count = 0 и возвращает null — следующую задачу возьмёт
      // следующий тик (2 с), поэтому очередь от этого не встаёт.
      const claim = await tx.job.updateMany({
        where: { id: row.id, state: 'pending' },
        data: { state: 'processing', startedAt: new Date(), attempts: { increment: 1 }, error: null },
      });
      if (claim.count === 0) return null;
      return { id: row.id, assetId: row.assetId, kind: row.kind, sha256: row.asset.sha256, mime: row.asset.mime };
    });
  }

  private async process(job: JobRow) {
    const group: JobGroup = job.kind === 'photo' ? 'photo' : job.kind === 'pdf' ? 'pdf' : 'video';
    const dir = join(tmpdir(), `clq-${job.id}`);
    const rawPath = join(dir, 'raw');
    const tag = `${job.kind} ${job.sha256.slice(0, 8)}`;
    // Длительность задачи: она идёт в лог и в ConvertStat. Строка Job на успехе удаляется
    // (очередь — это список того, что осталось), поэтому без ConvertStat срок остатка
    // посчитать негде: «7399 видео» без средней длительности ничего не говорит о сроке.
    const startedMs = Date.now();
    const tookMs = () => Date.now() - startedMs;
    const took = () => `${Math.max(1, Math.round(tookMs() / 1000))} с`;
    try {
      // Заполнение `active` и создание каталога — ВНУТРИ try: `active` это единственный источник
      // правды о занятых слотах, а его заполнение вне try/finally при исключении (ENOSPC/EACCES
      // на /tmp, EMFILE) навсегда съедало слот группы и оставляло строку в `processing` до
      // рестарта. Обе строки выполняются до первого await, поэтому тик по-прежнему видит слот
      // занятым сразу после запуска задачи.
      this.active.set(job.id, { assetId: job.assetId, group, child: null });
      mkdirSync(dir, { recursive: true });
      try {
        await this.s3.downloadToFile(S3Service.assetKey(job.sha256), rawPath);
      } catch (e) {
        // Оригинала нет — это не сбой задачи, а свойство содержимого (раньше сырьё удаляли
        // после конвертации): помечаем и убираем строку, иначе файл вечно висел бы в остатке
        // и возвращался кнопкой пересчёта. Всё остальное (сеть, S3, 5xx) идёт обычным путём с повторами.
        if (!this.isMissingObject(e)) throw e;
        await this.markImpossible(job.assetId, NO_ORIGINAL);
        await this.prisma.job.delete({ where: { id: job.id } }).catch(() => undefined);
        this.logger.warn(`✗ ${tag} за ${took()}: ${NO_ORIGINAL} — превью не собрать`);
        return;
      }
      // EXIF из локального файла, если MediaMeta ещё нет: так помечаются фото из архивов
      // (при распаковке captureMeta не вызывается) и не тратится повторный трафик S3.
      // Видео разбирает convertVideo — там же, где читаются параметры источника: два разбора
      // одного файла (и две записи в MediaMeta) не нужны.
      const hasMeta = await this.prisma.mediaMeta
        .findUnique({ where: { assetId: job.assetId }, select: { id: true } })
        .catch(() => null);
      if (!hasMeta) {
        await this.media
          .captureMetaFromFile(job.assetId, rawPath, statSync(rawPath).size, job.mime)
          .catch(() => undefined);
      }
      let res: ConvertResult = {};
      if (job.kind === 'photo') res = await this.convertPhoto(job, rawPath);
      else if (job.kind === 'video') res = await this.convertVideo(job, rawPath);
      else if (job.kind === 'pdf') res = await this.convertPdf(job, rawPath);
      else throw new Error('unknown kind');

      // Сырьё из S3 удаляем, только если это разрешено конфигом и ни одна живая копия
      // не лежит в зоне, где оригинал обязан оставаться как есть («Файлы» и скрытая
      // «Почта» с вложениями писем); заменять оригинал производными можно только в «Фото».
      // keepRaw: производные не заменяют оригинал (анимация/PDF) — он обязан остаться.
      if (env.KEEP_ORIGINALS || res.keepRaw) {
        this.logger.log(`оригинал сохранён: ${tag}${res.keepRaw && !env.KEEP_ORIGINALS ? ' (нужен как есть)' : ''}`);
      } else {
        const filesRefs = await this.prisma.fileEntry.count({
          // Любая зона, кроме «Фото»: в «Файлах» и в скрытой «Почте» (вложения писем)
          // оригинал обязан остаться, иначе у вложения пропадут байты.
          where: { assetId: job.assetId, zone: { not: ZONE_PHOTOS }, deletedAt: null },
        });
        if (filesRefs === 0) {
          await this.s3.deleteObject(S3Service.assetKey(job.sha256)).catch(() => undefined);
        }
      }
      // res.warn = производные собраны не полностью (например у видео есть только постер):
      // задача не «failed», иначе UI показывал бы ошибку, хотя медиа доступно для просмотра.
      this.retryAfter.delete(job.id);
      if (res.requeue) {
        // Остаток работы доедет этой же строкой: подтверждение — состояние 'pending'.
        await this.prisma.job
          .update({
            where: { id: job.id },
            data: { state: 'pending', attempts: 0, error: null, startedAt: null, finishedAt: null },
          })
          .catch(() => undefined);
      } else {
        // Успех — это Asset.previewState = 'done' (его выставил convert*), а не строка задачи.
        // Строку удаляем: очередь = список того, что осталось, готовое в ней не живёт.
        await this.prisma.job.delete({ where: { id: job.id } }).catch(() => undefined);
      }
      const ms = tookMs();
      void this.recordStat(job.kind, 'done', ms);
      if (res.warn) this.logger.warn(`△ ${tag} за ${took()}: ${res.warn}`);
      else this.logger.log(`✓ ${tag} за ${took()}`);
    } catch (e) {
      const msg = (e as Error).message || 'error';
      // Строки может уже не быть: ассет вычистили из корзины или очередь очистили кнопкой,
      // пока задача считалась. Тогда писать статус некуда — в логе остаётся сама ошибка.
      const row = await this.prisma.job.findUnique({ where: { id: job.id } }).catch(() => null);
      const attempts = row?.attempts ?? 1;
      const transient = this.isTransient(msg);
      void this.recordStat(job.kind, 'failed', tookMs());
      if (transient && attempts < MAX_ATTEMPTS) {
        const delay = RETRY_BASE_DELAY_MS * attempts;
        this.retryAfter.set(job.id, Date.now() + delay);
        this.logger.warn(
          `✗ ${tag} за ${took()}: ${msg.slice(0, 200)} — повтор через ${Math.round(delay / 1000)} с (попытка ${attempts} из ${MAX_ATTEMPTS})`,
        );
        await this.prisma.job.update({ where: { id: job.id }, data: { state: 'pending', error: truncErr(msg) } }).catch(() => undefined);
      } else {
        // постоянная ошибка: три попытки подряд дают тот же результат, а очередь занята.
        // Строка остаётся со статусом ошибки — её видно на странице ошибок и можно повторить.
        const why = transient ? `попытки исчерпаны (${attempts})` : 'ошибка не временная — повтор не поможет';
        this.retryAfter.delete(job.id);
        const hint = humanHint(msg);
        this.logger.warn(`✗ ${tag} за ${took()}: ${msg.slice(0, 200)} — ${why}${hint ? ` (${hint})` : ''}`);
        // Причину кладём и на ассет: состояние превью остаётся 'none' (файл должен оставаться
        // и в ошибках, и в пересчёте — libheif однажды обновится), но объяснение сохраняется.
        if (hint) await this.setPreviewState(job.assetId, 'none', hint);
        await this.prisma.job
          .update({ where: { id: job.id }, data: { state: 'failed', error: truncErr(hint ? `${msg} — ${hint}` : msg), finishedAt: new Date() } })
          .catch(() => undefined);
      }
    } finally {
      this.active.delete(job.id);
      rmSync(dir, { recursive: true, force: true });
      // и файлы, которые задача писала рядом с каталогом, а не внутри него
      this.removeJobTmp(job.id);
    }
  }

  /**
   * Записать длительность задачи в ConvertStat. Ошибку записи не поднимаем: статистика —
   * вещь полезная, но ронять из-за неё конвертацию нельзя. Заодно редкая чистка старых строк.
   */
  private async recordStat(kind: string, state: 'done' | 'failed', durationMs: number): Promise<void> {
    await this.prisma.convertStat
      .create({ data: { kind, state, durationMs: Math.max(0, Math.round(durationMs)) } })
      .catch(() => undefined);
    if (Math.random() < 0.01) {
      await this.prisma.convertStat
        .deleteMany({ where: { finishedAt: { lt: new Date(Date.now() - STAT_RETENTION_MS) } } })
        .catch(() => undefined);
    }
  }

  /**
   * Оценка срока остатка по видам задач: медианная длительность успешной задачи × остаток,
   * делённый на число слотов (фото идут пачкой по PHOTO_PARALLEL, видео и PDF — по одному).
   *
   * Медиана, а не среднее, и окно 6 часов, а не сутки: среднее поднимает одна зависшая задача
   * (таймаут энкода — 6 часов), а широкое окно долго держит старые настройки — сразу после
   * смены кодека оценка показывала бы прежние часы на видео. Это всё равно оценка, и грубая:
   * видео стартует только когда фото-очередь пуста (кроме случая голодания — см. VIDEO_STARVE_MS),
   * поэтому «срок всего» — сумма по видам. Кэш на 30 с: статус спрашивают каждые пару секунд.
   */
  async estimates(remaining: Record<string, number>): Promise<Record<string, { avgSec: number | null; etaSec: number | null; samples: number }>> {
    const out: Record<string, { avgSec: number | null; etaSec: number | null; samples: number }> = {};
    const now = Date.now();
    if (!this.estCache || now - this.estCache.at > 30_000) {
      const since = new Date(now - STAT_WINDOW_MS);
      const perKind = await Promise.all(
        ['photo', 'video', 'pdf'].map((kind) =>
          this.prisma.convertStat
            .findMany({
              where: { kind, state: 'done', finishedAt: { gt: since } },
              orderBy: { finishedAt: 'desc' },
              take: STAT_SAMPLE,
              select: { durationMs: true },
            })
            .catch(() => [] as Array<{ durationMs: number }>),
        ),
      );
      const value: Record<string, { avgMs: number | null; samples: number }> = {};
      (['photo', 'video', 'pdf'] as const).forEach((kind, i) => {
        const d = perKind[i].map((r) => r.durationMs).sort((a, b) => a - b);
        const median = d.length ? d[Math.floor(d.length / 2)] : null;
        value[kind] = { avgMs: median, samples: d.length };
      });
      this.estCache = { at: now, value };
    }
    for (const kind of ['photo', 'video', 'pdf']) {
      const s = this.estCache.value[kind];
      const slots = kind === 'photo' ? PHOTO_PARALLEL : 1;
      const left = Math.max(0, Math.round(remaining[kind] ?? 0));
      const avgSec = s?.avgMs ? Math.round(s.avgMs / 1000) : null;
      out[kind] = {
        avgSec,
        etaSec: avgSec === null ? null : Math.round((left * avgSec) / slots),
        samples: s?.samples ?? 0,
      };
    }
    return out;
  }

  // ============ Фото → превью 50×50 (список) + 1080 (полный экран) ============
  // Мастер-версия не создаётся: оригинал и есть мастер и отдаётся как есть
  // (при KEEP_ORIGINALS=true он не удаляется), поэтому метаданные исходника
  // (EXIF, GPS, ICC, MakerNotes, MPF/depth, gain map) не теряются вообще.

  private async convertPhoto(job: JobRow, rawPath: string): Promise<ConvertResult> {
    const sha = job.sha256;
    let base: any; // sharp pipeline (источник пикселей)
    let decodedPath = rawPath;
    // Формат определяем по сигнатуре файла, а не по mime: mime заявляет клиент при загрузке,
    // и он врёт (в библиотеке 18 файлов пришли как image/heic, а внутри JPEG — проверено).
    const sniffed = this.sniffImage(rawPath);
    if (sniffed === 'heic' || sniffed === 'avif') {
      // HEIC/HEIF: декодируем libheif'ом напрямую (sharp prebuilt умеет только AVIF:
      // format.heif.input.fileSuffix = ['.avif']). heif-convert отдаёт 8-битный PNG,
      // поэтому превью из 10-битных HDR-HEIC получаются SDR — оригинал при этом цел.
      //
      // Повтора «перекачать и попробовать снова» здесь нет намеренно: он был и оказался
      // бесполезен — файл после перекачки побайтово тот же (проверено cmp), ошибка та же,
      // а скачивание до 11 МБ дублировалось на каждом из 384 нечитаемых HEIC.
      const png = join(tmpdir(), `clq-${job.id}.png`);
      await this.run(job.id, ['heif-convert', rawPath, png], 120000);
      base = sharp(png, SHARP_IN).rotate();
      decodedPath = png;
    } else {
      // animated: true — чтобы многостраничные GIF/WebP не превратились в статику (см. ниже).
      // failOn: 'truncated' — не валить превью на предупреждениях libvips: imagemagick-подобная
      // строгость отбрасывала 90 JPEG с испорченным полем SOS, которые другие декодеры
      // (и ffmpeg, и libjpeg с failOn:'truncated') читают целиком и без потери пикселей.
      base = sharp(rawPath, SHARP_IN).rotate();
    }

    const meta = await sharp(decodedPath, SHARP_IN).metadata().catch(() => null);
    const animated = (meta?.pages ?? 1) > 1;

    // ICC кладём через keepIccProfile(): без профиля Display P3-фото выглядят блёкло
    // в браузере, а ICC в AVIF нельзя добавить постфактум (exiftool умеет только
    // заменять уже существующий блок). EXIF в превью не нужен — метаданные живут
    // в оригинале; ориентация уже запечена в пиксели через rotate().
    // Превью для списка — квадрат GRID_SIZE×GRID_SIZE: в сетке оно показывается
    // не крупнее 50 px, поэтому кадрируем по центру (fit: cover) вместо «ширины 512».
    const grid = await base
      .clone()
      .keepIccProfile()
      .resize({ width: GRID_SIZE, height: GRID_SIZE, fit: 'cover', withoutEnlargement: true })
      .webp({ quality: 78 })
      .toBuffer();

    // Анимированный источник (GIF/WebP): полноэкранное превью оставляем анимированным
    // WebP — AVIF-мастер в старом пайплайне отдавал только первый кадр.
    // Ширина полного превью — FULL_SIZE (1080): столько же, сколько у превью страницы PDF
    // и превью видео. 2048 давал заметно более тяжёлый файл, а на телефоне разницы не видно;
    // качество AVIF q60 (шкала не как у JPEG: на глаз ≈ JPEG 85–90) оставлено прежним.
    const full = animated
      ? await base
          .clone()
          .keepIccProfile()
          .resize({ width: FULL_SIZE, withoutEnlargement: true })
          .webp({ quality: 80 })
          .toBuffer()
      : await base
          .clone()
          .keepIccProfile()
          .resize({ width: FULL_SIZE, withoutEnlargement: true })
          .avif({ quality: 60 })
          .toBuffer();

    await Promise.all([
      this.s3.putObject(MediaService.gridKey(sha), grid, 'image/webp'),
      this.s3.putObject(MediaService.photoFullKey(sha), full, animated ? 'image/webp' : 'image/avif'),
    ]);

    // Превью собраны: и превью списка (50×50), и полноэкранное (1080). Оптимизированного
    // мастера нет — оригинал и есть мастер, он отдаётся как есть.
    await this.setPreviewState(job.assetId, 'done', null);
    return animated ? { keepRaw: true } : {};
  }

  // ============ Видео → постер 50×50 (список) + 1080 H.264/AV1 (полный экран) ============
  // Полноразмерный мастер не собирается: оригинал и есть мастер. Это заодно снимает
  // проблему памяти — энкодер больше не держит 4K-кадры, из-за которых libaom падал
  // под ulimit -v ("Failed to initialize encoder: Memory allocation error").

  private async convertVideo(job: JobRow, rawPath: string): Promise<ConvertResult> {
    const sha = job.sha256;
    const posterRaw = join(tmpdir(), `clq-${job.id}-poster.png`);
    const previewPath = join(tmpdir(), `clq-${job.id}-1080.mp4`);

    const src = await this.probeSource(rawPath);
    // Метаданные (дата, GPS, камера, длительность, кодеки, `raw` для деталки) пишет MediaService
    // из ЛОКАЛЬНОГО файла: по presigned-URL ffprobe на этом сервере не работает (резолвер
    // статической сборки не разрешает хост Hetzner S3 — "Failed to resolve hostname"), поэтому
    // воркер отдаёт ему уже скачанное сырьё. Разбор ровно один: у очереди был свой второй
    // ffprobe, который писал те же колонки, но не писал `raw` — и деталка видео оставалась
    // без параметров кадра.
    await this.media.captureVideoFromFile(job.assetId, rawPath).catch(() => undefined);

    // 1) постер — быстро, чтобы ролик сразу появился в ленте.
    // -ss 1 за концом ролика (видео короче ~1 с) не даёт ни одного кадра: ffmpeg
    // завершается с кодом 0, но файла не создаёт — нужен фолбэк на первый кадр.
    // Кадр режем сразу в квадрат для списка: апскейл по короткой стороне (increase) +
    // центральный кроп — иначе постер 16:9 растянулся бы в квадратной ячейке сетки.
    const seek = src.duration > 1.5 ? '1' : '0';
    const posterVf = `scale=${GRID_SIZE}:${GRID_SIZE}:force_original_aspect_ratio=increase,crop=${GRID_SIZE}:${GRID_SIZE}`;
    await this.run(job.id, [...FFMPEG, '-y', '-ss', seek, '-i', rawPath, '-frames:v', '1', '-vf', posterVf, posterRaw], 180000);
    if (!existsSync(posterRaw)) {
      await this.run(job.id, [...FFMPEG, '-y', '-i', rawPath, '-frames:v', '1', '-vf', posterVf, posterRaw], 180000);
    }
    const poster = await sharp(posterRaw, SHARP_IN).webp({ quality: 78 }).toBuffer();
    await this.s3.putObject(MediaService.videoPosterKey(sha), poster, 'image/webp');

    // 2) превью 1080: 5 → 99%.
    // Разрешение и частота кадров исходника сохраняются: апскейла нет (ролики ниже 1080
    // остаются в своём разрешении), fps не трогаем, кадры не выбрасываем — превью должно
    // выглядеть как оригинал, экономить на кадрах тут нечего.
    const filters: string[] = [];
    if (!(src.height && src.height <= 1080)) filters.push('scale=-2:1080');
    // HDR в 8-битном H.264 без тонапмапа выглядит выцветшим (AV1-ветка держит 10 бит и теги).
    if (VIDEO_CODEC === 'h264' && src.hdr) filters.push(TONEMAP_SDR);
    const vf = filters.length ? ['-vf', filters.join(',')] : [];
    // -map_metadata 0 + use_metadata_tags: без них у превью creation_time = 0, а Apple
    // Keys (GPS, Make/Model, ContentIdentifier) не переносятся вообще — проверено на проде.
    try {
      await this.run(job.id, [
        ...FFMPEG, '-y', '-i', rawPath,
        '-map_metadata', '0',
        '-map', '0:v:0', ...vf,
        ...this.videoEncodeArgs(src),
        '-map', '0:a?', ...this.audioArgs(src),
        '-movflags', '+faststart+use_metadata_tags',
        previewPath,
      ], 6 * 60 * 60 * 1000);
      await this.s3.putFile(MediaService.video1080Key(sha), previewPath, 'video/mp4');
    } catch (e) {
      // Постер уже опубликован — ролик виден в ленте, это не повод валить задачу.
      await this.setPreviewState(job.assetId, 'done', null);
      return { warn: `превью 1080 не собрано (${(e as Error).message}); есть только постер` };
    }

    await this.setPreviewState(job.assetId, 'done', null);
    return {};
  }

  // ============ PDF → миниатюра первой страницы (список) + превью всех страниц (деталка) ============
  // Рисует poppler (pdfinfo/pdftoppm): ffmpeg PDF не умеет, а JS-рендереры (mupdf, pdfjs)
  // собираются только в ESM, а сервис — CommonJS. Оригинал НЕ удаляем никогда: страницы —
  // это картинки, самого документа (текст, страницы сверх отрисованных) в них нет.
  //
  // Одна задача рисует не больше PDF_PAGES_PER_JOB страниц: PDF на сотни страниц иначе
  // занял бы единственный воркер на минуты, и превью фото ждали бы в очереди. Если
  // страницы остались — задача ставится заново и продолжает с того места, где встала
  // (уже отрисованные страницы видны в S3 и не перерисовываются).

  private async convertPdf(job: JobRow, rawPath: string): Promise<ConvertResult> {
    const sha = job.sha256;
    const total = await this.pdfPageCount(rawPath);
    if (!total) throw new Error('в PDF не найдено ни одной страницы');

    // Что уже отрисовано: у PDF превью каждой страницы — отдельный ключ, и после
    // рестарта/падения задача должна продолжить, а не начинать с нуля.
    const existing = new Set(
      (await this.s3.listKeys(`view/${sha}-p`).catch(() => []))
        .map((k) => /-p(\d+)-/.exec(k)?.[1])
        .filter(Boolean)
        .map(Number),
    );
    const missing: number[] = [];
    for (let p = 1; p <= total; p++) if (!existing.has(p)) missing.push(p);
    if (!missing.length) {
      await this.finishPdf(job, total);
      return { keepRaw: true };
    }
    const batch = missing.slice(0, PDF_PAGES_PER_JOB);

    let rendered = 0;
    let stopped = false;
    for (const page of batch) {
      // Пауза посреди длинного PDF: досчитывать десятки страниц, пока просили остановиться,
      // ни к чему — остаток доедет следующей задачей после снятия паузы.
      if (await this.isPaused()) break;
      // Строки задачи нет — ассет вычистили из корзины прямо сейчас (строки задач уходят
      // каскадом). Тогда остаток страниц рисовать некуда, и продолжение ставить не нужно.
      const row = await this.prisma.job.findUnique({ where: { id: job.id }, select: { state: true } }).catch(() => null);
      if (!row) {
        stopped = true;
        break;
      }
      const png = join(tmpdir(), `clq-${job.id}-p${page}.png`);
      try {
        // -scale-to-x/-scale-to-y -1: ширина ровно PDF_PAGE_WIDTH, высота по пропорциям
        await this.run(
          job.id,
          ['pdftoppm', '-png', '-f', String(page), '-l', String(page), '-scale-to-x', String(PDF_PAGE_WIDTH), '-scale-to-y', '-1', '-singlefile', rawPath, png.replace(/\.png$/, '')],
          180000,
        );
      } catch (e) {
        const why = String((e as { stderr?: string }).stderr || (e as Error).message).split('\n').filter(Boolean).pop();
        throw new Error(`страница ${page}: pdftoppm не смог (${why?.slice(0, 200) ?? 'без вывода'})`);
      }
      const webp = await sharp(png, SHARP_IN)
        .flatten({ background: '#ffffff' }) // страница прозрачной не бывает, но JPEG-подложка серую не даёт
        .webp({ quality: 78 })
        .toBuffer();
      await this.s3.putObject(MediaService.pdfPageKey(sha, page), webp, 'image/webp');
      if (page === 1) await this.s3.putObject(MediaService.gridKey(sha), await this.pdfGrid(png), 'image/webp');
      rmSync(png, { force: true });
      rendered++;
    }

    // «Есть чем показать» — только если хотя бы одна страница реально лежит в S3: иначе
    // деталка показала бы число страниц и битые картинки вместо «превью готовится».
    if (existing.size + rendered > 0) await this.finishPdf(job, total);
    // Остались страницы (упёрлись в лимит задачи или встали на паузу) — ту же строку вернём в
    // очередь: следующий заход дорисует остаток, а готовые страницы пропустит по списку ключей
    // в S3. Отдельную вторую строку на тот же файл не создаём: пока она ждала, файл висел в
    // очереди дважды (ожидает + считается), а если первый заход падал — ещё и в ошибках.
    // Если ассет вычистили из корзины, продолжать некуда: строку заберёт обычный путь.
    if (stopped || missing.length <= rendered) return { keepRaw: true };
    this.logger.log(`△ pdf ${sha.slice(0, 8)}: отрисовано ${rendered} из ${missing.length} оставшихся страниц`);
    return { keepRaw: true, requeue: true };
  }

  /** Миниатюра для списка: первая страница, вписанная в квадрат GRID_SIZE на белом фоне. */
  private async pdfGrid(pagePng: string): Promise<Buffer> {
    return sharp(pagePng, SHARP_IN)
      .resize({ width: GRID_SIZE, height: GRID_SIZE, fit: 'contain', background: '#ffffff', withoutEnlargement: true })
      .flatten({ background: '#ffffff' })
      .webp({ quality: 78 })
      .toBuffer();
  }

  /** Число страниц из pdfinfo (та же poppler). Без страниц считать нечего — это ошибка. */
  private async pdfPageCount(rawPath: string): Promise<number> {
    // execFile (а не execFileSync): синхронный вызов блокирует единственный поток Nest — на
    // битом или медленном PDF pdfinfo думает до минуты, и всё это время не обслуживается ни
    // один HTTP-запрос (ни API, ни загрузки, ни WebDAV). Нужен stdout, поэтому не run().
    const out = (
      await execFile('pdfinfo', [rawPath], { encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024 })
    ).stdout;
    const m = /^Pages:\s+(\d+)/m.exec(out);
    return m ? Number(m[1]) : 0;
  }

  /** Превью готовы (даже если это только часть страниц): деталка уже есть чем показать. */
  private async finishPdf(job: JobRow, total: number): Promise<void> {
    await this.prisma.asset.update({
      where: { id: job.assetId },
      data: { previewState: 'done', previewError: null, pageCount: total },
    });
  }

  /**
   * Аргументы кодирования превью.
   *
   * По умолчанию H.264 (libx264 veryfast). Причина — замер на проде: libaom-av1 в good-режиме
   * (`-cpu-used 8`) давал около кадра в секунду, и 18-секундный 4K50-ролик кодировался
   * 12 минут; libx264 на нём же упирается в декодер исходника и заканчивает за полминуты
   * (3.8 с на 3 с источника против 90 с у AV1). Плюс H.264 играется везде, включая Safari
   * и iOS без AV1, поэтому фолбэк `video-preview?src=original` нужен реже. Цена — файл
   * примерно в 1.7 раза тяжелее AV1 (см. X264_CRF), для превью это приемлемо.
   *
   * Разрешение и fps исходника не трогаем: апскейла нет, кадры не выбрасываются — превью
   * должно выглядеть так же, как оригинал.
   *
   * CONVERT_VIDEO_CODEC=av1 возвращает AV1: там тот же libaom, но в realtime-режиме
   * (замер: 15.7 с против ~200 с на том же ролике, то есть в разы быстрее good).
   * Если на сервере появится сборка ffmpeg с libsvtav1 — он ещё быстрее, менять здесь строку.
   *
   * 10 бит и color-теги сохраняются только в AV1-ветке и только для HDR/10-битного источника:
   * `-pix_fmt yuv420p` обрезал бы точность. H.264 в этой сборке 10 бит не умеет, поэтому
   * HDR-источник там проходит через тонапмап (см. TONEMAP_SDR).
   */
  private videoEncodeArgs(src: SourceProbe): string[] {
    if (VIDEO_CODEC === 'av1') {
      const args = ['-c:v', 'libaom-av1', '-usage', 'realtime', '-crf', String(AV1_CRF), '-cpu-used', '8', '-row-mt', '1'];
      if (src.hdr) {
        args.push('-pix_fmt', 'yuv420p10le');
        const c = (v?: string) => v && v !== 'unknown' && v !== 'unspecified';
        if (c(src.colorPrimaries)) args.push('-color_primaries', src.colorPrimaries!);
        if (c(src.colorTrc)) args.push('-color_trc', src.colorTrc!);
        if (c(src.colorSpace)) args.push('-colorspace', src.colorSpace!);
        if (c(src.colorRange)) args.push('-color_range', src.colorRange!);
      } else {
        args.push('-pix_fmt', 'yuv420p');
      }
      return args;
    }
    return ['-c:v', 'libx264', '-preset', X264_PRESET, '-crf', String(X264_CRF), '-pix_fmt', 'yuv420p'];
  }

  /**
   * Аудио превью: AAC из исходника копируем как есть — перекодирование ничего не добавляет,
   * кроме потери качества и работы. Остальное (opus, mp3, pcm) идёт в AAC; битрейт зависит
   * от каналов: 128k на шести каналах звучит плохо.
   */
  private audioArgs(src: SourceProbe): string[] {
    if (src.audioCodec === 'aac') return ['-c:a', 'copy'];
    return ['-c:a', 'aac', '-b:a', this.audioBitrate(src, '128k')];
  }

  /** AAC на 6 каналах при 128k звучит плохо — для многоканальных поднимаем битрейт. */
  private audioBitrate(src: SourceProbe, stereo: string): string {
    const ch = src.channels ?? 2;
    if (ch > 2) return ch > 6 ? '384k' : '256k';
    return stereo;
  }

  /**
   * Реальный формат файла по сигнатуре. mime заявляет клиент при загрузке и он врёт:
   * попадались файлы с mime image/heic, внутри которых обычный JPEG — heif-convert на них
   * отвечал «Input file is not an HEIF/AVIF file», хотя декодируются они без проблем.
   * Читаем 16 байт заголовка и больше ничего: содержимое распаковывать здесь незачем.
   */
  private sniffImage(file: string): 'heic' | 'avif' | 'jpeg' | 'png' | 'webp' | 'gif' | 'tiff' | 'other' {
    let fd: number | null = null;
    try {
      fd = openSync(file, 'r');
      const buf = Buffer.alloc(16);
      readSync(fd, buf, 0, buf.length, 0);
      if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'jpeg';
      if (buf.subarray(0, 8).toString('latin1') === '\x89PNG\r\n\x1a\n') return 'png';
      if (buf.subarray(0, 4).toString('latin1') === 'RIFF' && buf.subarray(8, 12).toString('latin1') === 'WEBP') return 'webp';
      if (buf.subarray(0, 4).toString('latin1') === 'GIF8') return 'gif';
      const tiff = buf.subarray(0, 4).toString('latin1');
      if (tiff === 'II*\x00' || tiff === 'MM\x00*') return 'tiff';
      // ISO-BMFF: у HEIC/AVIF на смещении 4 стоит 'ftyp', дальше — основной бренд
      if (buf.subarray(4, 8).toString('latin1') === 'ftyp') {
        const brand = buf.subarray(8, 12).toString('latin1');
        if (brand === 'avif' || brand === 'avis') return 'avif';
        if (/^(heic|heix|hevc|hevx|heim|heis|mif1|msf1|miaf)$/.test(brand)) return 'heic';
      }
      return 'other';
    } catch {
      return 'other';
    } finally {
      if (fd !== null) closeSync(fd);
    }
  }

  /**
   * Параметры источника одним вызовом ffprobe: длительность, 10 бит/HDR, каналы.
   * Теги контейнера (`tags`) здесь больше не разбираются воркером: и GPS, и дату съёмки, и
   * камеру пишет MediaService из того же локального файла — один разбор вместо двух.
   * Асинхронно (execFile): ffprobe на битом контейнере может думать до 30 с, а execFileSync
   * на это время останавливал весь HTTP-сервис — синхронные вызовы в Nest недопустимы.
   */
  private async probeSource(file: string): Promise<SourceProbe> {
    const res: SourceProbe = { duration: 0, hdr: false };
    try {
      const out = (
        await execFile(
          'ffprobe',
          [
            '-v', 'error',
            '-show_entries', 'format=duration',
            '-show_entries', 'format_tags',
            '-show_entries', 'stream=codec_type,codec_name,pix_fmt,color_primaries,color_transfer,color_space,color_range,channels,width,height',
            '-of', 'json',
            file,
          ],
          { encoding: 'utf8', timeout: 30000, maxBuffer: 16 * 1024 * 1024 },
        )
      ).stdout;
      const j = JSON.parse(out) as {
        format?: { duration?: string; tags?: Record<string, string> };
        streams?: Array<Record<string, unknown>>;
      };
      const d = Number(j.format?.duration);
      if (Number.isFinite(d) && d > 0) res.duration = d;
      if (j.format?.tags) res.tags = j.format.tags;
      const streams = j.streams ?? [];
      const v = streams.find((s) => s.codec_type === 'video');
      const a = streams.find((s) => s.codec_type === 'audio');
      if (v) {
        res.width = Number(v.width) || undefined;
        res.height = Number(v.height) || undefined;
        res.pixFmt = typeof v.pix_fmt === 'string' ? v.pix_fmt : undefined;
        res.colorPrimaries = typeof v.color_primaries === 'string' ? v.color_primaries : undefined;
        res.colorTrc = typeof v.color_transfer === 'string' ? v.color_transfer : undefined;
        res.colorSpace = typeof v.color_space === 'string' ? v.color_space : undefined;
        res.colorRange = typeof v.color_range === 'string' ? v.color_range : undefined;
      }
      if (a) {
        res.channels = Number(a.channels) || undefined;
        res.audioCodec = typeof a.codec_name === 'string' ? a.codec_name : undefined;
      }
      res.hdr =
        /10le|10be|p010/i.test(res.pixFmt ?? '') ||
        /smpte2084|arib-std-b67/i.test(res.colorTrc ?? '') ||
        /bt2020/i.test(res.colorPrimaries ?? '');
    } catch {
      /* ffprobe недоступен или файл битый — работаем с безопасными значениями */
    }
    return res;
  }

  /** Запуск бинаря под ограничением виртуальной памяти (ulimit -v). */
  private run(jobId: string, args: string[], timeoutMs: number): Promise<void> {
    return new Promise((resolve, reject) => {
      const script = `ulimit -v ${WORKER_MEM_KB} 2>/dev/null; exec -- "$@"`;
      const child = spawn('bash', ['-c', script, 'clq-worker', ...args], { stdio: ['ignore', 'ignore', 'pipe'] });
      this.setChild(jobId, child);
      let errTail = '';
      (child.stderr || ({} as NodeJS.ReadableStream)).on('data', (chunk: Buffer) => {
        errTail = (errTail + chunk.toString()).slice(-2000);
      });
      const timer = setTimeout(() => {
        child.kill('SIGKILL');
        reject(new Error('timeout'));
      }, timeoutMs);
      child.on('error', (e) => {
        clearTimeout(timer);
        reject(e);
      });
      child.on('exit', (code) => {
        clearTimeout(timer);
        if (code === 0) resolve();
        else {
          reject(new Error(`exit ${code}; ${errTail.slice(0, 1500)}`));
        }
      });
    });
  }
}
