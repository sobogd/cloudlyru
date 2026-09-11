import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import * as argon2 from 'argon2';
import { env } from '../config/env';
import { PrismaService } from '../prisma/prisma.service';
import { randomToken, sha256Hex } from '../common/utils';
import { PHONE_FOLDER_NAME, PHOTO_FOLDER_NAME, ZONE_PHOTOS } from '../common/zones';
import { AuditService } from '../audit/audit.service';
import { badRequest, notFound, unauthorized } from '../common/errors';

export const ROOT_FOLDER_NAME = '__root__';

/** Потолок живых device-токенов на пользователя. */
export const MAX_API_TOKENS_PER_USER = 32;

@Injectable()
export class AuthService implements OnModuleInit {
  private readonly logger = new Logger(AuthService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly audit: AuditService,
  ) {}

  /** При первом старте создаёт владельца, корневую папку и системные папки «Фото» и «Телефон». */
  async onModuleInit() {
    const count = await this.prisma.user.count();
    if (count === 0) {
      const passwordHash = await argon2.hash(env.ADMIN_PASSWORD);
      const user = await this.prisma.user.create({
        data: { login: env.ADMIN_LOGIN, passwordHash },
      });
      const root = await this.prisma.folder.create({
        data: { name: ROOT_FOLDER_NAME, parentId: null },
      });
      const photo = await this.prisma.folder.create({
        data: { parentId: root.id, name: PHOTO_FOLDER_NAME, zone: ZONE_PHOTOS },
      });
      const phone = await this.prisma.folder.create({
        data: { parentId: root.id, name: PHONE_FOLDER_NAME },
      });
      await this.prisma.user.update({
        where: { id: user.id },
        data: { rootFolderId: root.id, photoFolderId: photo.id, phoneFolderId: phone.id },
      });
      this.logger.log(
        `Создан владелец "${env.ADMIN_LOGIN}", корневая папка и системные «${PHOTO_FOLDER_NAME}» и «${PHONE_FOLDER_NAME}»`,
      );
    }
  }

  async login(login: string, password: string, ip?: string) {
    const user = await this.prisma.user.findUnique({ where: { login } });
    if (!user) {
      await this.audit.log('auth.login.failed', { login }, ip);
      throw unauthorized('invalid credentials');
    }
    const ok = await argon2.verify(user.passwordHash, password).catch(() => false);
    if (!ok) {
      await this.audit.log('auth.login.failed', { login }, ip);
      throw unauthorized('invalid credentials');
    }

    const token = randomToken(32);
    const ttlMs = env.SESSION_TTL_DAYS * 24 * 60 * 60 * 1000;
    await this.prisma.session.create({
      data: {
        userId: user.id,
        tokenHash: sha256Hex(token),
        expiresAt: new Date(Date.now() + ttlMs),
      },
    });
    await this.audit.log('auth.login', { login }, ip);
    return { token, expiresInMs: ttlMs, user: { id: user.id, login: user.login } };
  }

  async logout(token: string) {
    if (!token) throw badRequest('missing session token');
    const res = await this.prisma.session.deleteMany({ where: { tokenHash: sha256Hex(token) } });
    return { ok: res.count > 0 };
  }

  async me(userId: string) {
    const user = await this.prisma.user.findUnique({ where: { id: userId } });
    if (!user) throw unauthorized();
    const photoFolderId = await this.photoFolderId(userId).catch(() => null);
    const phoneFolderId = await this.phoneFolderId(userId).catch(() => null);
    return { id: user.id, login: user.login, rootFolderId: user.rootFolderId, photoFolderId, phoneFolderId };
  }

  /** Корневая папка пользователя (создаётся лениво, если отсутствует). */
  async rootFolderId(userId: string): Promise<string> {
    const user = await this.prisma.user.findUnique({ where: { id: userId } });
    if (!user) throw unauthorized();
    if (user.rootFolderId) {
      const root = await this.prisma.folder.findUnique({ where: { id: user.rootFolderId } });
      if (root && !root.deletedAt) return root.id;
    }
    const root = await this.prisma.folder.create({ data: { name: ROOT_FOLDER_NAME, parentId: null } });
    await this.prisma.user.update({ where: { id: userId }, data: { rootFolderId: root.id } });
    return root.id;
  }

