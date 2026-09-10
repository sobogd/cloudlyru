import { Body, Controller, Delete, Get, Param, Post, Query, Res } from '@nestjs/common';
import type { Response } from 'express';
import { MediaService } from './media.service';
import { AlbumsService } from './albums.service';
import { S3Service } from '../s3/s3.service';
import { PrismaService } from '../prisma/prisma.service';
import { CurrentUser, Public, RequestUser } from '../common/decorators';
import { asString, isPlainObject } from '../common/utils';
import { badRequest, notFound } from '../common/errors';

@Controller()
export class MediaController {
  constructor(
    private readonly media: MediaService,
    private readonly albums: AlbumsService,
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
  ) {}

  /** Превью для списка: ?w=512 (фото — кадр 512, видео — постер). */
  @Public()
  @Get('previews/:sha')
  async preview(@Param('sha') sha: string, @Query('w') wRaw: string | undefined, @Res() res: Response) {
    const asset = await this.prisma.asset.findUnique({ where: { sha256: sha } });
    if (!asset) return res.status(404).end();
    const isVideo = String(asset.mime).startsWith('video/') || asset.masterMime === 'video/mp4';
    if (isVideo) {
      const poster = MediaService.videoPosterKey(sha);
      if (!(await this.s3.headObject(poster).catch(() => false))) return res.status(404).end();
      return res.redirect(302, await this.s3.presignedInline(poster, 'image/webp'));
    }
    // Фото: 512 — сетка, 2048 — полный экран (AVIF; у анимированных источников WebP).
    const wantFull = Number(wRaw ?? 512) === 2048;
    const candidates = wantFull
      ? [MediaService.photoFullKey(sha), MediaService.legacyPhotoFullWebpKey(sha)]
      : [MediaService.gridKey(sha)];
    for (const key of candidates) {
      if (await this.s3.headObject(key).catch(() => false)) {
        const mime = key.endsWith('.avif') ? 'image/avif' : 'image/webp';
        return res.redirect(302, await this.s3.presignedInline(key, mime));
      }
    }
    return res.status(404).end();
  }

  /** Превью видео для полного экрана: 1080 (AV1), фолбэк — легаси 720 или сам оригинал. */
  @Public()
  @Get('video-preview/:sha')
  async videoPreview(@Param('sha') sha: string, @Res() res: Response) {
    const asset = await this.prisma.asset.findUnique({ where: { sha256: sha } });
    if (!asset) return res.status(404).end();
    for (const key of [MediaService.video1080Key(sha), MediaService.legacyVideo720Key(sha)]) {
      if (await this.s3.headObject(key).catch(() => false)) {
        return res.redirect(302, await this.s3.presignedInline(key, 'video/mp4'));
      }
    }
    // превью ещё не собрано — играем оригинал (он и есть мастер)
    return res.redirect(302, await this.s3.presignedInline(S3Service.assetKey(sha), asset.mime));
  }

  /** «Оригинал»: всегда исходный файл, как он был загружен. */
  @Public()
  @Get('originals/:sha')
  async original(@Param('sha') sha: string, @Res() res: Response) {
    const asset = await this.prisma.asset.findUnique({ where: { sha256: sha } });
    if (!asset) throw notFound('asset not found');
    if (await this.s3.headObject(S3Service.assetKey(sha)).catch(() => false)) {
      return res.redirect(302, await this.s3.presignedInline(S3Service.assetKey(sha), asset.mime));
    }
    // Легаси: у части старых ассетов оригинал был удалён после конвертации — отдаём мастер.
    const legacy = String(asset.mime).startsWith('video/')
      ? [MediaService.legacyVideoMasterKey(sha), MediaService.video1080Key(sha)]
      : [MediaService.legacyPhotoMasterKey(sha), MediaService.photoFullKey(sha)];
    for (const key of legacy) {
      if (await this.s3.headObject(key).catch(() => false)) {
        return res.redirect(302, await this.s3.presignedInline(key, key.endsWith('.avif') ? 'image/avif' : key.endsWith('.mp4') ? 'video/mp4' : 'image/webp'));
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
