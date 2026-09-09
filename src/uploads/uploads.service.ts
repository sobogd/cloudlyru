import { createHash, Hash } from 'crypto';
import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service, S3Part } from '../s3/s3.service';
import { FilesService } from '../files/files.service';
import { MediaService } from '../media/media.service';
import { QueueService } from '../queue/queue.service';
import { AuthService } from '../auth/auth.service';
import { CHUNK_MAX_BYTES, MAX_FILE_BYTES } from '../config/env';
import { assertSafeName, randomToken } from '../common/utils';
import { badRequest, conflict, notFound, payloadTooLarge } from '../common/errors';

interface LiveSession {
  hash: Hash; // инкрементальный sha256 по порядку чанков
  parts: S3Part[];
  tmpKey: string;
  s3UploadId: string;
}

/**
 * Чанкованная загрузка: каждый чанк = часть multipart-upload в S3.
 * sha256 считается инкрементально по мере поступления → на complete дедуп до финализации.
 * ВАЖНО: live-состояние (хэш/этаги) в памяти процесса; рестарт сервера = сессию надо
 * пересоздать (cleanup по старым UploadSession делает onModuleInit). TODO(M1): персистентность.
 */
@Injectable()
export class UploadsService implements OnModuleInit {
  private readonly logger = new Logger(UploadsService.name);
  private readonly live = new Map<string, LiveSession>();
  private readonly STALE_MS = 24 * 60 * 60 * 1000;

  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly files: FilesService,
    private readonly auth: AuthService,
    private readonly media: MediaService,
    private readonly queue: QueueService,
  ) {}

  async onModuleInit() {
    // чистка зависших сессий загрузки (после рестарта сервера)
    try {
      const stale = await this.prisma.uploadSession.findMany({
        where: { updatedAt: { lt: new Date(Date.now() - this.STALE_MS) } },
      });
      for (const s of stale) {
        await this.s3.abortMultipartUpload(s.uploadKey, s.s3UploadId).catch(() => undefined);
        await this.prisma.uploadSession.delete({ where: { id: s.id } }).catch(() => undefined);
      }
      if (stale.length) this.logger.log(`Очищено зависших upload-сессий: ${stale.length}`);
    } catch (e) {
      this.logger.warn(`cleanup uploads: ${(e as Error).message}`);
    }
  }

  private async resolveFolder(folderId: string | undefined, userId: string): Promise<string> {
    if (folderId) {
      const folder = await this.prisma.folder.findUnique({ where: { id: folderId } });
      if (!folder || folder.deletedAt) throw notFound('folder not found');
      return folder.id;
    }
    return this.auth.rootFolderId(userId);
  }

  async init(body: { folderId?: string; name: string; size: number; mime: string }, userId: string) {
    const name = String(body.name ?? '');
    const size = Number(body.size);
    const mime = String(body.mime ?? 'application/octet-stream');
    assertSafeName(name);
    if (!Number.isFinite(size) || size <= 0) throw badRequest('invalid size');
    if (size > MAX_FILE_BYTES) throw payloadTooLarge('file too large');
    const folderId = await this.resolveFolder(body.folderId, userId);

    const tmpKey = `files/tmp/${randomToken(16)}`;
    const s3UploadId = await this.s3.createMultipartUpload(tmpKey);
    const session = await this.prisma.uploadSession.create({
      data: { userId, s3UploadId, uploadKey: tmpKey, folderId, name, size: BigInt(size), mime },
    });

    this.live.set(session.id, { hash: createHash('sha256'), parts: [], tmpKey, s3UploadId });
    return {
      uploadId: session.id,
      folderId,
      name,
      size,
      chunkMaxBytes: CHUNK_MAX_BYTES,
      nextPart: 1,
    };
  }

  async status(uploadId: string, userId: string) {
    const row = await this.prisma.uploadSession.findUnique({ where: { id: uploadId } });
    if (!row || row.userId !== userId) throw notFound('upload not found');
    const live = this.live.get(uploadId);
    return {
      uploadId,
      nextPart: live ? live.parts.length + 1 : row.partCount + 1,
      receivedParts: row.partCount,
      size: Number(row.size),
      name: row.name,
      folderId: row.folderId,
    };
  }

  async putChunk(uploadId: string, partNumber: number, chunk: Buffer, userId: string) {
    if (chunk.length > CHUNK_MAX_BYTES) throw payloadTooLarge('chunk too large');
    const row = await this.prisma.uploadSession.findUnique({ where: { id: uploadId } });
    if (!row || row.userId !== userId) throw notFound('upload not found');

    const live = this.live.get(uploadId);
    if (!live) {
      throw conflict('upload session expired (server restart) — re-init upload', 'upload_session_lost');
    }
    const expected = live.parts.length + 1;
    if (partNumber < expected) {
      // идемпотентность: повторный/дублирующийся чанк — считаем успешным
      return { uploadId, nextPart: expected, duplicate: true };
    }
    if (partNumber > expected) {
      throw badRequest(`missing part ${expected} (got ${partNumber}) — upload out of order`);
    }

    const etag = await this.s3.uploadPart(live.tmpKey, live.s3UploadId, partNumber, chunk);
    live.hash.update(chunk);
    live.parts.push({ PartNumber: partNumber, ETag: etag });
    await this.prisma.uploadSession.update({
      where: { id: uploadId },
      data: { partCount: partNumber },
    });
    return { uploadId, nextPart: partNumber + 1, receivedBytes: partNumber * chunk.length };
  }

  async complete(uploadId: string, userId: string) {
    const row = await this.prisma.uploadSession.findUnique({ where: { id: uploadId } });
    if (!row || row.userId !== userId) throw notFound('upload not found');
    const live = this.live.get(uploadId);
    if (!live) throw conflict('upload session expired (server restart) — re-init upload', 'upload_session_lost');

    const sha256 = live.hash.digest('hex');
    const finalKey = S3Service.assetKey(sha256);
    const size = Number(row.size);
    const mime = row.mime;

    // Дедуп: такой объект уже есть?
    const existingAsset = await this.prisma.asset.findUnique({ where: { sha256 } });

    let assetId: string;
    let deduped = false;
    if (existingAsset) {
      // содержимое уже в S3 — multipart не финализируем, tmp отменяем
      deduped = true;
      assetId = existingAsset.id;
      await this.s3.abortMultipartUpload(live.tmpKey, live.s3UploadId).catch(() => undefined);
    } else {
      // финализируем tmp-объект и перекладываем под content-addressed ключ (server-side copy)
      await this.s3.completeMultipartUpload(live.tmpKey, live.s3UploadId, live.parts);
      await this.s3.copyObject(live.tmpKey, finalKey);
      assetId = await this.files.ensureAsset(sha256, size, mime, this.extOf(row.name));
    }

    // tmp-объект больше не нужен
    await this.s3.deleteObject(live.tmpKey).catch(() => undefined);

    const folderId = row.folderId ?? (await this.auth.rootFolderId(userId));
    const entry = await this.files.createEntry(folderId, row.name, assetId);

    await this.prisma.uploadSession.delete({ where: { id: uploadId } });
    this.live.delete(uploadId);

    // EXIF (дата съёмки/координаты) — best-effort, не валит загрузку
    try {
      await this.media.captureMeta(assetId, sha256, size, mime);
    } catch {
      /* ignore */
    }
    await this.queue.enqueue(assetId, sha256, mime);

    return {
      entry: { id: entry.id },
      asset: { sha256, size, mime },
      deduped,
    };
  }

  async abort(uploadId: string, userId: string) {
    const row = await this.prisma.uploadSession.findUnique({ where: { id: uploadId } });
    if (!row || row.userId !== userId) throw notFound('upload not found');
    const live = this.live.get(uploadId);
    if (live) await this.s3.abortMultipartUpload(live.tmpKey, live.s3UploadId).catch(() => undefined);
    await this.prisma.uploadSession.delete({ where: { id: uploadId } });
    this.live.delete(uploadId);
    return { ok: true };
  }

  private extOf(name: string): string | undefined {
    const i = name.lastIndexOf('.');
    if (i <= 0 || i === name.length - 1) return undefined;
    return name.slice(i + 1).toLowerCase().slice(0, 16);
  }
}
