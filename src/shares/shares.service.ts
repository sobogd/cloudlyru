import { Injectable } from '@nestjs/common';
import * as argon2 from 'argon2';
import { Prisma } from '@prisma/client';
import type { ShareKind as PrismaShareKind, ShareCapability as PrismaShareCapability } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { FilesService } from '../files/files.service';
import { AuthService } from '../auth/auth.service';
import { MediaService } from '../media/media.service';
import { QueueService } from '../queue/queue.service';
import { env } from '../config/env';
import { assertSafeName, randomToken, sha256Hex } from '../common/utils';
import { ZONE_PHOTOS } from '../common/zones';
import { badRequest, forbidden, notFound, tooMany, unauthorized } from '../common/errors';

export type ShareKind = 'FOLDER' | 'FILE';
export type ShareCapability = 'VIEW' | 'DOWNLOAD' | 'UPLOAD' | 'RW';

const KIND = { FOLDER: 'FOLDER', FILE: 'FILE' } as const;
const CAP = { VIEW: 'VIEW', DOWNLOAD: 'DOWNLOAD', UPLOAD: 'UPLOAD', RW: 'RW' } as const;

interface Attempts {
  count: number;
  resetAt: number;
}

/**
 * Шаринг без аккаунтов: ссылка-токен + (опционально) пароль + срок действия.
 * Пароль проверяется на каждый запрос (header X-Share-Password или ?password=).
 */
