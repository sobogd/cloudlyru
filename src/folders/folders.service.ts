import { Injectable } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService, ROOT_FOLDER_NAME } from '../auth/auth.service';
import { MediaService } from '../media/media.service';
import { assertSafeName } from '../common/utils';
import { QueueService } from '../queue/queue.service';
import { ChangesService } from '../sync/changes.service';
import { HIDDEN_ZONES, MAIL_FOLDER_NAME, ZONE_PHOTOS, isHiddenZone, zoneOf } from '../common/zones';
import { badRequest, conflict, notFound } from '../common/errors';

const isRoot = (f: { name: string }) => f.name === ROOT_FOLDER_NAME;

/** Порция содержимого папки по умолчанию и её потолок (keyset-пагинация по имени). */
const CHILDREN_PAGE = 1000;
const CHILDREN_PAGE_MAX = 5000;

/** Разбиение длинных `IN`-списков: у Postgres лимит параметров запроса — 65 535. */
function chunksOf<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

@Injectable()
export class FoldersService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
    private readonly media: MediaService,
    private readonly queue: QueueService,
    private readonly changes: ChangesService,
  ) {}

  /**
   * Системные папки (корень, «Фото», «Телефон», корни зеркал устройств) нельзя переименовать,
   * переместить или удалить. Клиент льёт в них по адресации, заведённой сервером: смена имени
   * или места ломает и медиатеку, и зеркало, а удаление уносит содержимое в корзину.
   * Список берём одним методом — иначе новую системную папку легко защитить в одном месте
   * и забыть в другом.
   */
  private async assertNotSystemRoot(folder: { id: string; name?: string }, userId: string, action: string) {
    const protectedIds = await this.auth.protectedFolderIds(userId);
    if (!protectedIds.has(folder.id)) return;
    throw badRequest(`cannot ${action} system folder${folder.name ? ` "${folder.name}"` : ''}`);
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
    // Скрытые зоны (папка «Почта» с вложениями писем) недоступны через API папок: ни список,
    // ни создание/копирование/перенос внутрь, ни мета. Одним гардом на входе, а не проверками
    // в каждой ручке. Прямая ссылка на файл-вложение при этом работает — она идёт мимо папок.
    if (isHiddenZone(folder.zone)) throw notFound('folder not found');
    return folder;
  }

  /**
   * Список содержимого папки. `after` — keyset-пагинация по имени: плоская «Фото» на десятки
   * тысяч записей иначе отдавалась бы одним ответом в десятки мегабайт (клиент синхронизации
   * читает это на каждом проходе). Без `after` отдаём первую порцию и признак `hasMore`.
   *
   * Взаимодействие с мягким удалением: keyset идёт по (имя > after) и фильтрует `deletedAt`,
   * поэтому запись, восстановленная из корзины с именем ≤ `after`, в текущем проходе уже не
   * появится — клиент увидит её только со следующим полным обходом. Для удалений это безопасно
   * (tombstone в журнале), а вот восстановление в середину уже прочитанной страницы клиент
   * увидит не сразу: полагаться на «после восстановления файл тут же в листинге» нельзя.
   */
  async listChildren(parentId: string | undefined, userId: string, after?: string, limit?: number) {
    const parent = await this.resolveAccessible(parentId, userId);
    const take = Math.min(Math.max(limit ?? CHILDREN_PAGE, 1), CHILDREN_PAGE_MAX);
    const nameFilter = after ? { gt: after } : {};
    // Скрытые зоны (сейчас это «Почта») из листинга выпадают целиком: и папки, и записи,
    // и те же фильтры стоят в подсчёте «есть ли ещё» — иначе hasMore считался бы по
    // невидимым строкам и клиент вечно догружал пустые страницы.
    const hidden = { notIn: [...HIDDEN_ZONES] };
    const [folders, entries] = await Promise.all([
      this.prisma.folder.findMany({
        where: { parentId: parent.id, deletedAt: null, name: nameFilter, zone: hidden },
        orderBy: { name: 'asc' },
        take,
        select: { id: true, name: true, createdAt: true, updatedAt: true },
      }),
      this.prisma.fileEntry.findMany({
        where: { folderId: parent.id, deletedAt: null, name: nameFilter, zone: hidden },
        orderBy: { name: 'asc' },
        take,
        select: {
          id: true,
          name: true,
          createdAt: true,
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
          where: { folderId: parent.id, deletedAt: null, name: { gt: last }, zone: hidden },
        })) +
          (await this.prisma.folder.count({
            where: { parentId: parent.id, deletedAt: null, name: { gt: last }, zone: hidden },
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
        // нужен клиенту синхронизации: mtime восстанавливается у скачанного файла
        clientMtime: e.clientMtime ? e.clientMtime.toISOString() : null,
      })),
    };
  }

  /** Метаданные папки для деталки: путь, счётчики, даты. */
  async meta(id: string, userId: string) {
    const folder = await this.resolveAccessible(id, userId);
    // Скрытые зоны считаем так же, как листинг (listChildren): иначе в корне пользователя
    // счётчик папок включал бы невидимую «Почту», и «Папок: N» не сходилось бы со списком N−1.
    const visible = { notIn: [...HIDDEN_ZONES] };
    const [folderCount, entryCount] = await Promise.all([
      this.prisma.folder.count({ where: { parentId: folder.id, deletedAt: null, zone: visible } }),
      this.prisma.fileEntry.count({ where: { folderId: folder.id, deletedAt: null, zone: visible } }),
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
    this.assertNotReservedName(name);
    const parent = await this.resolveAccessible(parentId, userId);
    await this.assertNameFree(parent.id, name);
    // новые папки наследуют зону родителя: внутри «Фото» — медиа-зона, внутри «Почты» —
    // скрытая зона вложений, в остальном дереве — файлы
    const zone = zoneOf(parent.zone);
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
   * «Почта» зарезервирована по другой причине: это имя системной папки вложений, и
   * пользовательская папка-тёзка при первом же обращении почтового модуля стала бы скрытой
   * зоной MAIL — её файлы исчезли бы из «Файлов» и превратились бы во вложения писем.
   */
  private assertNotReservedName(name: string): void {
    if (name === ROOT_FOLDER_NAME) throw badRequest(`${ROOT_FOLDER_NAME} is a reserved name`);
    if (name === MAIL_FOLDER_NAME) throw badRequest(`${MAIL_FOLDER_NAME} is a reserved name`);
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
    // Потолок глубины нужен только чтобы один запрос не создал тысячи папок (и столько же
    // строк журнала): 64 сегмента — это потолок зеркала на клиенте, глубже дерево всё равно
    // не появится. Владельца поддерева ищет рекурсивный CTE (ownerOfFolder), поэтому
    // ограничение не связано с обходом дерева — раньше здесь стояло 32, и зеркало
    // останавливалось на «too many path segments» задолго до клиентского предела.
    const MAX_PATH_SEGMENTS = 64;
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
    // Системный корень приходит первым сегментом (`__root__/2025/07`): он не создаётся, а
    // просто отбрасывается — дальше путь строится от корня пользователя. В середине пути это
    // имя зарезервировано, как и в create/rename (assertNotReservedName в цикле ниже).
    const wanted = segments[0] === ROOT_FOLDER_NAME ? segments.slice(1) : segments;

    let current = await this.resolveAccessible(parentId, userId);
    let createdCount = 0;
    for (const name of wanted) {
      // Зарезервированные имена проверяем теми же правилами, что create/rename. Без этого
      // `POST /folders/ensure-path {path:"Почта"}` заводил в корне пользовательскую папку с
      // именем системной папки вложений, а первый же заход почтового модуля «усыновлял» её
      // (AuthService.mailFolderId ищет папку по имени), ставил зону MAIL и переводил в скрытую
      // зону всё поддерево: файлы пользователя исчезали из «Файлов», поиска, WebDAV и журнала.
      this.assertNotReservedName(name);
      const existing = await this.prisma.folder.findFirst({ where: { parentId: current.id, name } });
      if (existing) {
        if (existing.deletedAt) {
          throw conflict(`folder ${name} is in trash — restore or purge it first`);
        }
        // Внутрь скрытой зоны путь не продолжаем и её id наружу не отдаём: клиенту не положено
        // даже знать, что такая папка существует (её видно только по ссылке из письма).
        if (isHiddenZone(existing.zone)) throw notFound('folder not found');
        current = existing;
        continue;
      }
      // зона новой папки наследуется от уже проверенного на скрытость родителя, поэтому
      // созданная папка скрытой быть не может — отдельная проверка после create не нужна
      const zone = zoneOf(current.zone);
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

  /**
   * Правка папки одним запросом (клиент синхронизации): имя и переезд.
   *
   * Обе правки — в ОДНОЙ транзакции: раньше это были два независимых вызова (rename и move),
   * каждый со своей транзакцией и своим событием журнала, поэтому падение переезда после
   * удачного переименования оставляло клиента с состоянием, которого на сервере нет
   * (имя уже новое, папка ещё на месте). Событие тоже одно: если папка переехала — `move`
   * с итоговым именем, иначе `update`.
   */
  async patch(
    id: string,
    body: { name?: string; parentId?: string },
    userId: string,
  ) {
    const wantsRename = body.name !== undefined;
    const wantsMove = body.parentId !== undefined;
    const folder = await this.resolveAccessible(id, userId);

    if (wantsRename) {
      await this.assertCanRename(folder, body.name!, userId);
      await this.assertNameFree(folder.parentId!, body.name!, id);
    }
    let target: { id: string; zone: string } | null = null;
    if (wantsMove) {
      await this.assertNotSystemRoot(folder, userId, 'move');
      if (isRoot(folder)) throw badRequest('cannot move root');
      target = await this.resolveAccessible(body.parentId, userId);
      await this.assertNameFree(target.id, body.name ?? folder.name, id);
    }
    if (!wantsRename && !wantsMove) {
      const current = await this.prisma.folder.findUnique({
        where: { id },
        select: { id: true, name: true, parentId: true, zone: true },
      });
      return { ok: true, renamed: null, moved: null, folder: current };
    }

    const newZone = target ? zoneOf(target.zone) : null;
    let changedIds: string[] = [];
    const res = await this.runNameConflictMapped(() =>
      this.prisma.$transaction(async (tx) => {
        const renamed = wantsRename
          ? await tx.folder.update({ where: { id }, data: { name: body.name! }, select: { id: true, name: true } })
          : null;
        let moved: { id: string; parentId: string | null; zone: string } | null = null;
        if (target && newZone) {
          const zoneBefore = folder.zone;
          const movedRes = await this.applyMove(tx, id, target.id, newZone, zoneBefore);
          moved = movedRes.row;
          changedIds = movedRes.changedIds;
        }
        await this.changes.record(
          {
            userId,
            target: 'folder',
            op: moved ? 'move' : 'update',
            targetId: id,
            folderId: moved ? moved.parentId : folder.parentId,
            name: renamed ? renamed.name : folder.name,
            zone: moved ? moved.zone : folder.zone,
          },
          tx,
        );
        return { renamed, moved };
      }),
    );
    if (target && newZone === ZONE_PHOTOS && folder.zone !== newZone) void this.reprocessAsMedia(changedIds);
    const current = await this.prisma.folder.findUnique({
      where: { id },
      select: { id: true, name: true, parentId: true, zone: true },
    });
    return { ok: true, renamed: res.renamed, moved: res.moved, folder: current };
  }

  /** Проверки переименования (общие для patch и rename). */
  private async assertCanRename(
    folder: { id: string; name: string; parentId: string | null },
    name: string,
    userId: string,
  ): Promise<void> {
    assertSafeName(name);
    this.assertNotReservedName(name);
    await this.assertNotSystemRoot(folder, userId, 'rename');
    if (isRoot(folder)) throw badRequest('cannot rename root');
  }

  async rename(id: string, name: string, userId: string) {
    const folder = await this.resolveAccessible(id, userId);
    await this.assertCanRename(folder, name, userId);
    await this.assertNameFree(folder.parentId!, name, id);
    return this.runNameConflictMapped(() =>
      this.prisma.$transaction(async (tx) => {
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
          },
          tx,
        );
        return renamed;
      }),
    );
  }

  async move(id: string, newParentId: string, userId: string) {
    const folder = await this.resolveAccessible(id, userId);
    await this.assertNotSystemRoot(folder, userId, 'move');
    if (isRoot(folder)) throw badRequest('cannot move root');
    const target = await this.resolveAccessible(newParentId, userId);
    await this.assertNameFree(target.id, folder.name, id);

    const newZone = zoneOf(target.zone);
    let changedIds: string[] = [];
    const moved = await this.prisma.$transaction(async (tx) => {
      const res = await this.applyMove(tx, id, target.id, newZone, folder.zone);
      changedIds = res.changedIds;
      await this.changes.record(
        {
          userId,
          target: 'folder',
          op: 'move',
          targetId: id,
          folderId: target.id,
          name: folder.name,
          zone: newZone,
        },
        tx,
      );
      return res.row;
    });
    if (folder.zone !== newZone && newZone === ZONE_PHOTOS) void this.reprocessAsMedia(changedIds);
    return { id: moved.id, parentId: moved.parentId, zone: newZone };
  }

  /**
   * Переезд папки внутри уже открытой транзакции.
   *
   * Инвариант дерева держит ЭТА транзакция, а не проверка до неё: «цель не внутри собственного
   * поддерева» проверяется под блокировкой строк перемещаемой папки и цели, в той же транзакции,
   * что и запись `parentId`. Раньше проверка стояла вне транзакции, и два встречных перемещения
   * (A в поддерево B и B в поддерево A) проходили обе проверки и коммитились: `A.parent=B`,
   * `B.parent=A`. Такой цикл не переживает рекурсивный CTE `AuthService.subtreeIds` (UNION ALL
   * без ограничения глубины) — запрос не завершается и занимает соединение, а корзина, лента и
   * синхронизация этого пользователя перестают работать.
   */
  private async applyMove(
    tx: Prisma.TransactionClient,
    id: string,
    targetId: string,
    newZone: string,
    zoneBefore: string,
  ): Promise<{ row: { id: string; parentId: string | null; zone: string }; changedIds: string[] }> {
    await this.lockFolders(tx, [id, targetId]);
    if (await this.isInSubtree(tx, targetId, id)) {
      throw badRequest('cannot move folder into its own subtree');
    }
    const row: { id: string; parentId: string | null; zone: string } = await tx.folder.update({
      where: { id },
      data: { parentId: targetId },
      select: { id: true, parentId: true, zone: true },
    });
    // Папка переехала между зонами — пересчитываем зону живого поддерева (папки + записи).
    // Строки из корзины не трогаем: их зона остаётся той, что была на момент удаления, иначе
    // после восстановления подпапка оказалась бы в медиа-зоне, которой у неё никогда не было.
    let changedIds: string[] = [];
    if (zoneBefore !== newZone) {
      changedIds = await this.liveSubtreeIds(tx, id);
      for (const chunk of chunksOf(changedIds, 1000)) {
        await tx.folder.updateMany({
          where: { id: { in: chunk }, deletedAt: null },
          data: { zone: newZone },
        });
        await tx.fileEntry.updateMany({
          where: { folderId: { in: chunk }, deletedAt: null },
          data: { zone: newZone },
        });
      }
    }
    return { row, changedIds };
  }

  /**
   * Блокировка строк папок в детерминированном порядке (по id): два встречных перемещения
   * берут одни и те же строки, и без сортировки они бы заклинились взаимным ожиданием.
   */
  private async lockFolders(tx: Prisma.TransactionClient, ids: string[]): Promise<void> {
    const sorted = [...new Set(ids)].sort();
    await tx.$queryRaw`SELECT id FROM "Folder" WHERE id IN (${Prisma.join(sorted)}) ORDER BY id FOR UPDATE`;
  }

  /** Лежит ли папка внутри поддерева rootId: подъём по parentId (потолок — страховка от цикла). */
  private async isInSubtree(tx: Prisma.TransactionClient, folderId: string, rootId: string): Promise<boolean> {
    let cur: string | null = folderId;
    for (let depth = 0; cur && depth < 128; depth++) {
      if (cur === rootId) return true;
      const row: { parentId: string | null } | null = await tx.folder.findUnique({
        where: { id: cur },
        select: { parentId: true },
      });
      if (!row) return false;
      cur = row.parentId;
    }
    return false;
  }

  /** Гонка на @@unique([parentId, name]) должна давать 409, а не 500 от Prisma. */
  private async runNameConflictMapped<T>(fn: () => Promise<T>): Promise<T> {
    try {
      return await fn();
    } catch (e) {
      throw this.asNameConflict(e, 'folder');
    }
  }

  /** Мягкое удаление папки вместе со всем поддеревом. */
  async softDelete(id: string, userId: string) {
    const folder = await this.resolveAccessible(id, userId);
    await this.assertNotSystemRoot(folder, userId, 'delete');
    if (isRoot(folder)) throw badRequest('cannot delete root');
    const ids = await this.collectSubtreeIds(id);
    await this.prisma.$transaction(async (tx) => {
      // Порциями: id всего дерева — это десятки тысяч значений в одном `IN`, а список
      // параметров Postgres ограничен 65 535.
      for (const chunk of chunksOf(ids, 5000)) {
        await tx.folder.updateMany({ where: { id: { in: chunk } }, data: { deletedAt: new Date() } });
      }
      // одно событие на корень поддерева: «папка удалена» означает «всего её содержимого нет»
      await this.changes.recordFolderTreeDeleted(userId, id, tx);
    });
    return { ok: true, affected: ids.length };
  }

  /**
   * Восстановление папки: само поддерево, но не выше.
   * Удаление журналируется одним событием на поддерево («папки нет» ⇒ содержимого нет),
   * поэтому на восстановлении наоборот нужны события по детям: иначе клиент знает только
   * про саму папку и не может восстановить её содержимое.
   *
   * Родитель удалён — отказываем так же, как `files.restore`: иначе папка оживает вне дерева
   * (`folderOwnedBy` по ней уже false, в корзине её тоже не видно — она отфильтрована как
   * «ребёнок удалённого родителя»), а при следующем purge родителя её `parentId` обнулился бы
   * по `ON DELETE SET NULL` и поддерево выпало бы из дерева пользователя навсегда.
   */
  async restore(id: string, userId: string) {
    const root = await this.resolveAccessibleOrDeleted(id, userId);
    if (root.deletedAt && root.parentId) {
      const parent = await this.prisma.folder.findUnique({
        where: { id: root.parentId },
        select: { deletedAt: true },
      });
      if (parent?.deletedAt) throw conflict('parent folder is deleted — restore folder first');
    }
    const ids = await this.collectSubtreeIds(id);
    // Возвращаем только то, что удалили вместе с папкой: подпапки, удалённые пользователем
    // отдельно (раньше), остаются в корзине, иначе они воскресали бы без спроса.
    // «Минус 1000 мс» — потому что softDelete проставляет всему поддереву один и тот же
    // `new Date()`: у детей время удаления совпадает с временем корня, а у отдельно удалённых
    // подпапок оно строго раньше, поэтому небольшой запас в прошлое ничего лишнего не захватит.
    const cutoff = root.deletedAt ? new Date(root.deletedAt.getTime() - 1000) : null;
    const folders: Array<{ id: string; parentId: string | null; name: string; zone: string }> = [];
    for (const chunk of chunksOf(ids, 5000)) {
      folders.push(
        ...(await this.prisma.folder.findMany({
          where: {
            id: { in: chunk },
            ...(cutoff ? { OR: [{ deletedAt: null }, { deletedAt: { gte: cutoff } }] } : {}),
          },
          select: { id: true, parentId: true, name: true, zone: true },
        })),
      );
    }
    const restoreIds = folders.map((f) => f.id);
    const entries: Array<{
      id: string;
      folderId: string;
      name: string;
      zone: string;
      clientMtime: Date | null;
      asset: { sha256: string; size: bigint; mime: string };
    }> = [];
    for (const chunk of chunksOf(restoreIds, 5000)) {
      entries.push(
        ...(await this.prisma.fileEntry.findMany({
          where: { folderId: { in: chunk }, deletedAt: null },
          select: {
            id: true,
            folderId: true,
            name: true,
            zone: true,
            clientMtime: true,
            asset: { select: { sha256: true, size: true, mime: true } },
          },
        })),
      );
    }
    await this.prisma.$transaction(async (tx) => {
      for (const chunk of chunksOf(restoreIds, 5000)) {
        await tx.folder.updateMany({ where: { id: { in: chunk } }, data: { deletedAt: null } });
      }
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
            })),
          });
        }
      }
    }, { timeout: 120_000, maxWait: 15_000 });
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


  /** Папки переехали в медиа-зону: ставим на обработку их ещё не конвертированные фото/видео (best-effort). */
  private async reprocessAsMedia(folderIds: string[]) {
    try {
      const assets = await this.prisma.asset.findMany({
        where: {
          previewState: 'none',
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
    return this.subtreeIdsIn(this.prisma, rootId, false);
  }

  /** То же, но только живые папки: для пересчёта зон строки из корзины не трогаем. */
  private async liveSubtreeIds(tx: Prisma.TransactionClient, rootId: string): Promise<string[]> {
    return this.subtreeIdsIn(tx, rootId, true);
  }

  /**
   * BFS всех id поддерева, включая саму папку. `aliveOnly` — не спускаться в удалённые папки.
   *
   * `seen` защищает только сам обход в памяти (без отметок BFS разросся бы до OOM, если в
   * дереве уже есть цикл), но НЕ инвариант дерева: цикл в БД эти отметки не лечат, а
   * `AuthService.subtreeIds` (рекурсивный CTE без ограничения глубины) на таком цикле не
   * завершается. Инвариант держит `applyMove` — проверка поддерева под блокировкой в одной
   * транзакции с записью `parentId`.
   */
  private async subtreeIdsIn(
    client: Prisma.TransactionClient,
    rootId: string,
    aliveOnly: boolean,
  ): Promise<string[]> {
    const all: string[] = [rootId];
    const seen = new Set<string>([rootId]);
    let frontier = [rootId];
    // Потолок глубины — страховка от цикла в parentId (легаси-данные): 128 уровней
    // хватает с запасом (у AuthService.folderOwnedBy тот же предел).
    for (let depth = 0; frontier.length && depth < 128; depth++) {
      const children: Array<{ id: string }> = [];
      for (const chunk of chunksOf(frontier, 5000)) {
        children.push(
          ...(await client.folder.findMany({
            where: { parentId: { in: chunk }, ...(aliveOnly ? { deletedAt: null } : {}) },
            select: { id: true },
          })),
        );
      }
      const ids = children.map((c) => c.id).filter((cid) => !seen.has(cid));
      if (!ids.length) break;
      for (const cid of ids) seen.add(cid);
      all.push(...ids);
      frontier = ids;
    }
    return all;
  }
}
