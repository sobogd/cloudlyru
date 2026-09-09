import {
  BadRequestException,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { createHash } from 'crypto';
import { AuthService } from '../auth/auth.service';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { FilesService } from '../files/files.service';
import { MediaService } from '../media/media.service';
import { QueueService } from '../queue/queue.service';
import { assertSafeName } from '../common/utils';
import { ZONE_FILES, ZONE_PHOTOS } from '../common/zones';
import { notFound } from '../common/errors';

export class DavError extends Error {}

@Injectable()
export class DavService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly files: FilesService,
    private readonly auth: AuthService,
    private readonly media: MediaService,
    private readonly queue: QueueService,
  ) {}

  /** Проверка Authorization: Basic login:apptoken. */
  async authenticate(req: { headers: Record<string, unknown> }): Promise<string> {
    const h = req.headers['authorization'];
    if (typeof h !== 'string' || !h.startsWith('Basic ')) throw new UnauthorizedException('Basic auth required');
    const decoded = Buffer.from(h.slice(6), 'base64').toString('utf8');
    const idx = decoded.indexOf(':');
    const token = idx >= 0 ? decoded.slice(idx + 1) : decoded;
    const userId = await this.auth.resolveApiToken(token);
    if (!userId) throw new UnauthorizedException('invalid token');
    return userId;
  }

  // ---- path → сущность ----
  // '/' — корень; '/a/b.txt' — вложенные папки/файл. Только первый уровень у root: папки root → дети.

  async resolvePath(userId: string, davPath: string) {
    const parts = davPath.split('/').filter(Boolean);
    const rootId = await this.auth.rootFolderId(userId);

    // конечный сегмент может быть файлом
    const isFile = parts.length > 0 && (await this.isFile(userId, parts));
    return { parts, rootId, isFile };
  }

  private async isFile(userId: string, parts: string[]): Promise<boolean> {
    const rootId = await this.auth.rootFolderId(userId);
    let folderId: string = rootId;
    for (let i = 0; i < parts.length - 1; i++) {
      const f: { id: string } | null = await this.prisma.folder.findFirst({
        where: { parentId: folderId, name: parts[i], deletedAt: null },
        select: { id: true },
      });
      if (!f) throw notFound('path not found');
      folderId = f.id;
    }
    const name = parts[parts.length - 1];
    const entry = await this.prisma.fileEntry.findFirst({ where: { folderId, name, deletedAt: null } });
    return Boolean(entry);
  }

  private async folderByPath(userId: string, parts: string[]) {
    const rootId = await this.auth.rootFolderId(userId);
    let folderId = rootId;
    for (const name of parts) {
      const f = await this.prisma.folder.findFirst({ where: { parentId: folderId, name, deletedAt: null } });
      if (!f) return null;
      folderId = f.id;
    }
    return folderId;
  }

  private async entryByPath(userId: string, parts: string[]) {
    if (parts.length === 0) return null;
    const parentParts = parts.slice(0, -1);
    const parentId = await this.folderByPath(userId, parentParts);
    if (!parentId) return null;
    const name = parts[parts.length - 1];
    return this.prisma.fileEntry.findFirst({ where: { folderId: parentId, name, deletedAt: null } });
  }

  private async folderMeta(folderId: string) {
    const f = await this.prisma.folder.findUnique({ where: { id: folderId } });
    return f;
  }

  async propfind(userId: string, davPath: string, depth: string) {
    const parts = davPath.split('/').filter(Boolean);
    const entry = await this.entryByPath(userId, parts);
    const rootId = await this.auth.rootFolderId(userId);

    let responses: Array<{ href: string; isCollection: boolean; name: string; size?: number; mtime?: Date }> = [];

    if (entry) {
      responses.push({ href: davPath, isCollection: false, name: entry.name, size: 0 });
    } else {
      const folderId = parts.length ? await this.folderByPath(userId, parts) : rootId;
      if (!folderId) throw notFound('path not found');
      const folder = await this.folderMeta(folderId);
      if (!folder || folder.deletedAt) throw notFound('path not found');
      const href = '/' + parts.join('/');
      responses.push({ href: href === '/' ? '/' : href, isCollection: true, name: folder.name, mtime: folder.updatedAt });
      if (depth !== '0') {
        const [folders, entries] = await Promise.all([
          this.prisma.folder.findMany({ where: { parentId: folderId, deletedAt: null }, orderBy: { name: 'asc' } }),
          this.prisma.fileEntry.findMany({
            where: { folderId, deletedAt: null },
            orderBy: { name: 'asc' },
            include: { asset: { select: { size: true, mime: true } } },
          }),
        ]);
        for (const c of folders) {
          responses.push({ href: `${href === '/' ? '' : href}/${encodeURIComponent(c.name)}`, isCollection: true, name: c.name, mtime: c.updatedAt });
        }
        for (const c of entries) {
          responses.push({
            href: `${href === '/' ? '' : href}/${encodeURIComponent(c.name)}`,
            isCollection: false,
            name: c.name,
            size: Number(c.asset.size),
            mtime: c.createdAt,
          });
        }
      }
    }
    return this.renderMultistatus(responses);
  }

  async mkcol(userId: string, davPath: string) {
    const parts = davPath.split('/').filter(Boolean);
    if (parts.length === 0) throw new BadRequestException('invalid path');
    const parentId = await this.folderByPath(userId, parts.slice(0, -1));
    if (!parentId) throw notFound('parent not found');
    const name = decodeURIComponent(parts[parts.length - 1]);
    try {
      assertSafeName(name);
    } catch {
      throw new BadRequestException('invalid name');
    }
    const dup = await this.prisma.folder.findFirst({ where: { parentId, name } });
    if (dup) throw new BadRequestException('already exists');
    const parent = await this.prisma.folder.findUnique({ where: { id: parentId }, select: { zone: true } });
    await this.prisma.folder.create({
      data: { parentId, name, zone: parent?.zone === ZONE_PHOTOS ? ZONE_PHOTOS : ZONE_FILES },
    });
    return 201;
  }

  async put(userId: string, davPath: string, body: NodeJS.ReadableStream, contentLength: number | null, contentType: string) {
    const parts = davPath.split('/').filter(Boolean);
    if (parts.length === 0) throw new BadRequestException('invalid path');
    const parentId = await this.folderByPath(userId, parts.slice(0, -1));
    if (!parentId) throw notFound('parent not found');
    const parent = await this.prisma.folder.findUnique({ where: { id: parentId }, select: { zone: true } });
    const zone = parent?.zone === ZONE_PHOTOS ? ZONE_PHOTOS : ZONE_FILES;
    const name = decodeURIComponent(parts[parts.length - 1]);
    try {
      assertSafeName(name);
    } catch {
      throw new BadRequestException('invalid name');
    }
    if (contentLength !== null && contentLength <= 0) throw new BadRequestException('empty body');

    // стримим в S3 с инкрементальным sha256 (tee)
    const hash = createHash('sha256');
    const { PassThrough } = await import('stream');
    const tee = new PassThrough();
    const p = body as NodeJS.ReadableStream;
    const reader = (async () => {
      for await (const chunk of p as AsyncIterable<Buffer | string>) {
        const b = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        hash.update(b);
        tee.write(b);
      }
      tee.end();
    })().catch((e) => {
      tee.destroy(e);
      throw e;
    });

    const key = S3Service.assetKey('pending'); // временно; финальный ключ по хэшу ниже
    // читаем во временный S3-объект, затем перекладываем — используем tmp key
    const tmpKey = `files/tmp/${createHash('sha256').update(name + Date.now()).digest('hex').slice(0, 16)}`;
    const mime = contentType || 'application/octet-stream';

    await this.s3.putObjectStream(tmpKey, tee, mime, contentLength ?? undefined);
    await reader;

    const sha256 = hash.digest('hex');
    const finalKey = S3Service.assetKey(sha256);
    const size = contentLength ?? 0;

    const existing = await this.prisma.asset.findUnique({ where: { sha256 } });
    let assetId: string;
    let deduped = false;
    if (existing) {
      deduped = true;
      assetId = existing.id;
    } else {
      await this.s3.copyObject(tmpKey, finalKey);
      assetId = await this.files.ensureAsset(sha256, size, mime, this.extOf(name));
    }
    await this.s3.deleteObject(tmpKey).catch(() => undefined);

    // EXIF + очередь конвертации — только для медиа-зоны («Фото»); в «Файлы» — как есть
    if (zone === ZONE_PHOTOS) {
      try {
        await this.media.captureMeta(assetId, sha256, Number(contentLength ?? 0), mime);
      } catch { /* ignore */ }
      await this.queue.enqueue(assetId, sha256, mime);
    }

    // перезапись существующего файла с тем же именем — обновляем entry на новый asset
    const dup = await this.prisma.fileEntry.findFirst({ where: { folderId: parentId, name } });
    if (dup) {
      if (dup.deletedAt) {
        await this.prisma.fileEntry.update({ where: { id: dup.id }, data: { deletedAt: null, assetId, zone } });
      } else {
        await this.prisma.fileEntry.update({ where: { id: dup.id }, data: { assetId, zone } });
      }
      return 204;
    }
    await this.prisma.fileEntry.create({ data: { folderId: parentId, name, assetId, zone } });
    return 201;
  }

  async getUrl(userId: string, davPath: string): Promise<{ url: string; mime: string; size: number }> {
    const parts = davPath.split('/').filter(Boolean);
    const entry = await this.entryByPath(userId, parts);
    if (!entry) throw notFound('file not found');
    const asset = await this.prisma.asset.findUnique({ where: { id: entry.assetId } });
    if (!asset) throw notFound('file not found');
    return {
      url: await this.s3.presignedGet(S3Service.assetKey(asset.sha256), asset.mime),
      mime: asset.mime,
      size: Number(asset.size),
    };
  }

  async headMeta(userId: string, davPath: string): Promise<{ mime: string; size: number }> {
    const parts = davPath.split('/').filter(Boolean);
    const entry = await this.entryByPath(userId, parts);
    if (!entry) throw notFound('file not found');
    const asset = await this.prisma.asset.findUnique({ where: { id: entry.assetId } });
    if (!asset) throw notFound('file not found');
    return { mime: asset.mime, size: Number(asset.size) };
  }

  async delete(userId: string, davPath: string) {
    const parts = davPath.split('/').filter(Boolean);
    if (parts.length === 0) throw new BadRequestException('cannot delete root');
    const entry = await this.entryByPath(userId, parts);
    if (entry) {
      await this.prisma.fileEntry.update({ where: { id: entry.id }, data: { deletedAt: new Date() } });
      return 204;
    }
    const parentId = await this.folderByPath(userId, parts.slice(0, -1));
    const name = parts[parts.length - 1];
    const folder = parentId
      ? await this.prisma.folder.findFirst({ where: { parentId, name, deletedAt: null } })
      : await this.prisma.folder.findFirst({ where: { parentId: null, name, deletedAt: null } });
    if (!folder) throw notFound('path not found');
    if (folder.name === '__root__') throw new BadRequestException('cannot delete root');
    const photoId = await this.auth.photoRootIdOrNull(userId);
    if (photoId && folder.id === photoId) throw new BadRequestException('cannot delete photo library root');
    // мягкое удаление поддерева
    const ids: string[] = [folder.id];
    let frontier = [folder.id];
    while (frontier.length) {
      const children = await this.prisma.folder.findMany({ where: { parentId: { in: frontier } }, select: { id: true } });
      const next = children.map((c) => c.id);
      if (!next.length) break;
      ids.push(...next);
      frontier = next;
    }
    await this.prisma.folder.updateMany({ where: { id: { in: ids } }, data: { deletedAt: new Date() } });
    return 204;
  }

  async move(userId: string, srcPath: string, dstPath: string) {
    // rename/move в пределах дерева: переименование конечного сегмента (папки или файла)
    const srcParts = srcPath.split('/').filter(Boolean);
    const dstParts = dstPath.split('/').filter(Boolean);
    if (!srcParts.length || !dstParts.length) throw new BadRequestException('invalid path');
    const newName = decodeURIComponent(dstParts[dstParts.length - 1]);
    try {
      assertSafeName(newName);
    } catch {
      throw new BadRequestException('invalid name');
    }
    const entry = await this.entryByPath(userId, srcParts);
    if (entry) {
      const dup = await this.prisma.fileEntry.findFirst({ where: { folderId: entry.folderId, name: newName, id: { not: entry.id } } });
      if (dup) throw new BadRequestException('already exists');
      await this.prisma.fileEntry.update({ where: { id: entry.id }, data: { name: newName } });
      return 204;
    }
    const parentId = await this.folderByPath(userId, srcParts.slice(0, -1));
    const folder = parentId
      ? await this.prisma.folder.findFirst({ where: { parentId, name: srcParts[srcParts.length - 1], deletedAt: null } })
      : await this.prisma.folder.findFirst({ where: { parentId: null, name: srcParts[srcParts.length - 1], deletedAt: null } });
    if (!folder) throw notFound('path not found');
    if (folder.name === '__root__') throw new BadRequestException('cannot rename root');
    const photoId = await this.auth.photoRootIdOrNull(userId);
    if (photoId && folder.id === photoId) throw new BadRequestException('cannot rename photo library root');
    const dup = await this.prisma.folder.findFirst({ where: { parentId: folder.parentId ?? undefined, name: newName, id: { not: folder.id } } });
    if (dup) throw new BadRequestException('already exists');
    await this.prisma.folder.update({ where: { id: folder.id }, data: { name: newName } });
    return 204;
  }

  // ============ XML ============

  private esc(s: string): string {
    return s
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  private renderMultistatus(
    items: Array<{ href: string; isCollection: boolean; name: string; size?: number; mtime?: Date }>,
  ): string {
    const rows = items
      .map((it) => {
        const type = it.isCollection ? '<D:collection/>' : '';
        const len = it.isCollection ? '' : `<D:getcontentlength>${it.size ?? 0}</D:getcontentlength>`;
        const ct = it.isCollection ? '' : '<D:getcontenttype>application/octet-stream</D:getcontenttype>';
        const mtime = it.mtime ? `<D:getlastmodified>${it.mtime.toUTCString()}</D:getlastmodified>` : '';
        return `<D:response><D:href>${this.esc(it.href)}</D:href><D:propstat><D:prop><D:displayname>${this.esc(it.name)}</D:displayname><D:resourcetype>${type}</D:resourcetype>${len}${ct}${mtime}</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>`;
      })
      .join('');
    return `<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">${rows}</D:multistatus>`;
  }

  private extOf(name: string): string | undefined {
    const i = name.lastIndexOf('.');
    if (i <= 0 || i === name.length - 1) return undefined;
    return name.slice(i + 1).toLowerCase().slice(0, 16);
  }
}
