import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { FoldersService } from '../folders/folders.service';
import { FilesService } from '../files/files.service';
import { conflict } from '../common/errors';

@Injectable()
export class TrashService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly folders: FoldersService,
    private readonly files: FilesService,
  ) {}

  async list() {
    // «корни» удалённых папок: папка удалена, а её родитель — нет
    const deletedFolders = await this.prisma.folder.findMany({
      where: { deletedAt: { not: null } },
      select: { id: true, name: true, deletedAt: true, parent: { select: { deletedAt: true } } },
      orderBy: { deletedAt: 'desc' },
    });
    const folders = deletedFolders
      .filter((f) => !f.parent?.deletedAt)
      .map((f) => ({ id: f.id, name: f.name, deletedAt: f.deletedAt, kind: 'folder' as const }));

    const deletedEntries = await this.prisma.fileEntry.findMany({
      where: { deletedAt: { not: null } },
      select: {
        id: true,
        name: true,
        deletedAt: true,
        folder: { select: { id: true, name: true, deletedAt: true } },
        asset: { select: { size: true } },
      },
      orderBy: { deletedAt: 'desc' },
    });
    const entries = deletedEntries
      .filter((e) => !e.folder.deletedAt)
      .map((e) => ({
        id: e.id,
        name: e.name,
        deletedAt: e.deletedAt,
        kind: 'file' as const,
        size: Number(e.asset.size),
        folderId: e.folder.id,
      }));

    return { folders, entries };
  }

  async restore(type: 'folder' | 'file', id: string) {
    if (type === 'folder') return this.folders.restore(id, 'unused'); // userId не используется
    try {
      return await this.files.restore(id);
    } catch (e) {
      const code = (e as { code?: string }).code;
      if (code === 'P2002') {
        throw conflict('file with this name already exists — rename it first');
      }
      throw e;
    }
  }

  /** Полная очистка корзины (hard delete) с удалением осиротевших объектов из S3. */
  async purge(olderThanDays?: number) {
    const cutoff = olderThanDays ? new Date(Date.now() - olderThanDays * 24 * 60 * 60 * 1000) : undefined;

    const deletedEntries = await this.prisma.fileEntry.findMany({
      where: { deletedAt: { not: null }, ...(cutoff ? { deletedAt: { lt: cutoff } } : {}) },
      select: { id: true },
    });
    const deletedFolders = await this.prisma.folder.findMany({
      where: { deletedAt: { not: null }, ...(cutoff ? { deletedAt: { lt: cutoff } } : {}) },
      select: { id: true },
    });
    const entryIds = deletedEntries.map((e) => e.id);
    const folderIds = deletedFolders.map((f) => f.id);

    if (entryIds.length) await this.prisma.fileEntry.deleteMany({ where: { id: { in: entryIds } } });
    if (folderIds.length) {
      // onDelete: Cascade убирает и все FileEntry внутри удалённых папок
      await this.prisma.folder.deleteMany({ where: { id: { in: folderIds } } });
    }

    // осиротевшие Asset (больше ни один FileEntry не ссылается) — удаляем из S3 и БД
    const orphanAssets = await this.prisma.asset.findMany({
      where: { entries: { none: {} } },
      select: { id: true, sha256: true },
    });
    if (orphanAssets.length) {
      await this.s3
        .deleteObjects(orphanAssets.map((a) => S3Service.assetKey(a.sha256)))
        .catch(() => undefined);
      await this.prisma.asset.deleteMany({
        where: { id: { in: orphanAssets.map((a) => a.id) } },
      });
    }

    return {
      purgedEntries: entryIds.length,
      purgedFolders: folderIds.length,
      purgedAssets: orphanAssets.length,
    };
  }
}