  /** id системной папки «Фото», если она уже есть (без побочных эффектов; для гардов). */
  async photoRootIdOrNull(userId: string): Promise<string | null> {
    const user = await this.prisma.user.findUnique({ where: { id: userId }, select: { photoFolderId: true } });
    return user?.photoFolderId ?? null;
  }

  /** id системной папки «Телефон», если она уже есть (без побочных эффектов; для гардов). */
  async phoneRootIdOrNull(userId: string): Promise<string | null> {
    const user = await this.prisma.user.findUnique({ where: { id: userId }, select: { phoneFolderId: true } });
    return user?.phoneFolderId ?? null;
  }

  /**
   * Системная папка «Телефон» — корень зеркала папок телефона. Как и у «Фото», папка
   * создаётся лениво, а существующую папку с таким именем «усыновляем»: она уже могла быть
   * заведена руками, и плодить вторую «Телефон» рядом нельзя. Удалить её нельзя (гарды
   * в Folders/Dav): клиент льёт в неё структуру, и потеря корня ломает адресацию.
   */
  async phoneFolderId(userId: string): Promise<string> {
    const user = await this.prisma.user.findUnique({ where: { id: userId } });
    if (!user) throw unauthorized();
    if (user.phoneFolderId) {
      const current = await this.prisma.folder.findUnique({ where: { id: user.phoneFolderId } });
      if (current && !current.deletedAt) return current.id;
    }
    const rootId = await this.rootFolderId(userId);

    const existing = await this.prisma.folder.findFirst({
      where: { parentId: rootId, name: PHONE_FOLDER_NAME },
    });
    const phone = existing
      ? await this.prisma.folder.update({ where: { id: existing.id }, data: { deletedAt: null } })
      : await this.prisma.folder.create({ data: { parentId: rootId, name: PHONE_FOLDER_NAME } });
    await this.prisma.user.update({ where: { id: userId }, data: { phoneFolderId: phone.id } });
    return phone.id;
  }

  /**
   * Владелец дерева, в котором лежит папка. Нужен там, где известна только папка, а журнал
   * изменений требует userId (гостевая загрузка по share-ссылке, распаковка архивов).
   * Один рекурсивный запрос вверх: раньше это был цикл с лимитом 64 уровня, из-за чего на
   * глубоком дереве владелец не находился и событие журнала молча терялось.
   */
  async ownerOfFolder(folderId: string): Promise<string | null> {
    const rows = await this.prisma.$queryRaw<Array<{ userId: string }>>`
      WITH RECURSIVE up AS (
        SELECT f.id, f."parentId" FROM "Folder" f WHERE f.id = ${folderId}
        UNION ALL
        SELECT f.id, f."parentId" FROM "Folder" f JOIN up ON f.id = up."parentId"
      )
      SELECT u.id AS "userId" FROM "User" u JOIN up ON u."rootFolderId" = up.id LIMIT 1`;
    return rows[0]?.userId ?? null;
  }

  // ===== Принадлежность файлов пользователю =====
  // В схеме у папки нет userId: дерево пользователя — это поддерево его корневой папки
  // (users.rootFolderId). Поэтому «свой файл» = живой FileEntry, чья папка поднимается
  // по parentId до корня этого пользователя.

