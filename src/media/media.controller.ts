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

  /** Превью WebP: ?w=512 (сетка; для видео — постер) | ?w=2048 (полный экран фото). */
  @Public()
  @Get('previews/:sha')
  async preview(@Param('sha') sha: string, @Query('w') wRaw: string | undefined, @Res() res: Response) {
    const asset = await this.prisma.asset.findUnique({ where: { sha256: sha } });
    if (!asset) return res.status(404).end();
    const isVideo = asset.masterMime === 'video/mp4' || String(asset.mime).startsWith('video/');
    const w = Number(wRaw ?? 512);
    let key: string | null = null;
    if (w === 512) key = isVideo ? MediaService.videoPosterKey(sha) : MediaService.gridKey(sha);
    else if (w === 2048 && !isVideo) key = MediaService.fullKey(sha);
    if (!key || !(await this.s3.headObject(key))) return res.status(404).end();
    return res.redirect(302, await this.s3.presignedInline(key, 'image/webp'));
  }

  /** 720p-превью видео (просмотр); фолбэк — мастер AV1. */
  @Public()
  @Get('video-preview/:sha')
  async videoPreview(@Param('sha') sha: string, @Res() res: Response) {
    const asset = await this.prisma.asset.findUnique({ where: { sha256: sha } });
    if (!asset) return res.status(404).end();
    let url: string;
    if (await this.s3.headObject(MediaService.video720Key(sha))) {
      url = await this.s3.presignedInline(MediaService.video720Key(sha), 'video/mp4');
    } else if (asset.masterMime === 'video/mp4' && (await this.s3.headObject(MediaService.videoMasterKey(sha)))) {
      url = await this.s3.presignedInline(MediaService.videoMasterKey(sha), 'video/mp4');
    } else {
      return res.status(404).end();
    }
    return res.redirect(302, url);
  }

  /** «Оригинал»: AVIF (фото) / AV1 mp4 (видео) мастер; фолбэк — сырьё. */
  @Public()
  @Get('originals/:sha')
  async original(@Param('sha') sha: string, @Res() res: Response) {
    const asset = await this.prisma.asset.findUnique({ where: { sha256: sha } });
    if (!asset) throw notFound('asset not found');
    let key: string | null = null;
    let mime = 'application/octet-stream';
    if (asset.masterMime === 'image/avif' && (await this.s3.headObject(MediaService.photoMasterKey(sha)))) {
      key = MediaService.photoMasterKey(sha);
      mime = 'image/avif';
    } else if (asset.masterMime === 'video/mp4' && (await this.s3.headObject(MediaService.videoMasterKey(sha)))) {
      key = MediaService.videoMasterKey(sha);
      mime = 'video/mp4';
    }
    const url = key ? await this.s3.presignedInline(key, mime) : await this.s3.presignedGet(S3Service.assetKey(sha), asset.mime);
    return res.redirect(302, url);
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
