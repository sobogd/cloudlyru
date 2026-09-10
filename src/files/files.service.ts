import { Injectable } from '@nestjs/common';
import type { Request, Response } from 'express';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { MediaService } from '../media/media.service';
import { AuthService, ROOT_FOLDER_NAME } from '../auth/auth.service';
import { sendObjectOr404 } from '../common/http-object';
import { assertSafeName } from '../common/utils';
import { ZONE_FILES, ZONE_PHOTOS } from '../common/zones';
import { conflict, notFound } from '../common/errors';

/**
 * Типы, которые безопасно показывать прямо в интерфейсе. SVG/HTML сюда не попадают
 * намеренно: они исполняют скрипты, а отдаём мы их с нашего же домена.
 */
const INLINE_IMAGE_MIMES: Record<string, string> = {
  'image/jpeg': 'image/jpeg',
  'image/png': 'image/png',
  'image/gif': 'image/gif',
  'image/webp': 'image/webp',
  'image/avif': 'image/avif',
  'image/bmp': 'image/bmp',
  'image/tiff': 'image/tiff',
  'image/heic': 'image/heic',
  'image/heif': 'image/heif',
};

@Injectable()
export class FilesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly media: MediaService,
    private readonly auth: AuthService,
  ) {}

  /** Папка-приёмник: существует и не в корзине. */
  private async ensureFolder(folderId: string) {
    const folder = await this.prisma.folder.findUnique({ where: { id: folderId } });
    if (!folder || folder.deletedAt) throw notFound('folder not found');
    return folder;
  }

  /** Asset по хэшу; если нет — создаёт запись (объект в S3 уже должен лежать под files/<sha256>). */
  async ensureAsset(sha256: string, size: number, mime: string, ext?: string): Promise<string> {
    const existing = await this.prisma.asset.findUnique({ where: { sha256 } });
    if (existing) return existing.id;
    const asset = await this.prisma.asset.create({
      data: { sha256, size: BigInt(size), mime, ext },
    });
    return asset.id;
  }

  async assertNameFree(folderId: string, name: string, exceptId?: string): Promise<void> {
    const existing = await this.prisma.fileEntry.findFirst({
      where: { folderId, name, ...(exceptId ? { id: { not: exceptId } } : {}) },
    });
    if (existing) {
      if (existing.deletedAt) {
        throw conflict('file with this name is in trash — restore or purge it first');
      }
      throw conflict('file name already exists');
    }
  }

  /** Создание FileEntry (после того, как объект в S3 готов или найден по хэшу). Возвращает зону записи. */
  async createEntry(folderId: string, name: string, assetId: string): Promise<{ id: string; deduped: boolean; zone: string }> {
    const folder = await this.ensureFolder(folderId);
    assertSafeName(name);
    await this.assertNameFree(folderId, name);

    // если на одно содержимое уже есть живой entry в этой папке с другим именем — дедуп по содержимому
    const sameAssetLive = await this.prisma.fileEntry.findFirst({
      where: { folderId, assetId, deletedAt: null, name: { not: name } },
    });

    const zone = folder.zone === ZONE_PHOTOS ? ZONE_PHOTOS : ZONE_FILES;
    const entry = await this.prisma.fileEntry.create({
      data: { folderId, assetId, name, zone },
      select: { id: true },
    });
    return { id: entry.id, deduped: Boolean(sameAssetLive), zone };
  }

  /** Полные метаданные файла для деталки: путь, размер/тип/хэш, EXIF/видео и метаданные Google. */
  async getEntryMeta(entryId: string) {
    const entry = await this.prisma.fileEntry.findUnique({
      where: { id: entryId },
      include: { asset: { include: { media: true } }, folder: true },
    });
    if (!entry || entry.deletedAt) throw notFound('file not found');

    // Подробные метаданные извлекаем лениво при первом открытии деталки и кэшируем в БД.
    // Раньше EXIF парсился только для зоны «Фото», поэтому у файлов в «Файлах» деталка была пустой.
    if (!entry.asset.media?.raw) {
      await this.media.extractDetail(
        entry.assetId,
        entry.asset.sha256,
        Number(entry.asset.size),
        entry.asset.mime,
      );
      entry.asset.media = await this.prisma.mediaMeta.findUnique({ where: { assetId: entry.assetId } });
    }

    const m = entry.asset.media;
    return {
      id: entry.id,
      name: entry.name,
      createdAt: entry.createdAt,
      folderId: entry.folderId,
      zone: entry.zone,
      path: await this.folderPath(entry.folder),
      size: Number(entry.asset.size),
      mime: entry.asset.mime,
      ext: entry.asset.ext ?? undefined,
      sha256: entry.asset.sha256,
      masterMime: entry.asset.masterMime && entry.asset.masterReadyAt ? entry.asset.masterMime : null,
      media: m
        ? {
            capturedAt: m.capturedAt ? m.capturedAt.toISOString() : null,
            latitude: m.latitude ?? undefined,
            longitude: m.longitude ?? undefined,
            make: m.make ?? undefined,
            model: m.model ?? undefined,
            width: m.width ?? undefined,
            height: m.height ?? undefined,
            raw: (m.raw as Record<string, unknown> | null) ?? null,
          }
        : null,
    };
  }

  /** Человекочитаемый путь файла: «Главная / папка / …». */
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

  /**
   * Самый полный доступный объект ассета: оригинал (он и есть мастер), а если его нет —
   * лучшая из производных. У части легаси-ассетов оригинал удалялся прежним кодом сразу
   * после конвертации. Возвращаем также признак «это оригинал»: для него S3 отдаёт
   * content-disposition: attachment (скачивание), для производных — inline (превью).
   */
  private async resolveContentKey(asset: {
    sha256: string;
    mime: string;
  }): Promise<{ key: string; mime: string; original: boolean }> {
    const sha = asset.sha256;
    const rawKey = S3Service.assetKey(sha);
    if (await this.s3.headObject(rawKey).catch(() => false)) {
      return { key: rawKey, mime: asset.mime, original: true };
    }

    const isVideo = String(asset.mime).startsWith('video/');
    const fallback = isVideo
      ? [
          MediaService.legacyVideoMasterKey(sha),
          MediaService.video1080Key(sha),
          MediaService.legacyVideo720Key(sha),
          MediaService.videoPosterKey(sha),
        ]
      : [
          MediaService.legacyPhotoMasterKey(sha),
          MediaService.photoFullKey(sha),
          MediaService.legacyPhotoFullWebpKey(sha),
          MediaService.gridKey(sha),
        ];
    for (const key of fallback) {
      if (await this.s3.headObject(key).catch(() => false)) {
        const mime = key.endsWith('.avif') ? 'image/avif' : key.endsWith('.mp4') ? 'video/mp4' : 'image/webp';
        return { key, mime, original: false };
      }
    }
    // ничего нет — вернём ключ оригинала, чтобы вызывающий получил ошибку S3
    return { key: rawKey, mime: asset.mime, original: true };
  }

  /**
   * Presigned-URL для скачивания. Нужен там, где клиент качает мимо сервиса
   * (публичные шаринг-ссылки, WebDAV). Для своих файлов используйте download().
   */
  async presignedUrl(entryId: string): Promise<string> {
    const entry = await this.prisma.fileEntry.findUnique({
      where: { id: entryId },
      include: { asset: true },
    });
    if (!entry || entry.deletedAt) throw notFound('file not found');
    const { key, mime, original } = await this.resolveContentKey(entry.asset);
    return original ? this.s3.presignedGet(key, mime) : this.s3.presignedInline(key, mime);
  }

  /** Свой живой файл: вход по id с проверкой, что он в дереве этого пользователя. */
  private async requireOwnEntry(entryId: string, userId: string) {
    const entry = await this.prisma.fileEntry.findUnique({
      where: { id: entryId },
      include: { asset: true },
    });
    // 404, а не 403: чужой файл не должен отличаться от несуществующего
    if (!entry || entry.deletedAt) throw notFound('file not found');
    if (!(await this.auth.folderOwnedBy(userId, entry.folderId))) throw notFound('file not found');
    return entry;
  }

  /**
   * Скачивание файла: байты идут через сервис (не отдаём наружу presigned-ссылку на S3,
   * она живёт без авторизации), тип — octet-stream, имя — из дерева, disposition: attachment.
   * Так браузер сохраняет файл, а не открывает новую вкладку и не рендерит содержимое.
   */
  async download(entryId: string, userId: string, req: Request, res: Response): Promise<void> {
    const entry = await this.requireOwnEntry(entryId, userId);
    const { key } = await this.resolveContentKey(entry.asset);
    await sendObjectOr404(req, res, this.s3, key, {
      mime: 'application/octet-stream',
      disposition: 'attachment',
      filename: entry.name,
    });
  }

  /**
   * Показ файла в интерфейсе (миниатюры альбомов): только «безопасные» картинки и только
   * с типом из белого списка. Всё остальное (SVG, HTML, PDF, видео) уходит на скачивание.
   */
  async inlineImage(entryId: string, userId: string, req: Request, res: Response): Promise<void> {
    const entry = await this.requireOwnEntry(entryId, userId);
    const mime = INLINE_IMAGE_MIMES[String(entry.asset.mime).toLowerCase()];
    if (!mime) return this.download(entryId, userId, req, res);
    const { key } = await this.resolveContentKey(entry.asset);
    await sendObjectOr404(req, res, this.s3, key, {
      mime,
      disposition: 'inline',
      filename: entry.name,
      // содержимое неизменяемо (ключ = sha256), но приватно: кэширует только браузер
      cache: 'private, max-age=600',
    });
  }

  async softDelete(entryId: string) {
    const entry = await this.prisma.fileEntry.findUnique({ where: { id: entryId } });
    if (!entry || entry.deletedAt) throw notFound('file not found');
    await this.prisma.fileEntry.update({ where: { id: entryId }, data: { deletedAt: new Date() } });
    return { ok: true };
  }

  async restore(entryId: string) {
    const entry = await this.prisma.fileEntry.findUnique({ where: { id: entryId } });
    if (!entry) throw notFound('file not found');
    if (entry.deletedAt) {
      const folder = await this.prisma.folder.findUnique({ where: { id: entry.folderId } });
      if (!folder || folder.deletedAt) throw conflict('parent folder is deleted — restore folder first');
    }
    await this.prisma.fileEntry.update({ where: { id: entryId }, data: { deletedAt: null } });
    return { ok: true };
  }
}
