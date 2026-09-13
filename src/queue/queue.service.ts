import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { execFileSync, spawn } from 'child_process';
import { existsSync, mkdirSync, readdirSync, rmSync, statfsSync, statSync } from 'fs';
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
  parseIso6709,
  videoInstant,
} from '../media/media.service';
import { ZONE_FILES } from '../common/zones';
import { CONVERT_MAX_BYTES, env } from '../config/env';

const WORKER_MEM_KB = (env.CONVERT_MEM_MB ?? 1024) * 1024; // виртуальная память на ffmpeg (по умолчанию 1 ГБ)
/**
 * Сколько ФОТО-задач считать одновременно. Фото упираются в ядра (AVIF-энкод и heif-convert),
 * поэтому на 2 ядрах смысл есть в 2 потоках, на 4 — в 3-4. Видео и PDF всегда идут по одному:
 * AV1-энкод забирает все ядра, и второй такой процесс лишь замедлил бы оба.
 */
const PHOTO_PARALLEL = Math.min(Math.max(Number(env.CONVERT_PHOTO_PARALLEL ?? 1) || 1, 1), 8);
/**
 * Пускать видео параллельно с фото. По умолчанию нет, и вот почему: AV1-энкод занимает все
 * ядра, и фото рядом с ним идут в разы медленнее (замер на проде: 3,4 с против 19,4 с).
 * Флаг имеет смысл на машине с большим числом ядер, где фото-слоты не съедают всё.
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

interface JobRow {
  id: string;
  assetId: string;
  kind: string;
  sha256: string;
  mime: string;
}

/**
 * Группы задач в очереди. Фото и PDF дешёвые (секунды-минуты), видео — часы AV1 на все ядра,
 * поэтому у него отдельное правило: оно не идёт, пока в очереди есть фото.
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
  /** Когда последний раз жаловались на кончающееся место: в лог, а не в спам каждые 2 секунды. */
  private lowDiskWarnedAt = 0;
  /**
   * Задачи в работе сейчас: id → { assetId, group, child } — по нему считаются свободные слоты
   * (фото идут параллельно) и убивается процесс задачи по таймауту.
   */
  private readonly active = new Map<string, { assetId: string; group: JobGroup; child: import('child_process').ChildProcess | null }>();
  /** Короткий кэш числа ожидающих фото: по нему решается, брать ли видео. */
  private photoPendingCache: { at: number; value: number } | null = null;

  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly media: MediaService,
  ) {}

  async onModuleInit() {
    if ((env.CONVERT_ENABLED ?? 'true') !== 'true') return;
    // Дубли сначала: если на файл лежат две строки, перевод processing→pending падает на
    // частичном уникальном индексе (Job_one_pending_per_asset_kind) — одним запросом, то есть
    // молча оставляет ВСЕ прерванные задачи в processing, и очередь после рестарта встаёт.
    await this.dedupeJobs();
    // после рестарта все processing возвращаем в очередь (рестарт = прерванный воркер)
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
      // Видео — отдельное правило: AV1-энкод занимает все ядра, поэтому оно стартует только
      // когда фото-очередь разобрана. Иначе одно длинное видео растягивает превью всех фото.
      if (this.countActive('video') === 0 && (VIDEO_ALONGSIDE_PHOTOS || (await this.pendingPhotos()) === 0)) {
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
      // Приоритет по виду задачи: фото (секунды на кадр) обгоняют видео (часы AV1), иначе одно
      // длинное видео держало бы превью всех фото, залитых после него, — а их ждёт телефон.
      const baseWhere = { state: 'pending', ...(delayed.length ? { id: { notIn: delayed } } : {}) };
      const row = await tx.job.findFirst({
        where: { ...baseWhere, kind: group },
        orderBy: { createdAt: 'asc' },
        include: { asset: true },
      });
      if (!row) return null;
      // Захват атомарный: условие по state перепроверяется после блокировки строки, поэтому
      // при параллельных тиках (и даже при нескольких процессах) задачу получит ровно один.
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
    this.active.set(job.id, { assetId: job.assetId, group, child: null });
    const dir = join(tmpdir(), `clq-${job.id}`);
    mkdirSync(dir, { recursive: true });
    const rawPath = join(dir, 'raw');
    const tag = `${job.kind} ${job.sha256.slice(0, 8)}`;
    try {
      try {
        await this.s3.downloadToFile(S3Service.assetKey(job.sha256), rawPath);
      } catch (e) {
        // Оригинала нет — это не сбой задачи, а свойство содержимого (раньше сырьё удаляли
        // после конвертации): помечаем и убираем строку, иначе файл вечно висел бы в остатке
        // и возвращался кнопкой пересчёта. Всё остальное (сеть, S3, 5xx) идёт обычным путём с повторами.
        if (!this.isMissingObject(e)) throw e;
        await this.markImpossible(job.assetId, NO_ORIGINAL);
        await this.prisma.job.delete({ where: { id: job.id } }).catch(() => undefined);
        this.logger.warn(`✗ ${tag}: ${NO_ORIGINAL} — превью не собрать`);
        return;
      }
      // EXIF из локального файла, если MediaMeta ещё нет: так помечаются фото из архивов
      // (при распаковке captureMeta не вызывается) и не тратится повторный трафик S3.
      const hasMeta = await this.prisma.mediaMeta
        .findUnique({ where: { assetId: job.assetId }, select: { id: true } })
        .catch(() => null);
      if (!hasMeta) {
        await this.media
          .captureMetaFromFile(job.assetId, rawPath, statSync(rawPath).size, job.mime)
          .catch(() => undefined);
      } else if (job.kind === 'video') {
        // У видео строка MediaMeta уже есть (её создал enqueue с датой загрузки), поэтому разбор
        // по локальному файлу раньше пропускался: в деталке не было ни длительности, ни кодеков.
        // Файл под конвертацию уже скачан — теги читаем с него, без второго похода в S3.
        await this.media.captureVideoFromFile(job.assetId, rawPath).catch(() => undefined);
      }
      let res: ConvertResult = {};
      if (job.kind === 'photo') res = await this.convertPhoto(job, rawPath);
      else if (job.kind === 'video') res = await this.convertVideo(job, rawPath);
      else if (job.kind === 'pdf') res = await this.convertPdf(job, rawPath);
      else throw new Error('unknown kind');

      // Сырьё из S3 удаляем, только если это разрешено конфигом и ни одна живая копия
      // не лежит в зоне «Файлы» — там файл должен оставаться оригиналом как есть.
      // keepRaw: производные не заменяют оригинал (анимация/PDF) — он обязан остаться.
      if (env.KEEP_ORIGINALS || res.keepRaw) {
        this.logger.log(`оригинал сохранён: ${tag}${res.keepRaw && !env.KEEP_ORIGINALS ? ' (нужен как есть)' : ''}`);
      } else {
        const filesRefs = await this.prisma.fileEntry.count({
          where: { assetId: job.assetId, zone: ZONE_FILES, deletedAt: null },
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
      if (res.warn) this.logger.warn(`△ ${tag}: ${res.warn}`);
      else this.logger.log(`✓ ${tag}`);
    } catch (e) {
      const msg = (e as Error).message || 'error';
      // Строки может уже не быть: ассет вычистили из корзины или очередь очистили кнопкой,
      // пока задача считалась. Тогда писать статус некуда — в логе остаётся сама ошибка.
      const row = await this.prisma.job.findUnique({ where: { id: job.id } }).catch(() => null);
      const attempts = row?.attempts ?? 1;
      const transient = this.isTransient(msg);
      if (transient && attempts < MAX_ATTEMPTS) {
        const delay = RETRY_BASE_DELAY_MS * attempts;
        this.retryAfter.set(job.id, Date.now() + delay);
        this.logger.warn(
          `✗ ${tag}: ${msg.slice(0, 200)} — повтор через ${Math.round(delay / 1000)} с (попытка ${attempts} из ${MAX_ATTEMPTS})`,
        );
        await this.prisma.job.update({ where: { id: job.id }, data: { state: 'pending', error: truncErr(msg) } }).catch(() => undefined);
      } else {
        // постоянная ошибка: три попытки подряд дают тот же результат, а очередь занята.
        // Строка остаётся со статусом ошибки — её видно на странице ошибок и можно повторить.
        const why = transient ? `попытки исчерпаны (${attempts})` : 'ошибка не временная — повтор не поможет';
        this.retryAfter.delete(job.id);
        this.logger.warn(`✗ ${tag}: ${msg.slice(0, 200)} — ${why}`);
        await this.prisma.job.update({ where: { id: job.id }, data: { state: 'failed', error: truncErr(msg), finishedAt: new Date() } }).catch(() => undefined);
      }
    } finally {
      this.active.delete(job.id);
      rmSync(dir, { recursive: true, force: true });
      // и файлы, которые задача писала рядом с каталогом, а не внутри него
      this.removeJobTmp(job.id);
    }
  }

  // ============ Фото → превью 50×50 (список) + 1080 (полный экран) ============
  // Мастер-версия не создаётся: оригинал и есть мастер и отдаётся как есть
  // (при KEEP_ORIGINALS=true он не удаляется), поэтому метаданные исходника
  // (EXIF, GPS, ICC, MakerNotes, MPF/depth, gain map) не теряются вообще.

  private async convertPhoto(job: JobRow, rawPath: string): Promise<ConvertResult> {
    const sha = job.sha256;
    let base: any; // sharp pipeline (источник пикселей)
    let decodedPath = rawPath;
    if (/^image\/(heic|heif)/.test(job.mime)) {
      // HEIC/HEIF: декодируем libheif'ом напрямую (sharp prebuilt умеет только AVIF:
      // format.heif.input.fileSuffix = ['.avif']). heif-convert отдаёт 8-битный PNG,
      // поэтому превью из 10-битных HDR-HEIC получаются SDR — оригинал при этом цел.
      const png = join(tmpdir(), `clq-${job.id}.png`);
      try {
        await this.run(job.id, ['heif-convert', rawPath, png], 120000);
      } catch {
        // повтор: возможно файл был недокачан — перекачиваем и пробуем ещё раз
        rmSync(rawPath, { force: true });
        await this.s3.downloadToFile(S3Service.assetKey(job.sha256), rawPath);
        await this.run(job.id, ['heif-convert', rawPath, png], 120000);
      }
      base = sharp(png, { animated: true }).rotate();
      decodedPath = png;
    } else {
      // animated: true — чтобы многостраничные GIF/WebP не превратились в статику (см. ниже)
      base = sharp(rawPath, { animated: true }).rotate();
    }

    const meta = await sharp(decodedPath, { animated: true }).metadata().catch(() => null);
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

  // ============ Видео → постер 50×50 (список) + 1080 AV1 (полный экран) ============  // Полноразмерный AV1-мастер не собирается: оригинал и есть мастер. Это заодно снимает
  // проблему памяти — энкодер больше не держит 4K-кадры, из-за которых libaom падал
  // под ulimit -v ("Failed to initialize encoder: Memory allocation error").

  private async convertVideo(job: JobRow, rawPath: string): Promise<ConvertResult> {
    const sha = job.sha256;
    const posterRaw = join(tmpdir(), `clq-${job.id}-poster.png`);
    const previewPath = join(tmpdir(), `clq-${job.id}-1080.mp4`);

    const src = this.probeSource(rawPath);
    // Метаданные пишем здесь, из ЛОКАЛЬНОГО файла: extractDetail() ходит в ffprobe по
    // presigned-URL, а резолвер статической сборки ffmpeg не разрешает хост Hetzner S3
    // ("Failed to resolve hostname") — по ссылке видео-метаданные не достаются вообще.
    await this.storeVideoMeta(job.assetId, src);

    // 1) постер — быстро, чтобы ролик сразу появился в ленте.
    // -ss 1 за концом ролика (видео короче ~1 с) не даёт ни одного кадра: ffmpeg
    // завершается с кодом 0, но файла не создаёт — нужен фолбэк на первый кадр.
    // Кадр режем сразу в квадрат для списка: апскейл по короткой стороне (increase) +
    // центральный кроп — иначе постер 16:9 растянулся бы в квадратной ячейке сетки.
    const seek = src.duration > 1.5 ? '1' : '0';
    const posterVf = `scale=${GRID_SIZE}:${GRID_SIZE}:force_original_aspect_ratio=increase,crop=${GRID_SIZE}:${GRID_SIZE}`;
    await this.run(job.id, ['ffmpeg', '-y', '-ss', seek, '-i', rawPath, '-frames:v', '1', '-vf', posterVf, posterRaw], 180000);
    if (!existsSync(posterRaw)) {
      await this.run(job.id, ['ffmpeg', '-y', '-i', rawPath, '-frames:v', '1', '-vf', posterVf, posterRaw], 180000);
    }
    const poster = await sharp(posterRaw).webp({ quality: 78 }).toBuffer();
    await this.s3.putObject(MediaService.videoPosterKey(sha), poster, 'image/webp');

    // 2) превью 1080 (AV1 libaom): 5 → 99%.
    // Апскейл не делаем: ролики ниже 1080 остаются в своём разрешении (scale с ростом
    // только раздул бы битрейт без пользы).
    const vf = src.height && src.height <= 1080 ? [] : ['-vf', 'scale=-2:1080'];
    // -map_metadata 0 + use_metadata_tags: без них у превью creation_time = 0, а Apple
    // Keys (GPS, Make/Model, ContentIdentifier) не переносятся вообще — проверено на проде.
    try {
      await this.run(job.id, [
        'ffmpeg', '-y', '-i', rawPath,
        '-map_metadata', '0',
        '-map', '0:v:0', ...vf,
        ...this.videoEncodeArgs(src, 36, true),
        '-map', '0:a?', '-c:a', 'aac', '-b:a', this.audioBitrate(src, '128k'),
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
      const webp = await sharp(png)
        .flatten({ background: '#ffffff' }) // страница прозрачной не бывает, но JPEG-подложка серую не даёт
        .webp({ quality: 78 })
        .toBuffer();
      await this.s3.putObject(MediaService.pdfPageKey(sha, page), webp, 'image/webp');
      if (page === 1) await this.s3.putObject(MediaService.gridKey(sha), await this.pdfGrid(png), 'image/webp');
      rmSync(png, { force: true });
      rendered++;
      const doneCount = total - missing.length + batch.indexOf(page) + 1;
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
    return sharp(pagePng)
      .resize({ width: GRID_SIZE, height: GRID_SIZE, fit: 'contain', background: '#ffffff', withoutEnlargement: true })
      .flatten({ background: '#ffffff' })
      .webp({ quality: 78 })
      .toBuffer();
  }

  /** Число страниц из pdfinfo (та же poppler). Без страниц считать нечего — это ошибка. */
  private async pdfPageCount(rawPath: string): Promise<number> {
    // execFileSync, а не run(): нужен stdout, а run() отдаёт только код выхода и stderr.
    const out = execFileSync('pdfinfo', [rawPath], { encoding: 'utf8', timeout: 60000 });
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
   * Аргументы кодирования AV1.
   * allow10bit: для мастера сохраняем 10 бит и пробрасываем color-теги, если источник
   * HDR/10-битный — иначе -pix_fmt yuv420p обрезает точность (полосы) и теряет HDR.
   * Превью всегда 8-битное: так проход гарантированно проходит по памяти.
   */
  private videoEncodeArgs(src: SourceProbe, crf: number, allow10bit: boolean): string[] {
    const args = ['-c:v', 'libaom-av1', '-crf', String(crf), '-cpu-used', '8', '-row-mt', '1'];
    if (allow10bit && src.hdr) {
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

  /** AAC на 6 каналах при 128k звучит плохо — для многоканальных поднимаем битрейт. */
  private audioBitrate(src: SourceProbe, stereo: string): string {
    const ch = src.channels ?? 2;
    if (ch > 2) return ch > 6 ? '384k' : '256k';
    return stereo;
  }

  /** Параметры источника одним вызовом ffprobe: длительность, 10 бит/HDR, каналы. */
  private probeSource(file: string): SourceProbe {
    const res: SourceProbe = { duration: 0, hdr: false };
    try {
      const out = execFileSync(
        'ffprobe',
        [
          '-v', 'error',
          '-show_entries', 'format=duration',
          '-show_entries', 'format_tags',
          '-show_entries', 'stream=codec_type,pix_fmt,color_primaries,color_transfer,color_space,color_range,channels,width,height',
          '-of', 'json',
          file,
        ],
        { encoding: 'utf8', timeout: 30000 },
      );
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
      if (a) res.channels = Number(a.channels) || undefined;
      res.hdr =
        /10le|10be|p010/i.test(res.pixFmt ?? '') ||
        /smpte2084|arib-std-b67/i.test(res.colorTrc ?? '') ||
        /bt2020/i.test(res.colorPrimaries ?? '');
    } catch {
      /* ffprobe недоступен или файл битый — работаем с безопасными значениями */
    }
    return res;
  }

  /**
   * Метаданные видео из локального файла → MediaMeta (дата съёмки, GPS, камера, размеры).
   * Иначе видео навсегда остаётся в таймлайне датой загрузки и не попадает на карту/в поездки:
   * строка MediaMeta создаётся queue.enqueue() сразу, а extractDetail() по presigned-URL
   * на этом сервере не работает (резолвер ffmpeg не разрешает хост S3).
   */
  private async storeVideoMeta(assetId: string, src: SourceProbe): Promise<void> {
    const tags = src.tags;
    if (!tags) return;
    const created = videoInstant(tags);
    const pos = parseIso6709(tags['com.apple.quicktime.location.ISO6709']);
    const make = tags['com.apple.quicktime.make'] ?? tags.make ?? null;
    const model = tags['com.apple.quicktime.model'] ?? tags.model ?? null;
    if (!created && !pos && !make && !model && !src.width) return;
    await this.prisma.mediaMeta
      .upsert({
        where: { assetId },
        create: {
          assetId,
          capturedAt: created,
          latitude: pos?.latitude,
          longitude: pos?.longitude,
          make,
          model,
          width: src.width,
          height: src.height,
        },
        update: {
          capturedAt: created,
          latitude: pos?.latitude,
          longitude: pos?.longitude,
          make,
          model,
          width: src.width,
          height: src.height,
        },
      })
      .catch(() => undefined);
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
