import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { MediaService } from '../media/media.service';
import { assertSafeName } from '../common/utils';
import { conflict, notFound } from '../common/errors';

@Injectable()
export class FilesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
  ) {}

  /** Папка-приёмник: существует и не в корзине. */
  private async ensureFolder(folderId: string) {
    const folder = await this.prisma.folder.findUnique({ where: { id: folderId } });
    if (!folder || folder.deletedAt) throw notFound('folder not found');
    return folder;
  }

  /** Asset по хэшу; если нет — создаёт запись (объект в S3 уже должен лежать под files/<sha256>). */
  async ensureAsset(sha256: string, size: number, mime: string, ext?: string): Promise<string> {
    const existing = await this.prisma.asset.findUnique({ where: { sha256 } });
    if (existing) return existing.id;
    const asset = await this.prisma.asset.create({
      data: { sha256, size: BigInt(size), mime, ext },
    });
    return asset.id;
  }

  async assertNameFree(folderId: string, name: string, exceptId?: string): Promise<void> {
    const existing = await this.prisma.fileEntry.findFirst({
      where: { folderId, name, ...(exceptId ? { id: { not: exceptId } } : {}) },
    });
    if (existing) {
      if (existing.deletedAt) {
        throw conflict('file with this name is in trash — restore or purge it first');
      }
      throw conflict('file name already exists');
    }
  }

  /** Создание FileEntry (после того, как объект в S3 готов или найден по хэшу). */
  async createEntry(folderId: string, name: string, assetId: string): Promise<{ id: string; deduped: boolean }> {
    await this.ensureFolder(folderId);
    assertSafeName(name);
    await this.assertNameFree(folderId, name);

    // если на одно содержимое уже есть живой entry в этой папке с другим именем — дедуп по содержимому
    const sameAssetLive = await this.prisma.fileEntry.findFirst({
      where: { folderId, assetId, deletedAt: null, name: { not: name } },
    });

    const entry = await this.prisma.fileEntry.create({
      data: { folderId, assetId, name },
      select: { id: true },
    });
    return { id: entry.id, deduped: Boolean(sameAssetLive) };
  }

  async getEntryMeta(entryId: string) {
    const entry = await this.prisma.fileEntry.findUnique({
      where: { id: entryId },
      include: { asset: true, folder: { select: { id: true, name: true } } },
    });
    if (!entry || entry.deletedAt) throw notFound('file not found');
    return {
      id: entry.id,
      name: entry.name,
      createdAt: entry.createdAt,
      folderId: entry.folderId,
      size: Number(entry.asset.size),
      mime: entry.asset.mime,
      sha256: entry.asset.sha256,
    };
  }

  /** Presigned-URL для скачивания оригинала. */
  async presignedUrl(entryId: string): Promise<string> {
    const entry = await this.prisma.fileEntry.findUnique({
      where: { id: entryId },
      include: { asset: true },
    });
    if (!entry || entry.deletedAt) throw notFound('file not found');
    if (entry.asset.masterMime === 'image/avif' && entry.asset.masterReadyAt) {
      return this.s3.presignedInline(MediaService.photoMasterKey(entry.asset.sha256), 'image/avif');
    }
    if (entry.asset.masterMime === 'video/mp4' && entry.asset.masterReadyAt) {
      return this.s3.presignedInline(MediaService.videoMasterKey(entry.asset.sha256), 'video/mp4');
    }
    return this.s3.presignedGet(S3Service.assetKey(entry.asset.sha256), entry.asset.mime);
  }

  async softDelete(entryId: string) {
    const entry = await this.prisma.fileEntry.findUnique({ where: { id: entryId } });
    if (!entry || entry.deletedAt) throw notFound('file not found');
    await this.prisma.fileEntry.update({ where: { id: entryId }, data: { deletedAt: new Date() } });
    return { ok: true };
  }

  async restore(entryId: string) {
    const entry = await this.prisma.fileEntry.findUnique({ where: { id: entryId } });
    if (!entry) throw notFound('file not found');
    if (entry.deletedAt) {
      const folder = await this.prisma.folder.findUnique({ where: { id: entry.folderId } });
      if (!folder || folder.deletedAt) throw conflict('parent folder is deleted — restore folder first');
    }
    await this.prisma.fileEntry.update({ where: { id: entryId }, data: { deletedAt: null } });
    return { ok: true };
  }
}
