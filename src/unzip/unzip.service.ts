import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { createHash } from 'crypto';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { FilesService } from '../files/files.service';
import { RemoteZip, ZipEntryInfo, hashStream } from './s3-zip';
import { assertSafeName } from '../common/utils';
import { ZONE_FILES, ZONE_PHOTOS } from '../common/zones';
import { badRequest, notFound } from '../common/errors';

/** Файлы до этого размера распаковываются в память (один проход по S3). */
const BUFFER_LIMIT = 128 * 1024 * 1024;

const MIME_BY_EXT: Record<string, string> = {
  jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', gif: 'image/gif', webp: 'image/webp',
  heic: 'image/heic', heif: 'image/heif', tif: 'image/tiff', tiff: 'image/tiff', avif: 'image/avif',
  bmp: 'image/bmp', svg: 'image/svg+xml',
  mp4: 'video/mp4', mov: 'video/quicktime', m4v: 'video/x-m4v', webm: 'video/webm',
  mkv: 'video/x-matroska', avi: 'video/avi', '3gp': 'video/3gpp', mpg: 'video/mpeg', mpeg: 'video/mpeg',
  json: 'application/json', txt: 'text/plain', html: 'text/html', htm: 'text/html',
  pdf: 'application/pdf', zip: 'application/zip',
};

function mimeOf(name: string): string {
  const ext = name.split('.').pop()?.toLowerCase() ?? '';
  return MIME_BY_EXT[ext] ?? 'application/octet-stream';
}

function extOf(name: string): string | undefined {
  const i = name.lastIndexOf('.');
  if (i <= 0 || i === name.length - 1) return undefined;
  return name.slice(i + 1).toLowerCase().slice(0, 16);
}

/** Сегмент пути из архива → безопасное имя для нашего дерева. */
function safeSegment(raw: string): string {
  let s = raw.replace(/[\u0000-\u001f\\/]/g, '_').trim();
  if (!s || s === '.' || s === '..') s = '_';
  if (s.length > 200) {
    const ext = extOf(s);
    s = ext ? `${s.slice(0, 190)}.${ext}` : s.slice(0, 200);
  }
  assertSafeName(s);
  return s;
}