  /** Корень пользователя, если он уже есть (без создания нового). */
  private async rootIdOrNull(userId: string): Promise<string | null> {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { rootFolderId: true },
    });
    if (!user?.rootFolderId) return null;
    const root = await this.prisma.folder.findUnique({
      where: { id: user.rootFolderId },
      select: { id: true, deletedAt: true },
    });
    return root && !root.deletedAt ? root.id : null;
  }

  /** Папка лежит в дереве пользователя и не в корзине (сама и все её родители)? */
  async folderOwnedBy(userId: string, folderId: string): Promise<boolean> {
    const rootId = await this.rootIdOrNull(userId);
    if (!rootId) return false;
    let cur: string | null = folderId;
    for (let depth = 0; cur && depth < 128; depth++) {
      if (cur === rootId) return true;
      const folder: { parentId: string | null; deletedAt: Date | null } | null =
        await this.prisma.folder.findUnique({
          where: { id: cur },
          select: { parentId: true, deletedAt: true },
        });
      if (!folder || folder.deletedAt) return false;
      cur = folder.parentId;
    }
    return false;
  }

  /** Есть ли у пользователя живой файл с этим содержимым (ассеты дедуплицируются между всеми). */
  async ownsAsset(userId: string, assetId: string): Promise<boolean> {
    const entries = await this.prisma.fileEntry.findMany({
      where: { assetId, deletedAt: null },
      select: { folderId: true },
    });
    for (const entry of entries) {
      if (await this.folderOwnedBy(userId, entry.folderId)) return true;
    }
    return false;
  }

  /**
   * Все папки дерева пользователя одним запросом (рекурсивный CTE).
   * includeDeleted=true нужен корзине: удалённая папка со всем поддеревом тоже «своя».
   * Нужен там, где фильтровать надо не по одной записи, а по всему дереву
   * (лента фото, поездки, корзина, очередь).
   */
  async subtreeIds(userId: string, opts: { includeDeleted?: boolean } = {}): Promise<string[]> {
    const rootId = await this.rootIdOrNull(userId);
    if (!rootId) return [];
    const sql = opts.includeDeleted
      ? `WITH RECURSIVE t AS (
           SELECT f.id, f."parentId" FROM "Folder" f WHERE f.id = $1
           UNION ALL
           SELECT f.id, f."parentId" FROM "Folder" f JOIN t ON f."parentId" = t.id
         ) SELECT id FROM t`
      : `WITH RECURSIVE t AS (
           SELECT f.id, f."parentId" FROM "Folder" f WHERE f.id = $1
           UNION ALL
           SELECT f.id, f."parentId" FROM "Folder" f JOIN t ON f."parentId" = t.id WHERE f."deletedAt" IS NULL
         ) SELECT id FROM t`;
    const rows = await this.prisma.$queryRawUnsafe<Array<{ id: string }>>(sql, rootId);
    return rows.map((r) => r.id);
  }

  /** Своя папка или 404 (deletedOk — для восстановления из корзины). */
  async assertFolderOwned(userId: string, folderId: string, opts: { deletedOk?: boolean } = {}): Promise<void> {
    if (opts.deletedOk) {
      const ids = await this.subtreeIds(userId, { includeDeleted: true });
      if (!ids.includes(folderId)) throw notFound('folder not found');
      return;
    }
    if (!(await this.folderOwnedBy(userId, folderId))) throw notFound('folder not found');
  }

  /** Своя запись файла или null (deletedOk — для восстановления из корзины). */
  async ownEntry(userId: string, entryId: string, opts: { deletedOk?: boolean } = {}) {
    const entry = await this.prisma.fileEntry.findUnique({ where: { id: entryId }, include: { asset: true } });
    if (!entry) return null;
    if (!opts.deletedOk && entry.deletedAt) return null;
    if (!(await this.folderOwnedBy(userId, entry.folderId))) return null;
    return entry;
  }

  /**
   * Системная папка «Фото» (медиа-зона). Создаётся лениво как ребёнок корня;
   * существующую папку с таким именем «усыновляем» (делаем её медиа-корнем).
   * Её нельзя переименовать/переместить/удалить (гарды в Folders/Dav).
   */
  async photoFolderId(userId: string): Promise<string> {
    const user = await this.prisma.user.findUnique({ where: { id: userId } });
    if (!user) throw unauthorized();
    if (user.photoFolderId) {
      const current = await this.prisma.folder.findUnique({ where: { id: user.photoFolderId } });
      if (current && !current.deletedAt && current.zone === ZONE_PHOTOS) return current.id;
    }
    const rootId = await this.rootFolderId(userId);

    let photo = await this.prisma.folder.findFirst({
      where: { parentId: rootId, name: PHOTO_FOLDER_NAME },
    });
    if (photo) {
      // обычная папка с именем «Фото» уже существует — делаем её медиа-корнем
      photo = await this.prisma.folder.update({
        where: { id: photo.id },
        data: { zone: ZONE_PHOTOS, deletedAt: null },
      });
    } else {
      photo = await this.prisma.folder.create({
        data: { parentId: rootId, name: PHOTO_FOLDER_NAME, zone: ZONE_PHOTOS },
      });
    }
    await this.prisma.user.update({ where: { id: userId }, data: { photoFolderId: photo.id } });
    await this.rezoneSubtree(photo.id, ZONE_PHOTOS);
    return photo.id;
  }

  /** Проставить зону всему поддереву папки (BFS) — используется при «усыновлении» фото-корня. */
  private async rezoneSubtree(rootFolderId: string, zone: string): Promise<void> {
    const all = [rootFolderId];
    let frontier = [rootFolderId];
    while (frontier.length) {
      const children = await this.prisma.folder.findMany({
        where: { parentId: { in: frontier }, deletedAt: null },
        select: { id: true },
      });
      const ids = children.map((c) => c.id);
      if (!ids.length) break;
      all.push(...ids);
      frontier = ids;
    }
    await this.prisma.folder.updateMany({ where: { id: { in: all } }, data: { zone } });
    await this.prisma.fileEntry.updateMany({ where: { folderId: { in: all } }, data: { zone } });
  }

  // ============ App-password / device-токены (WebDAV, клиенты) ============

  async createToken(userId: string, label: string): Promise<{ id: string; token: string; label: string }> {
    const clean = String(label ?? 'app').slice(0, 64) || 'app';
    // кап на число живых токенов: без него выпуск токенов бесконечен, а отзыв одного
    // ничего не значит (владелец не видит, сколько их всего)
    const alive = await this.prisma.apiToken.count({ where: { userId, revokedAt: null } });
    if (alive >= MAX_API_TOKENS_PER_USER) {
      throw badRequest(`слишком много активных токенов (${alive}) — отзовите ненужные (лимит ${MAX_API_TOKENS_PER_USER})`);
    }
    const token = randomToken(32);
    const t = await this.prisma.apiToken.create({
      data: {
        userId,
        label: clean,
        tokenHash: sha256Hex(token),
        scope: 'files:rw',
        expiresAt: new Date(Date.now() + env.API_TOKEN_TTL_DAYS * 24 * 60 * 60 * 1000),
      },
    });
    await this.audit.log('auth.token.create', { label: clean, tokenId: t.id });
    // plain-токен показывается один раз
    return { id: t.id, token, label: t.label };
  }

  async listTokens(userId: string) {
    const rows = await this.prisma.apiToken.findMany({
      where: { userId, revokedAt: null },
      orderBy: { createdAt: 'desc' },
      select: { id: true, label: true, scope: true, expiresAt: true, lastUsedAt: true, createdAt: true },
    });
    return rows;
  }

  async revokeToken(userId: string, tokenId: string) {
    const res = await this.prisma.apiToken.updateMany({
      where: { id: tokenId, userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
    if (res.count === 0) throw badRequest('token not found');
    await this.audit.log('auth.token.revoke', { tokenId });
    return { ok: true };
  }

  /**
   * Проверка Basic-токена (WebDAV). Возвращает владельца и scope или null.
   * Раньше поле scope было декоративным и не читалось, а срок жизни отсутствовал.
   */
  async resolveApiToken(token: string): Promise<{ userId: string; scope: string } | null> {
    if (!token) return null;
    const t = await this.prisma.apiToken.findUnique({ where: { tokenHash: sha256Hex(token) } });
    if (!t || t.revokedAt) return null;
    if (t.expiresAt && t.expiresAt.getTime() <= Date.now()) return null;
    if (!String(t.scope).startsWith('files:')) return null;
    // Телефон синхронизации делает сотни запросов за проход — писать в БД на каждый незачем
    const stale = !t.lastUsedAt || Date.now() - t.lastUsedAt.getTime() > 5 * 60 * 1000;
    if (stale) {
      await this.prisma.apiToken
        .update({ where: { id: t.id }, data: { lastUsedAt: new Date() } })
        .catch(() => undefined);
    }
    return { userId: t.userId, scope: t.scope };
  }
}
