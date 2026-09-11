import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { createHash } from 'crypto';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { FilesService } from '../files/files.service';
import { QueueService } from '../queue/queue.service';
import { AuthService } from '../auth/auth.service';
import { ChangesService } from '../sync/changes.service';
import { IMAGE_MIMES, MediaService, VIDEO_MIMES } from '../media/media.service';
import { RemoteZip, ZipEntryInfo, hashStream, mediaKey } from './s3-zip';
import { assertSafeName } from '../common/utils';
import { ZONE_FILES, ZONE_PHOTOS } from '../common/zones';
import { badRequest, conflict, notFound } from '../common/errors';

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
    private readonly queue: QueueService,
    private readonly auth: AuthService,
    private readonly changes: ChangesService,
    private readonly media: MediaService,
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

  /**
   * Дата съёмки и координаты из сайдкара Google Takeout. Сайдкар лежит рядом с файлом и
   * называется `<имя файла>.supplemental-metadata.json` (в старых выгрузках — `<имя>.json`).
   * Без него у импортированной библиотеки нет ни даты, ни места: в самом архиве дата —
   * это время упаковки, а EXIF есть не у всех снимков.
   */
  private async takeoutDate(
    zip: RemoteZip,
    sidecars: Map<string, ZipEntryInfo>,
    byKey: Map<string, ZipEntryInfo | null>,
    entryName: string,
  ): Promise<{ date: Date | null; geo: { latitude: number; longitude: number } | null } | null> {
    const dir = entryName.includes('/') ? entryName.slice(0, entryName.lastIndexOf('/') + 1) : '';
    const base = entryName.slice(dir.length);
    const candidates = [
      `${entryName}.supplemental-metadata.json`,
      `${entryName}.json`,
      `${dir}${base}.supplemental-metadata.json`,
    ];
    for (const candidate of candidates) {
      const sidecar = sidecars.get(candidate);
      if (!sidecar || sidecar.uncompressedSize > 1_000_000) continue;
      try {
        const parsed = JSON.parse((await zip.readEntryBuffer(sidecar)).toString('utf8')) as {
          photoTakenTime?: { timestamp?: string };
          geoData?: { latitude?: number; longitude?: number };
        };
        const seconds = Number(parsed.photoTakenTime?.timestamp);
        const date = Number.isFinite(seconds) && seconds > 0 ? new Date(seconds * 1000) : null;
        const lat = Number(parsed.geoData?.latitude);
        const lon = Number(parsed.geoData?.longitude);
        const geo =
          Number.isFinite(lat) && Number.isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180 && (lat !== 0 || lon !== 0)
            ? { latitude: lat, longitude: lon }
            : null;
        return { date, geo };
      } catch {
        return null;
      }
    }
    const fallback = byKey.get(mediaKey(entryName));
    if (!fallback) return null;
    try {
      const parsed = JSON.parse((await zip.readEntryBuffer(fallback)).toString('utf8')) as {
        photoTakenTime?: { timestamp?: string };
        geoData?: { latitude?: number; longitude?: number };
      };
      const seconds = Number(parsed.photoTakenTime?.timestamp);
      return {
        date: Number.isFinite(seconds) && seconds > 0 ? new Date(seconds * 1000) : null,
        geo: null,
      };
    } catch {
      return null;
    }
  }

  /**
   * Метаданные медиафайлов из архива: EXIF фото и ffprobe видео. Идём по списку по одному —
   * так разбор не отбирает процессор у самой распаковки и у API, и не плодит параллельные ffprobe.
   */
  private async collectMeta(
    items: Array<{
      assetId: string;
      sha256: string;
      size: number;
      mime: string;
      date: Date | null;
      geo: { latitude: number; longitude: number } | null;
    }>,
  ): Promise<void> {
    let done = 0;
    for (const item of items) {
      try {
        await this.media.captureAny(item.assetId, item.sha256, item.size, item.mime);
        // EXIF/контейнер даты не дали (скриншот, мессенджер, вырезанные теги) — берём
        // дату и координаты из сайдкара Takeout или из даты файла
        if (item.date || item.geo) {
          await this.media.fillDateAndGeo(item.assetId, item.date, item.geo);
        }
        done += 1;
      } catch (e) {
        this.logger.debug(`метаданные из архива пропущены: ${(e as Error).message}`);
      }
    }
    if (done) this.logger.log(`метаданные из архива: разобрано ${done} из ${items.length}`);
  }

  // ================= API =================

  private async entryOf(entryId: string, userId: string) {
    const entry = await this.auth.ownEntry(userId, entryId);
    if (!entry) throw notFound('файл не найден');
    return entry;
  }

  /** Задача принадлежит пользователю, если её архив лежит в его дереве. */
  private async ownJob(id: string, userId: string) {
    const job = await this.prisma.unzipJob.findUnique({ where: { id } });
    if (!job) throw notFound('задача не найдена');
    await this.auth.assertFolderOwned(userId, job.folderId, { deletedOk: true });
    return job;
  }

  private assertZip(entry: { name: string; asset: { mime: string } }) {
    const isZip = entry.asset.mime === 'application/zip' || /\.zip$/i.test(entry.name);
    if (!isZip) throw badRequest('это не zip-архив');
  }

  /** Поставить архив в очередь на распаковку (или вернуть уже идущую задачу). */
  async start(entryId: string, userId: string) {
    const entry = await this.entryOf(entryId, userId);
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
  async status(id: string, userId: string) {
    return this.view(await this.ownJob(id, userId));
  }

  /** Последняя задача по архиву (чтобы UI показал прогресс после перезагрузки страницы). */
  async latestForEntry(entryId: string, userId: string) {
    const entry = await this.auth.ownEntry(userId, entryId);
    if (!entry) throw notFound('файл не найден');
    const job = await this.prisma.unzipJob.findFirst({ where: { entryId }, orderBy: { createdAt: 'desc' } });
    return job ? this.view(job) : null;
  }

  async cancel(id: string, userId: string) {
    const job = await this.ownJob(id, userId);
    if (job.state === 'pending') {
      await this.prisma.unzipJob.update({
        where: { id },
        data: { state: 'cancelled', finishedAt: new Date(), error: 'отменено пользователем' },
      });
    } else if (job.state === 'processing') {
      this.cancelled.add(id);
    }
    return this.status(id, userId);
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
  private async ensureTargetFolder(parentId: string, baseName: string, ownerId: string | null): Promise<string> {
    const existing = await this.prisma.folder.findFirst({ where: { parentId, name: baseName, deletedAt: null } });
    if (existing) return existing.id;
    const parent = await this.prisma.folder.findUniqueOrThrow({ where: { id: parentId }, select: { zone: true } });
    const zone = parent.zone === ZONE_PHOTOS ? ZONE_PHOTOS : ZONE_FILES;
    const created = await this.prisma.$transaction(async (tx) => {
      const row = await tx.folder.create({ data: { parentId, name: baseName, zone } });
      if (ownerId) {
        await this.changes.record(
          {
            userId: ownerId,
            target: 'folder',
            op: 'create',
            targetId: row.id,
            folderId: parentId,
            name: baseName,
            zone,
            keepOffline: false,
          },
          tx,
        );
      }
      return row;
    });
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
    // Google Takeout кладёт рядом с каждым фото и видео сайдкар с датой съёмки и координатами.
    // Дата самого файла в архиве — время упаковки архива, поэтому брать её нельзя.
    const sidecarList = all.filter((e) => !e.isDirectory && /\.json$/i.test(e.name));
    const sidecars = new Map(sidecarList.map((e) => [e.name, e]));
    // нормализованный ключ: по нему находятся сайдкары с маркерами дублей; если ключ
    // неоднозначен (два разных сайдкара), им не пользуемся — лучше без даты, чем чужая
    const sidecarsByKey = new Map<string, ZipEntryInfo | null>();
    for (const sidecar of sidecarList) {
      const key = mediaKey(sidecar.name);
      sidecarsByKey.set(key, sidecarsByKey.has(key) ? null : sidecar);
    }
    const isTakeout = files.some((e) => e.name.startsWith('Takeout/'));
    const totalBytes = files.reduce((s, e) => s + e.uncompressedSize, 0);
    // последовательное чтение по возрастанию смещения — меньше Range-запросов
    files.sort((a, b) => a.localHeaderOffset - b.localHeaderOffset);

    const baseName = entry.name.replace(/\.zip$/i, '') || 'archive';
    // владелец дерева нужен для журнала изменений (клиенты синхронизации должны увидеть распаковку)
    const ownerId = await this.auth.ownerOfFolder(job.folderId);
    const targetId = await this.ensureTargetFolder(entry.folderId, baseName, ownerId);
    await this.progress(jobId, { totalEntries: files.length, totalBytes: BigInt(totalBytes), currentName: null }, true);
    await this.prisma.unzipJob.update({ where: { id: jobId }, data: { targetFolderId: targetId } });
    this.logger.log(`распаковка «${entry.name}»: ${files.length} файлов, ${(totalBytes / 1e9).toFixed(2)} ГБ → папка «${baseName}»`);

    const folderCache = new Map<string, string>(); // "a/b/c" → folderId
    folderCache.set('', targetId);
    /** Папки, по которым событие уже записано: за один проход в одну папку заходим многократно. */
    const journaledFolders = new Set<string>();

    const folderIdFor = async (segments: string[]): Promise<string> => {
      const key = segments.join('/');
      const cached = folderCache.get(key);
      if (cached) return cached;
      const parentId = await folderIdFor(segments.slice(0, -1));
      const name = segments[segments.length - 1];
      const parentZone = await this.prisma.folder.findUniqueOrThrow({ where: { id: parentId }, select: { zone: true } });
      const zone = parentZone.zone === ZONE_PHOTOS ? ZONE_PHOTOS : ZONE_FILES;
      const found = await this.prisma.folder.findFirst({ where: { parentId, name } });
      if (found?.deletedAt) {
        // уникальный индекс (parentId, name) включает и мягко удалённые: без явной проверки
        // create падал бы P2002 и задача распаковки уходила в failed с текстом Prisma
        throw conflict(`папка «${name}» лежит в корзине — восстановите или очистите её`, 'in_trash');
      }
      let folder = found;
      let op: 'create' | 'restore' | null = null;
      if (!found) {
        folder = await this.prisma.$transaction(async (tx) => {
          const row = await tx.folder.create({ data: { parentId, name, zone } });
          if (ownerId) {
            await this.changes.record(
              {
                userId: ownerId,
                target: 'folder',
                op: 'create',
                targetId: row.id,
                folderId: parentId,
                name,
                zone,
                keepOffline: row.keepOffline,
              },
              tx,
            );
            journaledFolders.add(row.id);
          }
          return row;
        });
        op = null;
      }
      if (!folder) throw notFound(`folder ${name} not found after create`);
      // одно событие на папку за проход; ошибку журнала не глотаем — распаковка идемпотентна
      // (чекпойнт + проверка уже распакованных записей), повторный заход безопасен
      if (op && ownerId && !journaledFolders.has(folder.id)) {
        journaledFolders.add(folder.id);
        const target = folder;
        // создание и событие — одной транзакцией: раньше падение между ними теряло событие
        await this.prisma.$transaction(async (tx) => {
          await this.changes.record(
            {
              userId: ownerId,
              target: 'folder',
              op,
              targetId: target.id,
              folderId: parentId,
              name,
              zone: target.zone,
              keepOffline: target.keepOffline,
            },
            tx,
          );
        });
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
    /** Медиа зоны «Фото» — ставим в очередь конвертации после распаковки (см. конец цикла). */
    const pendingMedia: Array<{ assetId: string; sha256: string; mime: string }> = [];
    // Фото и видео из архива: метаданные разбираем после распаковки, из локальных файлов
    /** Фото и видео из архива: метаданные и дата съёмки из сайдкаров — после распаковки */
    const pendingMeta: Array<{
      assetId: string;
      sha256: string;
      size: number;
      mime: string;
      date: Date | null;
      geo: { latitude: number; longitude: number } | null;
    }> = [];
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

      // имя занято другим содержимым — не затираем, добавляем суффикс
      const createdName = existing ? await this.uniqueName(folderId, fileName) : fileName;
      // через FilesService.createEntry: зона берётся у папки-приёмника, запись в дереве и
      // событие журнала идут одной транзакцией (раньше здесь была своя копия этой логики)
      // дата съёмки: сначала сайдкар Takeout, иначе дата файла из архива (у Takeout это время
      // упаковки, поэтому для него архивную дату не берём)
      const taken = await this.takeoutDate(zip, sidecars, sidecarsByKey, e.name);
      const fileDate = taken?.date ?? (isTakeout ? null : e.lastModified);

      await this.files.createEntry(folderId, createdName, assetId, {
        userId: ownerId ?? undefined,
        // без этого у всего импорта остаётся только дата импорта, а «дата файла» теряется
        clientMtime: fileDate,
        asset: { sha256, size: realSize, mime },
      });

      // Медиа-зона: запоминаем для очереди конвертации. Ставим её ПОСЛЕ распаковки —
      // вызов здесь блокировал бы разбор архива, а EXIF воркер возьмёт из локального файла.
      if (entry.zone === ZONE_PHOTOS) pendingMedia.push({ assetId, sha256, mime });

      // Метаданные — любому фото и видео, независимо от зоны. Разбираем фоном и по одному:
      // ffprobe на каждый файл внутри распаковки заметно удлинил бы импорт.
      if (IMAGE_MIMES.includes(mime) || VIDEO_MIMES.includes(mime)) {
        pendingMeta.push({ assetId, sha256, size: realSize, mime, date: fileDate, geo: taken?.geo ?? null });
      }

      doneEntries += 1;
      doneBytes += e.uncompressedSize;
      await this.checkpoint(jobId, idx + 1, doneEntries, doneBytes, skipped, fileName);
    }

    if (pendingMeta.length) {
      void this.collectMeta(pendingMeta);
    }

    if (pendingMedia.length) {
      this.logger.log(`«Фото»: ставим в очередь конвертации ${pendingMedia.length} файлов из архива`);
      for (const m of pendingMedia) {
        await this.queue.enqueue(m.assetId, m.sha256, m.mime).catch(() => undefined);
      }
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
