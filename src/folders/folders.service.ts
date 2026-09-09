import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService, ROOT_FOLDER_NAME } from '../auth/auth.service';
import { MediaService } from '../media/media.service';
import { assertSafeName } from '../common/utils';
import { QueueService } from '../queue/queue.service';
import { ZONE_FILES, ZONE_PHOTOS } from '../common/zones';
import { badRequest, conflict, notFound } from '../common/errors';

const isRoot = (f: { name: string }) => f.name === ROOT_FOLDER_NAME;

@Injectable()
export class FoldersService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
    private readonly media: MediaService,
    private readonly queue: QueueService,
  ) {}

  /** Системную папку «Фото» нельзя переименовать/переместить/удалить. */
  private async assertNotPhotoRoot(folder: { id: string }, userId: string, action: string) {
    const photoId = await this.auth.photoRootIdOrNull(userId);
    if (photoId && folder.id === photoId) throw badRequest(`cannot ${action} photo library root`);
  }

  private async rootId(userId: string): Promise<string> {
    return this.auth.rootFolderId(userId);
  }

  /** Папка доступна (существует, не удалена). Если id — null/undefined → корень. */
  private async resolveAccessible(id: string | undefined | null, userId: string) {
    if (!id) return this.prisma.folder.findUniqueOrThrow({ where: { id: await this.rootId(userId) } });
    const folder = await this.prisma.folder.findUnique({ where: { id } });
    if (!folder || folder.deletedAt) throw notFound('folder not found');
    return folder;
  }

  async listChildren(parentId: string | undefined, userId: string) {
    const parent = await this.resolveAccessible(parentId, userId);
    const [folders, entries] = await Promise.all([
      this.prisma.folder.findMany({
        where: { parentId: parent.id, deletedAt: null },
        orderBy: { name: 'asc' },
        select: { id: true, name: true, createdAt: true, updatedAt: true },
      }),
      this.prisma.fileEntry.findMany({
        where: { folderId: parent.id, deletedAt: null },
        orderBy: { name: 'asc' },
        select: {
          id: true,
          name: true,
          createdAt: true,
          asset: { select: { size: true, mime: true, sha256: true } },
        },
      }),
    ]);
    return {
      parentId: parent.id,
      folders,
      entries: entries.map((e) => ({
        id: e.id,
        name: e.name,
        createdAt: e.createdAt,
        size: Number(e.asset.size),
        mime: e.asset.mime,
        sha256: e.asset.sha256,
      })),
    };
  }

  /** Метаданные папки для деталки: путь, счётчики, даты. */
  async meta(id: string, userId: string) {
    const folder = await this.resolveAccessible(id, userId);
    const [folderCount, entryCount] = await Promise.all([
      this.prisma.folder.count({ where: { parentId: folder.id, deletedAt: null } }),
      this.prisma.fileEntry.count({ where: { folderId: folder.id, deletedAt: null } }),
    ]);
    return {
      id: folder.id,
      name: folder.name,
      zone: folder.zone,
      path: await this.folderPath(folder),
      folders: folderCount,
      entries: entryCount,
      createdAt: folder.createdAt,
      updatedAt: folder.updatedAt,
    };
  }

  /** Человекочитаемый путь папки: «Главная / папка / …». */
  private async folderPath(folder: { id: string; parentId: string | null; name: string }): Promise<string> {
    const names: string[] = [];
    let cur: { id: string; parentId: string | null; name: string } = folder;
    for (let i = 0; i < 32 && cur.name !== ROOT_FOLDER_NAME; i++) {
      names.unshift(cur.name);
      if (!cur.parentId) break;
      const parent = await this.prisma.folder.findUnique({
        where: { id: cur.parentId },
        select: { id: true, parentId: true, name: true },
      });
      if (!parent) break;
      cur = parent;
    }
    return ['Главная', ...names].join(' / ');
  }

  async create(parentId: string | undefined, name: string, userId: string) {
    assertSafeName(name);
    const parent = await this.resolveAccessible(parentId, userId);
    await this.assertNameFree(parent.id, name);
    // новые папки наследуют зону родителя: внутри «Фото» — медиа-зона, в остальном дереве — файлы
    const zone = parent.zone === ZONE_PHOTOS ? ZONE_PHOTOS : ZONE_FILES;
    return this.prisma.folder.create({
      data: { parentId: parent.id, name, zone },
      select: { id: true, name: true, parentId: true, createdAt: true },
    });
  }

  async rename(id: string, name: string, userId: string) {
    assertSafeName(name);
    const folder = await this.resolveAccessible(id, userId);
    await this.assertNotPhotoRoot(folder, userId, 'rename');
    if (isRoot(folder)) throw badRequest('cannot rename root');
    await this.assertNameFree(folder.parentId!, name, id);
    return this.prisma.folder.update({
      where: { id },
      data: { name },
      select: { id: true, name: true },
    });
  }

  async move(id: string, newParentId: string, userId: string) {
    const folder = await this.resolveAccessible(id, userId);
    await this.assertNotPhotoRoot(folder, userId, 'move');
    if (isRoot(folder)) throw badRequest('cannot move root');
    const target = await this.resolveAccessible(newParentId, userId);
    const subtree = await this.collectSubtreeIds(id);
    if (subtree.includes(target.id)) throw badRequest('cannot move folder into its own subtree');
    await this.assertNameFree(target.id, folder.name, id);

    const newZone = target.zone === ZONE_PHOTOS ? ZONE_PHOTOS : ZONE_FILES;
    const moved = await this.prisma.folder.update({
      where: { id },
      data: { parentId: target.id },
      select: { id: true, parentId: true, zone: true },
    });
    // папка переехала между зонами — пересчитываем зону всего поддерева (папки + файлы)
    if (folder.zone !== newZone) {
      await this.prisma.folder.updateMany({ where: { id: { in: subtree } }, data: { zone: newZone } });
      await this.prisma.fileEntry.updateMany({ where: { folderId: { in: subtree } }, data: { zone: newZone } });
      if (newZone === ZONE_PHOTOS) void this.reprocessAsMedia(subtree);
    }
    return { id: moved.id, parentId: moved.parentId, zone: newZone };
  }

  /** Мягкое удаление папки вместе со всем поддеревом. */
  async softDelete(id: string, userId: string) {
    const folder = await this.resolveAccessible(id, userId);
    await this.assertNotPhotoRoot(folder, userId, 'delete');
    if (isRoot(folder)) throw badRequest('cannot delete root');
    const ids = await this.collectSubtreeIds(id);
    await this.prisma.folder.updateMany({ where: { id: { in: ids } }, data: { deletedAt: new Date() } });
    await this.cancelAssetsIn(ids);
    return { ok: true, affected: ids.length };
  }

  /** Восстановление папки: само поддерево, но не выше (родитель уже мог быть удалён). */
  async restore(id: string, userId: string) {
    await this.resolveAccessibleOrDeleted(id, userId);
    const ids = await this.collectSubtreeIds(id);
    await this.prisma.folder.updateMany({ where: { id: { in: ids } }, data: { deletedAt: null } });
    await this.requeueAssetsIn(ids);
    return { ok: true, affected: ids.length };
  }

  private async resolveAccessibleOrDeleted(id: string, _userId: string) {
    const folder = await this.prisma.folder.findUnique({ where: { id } });
    if (!folder) throw notFound('folder not found');
    return folder;
  }

  private async assertNameFree(parentId: string, name: string, exceptId?: string) {
    const existing = await this.prisma.folder.findFirst({
      where: { parentId, name, ...(exceptId ? { id: { not: exceptId } } : {}) },
    });
    if (existing) {
      if (existing.deletedAt) {
        throw conflict('folder with this name is in trash — restore or purge it first');
      }
      throw conflict('folder name already exists');
    }
  }


  /** assetId'ы файлов внутри папок (для отмены/возврата конвертации). */
  private async assetsIn(folderIds: string[]): Promise<string[]> {
    const rows = await this.prisma.fileEntry.findMany({ where: { folderId: { in: folderIds } }, select: { assetId: true } });
    return [...new Set(rows.map((r) => r.assetId))];
  }
  private async cancelAssetsIn(folderIds: string[]): Promise<void> {
    const assetIds = await this.assetsIn(folderIds);
    if (assetIds.length) await this.queue.cancelForAssets(assetIds);
  }
  private async requeueAssetsIn(folderIds: string[]): Promise<void> {
    const assetIds = await this.assetsIn(folderIds);
    if (assetIds.length) await this.queue.requeueForAssets(assetIds);
  }

  /** Папки переехали в медиа-зону: ставим на обработку их ещё не конвертированные фото/видео (best-effort). */
  private async reprocessAsMedia(folderIds: string[]) {
    try {
      const assets = await this.prisma.asset.findMany({
        where: {
          masterReadyAt: null,
          entries: { some: { folderId: { in: folderIds }, deletedAt: null, zone: ZONE_PHOTOS } },
        },
        select: { id: true, sha256: true, mime: true, size: true },
      });
      for (const a of assets) {
        try {
          await this.media.captureMeta(a.id, a.sha256, Number(a.size), a.mime);
        } catch {
          /* best-effort */
        }
        await this.queue.enqueue(a.id, a.sha256, a.mime);
      }
    } catch {
      /* best-effort: не валим перемещение из-за очереди */
    }
  }

  /** BFS всех id поддерева, включая саму папку. */
  async collectSubtreeIds(rootId: string): Promise<string[]> {
    const all: string[] = [rootId];
    let frontier = [rootId];
    while (frontier.length) {
      const children = await this.prisma.folder.findMany({
        where: { parentId: { in: frontier } },
        select: { id: true },
      });
      const ids = children.map((c) => c.id);
      if (!ids.length) break;
      all.push(...ids);
      frontier = ids;
    }
    return all;
  }
}
