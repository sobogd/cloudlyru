import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { spawn } from 'child_process';
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
      const attempts = ((await this.prisma.job.findUnique({ where: { id: job.id } }))?.attempts ?? 1);
      if (attempts < MAX_ATTEMPTS) {
        await this.prisma.job.update({ where: { id: job.id }, data: { state: 'pending', error: msg } });
      } else {
        await this.prisma.job.update({ where: { id: job.id }, data: { state: 'failed', error: msg, finishedAt: new Date() } });
      }
    } finally {
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

    const avif = await pipeline.clone().avif({ quality: 85 }).toBuffer();
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

    // 1) постер (кадр ~1с → WebP 512) — быстро, чтобы ролик сразу появился в ленте
    await this.run(['ffmpeg', '-y', '-ss', '1', '-i', rawPath, '-frames:v', '1', '-vf', 'scale=512:-2', posterRaw], 180000);
    const poster = await sharp(posterRaw).webp({ quality: 78 }).toBuffer();
    await this.s3.putObject(MediaService.videoPosterKey(sha), poster, 'image/webp');

    // 2) 720p-превью (AV1 libaom, быстрее полного)
    await this.run([
      'ffmpeg', '-y', '-i', rawPath,
      '-map', '0:v:0', '-vf', 'scale=-2:720',
      '-c:v', 'libaom-av1', '-crf', '36', '-cpu-used', '8', '-row-mt', '1', '-pix_fmt', 'yuv420p',
      '-map', '0:a?', '-c:a', 'aac', '-b:a', '96k',
      '-movflags', '+faststart',
      previewPath,
    ], 6 * 60 * 60 * 1000);
    const { statSync } = await import('fs');
    await this.s3.putFile(MediaService.video720Key(sha), previewPath, 'video/mp4');
    void statSync;

    // 3) мастер: AV1 полный (в конце), метаданные копируются
    await this.run([
      'ffmpeg', '-y', '-i', rawPath,
      '-map_metadata', '0',
      '-map', '0:v:0',
      '-c:v', 'libaom-av1', '-crf', '32', '-cpu-used', '8', '-row-mt', '1', '-pix_fmt', 'yuv420p',
      '-map', '0:a?', '-c:a', 'aac', '-b:a', '128k',
      '-movflags', '+faststart',
      masterPath,
    ], 6 * 60 * 60 * 1000);

    await this.s3.putFile(MediaService.videoMasterKey(sha), masterPath, 'video/mp4');
    await this.prisma.asset.update({ where: { id: job.assetId }, data: { masterMime: 'video/mp4', masterReadyAt: new Date() } });
  }

  /** Запуск бинаря под ограничением виртуальной памяти (ulimit -v). */
  private run(args: string[], timeoutMs: number): Promise<void> {
    return new Promise((resolve, reject) => {
      const script = `ulimit -v ${WORKER_MEM_KB} 2>/dev/null; exec -- "$@"`;
      const child = spawn('bash', ['-c', script, 'clq-worker', ...args], { stdio: ['ignore', 'ignore', 'pipe'] });
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
