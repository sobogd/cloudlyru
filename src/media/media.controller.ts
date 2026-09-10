import { Body, Controller, Delete, Get, Param, Post, Query, Req, Res } from '@nestjs/common';
import type { Request, Response } from 'express';
import { MediaService } from './media.service';
import { AlbumsService } from './albums.service';
import { S3Service } from '../s3/s3.service';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService } from '../auth/auth.service';
import { CurrentUser, RequestUser } from '../common/decorators';
import { sendObjectOr404 } from '../common/http-object';
import { asString, isPlainObject } from '../common/utils';
import { badRequest, notFound } from '../common/errors';

/** Превью неизменяемы (ключ = sha256), но приватны — кэширует только браузер пользователя. */
const PREVIEW_CACHE = 'private, max-age=600';

@Controller()
export class MediaController {
  constructor(
    private readonly media: MediaService,
    private readonly albums: AlbumsService,
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly auth: AuthService,
  ) {}

  /**
   * Свой ли это ассет. Чужой и несуществующий не отличаем — оба 404.
   * Раньше эти ручки были @Public(): картинку по одной ссылке мог открыть кто угодно
   * без входа в аккаунт, а следом уходила presigned-ссылка на сам S3.
   */
  private async ownAsset(sha: string, user: RequestUser) {
    const asset = await this.prisma.asset.findUnique({ where: { sha256: sha } });
    if (!asset) return null;
    return (await this.auth.ownsAsset(user.id, asset.id)) ? asset : null;
  }

  /** Превью для списка: ?w=512 (фото — кадр 512, видео — постер). */
  @Get('previews/:sha')
  async preview(
    @Param('sha') sha: string,
    @Query('w') wRaw: string | undefined,
    @CurrentUser() user: RequestUser,
    @Req() req: Request,
    @Res() res: Response,
  ) {
    const asset = await this.ownAsset(sha, user);
    if (!asset) return res.status(404).end();
    const isVideo = String(asset.mime).startsWith('video/') || asset.masterMime === 'video/mp4';
    if (isVideo) {
      const poster = MediaService.videoPosterKey(sha);
      if (!(await this.s3.headObject(poster).catch(() => false))) return res.status(404).end();
      return sendObjectOr404(req, res, this.s3, poster, {
        mime: 'image/webp',
        disposition: 'inline',
        cache: PREVIEW_CACHE,
      });
    }
    // Фото: 512 — сетка, 2048 — полный экран (AVIF; у анимированных источников WebP).
    const wantFull = Number(wRaw ?? 512) === 2048;
    const candidates = wantFull
      ? [MediaService.photoFullKey(sha), MediaService.legacyPhotoFullWebpKey(sha)]
      : [MediaService.gridKey(sha)];
    for (const key of candidates) {
      if (await this.s3.headObject(key).catch(() => false)) {
        const mime = key.endsWith('.avif') ? 'image/avif' : 'image/webp';
        return sendObjectOr404(req, res, this.s3, key, {
          mime,
          disposition: 'inline',
          cache: PREVIEW_CACHE,
        });
      }
    }
    return res.status(404).end();
  }

  /** Превью видео для полного экрана: 1080 (AV1), фолбэк — легаси 720 или сам оригинал. */
  @Get('video-preview/:sha')
  async videoPreview(
    @Param('sha') sha: string,
    @CurrentUser() user: RequestUser,
    @Req() req: Request,
    @Res() res: Response,
  ) {
    const asset = await this.ownAsset(sha, user);
    if (!asset) return res.status(404).end();
    for (const key of [MediaService.video1080Key(sha), MediaService.legacyVideo720Key(sha)]) {
      if (await this.s3.headObject(key).catch(() => false)) {
        return sendObjectOr404(req, res, this.s3, key, {
          mime: 'video/mp4',
          disposition: 'inline',
          cache: PREVIEW_CACHE,
        });
      }
    }
    // превью ещё не собрано — играем оригинал (он и есть мастер). Тип не берём из
    // объявленного при загрузке mime: под ним может приехать что угодно, а отдаём
    // мы это со своего домена.
    return sendObjectOr404(req, res, this.s3, S3Service.assetKey(sha), {
      mime: String(asset.mime).startsWith('video/') ? asset.mime : 'video/mp4',
      disposition: 'inline',
      cache: 'private, no-store',
    });
  }

  /** «Оригинал»: всегда исходный файл, как он был загружен. Только на скачивание. */
  @Get('originals/:sha')
  async original(
    @Param('sha') sha: string,
    @CurrentUser() user: RequestUser,
    @Req() req: Request,
    @Res() res: Response,
  ) {
    const asset = await this.ownAsset(sha, user);
    if (!asset) throw notFound('asset not found');
    const filename = asset.ext ? `original.${asset.ext}` : 'original';
    if (await this.s3.headObject(S3Service.assetKey(sha)).catch(() => false)) {
      return sendObjectOr404(req, res, this.s3, S3Service.assetKey(sha), {
        mime: 'application/octet-stream',
        disposition: 'attachment',
        filename,
      });
    }
    // Легаси: у части старых ассетов оригинал был удалён после конвертации — отдаём мастер.
    const legacy = String(asset.mime).startsWith('video/')
      ? [MediaService.legacyVideoMasterKey(sha), MediaService.video1080Key(sha)]
      : [MediaService.legacyPhotoMasterKey(sha), MediaService.photoFullKey(sha)];
    for (const key of legacy) {
      if (await this.s3.headObject(key).catch(() => false)) {
        const mime = key.endsWith('.avif') ? 'image/avif' : key.endsWith('.mp4') ? 'video/mp4' : 'image/webp';
        const ext = mime === 'image/avif' ? 'avif' : mime === 'video/mp4' ? 'mp4' : 'webp';
        return sendObjectOr404(req, res, this.s3, key, {
          mime: 'application/octet-stream',
          disposition: 'attachment',
          filename: `original.${ext}`,
        });
      }
    }
    return res.status(404).end();
  }

  @Get('timeline')
  timeline(@Query('limit') limit?: string, @Query('before') before?: string) {
    const lim = limit ? Number(limit) : 300;
    return this.media.timeline(Number.isFinite(lim) ? lim : 300, typeof before === 'string' ? before : undefined);
  }

  @Get('trips')
  trips() {
    return this.media.trips();
  }

  @Get('albums')
  listAlbums(@CurrentUser() user: RequestUser) {
    return this.albums.list(user.id);
  }

  @Post('albums')
  createAlbum(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    return this.albums.create(user.id, asString(body.name, 'name'));
  }

  @Get('albums/:id')
  getAlbum(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.albums.get(user.id, id);
  }

  @Post('albums/:id/items')
  addItems(@Param('id') id: string, @Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    if (!isPlainObject(body) || !Array.isArray(body.entryIds)) throw badRequest('entryIds array required');
    return this.albums.addItems(user.id, id, body.entryIds as string[]);
  }

  @Delete('albums/:id')
  removeAlbum(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.albums.remove(user.id, id);
  }

  @Delete('albums/:id/items/:entryId')
  removeItem(@Param('id') id: string, @Param('entryId') entryId: string, @CurrentUser() user: RequestUser) {
    return this.albums.removeItem(user.id, id, entryId);
  }
}
