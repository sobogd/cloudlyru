import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import * as argon2 from 'argon2';
import { env } from '../config/env';
import { PrismaService } from '../prisma/prisma.service';
import { randomToken, sha256Hex } from '../common/utils';
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

  /** При первом старте создаёт владельца и его корневую папку. */
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
      await this.prisma.user.update({ where: { id: user.id }, data: { rootFolderId: root.id } });
      this.logger.log(`Создан владелец "${env.ADMIN_LOGIN}" и корневая папка`);
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
    return { id: user.id, login: user.login, rootFolderId: user.rootFolderId };
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
}
