import { Body, Controller, Delete, Get, Param, Post, Query, Req, Res, UseGuards } from '@nestjs/common';
import type { Request, Response } from 'express';
import { FULL_SIZE, MediaService } from './media.service';
import { AlbumsService } from './albums.service';
import { S3Service } from '../s3/s3.service';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService } from '../auth/auth.service';
import { CurrentUser, RateLimit, RequestUser } from '../common/decorators';
import { RateLimitGuard } from '../common/guards/rate-limit.guard';
import { sendObjectOr404, sendFirstExisting } from '../common/http-object';
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

  /**
   * Превью для списка: ?w=512 (фото — квадрат 50×50, видео — постер 50×50); PDF — ?page=N.
   *
   * Лимит щедрый (3000/мин), но он есть: галерея законно просит сотни превью подряд, а
   * зацикленный клиент или украденная сессия без лимита выедали бы и БД, и S3.
   */
  @Get('previews/:sha')
  @UseGuards(RateLimitGuard)
  @RateLimit(3000, 60_000)
  async preview(
    @Param('sha') sha: string,
    @Query('w') wRaw: string | undefined,
    @Query('page') pageRaw: string | undefined,
    @CurrentUser() user: RequestUser,
    @Req() req: Request,
    @Res() res: Response,
  ) {
    const asset = await this.ownAsset(sha, user);
    if (!asset) return res.status(404).end();
    // Страница PDF: ключ на каждую страницу, нумерация с единицы. Верхнюю границу берём
    // из pageCount, чтобы по ?page=999999 не ходить в S3 впустую.
    const page = Number(pageRaw);
    if (pageRaw !== undefined) {
      if (!Number.isInteger(page) || page < 1 || page > (asset.pageCount ?? 0)) return res.status(404).end();
      return sendObjectOr404(req, res, this.s3, MediaService.pdfPageKey(sha, page), {
        mime: 'image/webp',
        disposition: 'inline',
        cache: PREVIEW_CACHE,
      });
    }
    const isVideo = String(asset.mime).startsWith('video/');
    if (isVideo) {
      const sent = await sendFirstExisting(
        req,
        res,
        this.s3,
        [{ key: MediaService.videoPosterKey(sha), mime: 'image/webp' }],
        { disposition: 'inline', cache: PREVIEW_CACHE },
      );
      return sent ? undefined : res.status(404).end();
    }
    // Фото: сетка (квадрат 50×50) — по умолчанию, полный экран — 1080.
    // Всё, что клиент просит от 1080 и выше, отдаём одним и тем же превью 1080: 2048
    // больше не собирается (это лишний вес на телефоне), а старые клиенты и ассеты
    // со старым превью продолжают работать через легаси-ключи.
    // Кандидаты перебираются во время отдачи (sendFirstExisting): headObject на каждый
    // ключ — это лишний поход в S3 на каждую миниатюру в галерее.
    const wantFull = Number(wRaw ?? 512) >= FULL_SIZE;
    const keys = wantFull
      ? [
          MediaService.photoFullKey(sha),
          MediaService.legacyPhotoFull2048Key(sha),
          MediaService.legacyPhotoFullWebpKey(sha),
        ]
      : [MediaService.gridKey(sha)];
    const sent = await sendFirstExisting(
      req,
      res,
      this.s3,
      keys.map((key) => ({ key, mime: key.endsWith('.avif') ? 'image/avif' : 'image/webp' })),
      { disposition: 'inline', cache: PREVIEW_CACHE },
    );
    return sent ? undefined : res.status(404).end();
  }

  /** Превью видео для полного экрана: 1080 (AV1), фолбэк — легаси 720 или сам оригинал. */
  @Get('video-preview/:sha')
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  async videoPreview(
    @Param('sha') sha: string,
    @Query('src') srcRaw: string | undefined,
    @CurrentUser() user: RequestUser,
    @Req() req: Request,
    @Res() res: Response,
  ) {
    const asset = await this.ownAsset(sha, user);
    if (!asset) return res.status(404).end();
    // ?src=original — фолбэк для браузеров без AV1 (Safari и iOS умеют его лишь частично,
    // с 17.0 и не на всяком железе). Превью 1080 собирается в AV1, и без этого параметра
    // такой браузер остался бы без картинки вовсе: производное есть, но не декодируется.
    if (srcRaw === 'original') {
      if (!String(asset.mime).startsWith('video/')) return res.status(404).end();
      return sendObjectOr404(req, res, this.s3, S3Service.assetKey(sha), {
        mime: String(asset.mime),
        disposition: 'inline',
        cache: 'private, no-store',
      });
    }
    // Кандидаты перебираем самой отдачей: headObject на каждый ключ — лишний поход в S3,
    // а миниатюр на страницу сотни.
    const sent1080 = await sendFirstExisting(
      req,
      res,
      this.s3,
      [
        { key: MediaService.video1080Key(sha), mime: 'video/mp4' },
        { key: MediaService.legacyVideo720Key(sha), mime: 'video/mp4' },
      ],
      { disposition: 'inline', cache: PREVIEW_CACHE },
    );
    if (sent1080) return undefined;
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
  @UseGuards(RateLimitGuard)
  @RateLimit(300, 60_000)
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

  /**
   * Лента «Фото»: `limit` — размер страницы, `cursor` — entryId последней показанной записи.
   * Протухший курсор (запись удалили или перенесли из зоны) — 409 `cursor_stale`; клиент по
   * этому коду откатывается на предыдущую запись, а не считает, что лента кончилась.
   */
  @Get('timeline')
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  timeline(
    @CurrentUser() user: RequestUser,
    @Query('limit') limit?: string,
    @Query('cursor') cursor?: string,
  ) {
    const lim = limit ? Number(limit) : 300;
    return this.media.timeline(
      user.id,
      Number.isFinite(lim) ? lim : 300,
      typeof cursor === 'string' && cursor ? cursor : undefined,
    );
  }

  /**
   * Дни месяца для календаря «Фото»: на каждый день, где есть снимки, — обложка и счётчик.
   * `month` — 'YYYY-MM' (без него текущий месяц). Клиент листает месяцы вручную, поэтому за один
   * запрос отдаётся ровно один месяц: ~30 строк вместо сотен строк ленты.
   */
  @Get('timeline/days')
  @UseGuards(RateLimitGuard)
  @RateLimit(1200, 60_000)
  timelineDays(@CurrentUser() user: RequestUser, @Query('month') month?: string) {
    return this.media.timelineDays(user.id, typeof month === 'string' && month ? month : undefined);
  }

  /**
   * Статусы сборки превью по списку записей: клиент спрашивает только про те снимки, которые
   * ещё собираются, и не перечитывает из-за них всю ленту.
   */
  @Post('timeline/status')
  @UseGuards(RateLimitGuard)
  @RateLimit(1200, 60_000)
  timelineStatus(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    return this.media.timelineStatus(user.id, isPlainObject(body) ? body.entryIds : undefined);
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
