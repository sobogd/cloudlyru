import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { execFileSync, spawn } from 'child_process';
import { existsSync, mkdirSync, readdirSync, rmSync, statSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import sharp from 'sharp';
import { Prisma } from '@prisma/client';
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
import { env } from '../config/env';

const WORKER_MEM_KB = (env.CONVERT_MEM_MB ?? 1024) * 1024; // виртуальная память на ffmpeg (по умолчанию 1 ГБ)
const MAX_ATTEMPTS = 3;
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
/** Каталог старше этого возраста считаем мусором (мастер 4K может идти часами). */
const TMP_STALE_MS = 12 * 60 * 60 * 1000;

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

@Injectable()
export class QueueService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger('Queue');
  private timer: NodeJS.Timeout | null = null;
  private stopped = false;
  private running = false;
  private activeJob: { id: string; assetId: string } | null = null;
  private activeChild: import('child_process').ChildProcess | null = null;

  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly media: MediaService,
  ) {}

  async onModuleInit() {
    if ((env.CONVERT_ENABLED ?? 'true') !== 'true') return;
    // после рестарта все processing возвращаем в очередь (рестарт = прерванный воркер)
    await this.prisma.job.updateMany({ where: { state: 'processing' }, data: { state: 'pending' } }).catch(() => undefined);
    this.cleanupTmp();
    this.timer = setInterval(() => void this.tick(), 2000);
    this.logger.log(`конвертер запущен (mem-limit ${WORKER_MEM_KB / 1024}MB, оригиналы ${env.KEEP_ORIGINALS ? 'храним' : 'удаляем'})`);
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
      if (removed) this.logger.log(`очищено осиротевших временных каталогов: ${removed}`);
    } catch (e) {
      this.logger.warn(`cleanup tmp: ${(e as Error).message}`);
    }
  }

  onModuleDestroy() {
    this.stopped = true;
    if (this.timer) clearInterval(this.timer);
  }

  /**
   * Ключи «полного» превью, которые реально умеет отдавать `/previews` и `/video-preview`
   * (включая легаси-ключи старого пайплайна: у части ассетов оригинал был удалён).
   */
  private fullPreviewKeys(kind: string, sha256: string): string[] {
    if (kind === 'photo') {
      return [
        MediaService.photoFullKey(sha256),
        MediaService.legacyPhotoFull2048Key(sha256),
        MediaService.legacyPhotoFullWebpKey(sha256),
      ];
    }
    if (kind === 'pdf') return [MediaService.pdfPageKey(sha256, 1)];
    return [MediaService.video1080Key(sha256), MediaService.legacyVideo720Key(sha256)];
  }

  /** Есть ли чем показать содержимое, кроме оригинала. */
  async previewsAlive(mime: string, sha256: string): Promise<boolean> {
    const kind = mediaKindOf(mime);
    if (!kind) return false;
    for (const key of this.fullPreviewKeys(kind, sha256)) {
      if (await this.s3.headObject(key).catch(() => false)) return true;
    }
    return false;
  }

  /** Ставит задачу, если для ассета ещё нет активной. */
  async enqueue(assetId: string, sha256: string, mime: string): Promise<void> {
    const kind = mediaKindOf(mime);
    if (!kind) return;
    // Превью уже есть, а оригинала нет (KEEP_ORIGINALS=false) — задача обречена на три
    // падения при скачивании files/<sha>. Ставим её только если превью на самом деле нет.
    // Проверяем весь набор ключей, которые отдаёт UI, а не только текущий: у старых
    // ассетов полное превью лежит под легаси-ключом `-2048.avif`/`-2048.webp`/`-720.mp4`.
    const asset = await this.prisma.asset
      .findUnique({ where: { id: assetId }, select: { masterReadyAt: true } })
      .catch(() => null);
    if (asset?.masterReadyAt) {
      const rawAlive = await this.s3.headObject(S3Service.assetKey(sha256)).catch(() => false);
      if (!rawAlive) {
        for (const key of this.fullPreviewKeys(kind, sha256)) {
          if (await this.s3.headObject(key).catch(() => false)) return;
        }
      }
    }
    if (kind === 'video') {
      // без MediaMeta видео не попадает в таймлайн — создаём сразу (дата = загрузка)
      await this.prisma.mediaMeta
        .upsert({ where: { assetId }, create: { assetId, capturedAt: new Date() }, update: {} })
        .catch(() => undefined);
    }
    const exists = await this.prisma.job.findFirst({
      where: { assetId, state: { in: ['pending', 'processing'] } },
      select: { id: true },
    });
    if (!exists) {
      await this.prisma.job.create({ data: { assetId, kind, state: 'pending' } }).catch(() => undefined);
    }
  }

  /** Отменить задачи ассетов (файл удалён) и вернуть из корзины при восстановлении. */
  async cancelForAssets(assetIds: string[]): Promise<void> {
    if (!assetIds.length) return;
    await this.prisma.job
      .updateMany({ where: { assetId: { in: assetIds }, state: { in: ['pending', 'processing'] } }, data: { state: 'failed', error: 'cancelled: файл удалён', finishedAt: new Date() } })
      .catch(() => undefined);
    // если удалённый файл прямо сейчас кодируется — убиваем ffmpeg
    if (this.activeJob && assetIds.includes(this.activeJob.assetId) && this.activeChild) {
      this.logger.warn(`отмена активной задачи ${this.activeJob.id} (файл удалён) — убиваю ffmpeg`);
      try { this.activeChild.kill('SIGKILL'); } catch { /* ignore */ }
    }
  }

  /**
   * Очистить очередь: отменить всё, что ждёт и что сейчас считается. Отмена жёсткая —
   * в этом её отличие от паузы: активный процесс (ffmpeg/pdftoppm) убивается, иначе
   * очередь не опустеет никогда. Уже собранные производные остаются на месте, так что
   * отменённое можно пересобрать кнопкой пересбора, а не с нуля.
   */
  async cancelAll(tree: string[]): Promise<number> {
    const where: Prisma.JobWhereInput = {
      state: { in: ['pending', 'processing'] },
      asset: { entries: { some: { folderId: { in: tree }, deletedAt: null } } },
    };
    // id забираем только чтобы понять, наша ли задача сейчас считается: обновляем по тому же
    // условию, а не списком id. Список id упирался в предел Postgres в 32767 bind-параметров:
    // на 45 тыс. задач очистка очереди падала с 500 (Assertion violation ... received 45500).
    const jobs = await this.prisma.job.findMany({ where, select: { id: true } });
    if (!jobs.length) return 0;
    const res = await this.prisma.job.updateMany({
      where,
      data: { state: 'failed', error: 'cancelled: очередь очищена', finishedAt: new Date() },
    });
    // Убиваем только свою активную задачу: чужие процессы отменять не наше дело.
    if (this.activeJob && jobs.some((j) => j.id === this.activeJob!.id) && this.activeChild) {
      this.logger.warn(`очистка очереди: убиваю активную задачу ${this.activeJob.id}`);
      try { this.activeChild.kill('SIGKILL'); } catch { /* ignore */ }
    }
    this.logger.log(`очередь очищена: отменено задач ${res.count}`);
    return res.count;
  }

  /** Вернуть в очередь отменённые задачи (файл восстановлен из корзины). */
  async requeueForAssets(assetIds: string[]): Promise<void> {
    if (!assetIds.length) return;
    const rows = await this.prisma.job.findMany({
      where: { assetId: { in: assetIds }, state: 'failed', error: { contains: 'cancelled' } },
      select: { id: true, asset: { select: { sha256: true } } },
    });
    // Возвращаем только те, для которых сырьё действительно на месте: иначе задача
    // просто трижды упадёт на downloadToFile (оригинал мог быть удалён после конвертации).
    const alive: string[] = [];
    for (const r of rows) {
      if (await this.s3.headObject(S3Service.assetKey(r.asset.sha256)).catch(() => false)) alive.push(r.id);
    }
    if (!alive.length) return;
    await this.prisma.job
      .updateMany({ where: { id: { in: alive } }, data: { state: 'pending', error: null, attempts: 0 } })
      .catch(() => undefined);
  }

  /** Временная ли ошибка: сеть/S3 могут отпустить сами, остальное повторится тем же. */
  private isTransient(msg: string): boolean {
    return TRANSIENT_ERR.test(msg);
  }

  /**
   * Пересобрать превью вручную: упавшую задачу сбрасываем в очередь с нуля.
   * Оригинала нет — собирать нечего, говорим об этом честно (обычно он удалён
   * после успешной конвертации, а падение было уже на превью).
   */
  async retryPreview(assetId: string): Promise<{ ok: true } | { ok: false; reason: string }> {
    const asset = await this.prisma.asset
      .findUnique({ where: { id: assetId }, select: { sha256: true, mime: true } })
      .catch(() => null);
    if (!asset) return { ok: false, reason: 'файл не найден' };
    const kind = mediaKindOf(asset.mime);
    if (!kind) return { ok: false, reason: 'превью для такого типа файла не собираются' };
    const rawAlive = await this.s3.headObject(S3Service.assetKey(asset.sha256)).catch(() => false);
    if (!rawAlive) return { ok: false, reason: 'оригинала больше нет в хранилище — залейте файл заново' };

    const last = await this.prisma.job.findFirst({ where: { assetId }, orderBy: { createdAt: 'desc' } });
    if (last && (last.state === 'pending' || last.state === 'processing')) return { ok: true }; // уже собирается
    if (last) {
      this.retryAfter.delete(last.id);
      await this.prisma.job.update({
        where: { id: last.id },
        data: { state: 'pending', error: null, attempts: 0, progress: 0, startedAt: null, finishedAt: null },
      });
    } else {
      await this.prisma.job.create({ data: { assetId, kind, state: 'pending' } });
    }
    this.logger.log(`пересборка превью запущена вручную (${kind} ${asset.sha256.slice(0, 8)})`);
    return { ok: true };
  }

  private lastProgressUpdate = 0;
  /** Отложенные повторы временно упавших задач: id → время, раньше которого не брать. */
  private readonly retryAfter = new Map<string, number>();

  private async setProgress(jobId: string, value: number, force = false): Promise<void> {
    const now = Date.now();
    if (!force && now - this.lastProgressUpdate < 2000) return;
    this.lastProgressUpdate = now;
    await this.prisma.job.update({ where: { id: jobId }, data: { progress: Math.max(0, Math.min(100, Math.round(value))) } }).catch(() => undefined);
  }

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
    if (this.stopped || this.running) return;
    this.running = true;
    try {
      // на паузе задачи просто ждут в БД: ничего не теряется, снятие паузы продолжит с места
      if (await this.isPaused()) return;
      const job = await this.next();
      if (job) await this.process(job);
    } catch (e) {
      this.logger.error(`tick: ${(e as Error).message}`);
    } finally {
      this.running = false;
    }
  }

  private async next(): Promise<JobRow | null> {
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
      const row =
        (await tx.job.findFirst({
          where: { ...baseWhere, kind: 'photo' },
          orderBy: { createdAt: 'asc' },
          include: { asset: true },
        })) ??
        (await tx.job.findFirst({
          where: baseWhere,
          orderBy: { createdAt: 'asc' },
          include: { asset: true },
        }));
      if (!row) return null;
      await tx.job.update({ where: { id: row.id }, data: { state: 'processing', startedAt: new Date(), attempts: { increment: 1 }, error: null } });
      return { id: row.id, assetId: row.assetId, kind: row.kind, sha256: row.asset.sha256, mime: row.asset.mime };
    });
  }

  private async process(job: JobRow) {
    this.activeJob = { id: job.id, assetId: job.assetId };
    const dir = join(tmpdir(), `clq-${job.id}`);
    mkdirSync(dir, { recursive: true });
    const rawPath = join(dir, 'raw');
    const tag = `${job.kind} ${job.sha256.slice(0, 8)}`;
    try {
      await this.s3.downloadToFile(S3Service.assetKey(job.sha256), rawPath);
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
      // keepRaw: мастер не создан (анимация/несжатый вариант) — оригинал обязан остаться.
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
      // res.warn = мастер-версия не собрана, но производные готовы: задача не «failed»,
      // иначе UI показывал бы ошибку конвертации, хотя медиа доступно для просмотра.
      this.retryAfter.delete(job.id);
      await this.prisma.job.update({
        where: { id: job.id },
        data: { state: 'done', error: res.warn ? truncErr(res.warn) : null, progress: 100, finishedAt: new Date() },
      });
      if (res.warn) this.logger.warn(`△ ${tag}: ${res.warn}`);
      else this.logger.log(`✓ ${tag}`);
    } catch (e) {
      const msg = (e as Error).message || 'error';
      const row = await this.prisma.job.findUnique({ where: { id: job.id } });
      const cancelled = row?.state === 'failed' && row?.error?.startsWith('cancelled');
      const attempts = row?.attempts ?? 1;
      const transient = this.isTransient(msg);
      if (cancelled) {
        // задачу сняли снаружи (файл удалён) — это не падение конвертации
        this.retryAfter.delete(job.id);
        this.logger.warn(`✗ ${tag}: ${msg.slice(0, 200)}`);
      } else if (transient && attempts < MAX_ATTEMPTS) {
        const delay = RETRY_BASE_DELAY_MS * attempts;
        this.retryAfter.set(job.id, Date.now() + delay);
        this.logger.warn(
          `✗ ${tag}: ${msg.slice(0, 200)} — повтор через ${Math.round(delay / 1000)} с (попытка ${attempts} из ${MAX_ATTEMPTS})`,
        );
        await this.prisma.job.update({ where: { id: job.id }, data: { state: 'pending', error: truncErr(msg) } });
      } else {
        // постоянная ошибка: три попытки подряд дают тот же результат, а очередь занята
        const why = transient ? `попытки исчерпаны (${attempts})` : 'ошибка не временная — повтор не поможет';
        this.retryAfter.delete(job.id);
        this.logger.warn(`✗ ${tag}: ${msg.slice(0, 200)} — ${why}`);
        await this.prisma.job.update({ where: { id: job.id }, data: { state: 'failed', error: truncErr(msg), finishedAt: new Date() } });
      }
    } finally {
      this.activeJob = null;
      this.activeChild = null;
      rmSync(dir, { recursive: true, force: true });
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
        await this.run(['heif-convert', rawPath, png], 120000);
      } catch {
        // повтор: возможно файл был недокачан — перекачиваем и пробуем ещё раз
        rmSync(rawPath, { force: true });
        await this.s3.downloadToFile(S3Service.assetKey(job.sha256), rawPath);
        await this.run(['heif-convert', rawPath, png], 120000);
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
    await this.setProgress(job.id, 40, true);
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

    await this.setProgress(job.id, 85, true);
    await Promise.all([
      this.s3.putObject(MediaService.gridKey(sha), grid, 'image/webp'),
      this.s3.putObject(MediaService.photoFullKey(sha), full, animated ? 'image/webp' : 'image/avif'),
    ]);

    // masterMime не выставляем: оптимизированного мастера нет, исходник — он и есть.
    await this.prisma.asset.update({ where: { id: job.assetId }, data: { masterMime: null, masterReadyAt: new Date() } });
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
    await this.run(['ffmpeg', '-y', '-ss', seek, '-i', rawPath, '-frames:v', '1', '-vf', posterVf, posterRaw], 180000);
    if (!existsSync(posterRaw)) {
      await this.run(['ffmpeg', '-y', '-i', rawPath, '-frames:v', '1', '-vf', posterVf, posterRaw], 180000);
    }
    await this.setProgress(job.id, 5, true);
    const poster = await sharp(posterRaw).webp({ quality: 78 }).toBuffer();
    await this.s3.putObject(MediaService.videoPosterKey(sha), poster, 'image/webp');

    // 2) превью 1080 (AV1 libaom): 5 → 99%.
    // Апскейл не делаем: ролики ниже 1080 остаются в своём разрешении (scale с ростом
    // только раздул бы битрейт без пользы).
    const vf = src.height && src.height <= 1080 ? [] : ['-vf', 'scale=-2:1080'];
    // -map_metadata 0 + use_metadata_tags: без них у превью creation_time = 0, а Apple
    // Keys (GPS, Make/Model, ContentIdentifier) не переносятся вообще — проверено на проде.
    try {
      await this.runProgress(job.id, src.duration, 5, 94, [
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
      await this.prisma.asset.update({ where: { id: job.assetId }, data: { masterMime: null, masterReadyAt: new Date() } });
      return { warn: `превью 1080 не собрано (${(e as Error).message}); есть только постер` };
    }

    // masterReadyAt = «превью готовы, есть чем показать» (оптимизированного мастера нет).
    await this.prisma.asset.update({ where: { id: job.assetId }, data: { masterMime: null, masterReadyAt: new Date() } });
    await this.setProgress(job.id, 100, true);
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
    let cancelled = false;
    for (const page of batch) {
      // Пауза посреди длинного PDF: досчитывать десятки страниц, пока просили остановиться,
      // ни к чему — остаток доедет следующей задачей после снятия паузы.
      if (await this.isPaused()) break;
      // Очистку очереди видно только по состоянию задачи: активный pdftoppm уже убит,
      // а между страницами процесса нет — иначе досчитали бы весь батч «в отменённом» виде.
      const row = await this.prisma.job.findUnique({ where: { id: job.id }, select: { state: true } }).catch(() => null);
      if (row?.state !== 'processing') {
        cancelled = true;
        break;
      }
      const png = join(tmpdir(), `clq-${job.id}-p${page}.png`);
      try {
        // -scale-to-x/-scale-to-y -1: ширина ровно PDF_PAGE_WIDTH, высота по пропорциям
        await this.run(
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
      await this.setProgress(job.id, Math.round((doneCount / total) * 100));
    }

    // «Есть чем показать» — только если хотя бы одна страница реально лежит в S3: иначе
    // деталка показала бы число страниц и битые картинки вместо «превью готовится».
    if (existing.size + rendered > 0) await this.finishPdf(job, total);
    // Остались страницы (упёрлись в лимит задачи или встали на паузу) — дорисуем следующей
    // задачей: готовые страницы она пропустит по списку ключей. После отмены очереди
    // следующую задачу не ставим — иначе отменённое воскресло бы само.
    if (!cancelled && missing.length > rendered) {
      await this.prisma.job.create({ data: { assetId: job.assetId, kind: 'pdf', state: 'pending' } }).catch(() => undefined);
      this.logger.log(`△ pdf ${sha.slice(0, 8)}: отрисовано ${rendered} из ${missing.length} оставшихся страниц`);
    }
    return { keepRaw: true };
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
      data: { masterMime: null, masterReadyAt: new Date(), pageCount: total },
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

  /** ffmpeg с прогрессом: out_time делится на длительность, пишется в Job.progress. */
  private runProgress(
    jobId: string,
    durationSec: number,
    base: number,
    span: number,
    args: string[],
    timeoutMs: number,
  ): Promise<void> {
    return new Promise((resolve, reject) => {
      const script = `ulimit -v ${WORKER_MEM_KB} 2>/dev/null; exec -- "$@"`;
      const child = spawn('bash', ['-c', script, 'clq-worker', ...args, '-progress', 'pipe:1', '-nostats'], { stdio: ['ignore', 'pipe', 'pipe'] });
      this.activeChild = child;
      let errTail = '';
      let lastPct = -1;
      let outUs = 0;
      let acc = '';
      const onData = (d: Buffer) => {
        acc += d.toString();
        let nl: number;
        while ((nl = acc.indexOf('\n')) >= 0) {
          const line = acc.slice(0, nl);
          acc = acc.slice(nl + 1);
          if (line.startsWith('out_time_us=')) outUs = parseInt(line.slice(12), 10) || 0;
        }
        if (durationSec > 0) {
          const t = outUs / 1e6;
          const pct = base + span * Math.min(1, t / durationSec);
          if (Math.floor(pct) !== lastPct) {
            lastPct = Math.floor(pct);
            void this.setProgress(jobId, pct);
          }
        }
      };
      (child.stdout as NodeJS.ReadableStream).on('data', onData);
      (child.stderr as NodeJS.ReadableStream).on('data', (c: Buffer) => {
        errTail = (errTail + c.toString()).slice(-2000);
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

  /** Запуск бинаря под ограничением виртуальной памяти (ulimit -v). */
  private run(args: string[], timeoutMs: number): Promise<void> {
    return new Promise((resolve, reject) => {
      const script = `ulimit -v ${WORKER_MEM_KB} 2>/dev/null; exec -- "$@"`;
      const child = spawn('bash', ['-c', script, 'clq-worker', ...args], { stdio: ['ignore', 'ignore', 'pipe'] });
      this.activeChild = child;
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
