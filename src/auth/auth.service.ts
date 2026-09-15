import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import * as argon2 from 'argon2';
import { env } from '../config/env';
import { PrismaService } from '../prisma/prisma.service';
import { randomToken, sha256Hex, assertSafeName } from '../common/utils';
import { MAIL_FOLDER_NAME, PHOTO_FOLDER_NAME, ZONE_MAIL, ZONE_PHOTOS, mirrorFolderName } from '../common/zones';
import { AuditService } from '../audit/audit.service';
import { ChangesService } from '../sync/changes.service';
import { badRequest, notFound, unauthorized } from '../common/errors';

export const ROOT_FOLDER_NAME = '__root__';

/** Потолок живых device-токенов на пользователя. */
export const MAX_API_TOKENS_PER_USER = 32;

/** Потолок длины метки токена: из неё строится имя папки-зеркала (см. createToken). */
const MAX_TOKEN_LABEL_BYTES = 64;

/**
 * Метка токена из запроса → безопасная метка. Из метки строится имя папки-зеркала
 * (`<Метка> - Файлы`), поэтому разделители пути и управляющие символы — это 400:
 * папку с таким именем телефон не создаст, а клиент потом не найдёт свой корень.
 * Концевые точки и пробелы (Windows/SMB их не хранит) и длину санитизируем сами —
 * это не ошибка клиента, а косметика.
 */
function cleanTokenLabel(raw: unknown): string {
  const value = String(raw ?? '');
  if (/[/\\\u0000-\u001f\u007f]/.test(value)) {
    throw badRequest('label must not contain path separators or control characters');
  }
  let clean = value.trim();
  while (clean.endsWith('.') || clean.endsWith(' ')) clean = clean.slice(0, -1);
  if (!clean) return 'app';
  // режем по байтам, а не по символам: 64 кириллических символа — это 128 байт, а имя
  // папки ограничено 255 байтами вместе с суффиксом, и «обрезать» символ пополам нельзя
  while (Buffer.byteLength(clean, 'utf8') > MAX_TOKEN_LABEL_BYTES) clean = clean.slice(0, -1);
  assertSafeName(clean);
  return clean;
}

@Injectable()
export class AuthService implements OnModuleInit {
  private readonly logger = new Logger(AuthService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly audit: AuditService,
    private readonly changes: ChangesService,
  ) {}