@Injectable()
export class SharesService {
  private readonly attempts = new Map<string, Attempts>();

  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly files: FilesService,
    private readonly media: MediaService,
    private readonly queue: QueueService,
    private readonly auth: AuthService,
  ) {}

  // ============ Владелец ============

  async create(opts: {
    kind: ShareKind;
    targetId: string;
    password?: string;
    capability?: ShareCapability;
    expiresAt?: Date | null;
  }, userId: string) {
    const kind = opts.kind === KIND.FILE ? KIND.FILE : KIND.FOLDER;
    const capability: ShareCapability = opts.capability ?? CAP.VIEW;
    if (opts.capability && !['VIEW', 'DOWNLOAD', 'UPLOAD', 'RW'].includes(opts.capability)) {
      throw badRequest('invalid capability');
    }
    if (opts.password && (opts.password.length < 8 || opts.password.length > 128)) {
      throw badRequest('password length 8..128');
    }
    if (opts.expiresAt && opts.expiresAt.getTime() <= Date.now()) {
      throw badRequest('expiresAt must be in the future');
    }

    // цель должна существовать, не быть в корзине И принадлежать тому, кто выдаёт ссылку:
    // без этой проверки любой залогиненный мог расшарить чужую папку с capability RW
    if (kind === KIND.FILE) {
      const entry = await this.auth.ownEntry(userId, opts.targetId);
      if (!entry) throw notFound('file not found');
    } else {
      const folder = await this.prisma.folder.findUnique({ where: { id: opts.targetId } });
      if (!folder || folder.deletedAt) throw notFound('folder not found');
      if (!(await this.auth.folderOwnedBy(userId, folder.id))) throw notFound('folder not found');
    }

    const token = randomToken(24);
    const share = await this.prisma.share.create({
      data: {
        userId,
        kind: kind as PrismaShareKind,
        targetId: opts.targetId,
        capability: capability as PrismaShareCapability,
        token,
        passwordHash: opts.password ? await argon2.hash(opts.password) : null,
        expiresAt: opts.expiresAt,
      },
    });
    return this.toPublic(share);
  }

  async list(userId: string) {
    const rows = await this.prisma.share.findMany({
      where: { userId, revokedAt: null },
      orderBy: { createdAt: 'desc' },
      take: 200,
    });
    return rows.map((r) => this.toPublic(r));
  }

  async revoke(token: string, userId: string) {
    const res = await this.prisma.share.updateMany({
      where: { token, userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
    if (res.count === 0) throw notFound('share not found');
    return { ok: true };
  }

  async update(
    token: string,
    patch: { password?: string | null; expiresAt?: Date | null; capability?: ShareCapability },
    userId: string,
  ) {
    const share = await this.prisma.share.findUnique({ where: { token } });
    if (!share || share.revokedAt || share.userId !== userId) throw notFound('share not found');
    if (patch.capability && !['VIEW', 'DOWNLOAD', 'UPLOAD', 'RW'].includes(patch.capability)) {
      throw badRequest('invalid capability');
    }
    const data: Prisma.ShareUpdateInput = {};
    if (patch.password !== undefined) {
      data.passwordHash = patch.password === null ? null : await argon2.hash(patch.password);
    }
    if (patch.expiresAt !== undefined) data.expiresAt = patch.expiresAt;
    if (patch.capability) data.capability = patch.capability as PrismaShareCapability;
    const updated = await this.prisma.share.update({ where: { id: share.id }, data });
    return this.toPublic(updated);
  }

  // ============ Публичный доступ ============

  private async resolve(token: string) {
    const share = await this.prisma.share.findUnique({ where: { token } });
    if (!share || share.revokedAt) throw notFound('share not found');
    if (share.expiresAt && share.expiresAt.getTime() <= Date.now()) {
      throw forbidden('share expired', 'share_expired');
    }
    return share;
  }

  /** Проверка пароля с rate-limit'ом попыток на ip. */
  private async checkPassword(share: { id: string; passwordHash: string | null }, ip: string, provided?: string) {
    if (!share.passwordHash) return;
    const key = `${ip}:${share.id}`;
    const now = Date.now();
    let a = this.attempts.get(key);
    if (!a || a.resetAt <= now) {
      a = { count: 0, resetAt: now + 60_000 };
      this.attempts.set(key, a);
    }
    if (a.count >= 10) throw tooMany('too many attempts');
    const ok = provided ? await argon2.verify(share.passwordHash, provided).catch(() => false) : false;
    if (!ok) {
      a.count += 1;
      throw unauthorized('invalid share password', 'invalid_share_password');
    }
  }

  private async entryMeta(entryId: string) {
    const entry = await this.prisma.fileEntry.findUnique({
      where: { id: entryId },
      include: { asset: { select: { size: true, mime: true, sha256: true } } },
    });
    if (!entry || entry.deletedAt) throw notFound('file not found');
    return {
      id: entry.id,
      name: entry.name,
      size: Number(entry.asset.size),
      mime: entry.asset.mime,
      sha256: entry.asset.sha256,
      createdAt: entry.createdAt,
    };
  }

  /** Инфо + содержимое шаринга (файл или дети папки верхнего уровня). */
  async view(token: string, ip: string, password?: string) {
    const share = await this.resolve(token);
    await this.checkPassword(share, ip, password);

    if (share.kind === 'FILE') {
      const file = await this.entryMeta(share.targetId);
      return { kind: 'file', capability: share.capability, name: file.name, file };
    }

    const folder = await this.prisma.folder.findUnique({ where: { id: share.targetId } });
    if (!folder || folder.deletedAt) throw notFound('folder not found');
    const [folders, entries] = await Promise.all([
      this.prisma.folder.findMany({
        where: { parentId: folder.id, deletedAt: null },
        orderBy: { name: 'asc' },
        select: { id: true, name: true },
      }),
      this.prisma.fileEntry.findMany({
        where: { folderId: folder.id, deletedAt: null },
        orderBy: { name: 'asc' },
        select: { id: true, name: true, asset: { select: { size: true, mime: true } } },
      }),
    ]);
    const canRead = ['VIEW', 'DOWNLOAD', 'RW'].includes(share.capability);
    if (!canRead) throw forbidden('share does not allow viewing', 'share_view_forbidden');
    return {
      kind: 'folder',
      capability: share.capability,
      name: folder.name,
      folders: folders.map((f) => ({ id: f.id, name: f.name })),
      entries: entries.map((e) => ({ id: e.id, name: e.name, size: Number(e.asset.size), mime: e.asset.mime })),
    };
  }

  /**
   * Содержимое файла из шаринга. Возвращаем ключ в S3 и имя: байты отдаёт контроллер
   * потоком. Раньше здесь выдавалась presigned-ссылка, которая работала уже без токена.
   */
  async content(
    token: string,
    entryId: string,
    ip: string,
    password?: string,
  ): Promise<{ key: string; mime: string; name: string }> {
    const share = await this.resolve(token);
    await this.checkPassword(share, ip, password);
    if (!['DOWNLOAD', 'RW'].includes(share.capability)) {
      throw forbidden('share does not allow download', 'share_download_forbidden');
    }
    const entry = await this.prisma.fileEntry.findUnique({
      where: { id: entryId },
      include: { asset: true },
    });
    if (!entry || entry.deletedAt) throw notFound('file not found');

    // файл-шаринг: entryId должен быть целью; папка-шаринг: файл — прямой ребёнок цели (M1)
    if (share.kind === 'FILE') {
      if (share.targetId !== entryId) throw forbidden('file not in share');
    } else {
      if (entry.folderId !== share.targetId) throw forbidden('file not in share');
    }
    // мастер для медиа-зоны (после конвертации сырья в S3 нет), оригинал — для зоны «Файлы»
    return this.files.contentForEntry(entryId);
  }

  /** File-drop: загрузка файла в расшаренную папку без аккаунта (capability UPLOAD/RW). */
  async upload(token: string, ip: string, name: string, mime: string, body: Buffer, password?: string) {
    const share = await this.resolve(token);
    await this.checkPassword(share, ip, password);
    if (!['UPLOAD', 'RW'].includes(share.capability)) {
      throw forbidden('share does not allow upload', 'share_upload_forbidden');
    }
    if (share.kind !== 'FOLDER') throw badRequest('upload allowed only into folder shares');
    try {
      assertSafeName(name);
    } catch {
      throw badRequest('invalid file name');
    }
    const folder = await this.prisma.folder.findUnique({ where: { id: share.targetId } });
    if (!folder || folder.deletedAt) throw notFound('folder not found');

    const sha256 = sha256Hex(body);
    const key = S3Service.assetKey(sha256);
    const existing = await this.prisma.asset.findUnique({ where: { sha256 } });
    if (!existing) {
      await this.s3.putObject(key, body, mime);
      await this.files.ensureAsset(sha256, body.length, mime, this.extOf(name));
    }
    const asset = await this.prisma.asset.findUniqueOrThrow({ where: { sha256 } });
    const entry = await this.files.createEntry(folder.id, name, asset.id);
    // конвертация/EXIF — только когда файл попал в медиа-зону («Фото»)
    if (entry.zone === ZONE_PHOTOS) {
      try {
        await this.media.captureMeta(asset.id, sha256, body.length, mime);
      } catch { /* ignore */ }
      await this.queue.enqueue(asset.id, sha256, mime);
    }
    return { ok: true, entryId: entry.id, size: body.length, deduped: Boolean(existing), zone: entry.zone };
  }

  private extOf(name: string): string | undefined {
    const i = name.lastIndexOf('.');
    if (i <= 0 || i === name.length - 1) return undefined;
    return name.slice(i + 1).toLowerCase().slice(0, 16);
  }

  private toPublic(share: {
    token: string;
    kind: string;
    capability: string;
    targetId: string;
    expiresAt: Date | null;
    passwordHash: string | null;
    createdAt: Date;
  }) {
    return {
      token: share.token,
      url: `${env.BASE_URL}/s/${share.token}`,
      kind: share.kind,
      capability: share.capability,
      targetId: share.targetId,
      hasPassword: Boolean(share.passwordHash),
      expiresAt: share.expiresAt,
      createdAt: share.createdAt,
    };
  }
}
