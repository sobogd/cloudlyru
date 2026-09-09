import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import * as argon2 from 'argon2';
import { env } from '../config/env';
import { PrismaService } from '../prisma/prisma.service';
import { randomToken, sha256Hex } from '../common/utils';
import { PHOTO_FOLDER_NAME, ZONE_PHOTOS } from '../common/zones';
import { AuditService } from '../audit/audit.service';
import { badRequest, unauthorized } from '../common/errors';

export const ROOT_FOLDER_NAME = '__root__';

@Injectable()
export class AuthService implements OnModuleInit {
  private readonly logger = new Logger(AuthService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly audit: AuditService,
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
      await this.prisma.user.update({
        where: { id: user.id },
        data: { rootFolderId: root.id, photoFolderId: photo.id },
      });
      this.logger.log(`Создан владелец "${env.ADMIN_LOGIN}", корневая папка и системная «${PHOTO_FOLDER_NAME}»`);
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
    return { id: user.id, login: user.login, rootFolderId: user.rootFolderId, photoFolderId };
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
    const token = randomToken(32);
    const t = await this.prisma.apiToken.create({
      data: { userId, label: clean, tokenHash: sha256Hex(token), scope: 'files:rw' },
    });
    // plain-токен показывается один раз
    return { id: t.id, token, label: t.label };
  }

  async listTokens(userId: string) {
    const rows = await this.prisma.apiToken.findMany({
      where: { userId, revokedAt: null },
      orderBy: { createdAt: 'desc' },
      select: { id: true, label: true, scope: true, lastUsedAt: true, createdAt: true },
    });
    return rows;
  }

  async revokeToken(userId: string, tokenId: string) {
    const res = await this.prisma.apiToken.updateMany({
      where: { id: tokenId, userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
    if (res.count === 0) throw badRequest('token not found');
    return { ok: true };
  }

  /** Проверка Basic-токена (WebDAV): возвращает userId или null. */
  async resolveApiToken(token: string): Promise<string | null> {
    if (!token) return null;
    const t = await this.prisma.apiToken.findUnique({ where: { tokenHash: sha256Hex(token) } });
    if (!t || t.revokedAt) return null;
    await this.prisma.apiToken
      .update({ where: { id: t.id }, data: { lastUsedAt: new Date() } })
      .catch(() => undefined);
    return t.userId;
  }
}
