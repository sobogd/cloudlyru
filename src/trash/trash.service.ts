import { Injectable, Logger } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { MediaService } from '../media/media.service';
import { FoldersService } from '../folders/folders.service';
import { FilesService } from '../files/files.service';
import { AuthService } from '../auth/auth.service';
import { conflict } from '../common/errors';

@Injectable()
export class TrashService {
  private readonly logger = new Logger(TrashService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly folders: FoldersService,
    private readonly files: FilesService,
    private readonly auth: AuthService,
  ) {}

  /** Корзина ТОЛЬКО этого пользователя: папки и файлы внутри его дерева. */
  async list(userId: string) {
    const tree = await this.auth.subtreeIds(userId, { includeDeleted: true });
    // «корни» удалённых папок: папка удалена, а её родитель — нет
    const deletedFolders = await this.prisma.folder.findMany({
      where: { deletedAt: { not: null }, id: { in: tree } },
      select: { id: true, name: true, deletedAt: true, parent: { select: { deletedAt: true } } },
      orderBy: { deletedAt: 'desc' },
    });
    const folders = deletedFolders
      .filter((f) => !f.parent?.deletedAt)
      .map((f) => ({ id: f.id, name: f.name, deletedAt: f.deletedAt, kind: 'folder' as const }));

    const deletedEntries = await this.prisma.fileEntry.findMany({
      where: { deletedAt: { not: null }, folderId: { in: tree } },
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

  async restore(type: 'folder' | 'file', id: string, userId: string) {
    if (type === 'folder') return this.folders.restore(id, userId);
    try {
      return await this.files.restore(id, userId);
    } catch (e) {
      const code = (e as { code?: string }).code;
      if (code === 'P2002') {
        throw conflict('file with this name already exists — rename it first');
      }
      throw e;
    }
  }

  /** Полная очистка СВОЕЙ корзины (hard delete) с удалением осиротевших объектов из S3. */
  async purge(userId: string, olderThanDays?: number) {
    const cutoff = olderThanDays ? new Date(Date.now() - olderThanDays * 24 * 60 * 60 * 1000) : undefined;
    const tree = await this.auth.subtreeIds(userId, { includeDeleted: true });

    const deletedEntries = await this.prisma.fileEntry.findMany({
      where: {
        deletedAt: { not: null },
        folderId: { in: tree },
        ...(cutoff ? { deletedAt: { lt: cutoff } } : {}),
      },
      select: { id: true },
    });
    const deletedFolders = await this.prisma.folder.findMany({
      where: {
        deletedAt: { not: null },
        id: { in: tree },
        ...(cutoff ? { deletedAt: { lt: cutoff } } : {}),
      },
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
      // Удаляем и сырьё, и ВСЕ производные (view/*): мастер AVIF/AV1, превью и постер.
      // Раньше удалялось только files/<sha>, поэтому деривативы оставались в S3 навсегда
      // (а для зоны «Фото», где сырьё уже удалено после конвертации, не удалялось вообще ничего).
      const keys = orphanAssets.flatMap((a) => [
        S3Service.assetKey(a.sha256),
        ...MediaService.derivativeKeys(a.sha256),
      ]);
      // Ошибку S3 больше не глотаем: если объект не удалился, ассет остаётся в БД и его
      // удаление повторится при следующей очистке. Иначе строка исчезает, а объект
      // остаётся в бакете навсегда — его уже ничто не найдёт (ровно так появлялись «зомби»
      // после того, как локальный инстанс с прод-бакетом терял свою БД).
      const failed = await this.s3.deleteObjects(keys).catch((e: Error) => {
        this.logger.error(`S3 не ответил на удаление объектов: ${e.message}`);
        return keys;
      });
      const failedSet = new Set(failed);
      const removed = orphanAssets.filter((a) => !failedSet.has(S3Service.assetKey(a.sha256)));
      const kept = orphanAssets.length - removed.length;
      if (kept) {
        this.logger.warn(
          `${kept} ассетов остались в БД: S3 не подтвердил удаление — повтор при следующей очистке`,
        );
      }
      if (removed.length) {
        await this.prisma.asset.deleteMany({ where: { id: { in: removed.map((a) => a.id) } } });
      }
      return {
        purgedEntries: entryIds.length,
        purgedFolders: folderIds.length,
        purgedAssets: removed.length,
        ...(kept ? { retryAssets: kept } : {}),
      };
    }

    return {
      purgedEntries: entryIds.length,
      purgedFolders: folderIds.length,
      purgedAssets: 0,
    };
  }
}