  /** При первом старте создаёт владельца, корневую папку и системную папку «Фото». */
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
      // «Телефон» больше не заводим: корень зеркала теперь свой у каждого устройства
      // (ApiToken.mirrorFolderId), а общая на всех папка означала бы, что удаление файла
      // на одном телефоне уносит файлы другого.
      await this.prisma.user.update({
        where: { id: user.id },
        data: { rootFolderId: root.id, photoFolderId: photo.id },
      });
      this.logger.log(
        `Создан владелец "${env.ADMIN_LOGIN}", корневая папка и системная «${PHOTO_FOLDER_NAME}»`,
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

  /**
   * Свои данные и id системных папок. `deviceId` — id ApiToken'а, которым пришёл запрос
   * (Bearer): клиенту синхронизации нужен свой корень зеркала, поэтому для устройства он
   * создаётся лениво. Веб-сессия папку не заводит — там зеркало ни к чему.
   */
  async me(userId: string, deviceId?: string | null) {
    const user = await this.prisma.user.findUnique({ where: { id: userId } });
    if (!user) throw unauthorized();
    const photoFolderId = await this.photoFolderId(userId).catch(() => null);
    // «Телефон» только читаем: папка больше не создаётся (корень зеркала свой у каждого
    // устройства), но поле в ответе остаётся — на него завязан веб и старые сборки клиента
    const phoneFolderId = await this.phoneRootIdOrNull(userId).catch(() => null);
    const mirrorFolderId = deviceId ? await this.deviceMirrorFolderId(deviceId).catch(() => null) : null;
    return {
      id: user.id,
      login: user.login,
      rootFolderId: user.rootFolderId,
      photoFolderId,
      phoneFolderId,
      mirrorFolderId,
      deviceId: deviceId ?? null,
    };
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

  /**
   * id легаси-папки «Телефон», если она уже есть (без побочных эффектов). Папка больше не
   * создаётся и не защищается от удаления: корень зеркала теперь свой у каждого устройства,
   * а старая общая папка нужна только чтобы веб и старые сборки клиента её видели.
   */
  async phoneRootIdOrNull(userId: string): Promise<string | null> {
    const user = await this.prisma.user.findUnique({ where: { id: userId }, select: { phoneFolderId: true } });
    if (!user?.phoneFolderId) return null;
    const folder = await this.prisma.folder.findUnique({
      where: { id: user.phoneFolderId },
      select: { id: true, deletedAt: true },
    });
    return folder && !folder.deletedAt ? folder.id : null;
  }

  /**
   * Корень зеркала устройства «<Имя> - Файлы» в корне пользователя. Ищем строго по
   * ApiToken.mirrorFolderId: раньше папка искалась по имени и «усыновлялась» (в том числе
   * воскрешалась из корзины), из-за чего чужая папка с подходящим именем молча становилась
   * корнем зеркала, а два телефона одной модели вели один корень и удаляли файлы друг друга.
   * Если своей папки нет или она в корзине — заводим НОВУЮ со свободным именем: корень
   * адресуется по id из токена, а не по имени, поэтому имя в корне — только подпись.
   */
  async deviceMirrorFolderId(tokenId: string): Promise<string> {
    const token = await this.prisma.apiToken.findUnique({ where: { id: tokenId } });
    if (!token) throw unauthorized();
    if (token.mirrorFolderId) {
      const current = await this.prisma.folder.findUnique({ where: { id: token.mirrorFolderId } });
      if (current && !current.deletedAt) return current.id;
    }
    const rootId = await this.rootFolderId(token.userId);
    const base = mirrorFolderName(token.label);

    // Уникальный индекс (parentId, name) распространяется и на записи в корзине, поэтому
    // имя мог занять параллельный запрос или удалённая тёзка — тогда берём уточнение «(2)».
    let lastError: unknown;
    for (let attempt = 0; attempt < 3; attempt++) {
      const name = await this.freeMirrorFolderName(rootId, base);
      let mirror: { id: string };
      try {
        mirror = await this.prisma.folder.create({ data: { parentId: rootId, name } });
      } catch (e) {
        // имя занял параллельный запрос — берём следующее уточнение, а не чужую папку
        if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
          lastError = e;
          continue;
        }
        throw e;
      }
      await this.prisma.apiToken.update({ where: { id: tokenId }, data: { mirrorFolderId: mirror.id } });
      await this.audit.log('device.mirror.folder.create', {
        userId: token.userId,
        tokenId,
        folderId: mirror.id,
        name,
        label: token.label,
      });
      // событие в журнал: остальные устройства пользователя увидят новую папку обычным
      // проходом, без «папка появилась, а журнал про неё молчит»
      await this.changes.recordFolder(token.userId, mirror.id, 'create');
      this.logger.log(`Корень зеркала устройства «${token.label}»: ${name}`);
      return mirror.id;
    }
    throw lastError;
  }

  /**
   * Свободное имя для корня зеркала: «Имя - Файлы (2)», «(3)»… Уточнение дописывается
   * в конец, а не перед расширением (как в клиенте): у папки расширения нет, а точка
   * в метке устройства встречается («Pixel 7.2»).
   */
  private async freeMirrorFolderName(rootId: string, base: string): Promise<string> {
    const siblings = await this.prisma.folder.findMany({
      where: { parentId: rootId },
      select: { name: true },
    });
    const taken = new Set(siblings.map((f) => f.name));
    if (!taken.has(base)) return base;
    for (let i = 2; i < 1000; i++) {
      const candidate = `${base} (${i})`;
      if (!taken.has(candidate)) return candidate;
    }
    // тысяча тёзок в корне: время как уточнение (как и в android-клиенте) гарантирует свободу
    return `${base} (${Date.now()})`;
  }

  /**
   * Живые корни зеркал устройств пользователя (без побочных эффектов; для гардов).
   * Только не отозванные токены: отозванный токен клиенту уже не выдан, папку с его именем
   * пользователь иначе не смог бы ни удалить, ни переименовать — и не увидел бы почему.
   */
  async deviceRootIdsOrNull(userId: string): Promise<string[]> {
    const tokens = await this.prisma.apiToken.findMany({
      where: { userId, revokedAt: null, mirrorFolderId: { not: null } },
      select: { mirrorFolderId: true },
    });
    const ids = tokens.map((t) => t.mirrorFolderId).filter((id): id is string => Boolean(id));
    if (!ids.length) return [];
    const alive = await this.prisma.folder.findMany({
      where: { id: { in: ids }, deletedAt: null },
      select: { id: true },
    });
    return alive.map((f) => f.id);
  }

  /**
   * Папки, которые нельзя удалять, переименовывать и переносить: корень пользователя, «Фото»,
   * «Почта» и корни зеркал устройств. «Телефона» в списке больше нет: он превратился в
   * легаси-папку, которую владелец вправе удалить. Собрано одним методом намеренно: пока
   * гарды в Folders и Dav проверяли папки по отдельности, новую системную папку забывали
   * защитить в одном из мест — и клиент терял адресацию.
   */
  async protectedFolderIds(userId: string): Promise<Set<string>> {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { rootFolderId: true, photoFolderId: true, mailFolderId: true },
    });
    const ids = new Set<string>();
    if (user?.rootFolderId) ids.add(user.rootFolderId);
    // «Фото» и «Почта» — только живые: удалённую системную папку незачем защищать от восстановления
    const systemIds = [user?.photoFolderId, user?.mailFolderId].filter((id): id is string => Boolean(id));
    if (systemIds.length) {
      const alive = await this.prisma.folder.findMany({
        where: { id: { in: systemIds }, deletedAt: null },
        select: { id: true },
      });
      for (const f of alive) ids.add(f.id);
    }
    for (const id of await this.deviceRootIdsOrNull(userId)) ids.add(id);
    return ids;
  }

  /**
   * Владелец дерева, в котором лежит папка. Нужен там, где известна только папка, а журнал
   * изменений требует userId (распаковка архивов и прочие служебные записи).
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

  /**
   * Системная папка «Почта» (скрытая зона MAIL) — корень для вложений писем. Создаётся
   * лениво, как «Фото», но в отличие от неё не попадает в `GET /auth/me`: клиенту незачем
   * знать про папку, которой он всё равно не увидит (она скрыта из листингов, WebDAV
   * и журнала изменений). Имя «Почта» зарезервировано, поэтому «усыновить» пользовательскую
   * папку с этим именем невозможно — иначе её файлы молча уехали бы в скрытую зону.
   */
  async mailFolderId(userId: string): Promise<string> {
    const user = await this.prisma.user.findUnique({ where: { id: userId } });
    if (!user) throw unauthorized();
    if (user.mailFolderId) {
      const current = await this.prisma.folder.findUnique({ where: { id: user.mailFolderId } });
      if (current && !current.deletedAt && current.zone === ZONE_MAIL) return current.id;
    }
    const rootId = await this.rootFolderId(userId);

    let mail = await this.prisma.folder.findFirst({
      where: { parentId: rootId, name: MAIL_FOLDER_NAME },
    });
    if (mail) {
      mail = await this.prisma.folder.update({
        where: { id: mail.id },
        data: { zone: ZONE_MAIL, deletedAt: null },
      });
    } else {
      mail = await this.prisma.folder.create({
        data: { parentId: rootId, name: MAIL_FOLDER_NAME, zone: ZONE_MAIL },
      });
    }
    await this.prisma.user.update({ where: { id: userId }, data: { mailFolderId: mail.id } });
    await this.rezoneSubtree(mail.id, ZONE_MAIL);
    return mail.id;
  }

  /** Проставить зону всему поддереву папки (BFS) — используется при «усыновлении» корня. */
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
    // метка раньше просто резалась до 64 символов и не проверялась, а из неё строится имя
    // папки-зеркала: «..» или «имя/2» давали папку, которую телефон не создаст
    const clean = cleanTokenLabel(label);
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

  /**
   * Отзыв токена. `bySelf` — токен отозвал сам себя (выход на телефоне, DELETE /auth/me/token):
   * в аудите это отдельная причина, иначе «токен исчез» не отличить от отзыва из веба.
   */
  async revokeToken(userId: string, tokenId: string, bySelf = false) {
    const res = await this.prisma.apiToken.updateMany({
      where: { id: tokenId, userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
    if (res.count === 0) throw badRequest('token not found');
    await this.audit.log('auth.token.revoke', { tokenId, ...(bySelf ? { bySelf: true } : {}) });
    return { ok: true };
  }

  /**
   * Проверка Basic-токена (WebDAV). Возвращает владельца, scope и id строки токена или null.
   * Раньше поле scope было декоративным и не читалось, а срок жизни отсутствовал.
   * tokenId нужен как identity устройства: по нему берётся корень зеркала и пишется deviceId
   * в журнал изменений.
   */
  async resolveApiToken(token: string): Promise<{ userId: string; scope: string; tokenId: string } | null> {
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
    return { userId: t.userId, scope: t.scope, tokenId: t.id };
  }
}
