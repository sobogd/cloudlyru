import { Injectable } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService, ROOT_FOLDER_NAME } from '../auth/auth.service';
import { MediaService } from '../media/media.service';
import { assertSafeName } from '../common/utils';
import { QueueService } from '../queue/queue.service';
import { ChangesService } from '../sync/changes.service';
import { ZONE_FILES, ZONE_PHOTOS } from '../common/zones';
import { badRequest, conflict, notFound } from '../common/errors';

const isRoot = (f: { name: string }) => f.name === ROOT_FOLDER_NAME;

/** Порция содержимого папки по умолчанию и её потолок (keyset-пагинация по имени). */
const CHILDREN_PAGE = 1000;
const CHILDREN_PAGE_MAX = 5000;

@Injectable()
export class FoldersService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
    private readonly media: MediaService,
    private readonly queue: QueueService,
    private readonly changes: ChangesService,
  ) {}

  /** Системную папку «Фото» нельзя переименовать/переместить/удалить. */
  private async assertNotPhotoRoot(folder: { id: string }, userId: string, action: string) {
    const photoId = await this.auth.photoRootIdOrNull(userId);
    if (photoId && folder.id === photoId) throw badRequest(`cannot ${action} photo library root`);
  }

  private async rootId(userId: string): Promise<string> {
    return this.auth.rootFolderId(userId);
  }

  /**
   * Папка доступна (существует, не удалена И принадлежит этому пользователю).
   * Если id — null/undefined → корень. Без проверки владельца сюда ходить нельзя:
   * раньше `PATCH /folders/:id {parentId: свой корень}` переносил чужое поддерево
   * в своё дерево, и после этого все проверки владения начинали пропускать чужие файлы.
   */
  private async resolveAccessible(id: string | undefined | null, userId: string) {
    if (!id) return this.prisma.folder.findUniqueOrThrow({ where: { id: await this.rootId(userId) } });
    const folder = await this.prisma.folder.findUnique({ where: { id } });
    if (!folder || folder.deletedAt) throw notFound('folder not found');
    if (!(await this.auth.folderOwnedBy(userId, folder.id))) throw notFound('folder not found');
    return folder;
  }

  /**
   * Список содержимого папки. `after` — keyset-пагинация по имени: плоская «Фото» на десятки
   * тысяч записей иначе отдавалась бы одним ответом в десятки мегабайт (клиент синхронизации
   * читает это на каждом проходе). Без `after` отдаём первую порцию и признак `hasMore`.
   */
  async listChildren(parentId: string | undefined, userId: string, after?: string, limit?: number) {
    const parent = await this.resolveAccessible(parentId, userId);
    const take = Math.min(Math.max(limit ?? CHILDREN_PAGE, 1), CHILDREN_PAGE_MAX);
    const nameFilter = after ? { gt: after } : {};
    const [folders, entries] = await Promise.all([
      this.prisma.folder.findMany({
        where: { parentId: parent.id, deletedAt: null, name: nameFilter },
        orderBy: { name: 'asc' },
        take,
        select: { id: true, name: true, createdAt: true, updatedAt: true },
      }),
      this.prisma.fileEntry.findMany({
        where: { folderId: parent.id, deletedAt: null, name: nameFilter },
        orderBy: { name: 'asc' },
        take,
        select: {
          id: true,
          name: true,
          createdAt: true,
          keepOffline: true,
          clientMtime: true,
          asset: { select: { size: true, mime: true, sha256: true } },
        },
      }),
    ]);
    // «есть ли ещё» считаем по общему числу за страницей, а не по размеру порции каждого списка
    const lastFolder = folders.length ? folders[folders.length - 1].name : null;
    const lastEntry = entries.length ? entries[entries.length - 1].name : null;
    const last = [lastFolder, lastEntry].filter((n): n is string => n !== null).sort().pop() ?? null;
    const hasMore =
      folders.length === take ||
      entries.length === take ||
      (last !== null &&
        (await this.prisma.fileEntry.count({
          where: { folderId: parent.id, deletedAt: null, name: { gt: last } },
        })) +
          (await this.prisma.folder.count({
            where: { parentId: parent.id, deletedAt: null, name: { gt: last } },
          })) >
          0);

    return {
      parentId: parent.id,
      hasMore,
      nextAfter: hasMore ? last : null,
      folders,
      entries: entries.map((e) => ({
        id: e.id,
        name: e.name,
        createdAt: e.createdAt,
        size: Number(e.asset.size),
        mime: e.asset.mime,
        sha256: e.asset.sha256,
        // нужны клиенту синхронизации: mtime восстанавливается у скачанного файла,
        // а «держать офлайн» перекрывает вытеснение на телефоне
        keepOffline: e.keepOffline,
        clientMtime: e.clientMtime ? e.clientMtime.toISOString() : null,
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
      keepOffline: folder.keepOffline,
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
    this.assertNotReservedName(name);
    const parent = await this.resolveAccessible(parentId, userId);
    await this.assertNameFree(parent.id, name);
    // новые папки наследуют зону родителя: внутри «Фото» — медиа-зона, в остальном дереве — файлы
    const zone = parent.zone === ZONE_PHOTOS ? ZONE_PHOTOS : ZONE_FILES;
    try {
      return await this.prisma.$transaction(async (tx) => {
        const created = await tx.folder.create({
          data: { parentId: parent.id, name, zone },
          select: { id: true, name: true, parentId: true, createdAt: true },
        });
        await this.changes.record(
          {
            userId,
            target: 'folder',
            op: 'create',
            targetId: created.id,
            folderId: parent.id,
            name,
            zone,
          },
          tx,
        );
        return created;
      });
    } catch (e) {
      throw this.asNameConflict(e, 'folder');
    }
  }

  /**
   * Имя системного корня зарезервировано: папка с таким именем считается корнем
   * (`isRoot`), её нельзя ни переименовать, ни переместить, ни удалить через API.
   */
  private assertNotReservedName(name: string): void {
    if (name === ROOT_FOLDER_NAME) throw badRequest(`${ROOT_FOLDER_NAME} is a reserved name`);
  }

  /** Гонка на @@unique([parentId, name]) должна давать 409, а не 500 от Prisma. */
  private asNameConflict(e: unknown, kind: 'folder' | 'file'): Error {
    if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
      return conflict(`${kind} name already exists (created concurrently)`);
    }
    return e as Error;
  }

  /**
   * Идемпотентный mkdir по пути: `Files/2025/07` от указанного родителя (по умолчанию — корень).
   * Нужен клиенту синхронизации, чтобы не строить дерево руками и не ловить 409 на каждом уровне.
   */
  async ensurePath(userId: string, path: string, parentId?: string) {
    const raw = String(path);
    if (raw.length > 1024) throw badRequest('path too long (max 1024)');
    const segments = raw
      .split('/')
      .map((s) => s.trim())
      .filter((s) => s.length > 0);
    if (!segments.length) throw badRequest('empty path');
    // без потолка глубины один запрос создаёт тысячи папок (и столько же строк журнала),
    // а папки глубже 128 уровней всё равно недоступны: обход владельца упирается в лимит
    const MAX_PATH_SEGMENTS = 32;
    if (segments.length > MAX_PATH_SEGMENTS) {
      throw badRequest(`too many path segments (max ${MAX_PATH_SEGMENTS})`);
    }
    for (const s of segments) {
      try {
        assertSafeName(s);
      } catch {
        throw badRequest(`invalid path segment: ${s}`);
      }
    }
    // запросы с других клиентов могут прислать системный корень первым сегментом — он не создаётся
    // системный корень может прийти только первым сегментом; в середине пути это обычное имя
    const wanted = segments[0] === ROOT_FOLDER_NAME ? segments.slice(1) : segments;

    let current = await this.resolveAccessible(parentId, userId);
    let createdCount = 0;
    for (const name of wanted) {
      const existing = await this.prisma.folder.findFirst({ where: { parentId: current.id, name } });
      if (existing) {
        if (existing.deletedAt) {
          throw conflict(`folder ${name} is in trash — restore or purge it first`);
        }
        current = existing;
        continue;
      }
      const zone = current.zone === ZONE_PHOTOS ? ZONE_PHOTOS : ZONE_FILES;
      try {
        const created = await this.prisma.$transaction(async (tx) => {
          const row = await tx.folder.create({ data: { parentId: current.id, name, zone } });
          await this.changes.record(
            {
              userId,
              target: 'folder',
              op: 'create',
              targetId: row.id,
              folderId: current.id,
              name,
              zone,
            },
            tx,
          );
          return row;
        });
        current = created;
        createdCount += 1;
      } catch (e) {
        // параллельный ensure-path того же пути: папку создал кто-то другой — просто идём в неё
        if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
          const raced = await this.prisma.folder.findFirst({ where: { parentId: current.id, name } });
          if (raced && !raced.deletedAt) {
            current = raced;
            continue;
          }
        }
        throw this.asNameConflict(e, 'folder');
      }
    }
    return { id: current.id, name: current.name, parentId: current.parentId, zone: current.zone, created: createdCount };
  }

  /** Флаг «держать офлайн»: клиент обязан держать содержимое папки целиком и не вытеснять его. */
  async setKeepOffline(id: string, keepOffline: boolean, userId: string) {
    const folder = await this.resolveAccessible(id, userId);
    if (folder.keepOffline !== keepOffline) {
      await this.prisma.$transaction(async (tx) => {
        await tx.folder.update({ where: { id: folder.id }, data: { keepOffline } });
        await this.changes.record(
          {
            userId,
            target: 'folder',
            op: 'pin',
            targetId: folder.id,
            folderId: folder.parentId,
            name: folder.name,
            zone: folder.zone,
            keepOffline,
          },
          tx,
        );
      });
    }
    return { ok: true, id: folder.id, keepOffline };
  }

  /**
   * Правка папки одним запросом (клиент синхронизации): имя, переезд, «держать офлайн».
   * Порядок важен: сначала переименование и переезд, потом флаг — каждое действие
   * пишет своё событие, клиент применяет их по порядку seq.
   */
  async patch(
    id: string,
    body: { name?: string; parentId?: string; keepOffline?: boolean },
    userId: string,
  ) {
    let renamed: { id: string; name: string } | null = null;
    let moved: { id: string; parentId: string | null; zone: string } | null = null;
    if (body.name !== undefined) renamed = await this.rename(id, body.name, userId);
    if (body.parentId !== undefined) {
      const res = await this.move(id, body.parentId, userId);
      moved = { id: res.id, parentId: res.parentId, zone: res.zone };
    }
    if (body.keepOffline !== undefined) await this.setKeepOffline(id, body.keepOffline, userId);
    const folder = await this.prisma.folder.findUnique({
      where: { id },
      select: { id: true, name: true, parentId: true, zone: true, keepOffline: true },
    });
    return { ok: true, renamed, moved, folder };
  }

  async rename(id: string, name: string, userId: string) {
    assertSafeName(name);
    this.assertNotReservedName(name);
    const folder = await this.resolveAccessible(id, userId);
    await this.assertNotPhotoRoot(folder, userId, 'rename');
    if (isRoot(folder)) throw badRequest('cannot rename root');
    await this.assertNameFree(folder.parentId!, name, id);
    try {
      return await this.prisma.$transaction(async (tx) => {
        const renamed = await tx.folder.update({
          where: { id },
          data: { name },
          select: { id: true, name: true },
        });
        await this.changes.record(
          {
            userId,
            target: 'folder',
            op: 'update',
            targetId: id,
            folderId: folder.parentId,
            name,
            zone: folder.zone,
            keepOffline: folder.keepOffline,
          },
          tx,
        );
        return renamed;
      });
    } catch (e) {
      throw this.asNameConflict(e, 'folder');
    }
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
    const moved = await this.prisma.$transaction(async (tx) => {
      const row = await tx.folder.update({
        where: { id },
        data: { parentId: target.id },
        select: { id: true, parentId: true, zone: true },
      });
      // папка переехала между зонами — пересчитываем зону всего поддерева (папки + файлы)
      if (folder.zone !== newZone) {
        await tx.folder.updateMany({ where: { id: { in: subtree } }, data: { zone: newZone } });
        await tx.fileEntry.updateMany({ where: { folderId: { in: subtree } }, data: { zone: newZone } });
      }
      await this.changes.record(
        {
          userId,
          target: 'folder',
          op: 'move',
          targetId: id,
          folderId: target.id,
          name: folder.name,
          zone: newZone,
          keepOffline: folder.keepOffline,
        },
        tx,
      );
      return row;
    });
    if (folder.zone !== newZone && newZone === ZONE_PHOTOS) void this.reprocessAsMedia(subtree);
    return { id: moved.id, parentId: moved.parentId, zone: newZone };
  }

  /** Мягкое удаление папки вместе со всем поддеревом. */
  async softDelete(id: string, userId: string) {
    const folder = await this.resolveAccessible(id, userId);
    await this.assertNotPhotoRoot(folder, userId, 'delete');
    if (isRoot(folder)) throw badRequest('cannot delete root');
    const ids = await this.collectSubtreeIds(id);
    await this.prisma.$transaction(async (tx) => {
      await tx.folder.updateMany({ where: { id: { in: ids } }, data: { deletedAt: new Date() } });
      // одно событие на корень поддерева: «папка удалена» означает «всего её содержимого нет»
      await this.changes.recordFolderTreeDeleted(userId, id, tx);
    });
    await this.cancelAssetsIn(ids);
    return { ok: true, affected: ids.length };
  }

  /**
   * Восстановление папки: само поддерево, но не выше (родитель уже мог быть удалён).
   * Удаление журналируется одним событием на поддерево («папки нет» ⇒ содержимого нет),
   * поэтому на восстановлении наоборот нужны события по детям: иначе клиент знает только
   * про саму папку и не может восстановить её содержимое.
   */
  async restore(id: string, userId: string) {
    const root = await this.resolveAccessibleOrDeleted(id, userId);
    const ids = await this.collectSubtreeIds(id);
    // Возвращаем только то, что удалили вместе с папкой: подпапки, удалённые пользователем
    // отдельно (раньше), остаются в корзине, иначе они воскресали бы без спроса.
    const cutoff = root.deletedAt ? new Date(root.deletedAt.getTime() - 1000) : null;
    const folders = await this.prisma.folder.findMany({
      where: {
        id: { in: ids },
        ...(cutoff ? { OR: [{ deletedAt: null }, { deletedAt: { gte: cutoff } }] } : {}),
      },
      select: { id: true, parentId: true, name: true, zone: true, keepOffline: true },
    });
    const restoreIds = folders.map((f) => f.id);
    const entries = await this.prisma.fileEntry.findMany({
      where: { folderId: { in: restoreIds }, deletedAt: null },
      select: {
        id: true,
        folderId: true,
        name: true,
        zone: true,
        clientMtime: true,
        keepOffline: true,
        asset: { select: { sha256: true, size: true, mime: true } },
      },
    });
    await this.prisma.$transaction(async (tx) => {
      await tx.folder.updateMany({ where: { id: { in: restoreIds } }, data: { deletedAt: null } });
      for (const f of folders) {
        await this.changes.record(
          {
            userId,
            target: 'folder',
            // и корень, и дети — именно restore: клиент отличает «вернулось из корзины»
            // от «создано заново», хотя применяет снимок одинаково
            op: 'restore',
            targetId: f.id,
            folderId: f.parentId,
            name: f.name,
            zone: f.zone,
            keepOffline: f.keepOffline,
          },
          tx,
        );
      }
      if (entries.length) {
        // Порциями: одна вставка с тысячами строк упирается в лимит параметров Postgres
        // (65 535), а по одному INSERT'у — в таймаут транзакции.
        for (let i = 0; i < entries.length; i += 500) {
          await tx.changeLog.createMany({
            data: entries.slice(i, i + 500).map((e) => ({
              userId,
              target: 'entry',
              op: 'restore',
              targetId: e.id,
              folderId: e.folderId,
              name: e.name,
              zone: e.zone,
              sha256: e.asset.sha256,
              size: e.asset.size,
              mime: e.asset.mime,
              clientMtime: e.clientMtime,
              keepOffline: e.keepOffline,
            })),
          });
        }
      }
    }, { timeout: 120_000, maxWait: 15_000 });
    await this.requeueAssetsIn(ids);
    return { ok: true, affected: ids.length };
  }

  private async resolveAccessibleOrDeleted(id: string, userId: string) {
    const folder = await this.prisma.folder.findUnique({ where: { id } });
    if (!folder) throw notFound('folder not found');
    await this.auth.assertFolderOwned(userId, folder.id, { deletedOk: true });
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
        // метаданные — любому фото и видео; конвертация ниже только для медиа-зоны
        await this.media.captureAny(a.id, a.sha256, Number(a.size), a.mime).catch(() => undefined);
        await this.queue.enqueue(a.id, a.sha256, a.mime);
      }
    } catch {
      /* best-effort: не валим перемещение из-за очереди */
    }
  }

  /** BFS всех id поддерева, включая саму папку. */
  async collectSubtreeIds(rootId: string): Promise<string[]> {
    const all: string[] = [rootId];
    // seen защищает от вечного цикла: два конкурентных перемещения могли сделать папку
    // своим же предком, и тогда BFS без отметок рос бы бесконечно (OOM процесса)
    const seen = new Set<string>([rootId]);
    let frontier = [rootId];
    while (frontier.length) {
      const children = await this.prisma.folder.findMany({
        where: { parentId: { in: frontier } },
        select: { id: true },
      });
      const ids = children.map((c) => c.id).filter((cid) => !seen.has(cid));
      if (!ids.length) break;
      for (const cid of ids) seen.add(cid);
      all.push(...ids);
      frontier = ids;
    }
    return all;
  }
}
