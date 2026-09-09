import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService, ROOT_FOLDER_NAME } from '../auth/auth.service';
import { assertSafeName } from '../common/utils';
import { badRequest, conflict, notFound } from '../common/errors';

const isRoot = (f: { name: string }) => f.name === ROOT_FOLDER_NAME;

@Injectable()
export class FoldersService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
  ) {}

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

  async create(parentId: string | undefined, name: string, userId: string) {
    assertSafeName(name);
    const parent = await this.resolveAccessible(parentId, userId);
    await this.assertNameFree(parent.id, name);
    return this.prisma.folder.create({
      data: { parentId: parent.id, name },
      select: { id: true, name: true, parentId: true, createdAt: true },
    });
  }

  async rename(id: string, name: string, userId: string) {
    assertSafeName(name);
    const folder = await this.resolveAccessible(id, userId);
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
    if (isRoot(folder)) throw badRequest('cannot move root');
    const target = await this.resolveAccessible(newParentId, userId);
    const subtree = await this.collectSubtreeIds(id);
    if (subtree.includes(target.id)) throw badRequest('cannot move folder into its own subtree');
    await this.assertNameFree(target.id, folder.name, id);
    return this.prisma.folder.update({
      where: { id },
      data: { parentId: target.id },
      select: { id: true, parentId: true },
    });
  }

  /** Мягкое удаление папки вместе со всем поддеревом. */
  async softDelete(id: string, userId: string) {
    const folder = await this.resolveAccessible(id, userId);
    if (isRoot(folder)) throw badRequest('cannot delete root');
    const ids = await this.collectSubtreeIds(id);
    await this.prisma.folder.updateMany({ where: { id: { in: ids } }, data: { deletedAt: new Date() } });
    return { ok: true, affected: ids.length };
  }

  /** Восстановление папки: само поддерево, но не выше (родитель уже мог быть удалён). */
  async restore(id: string, userId: string) {
    await this.resolveAccessibleOrDeleted(id, userId);
    const ids = await this.collectSubtreeIds(id);
    await this.prisma.folder.updateMany({ where: { id: { in: ids } }, data: { deletedAt: null } });
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