@Injectable()
export class UnzipService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger('Unzip');
  private timer: NodeJS.Timeout | null = null;
  private running = false;
  private current: string | null = null;
  private readonly cancelled = new Set<string>();
  private readonly recent = new Map<string, string>(); // jobId → последнее обновление прогресса

  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly files: FilesService,
  ) {}

  async onModuleInit() {
    // после рестарта незавершённые задачи возвращаем в очередь (распаковка идемпотентна)
    await this.prisma.unzipJob
      .updateMany({ where: { state: 'processing' }, data: { state: 'pending', startedAt: null } })
      .catch(() => undefined);
    this.timer = setInterval(() => void this.tick(), 3000);
    this.logger.log('сервис разархивирования запущен');
  }

  onModuleDestroy() {
    if (this.timer) clearInterval(this.timer);
  }

  // ================= API =================

  private async entryOf(entryId: string) {
    const entry = await this.prisma.fileEntry.findUnique({ where: { id: entryId }, include: { asset: true } });
    if (!entry || entry.deletedAt) throw notFound('файл не найден');
    return entry;
  }

  private assertZip(entry: { name: string; asset: { mime: string } }) {
    const isZip = entry.asset.mime === 'application/zip' || /\.zip$/i.test(entry.name);
    if (!isZip) throw badRequest('это не zip-архив');
  }

  /** Поставить архив в очередь на распаковку (или вернуть уже идущую задачу). */
  async start(entryId: string) {
    const entry = await this.entryOf(entryId);
    this.assertZip(entry);
    const active = await this.prisma.unzipJob.findFirst({
      where: { entryId, state: { in: ['pending', 'processing'] } },
      orderBy: { createdAt: 'desc' },
    });
    if (active) return this.view(active);
    const job = await this.prisma.unzipJob.create({
      data: { entryId, assetId: entry.assetId, folderId: entry.folderId },
    });
    this.logger.log(`задача распаковки создана: ${job.id} («${entry.name}»)`);
    return this.view(job);
  }

  /** Статус задачи. */
  async status(id: string) {
    const job = await this.prisma.unzipJob.findUnique({ where: { id } });
    if (!job) throw notFound('задача не найдена');
    return this.view(job);
  }

  /** Последняя задача по архиву (чтобы UI показал прогресс после перезагрузки страницы). */
  async latestForEntry(entryId: string) {
    const job = await this.prisma.unzipJob.findFirst({ where: { entryId }, orderBy: { createdAt: 'desc' } });
    return job ? this.view(job) : null;
  }

  async cancel(id: string) {
    const job = await this.prisma.unzipJob.findUnique({ where: { id } });
    if (!job) throw notFound('задача не найдена');
    if (job.state === 'pending') {
      await this.prisma.unzipJob.update({
        where: { id },
        data: { state: 'cancelled', finishedAt: new Date(), error: 'отменено пользователем' },
      });
    } else if (job.state === 'processing') {
      this.cancelled.add(id);
    }
    return this.status(id);
  }

  private view(job: {
    id: string; entryId: string; state: string; totalEntries: number; doneEntries: number;
    totalBytes: bigint; doneBytes: bigint; skippedEntries: number; currentName: string | null;
    error: string | null; targetFolderId: string | null; createdAt: Date; startedAt: Date | null;
    finishedAt: Date | null;
  }) {
    const total = Number(job.totalBytes);
    const done = Number(job.doneBytes);
    const percent = job.totalEntries
      ? Math.min(100, Math.round((job.doneEntries / job.totalEntries) * 100))
      : job.state === 'done' ? 100 : 0;
    return {
      id: job.id,
      entryId: job.entryId,
      state: job.state,
      totalEntries: job.totalEntries,
      doneEntries: job.doneEntries,
      totalBytes: total,
      doneBytes: done,
      skippedEntries: job.skippedEntries,
      currentName: job.currentName,
      error: job.error,
      targetFolderId: job.targetFolderId,
      percent,
      createdAt: job.createdAt,
      startedAt: job.startedAt,
      finishedAt: job.finishedAt,
    };
  }

  // ================= воркер =================

  private async tick() {
    if (this.running) return;
    this.running = true;
    try {
      const job = await this.prisma.$transaction(async (tx) => {
        const row = await tx.unzipJob.findFirst({
          where: { state: 'pending' },
          orderBy: { createdAt: 'asc' },
        });
        if (!row) return null;
        await tx.unzipJob.update({
          where: { id: row.id },
          data: { state: 'processing', startedAt: new Date(), error: null },
        });
        return row;
      });
      if (job) {
        this.current = job.id;
        await this.process(job.id).catch(async (e: Error) => {
          this.logger.error(`распаковка ${job.id} упала: ${e.message}`);
          await this.prisma.unzipJob
            .update({
              where: { id: job.id },
              data: { state: 'failed', error: e.message.slice(0, 500), finishedAt: new Date() },
            })
            .catch(() => undefined);
        });
        this.current = null;
        this.cancelled.delete(job.id);
      }
    } catch (e) {
      this.logger.error(`tick: ${(e as Error).message}`);
    } finally {
      this.running = false;
    }
  }

  private async progress(jobId: string, patch: {
    doneEntries?: number; doneBytes?: bigint; currentName?: string | null; totalEntries?: number; totalBytes?: bigint; skippedEntries?: number;
  }, force = false) {
    const now = Date.now();
    const last = Number(this.recent.get(jobId) ?? 0);
    if (!force && now - last < 2000) return;
    this.recent.set(jobId, String(now));
    await this.prisma.unzipJob.update({ where: { id: jobId }, data: patch }).catch(() => undefined);
  }

  /**
   * Чекпойнт: фиксирует индекс следующего файла и счётчики. Вызывается после
   * каждого обработанного файла, но пишет в БД: прогресс — раз в 2 с, курсор —
   * раз в 500 файлов (курсор всегда указывает на границу уже сделанного).
   */
  private async checkpoint(
    jobId: string,
    cursorIndex: number,
    doneEntries: number,
    doneBytes: number,
    skipped: number,
    currentName: string | null,
    force = false,
  ) {
    const now = Date.now();
    const last = Number(this.recent.get(jobId) ?? 0);
    const wantProgress = force || now - last >= 2000;
    const wantCursor = force || cursorIndex % 500 === 0;
    if (!wantProgress && !wantCursor) return;
    if (wantProgress) this.recent.set(jobId, String(now));
    await this.prisma.unzipJob
      .update({
        where: { id: jobId },
        data: {
          doneEntries,
          doneBytes: BigInt(doneBytes),
          skippedEntries: skipped,
          currentName,
          ...(wantCursor ? { cursorIndex } : {}),
        },
      })
      .catch(() => undefined);
  }

  /** Папка-приёмник: рядом с архивом, имя = имя архива без .zip. */
  private async ensureTargetFolder(parentId: string, baseName: string): Promise<string> {
    const existing = await this.prisma.folder.findFirst({ where: { parentId, name: baseName, deletedAt: null } });
    if (existing) return existing.id;
    const parent = await this.prisma.folder.findUniqueOrThrow({ where: { id: parentId }, select: { zone: true } });
    const zone = parent.zone === ZONE_PHOTOS ? ZONE_PHOTOS : ZONE_FILES;
    const created = await this.prisma.folder.create({ data: { parentId, name: baseName, zone } });
    return created.id;
  }

  private async process(jobId: string) {
    const job = await this.prisma.unzipJob.findUniqueOrThrow({ where: { id: jobId } });
    const entry = await this.prisma.fileEntry.findUniqueOrThrow({ where: { id: job.entryId }, include: { asset: true } });
    const size = Number(entry.asset.size);

    const zip = new RemoteZip({
      size: () => size,
      readRange: (start, end) => this.s3.readRange(S3Service.assetKey(entry.asset.sha256), start, end),
    });

    const all = await zip.entries();
    const files = all.filter((e) => !e.isDirectory);
    const totalBytes = files.reduce((s, e) => s + e.uncompressedSize, 0);
    // последовательное чтение по возрастанию смещения — меньше Range-запросов
    files.sort((a, b) => a.localHeaderOffset - b.localHeaderOffset);

    const baseName = entry.name.replace(/\.zip$/i, '') || 'archive';
    const targetId = await this.ensureTargetFolder(entry.folderId, baseName);
    await this.progress(jobId, { totalEntries: files.length, totalBytes: BigInt(totalBytes), currentName: null }, true);
    await this.prisma.unzipJob.update({ where: { id: jobId }, data: { targetFolderId: targetId } });
    this.logger.log(`распаковка «${entry.name}»: ${files.length} файлов, ${(totalBytes / 1e9).toFixed(2)} ГБ → папка «${baseName}»`);

    const folderCache = new Map<string, string>(); // "a/b/c" → folderId
    folderCache.set('', targetId);

    const folderIdFor = async (segments: string[]): Promise<string> => {
      const key = segments.join('/');
      const cached = folderCache.get(key);
      if (cached) return cached;
      const parentId = await folderIdFor(segments.slice(0, -1));
      const name = segments[segments.length - 1];
      const parentZone = await this.prisma.folder.findUniqueOrThrow({ where: { id: parentId }, select: { zone: true } });
      const zone = parentZone.zone === ZONE_PHOTOS ? ZONE_PHOTOS : ZONE_FILES;
      let folder = await this.prisma.folder.findFirst({ where: { parentId, name } });
      if (folder?.deletedAt) {
        folder = await this.prisma.folder.update({ where: { id: folder.id }, data: { deletedAt: null, zone } });
      } else if (!folder) {
        folder = await this.prisma.folder.create({ data: { parentId, name, zone } });
      }
      folderCache.set(key, folder.id);
      return folder.id;
    };

    // Чекпойнт: сколько файлов уже обработано в прошлых заходах. Счётчики считаем
    // ИЗ КУРСОРА, а не накапливаем из прошлых значений — иначе после рестарта
    // (рестарт сервиса при деплое) уже пройденное зачитывалось повторно.
    const startIndex = Math.min(job.cursorIndex ?? 0, files.length);
    let doneEntries = 0;
    let doneBytes = 0;
    for (let i = 0; i < startIndex; i++) {
      doneEntries += 1;
      doneBytes += files[i].uncompressedSize;
    }
    let skipped = job.skippedEntries;
    if (startIndex > 0) {
      this.logger.log(
        `распаковка ${jobId}: продолжаем с файла ${startIndex + 1} из ${files.length} (${(doneBytes / 1e9).toFixed(1)} ГБ уже сделано)`,
      );
      await this.checkpoint(jobId, startIndex, doneEntries, doneBytes, skipped, null, true);
    }

    for (let idx = startIndex; idx < files.length; idx++) {
      const e = files[idx];
      if (this.cancelled.has(jobId)) {
        await this.progress(jobId, { doneEntries, doneBytes: BigInt(doneBytes), currentName: null }, true);
        await this.prisma.unzipJob.update({
          where: { id: jobId },
          data: { state: 'cancelled', error: 'отменено пользователем', finishedAt: new Date() },
        });
        this.logger.warn(`распаковка ${jobId} отменена (готово ${doneEntries}/${files.length})`);
        return;
      }

      const rawSegments = e.name.split('/').filter(Boolean);
      if (!rawSegments.length) continue;
      const segments = rawSegments.map(safeSegment);
      const fileName = segments[segments.length - 1];
      const folderId = await folderIdFor(segments.slice(0, -1));
      const mime = mimeOf(fileName);
      const ext = extOf(fileName);

      // уже распаковано в прошлый заход? (идемпотентность)
      const existing = await this.prisma.fileEntry.findFirst({ where: { folderId, name: fileName } });
      if (existing && !existing.deletedAt) {
        const asset = await this.prisma.asset.findUnique({ where: { id: existing.assetId } });
        if (asset && Number(asset.size) === e.uncompressedSize) {
          skipped += 1;
          doneEntries += 1;
          doneBytes += e.uncompressedSize;
          await this.checkpoint(jobId, idx + 1, doneEntries, doneBytes, skipped, fileName);
          continue;
        }
      }

      let sha256: string;
      let realSize: number;

      if (e.uncompressedSize <= BUFFER_LIMIT) {
        const buf = await zip.readEntryBuffer(e); // внутри проверяются размер и CRC32
        sha256 = createHash('sha256').update(buf).digest('hex');
        realSize = buf.length;
        const known = await this.prisma.asset.findUnique({ where: { sha256 } });
        if (!known) {
          await this.s3.putObject(S3Service.assetKey(sha256), buf, mime);
          await this.files.ensureAsset(sha256, realSize, mime, ext);
        }
      } else {
        // крупный файл: первый проход — хэш, второй — заливка (в память не влезает)
        const first = await hashStream(zip.readEntryStream(e));
        sha256 = first.sha256;
        realSize = first.size;
        const known = await this.prisma.asset.findUnique({ where: { sha256 } });
        if (!known) {
          const { PassThrough } = await import('stream');
          const pass = new PassThrough();
          const source = zip.readEntryStream(e);
          source.on('error', (err) => pass.destroy(err));
          source.pipe(pass);
          await this.s3.uploadStream(S3Service.assetKey(sha256), pass, mime);
          await this.files.ensureAsset(sha256, realSize, mime, ext);
        }
      }

      const assetId = (await this.prisma.asset.findUniqueOrThrow({ where: { sha256 } })).id;

      if (existing) {
        // имя занято другим содержимым — не затираем, добавляем суффикс
        const unique = await this.uniqueName(folderId, fileName);
        await this.prisma.fileEntry.create({ data: { folderId, name: unique, assetId, zone: entry.zone } });
      } else {
        await this.prisma.fileEntry.create({ data: { folderId, name: fileName, assetId, zone: entry.zone } });
      }

      doneEntries += 1;
      doneBytes += e.uncompressedSize;
      await this.checkpoint(jobId, idx + 1, doneEntries, doneBytes, skipped, fileName);
    }

    await this.checkpoint(jobId, files.length, doneEntries, doneBytes, skipped, null, true);
    await this.prisma.unzipJob.update({
      where: { id: jobId },
      data: { state: 'done', finishedAt: new Date() },
    });
    this.logger.log(
      `распаковка «${entry.name}» завершена: ${doneEntries} файлов (пропущено как готовые: ${skipped})`,
    );
  }

  /** Свободное имя в папке: file.jpg → file (2).jpg */
  private async uniqueName(folderId: string, name: string): Promise<string> {
    const dot = name.lastIndexOf('.');
    const stem = dot > 0 ? name.slice(0, dot) : name;
    const ext = dot > 0 ? name.slice(dot) : '';
    for (let i = 2; i < 1000; i++) {
      const candidate = `${stem} (${i})${ext}`;
      const clash = await this.prisma.fileEntry.findFirst({ where: { folderId, name: candidate } });
      if (!clash) return candidate;
    }
    return `${stem}-${Date.now()}${ext}`;
  }
}
