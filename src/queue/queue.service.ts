import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { execFileSync, spawn } from 'child_process';
import { mkdirSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import sharp from 'sharp';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { IMAGE_MIMES, MediaService, VIDEO_MIMES } from '../media/media.service';
import { env } from '../config/env';

const WORKER_MEM_KB = (env.CONVERT_MEM_MB ?? 1024) * 1024; // виртуальная память на ffmpeg (по умолчанию 1 ГБ)
const STALE_MS = 30 * 60 * 1000;
const MAX_ATTEMPTS = 3;

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
  ) {}

  async onModuleInit() {
    if ((env.CONVERT_ENABLED ?? 'true') !== 'true') return;
    // после рестарта все processing возвращаем в очередь (рестарт = прерванный воркер)
    await this.prisma.job.updateMany({ where: { state: 'processing' }, data: { state: 'pending' } }).catch(() => undefined);
    this.timer = setInterval(() => void this.tick(), 2000);
    this.logger.log(`конвертер запущен (mem-limit ${WORKER_MEM_KB / 1024}MB)`);
  }

  onModuleDestroy() {
    this.stopped = true;
    if (this.timer) clearInterval(this.timer);
  }

  /** Ставит задачу, если для ассета ещё нет активной. */
  async enqueue(assetId: string, sha256: string, mime: string): Promise<void> {
    const kind = IMAGE_MIMES.includes(mime) ? 'photo' : VIDEO_MIMES.includes(mime) ? 'video' : null;
    if (!kind) return;
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

  /** Вернуть в очередь отменённые задачи (файл восстановлен из корзины). */
  async requeueForAssets(assetIds: string[]): Promise<void> {
    if (!assetIds.length) return;
    await this.prisma.job
      .updateMany({ where: { assetId: { in: assetIds }, state: 'failed', error: { contains: 'cancelled' } }, data: { state: 'pending', error: null, attempts: 0 } })
      .catch(() => undefined);
  }

  private lastProgressUpdate = 0;
  private async setProgress(jobId: string, value: number, force = false): Promise<void> {
    const now = Date.now();
    if (!force && now - this.lastProgressUpdate < 2000) return;
    this.lastProgressUpdate = now;
    await this.prisma.job.update({ where: { id: jobId }, data: { progress: Math.max(0, Math.min(100, Math.round(value))) } }).catch(() => undefined);
  }

  private async tick() {
    if (this.stopped || this.running) return;
    this.running = true;
    try {
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
      const row = await tx.job.findFirst({ where: { state: 'pending' }, orderBy: { createdAt: 'asc' }, include: { asset: true } });
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
      if (job.kind === 'photo') await this.convertPhoto(job, rawPath);
      else if (job.kind === 'video') await this.convertVideo(job, rawPath);
      else throw new Error('unknown kind');

      // успех: удаляем сырьё из S3 и помечаем мастер
      await this.s3.deleteObject(S3Service.assetKey(job.sha256)).catch(() => undefined);
      await this.prisma.job.update({ where: { id: job.id }, data: { state: 'done', finishedAt: new Date() } });
      this.logger.log(`✓ ${tag}`);
    } catch (e) {
      const msg = (e as Error).message || 'error';
      this.logger.warn(`✗ ${tag}: ${msg.slice(0, 200)}`);
      const row = await this.prisma.job.findUnique({ where: { id: job.id } });
      const cancelled = row?.state === 'failed' && row?.error?.startsWith('cancelled');
      if (!cancelled) {
        const attempts = row?.attempts ?? 1;
        if (attempts < MAX_ATTEMPTS) {
          await this.prisma.job.update({ where: { id: job.id }, data: { state: 'pending', error: msg } });
        } else {
          await this.prisma.job.update({ where: { id: job.id }, data: { state: 'failed', error: msg, finishedAt: new Date() } });
        }
      }
    } finally {
      this.activeJob = null;
      this.activeChild = null;
      rmSync(dir, { recursive: true, force: true });
    }
  }

  // ============ Фото → AVIF мастер + WebP 512/2048 ============

  private async convertPhoto(job: JobRow, rawPath: string) {
    const sha = job.sha256;
    let pipeline: any; // sharp pipeline (тип через ReturnType) 
    try {
      pipeline = sharp(rawPath).rotate();
      // проверяем читаемость
      await pipeline.clone().metadata();
    } catch {
      // HEIC/HEIF: декод через libheif (heif-convert → png)
      const png = join(tmpdir(), `clq-${job.id}.png`);
      await this.run(['heif-convert', rawPath, png], 60000);
      pipeline = sharp(png).rotate();
    }

    await this.setProgress(job.id, 40, true);
    const avif = await pipeline.clone().avif({ quality: 85 }).toBuffer();
    await this.setProgress(job.id, 70, true);
    const grid = await pipeline.clone().resize({ width: 512, withoutEnlargement: true }).webp({ quality: 78 }).toBuffer();
    const full = await pipeline.clone().resize({ width: 2048, withoutEnlargement: true }).webp({ quality: 80 }).toBuffer();

    const avifPath = join(tmpdir(), `clq-${job.id}.avif`);
    const { writeFileSync } = await import('fs');
    writeFileSync(avifPath, avif);
    // метаданные (EXIF/GPS) — из сырья в мастер
    try {
      await this.run(['exiftool', '-overwrite_original', '-TagsFromFile', rawPath, '-all:all', avifPath], 60000);
    } catch {
      /* метаданные некритичны */
    }

    await Promise.all([
      this.s3.putObject(MediaService.photoMasterKey(sha), avif, 'image/avif'),
      this.s3.putObject(MediaService.gridKey(sha), grid, 'image/webp'),
      this.s3.putObject(MediaService.fullKey(sha), full, 'image/webp'),
    ]);
    rmSync(avifPath, { force: true });

    await this.prisma.asset.update({ where: { id: job.assetId }, data: { masterMime: 'image/avif', masterReadyAt: new Date() } });
  }

  // ============ Видео → AV1 mp4 мастер + постер + 720p ============

  private async convertVideo(job: JobRow, rawPath: string) {
    const sha = job.sha256;
    const masterPath = join(tmpdir(), `clq-${job.id}.mp4`);
    const posterRaw = join(tmpdir(), `clq-${job.id}-poster.png`);
    const previewPath = join(tmpdir(), `clq-${job.id}-720.mp4`);

    const duration = this.probeDuration(rawPath);

    // 1) постер (кадр ~1с → WebP 512) — быстро, чтобы ролик сразу появился в ленте
    await this.run(['ffmpeg', '-y', '-ss', '1', '-i', rawPath, '-frames:v', '1', '-vf', 'scale=512:-2', posterRaw], 180000);
    await this.setProgress(job.id, 5, true);
    const poster = await sharp(posterRaw).webp({ quality: 78 }).toBuffer();
    await this.s3.putObject(MediaService.videoPosterKey(sha), poster, 'image/webp');

    // 2) 720p-превью (AV1 libaom, быстрее полного): 5 → 60%
    await this.runProgress(job.id, duration, 5, 55, [
      'ffmpeg', '-y', '-i', rawPath,
      '-map', '0:v:0', '-vf', 'scale=-2:720',
      '-c:v', 'libaom-av1', '-crf', '36', '-cpu-used', '8', '-row-mt', '1', '-pix_fmt', 'yuv420p',
      '-map', '0:a?', '-c:a', 'aac', '-b:a', '96k',
      '-movflags', '+faststart',
      previewPath,
    ], 6 * 60 * 60 * 1000);
    await this.setProgress(job.id, 60, true);
    await this.s3.putFile(MediaService.video720Key(sha), previewPath, 'video/mp4');
    // «готово для просмотра» — постер+720 уже есть; полный мастер дожимается в фоне
    await this.prisma.asset.update({ where: { id: job.assetId }, data: { masterMime: 'video/mp4', masterReadyAt: new Date() } });

    // 3) мастер: AV1 полный (в конце), метаданные копируются: 60 → 99%
    await this.runProgress(job.id, duration, 60, 39, [
      'ffmpeg', '-y', '-i', rawPath,
      '-map_metadata', '0',
      '-map', '0:v:0',
      '-c:v', 'libaom-av1', '-crf', '32', '-cpu-used', '8', '-row-mt', '1', '-pix_fmt', 'yuv420p',
      '-map', '0:a?', '-c:a', 'aac', '-b:a', '128k',
      '-movflags', '+faststart',
      masterPath,
    ], 6 * 60 * 60 * 1000);

    await this.s3.putFile(MediaService.videoMasterKey(sha), masterPath, 'video/mp4');
    await this.setProgress(job.id, 100, true);
  }

  private probeDuration(file: string): number {
    try {
      const out = execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', file], { encoding: 'utf8', timeout: 30000 }).trim();
      const d = Number(out);
      return Number.isFinite(d) && d > 0 ? d : 0;
    } catch {
      return 0;
    }
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
          const last = errTail.split('\n').filter(Boolean).slice(-6).join(' | ');
          reject(new Error(`exit ${code}; ${last}`));
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
          const last = errTail.split('\n').filter(Boolean).slice(-6).join(' | ');
          reject(new Error(`exit ${code}; ${last}`));
        }
      });
    });
  }
}
