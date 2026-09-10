import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { MediaService } from '../media/media.service';
import { ROOT_FOLDER_NAME } from '../auth/auth.service';
import { assertSafeName } from '../common/utils';
import { ZONE_FILES, ZONE_PHOTOS } from '../common/zones';
import { conflict, notFound } from '../common/errors';

@Injectable()
export class FilesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly media: MediaService,
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

  /**
   * Метаданные Google Takeout рядом с файлом: <имя>.supplemental-metadata.json
   * (или <имя>.json в старых экспортах) — дата съёмки, описание, источник.
   */
  private async findSidecar(folderId: string, name: string) {
    const row = await this.prisma.fileEntry.findFirst({
      where: { folderId, deletedAt: null, name: { in: [`${name}.supplemental-metadata.json`, `${name}.json`] } },
      include: { asset: { select: { sha256: true, size: true } } },
    });
    if (!row) return null;
    try {
      const buf = await this.s3.getObjectBytes(S3Service.assetKey(row.asset.sha256), 1024 * 1024);
      const j = JSON.parse(buf.toString('utf8')) as Record<string, any>;
      const iso = (t: any): string | null =>
        t && t.timestamp ? new Date(Number(t.timestamp) * 1000).toISOString() : null;
      return {
        name: row.name,
        entryId: row.id,
        title: j.title ?? null,
        description: j.description ?? null,
        photoTakenTime: j.photoTakenTime?.formatted ?? null,
        photoTakenTimeIso: iso(j.photoTakenTime),
        creationTime: j.creationTime?.formatted ?? null,
        creationTimeIso: iso(j.creationTime),
        imageViews: typeof j.imageViews === 'string' ? Number(j.imageViews) : (j.imageViews ?? null),
        geoData: j.geoData ?? null,
        origin: j.googlePhotosOrigin ?? null,
        url: j.url ?? null,
      };
    } catch {
      return null;
    }
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

    const sidecar = await this.findSidecar(entry.folderId, entry.name);
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
      sidecar,
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

  /** Presigned-URL для скачивания. Фото-зона: оптимизированный мастер; файлы-зона: оригинал как есть. */
  async presignedUrl(entryId: string): Promise<string> {
    const entry = await this.prisma.fileEntry.findUnique({
      where: { id: entryId },
      include: { asset: true },
    });
    if (!entry || entry.deletedAt) throw notFound('file not found');
    const { asset } = entry;
    const masterMime = entry.asset.masterMime === 'image/avif' || entry.asset.masterMime === 'video/mp4' ? entry.asset.masterMime : null;

    if (masterMime && asset.masterReadyAt) {
      const masterKey = masterMime === 'image/avif' ? MediaService.photoMasterKey(asset.sha256) : MediaService.videoMasterKey(asset.sha256);
      // фото-зона: мастер; файлы-зона: оригинал, если жив в S3 (у легаси-медиа сырьё могло быть удалено)
      if (entry.zone === ZONE_PHOTOS) return this.s3.presignedInline(masterKey, masterMime);
      const rawAlive = await this.s3.headObject(S3Service.assetKey(asset.sha256)).catch(() => false);
      if (!rawAlive) return this.s3.presignedInline(masterKey, masterMime);
    }
    return this.s3.presignedGet(S3Service.assetKey(asset.sha256), asset.mime);
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
