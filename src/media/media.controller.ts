import { Body, Controller, Delete, Get, Param, Post, Query, Req, Res, UseGuards } from '@nestjs/common';
import type { Request, Response } from 'express';
import { FULL_SIZE, MediaService, VIDEO_MIMES, isVideoMime } from './media.service';
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

/**
 * Тип, под которым отдаём оригинал видео inline. Только из белого списка: `normalizeMime`
 * пропускает любой `video/*`, то есть объявленный клиентом тип доверять нельзя (иначе это
 * готовый stored XSS на своём домене), а `nosniff` спасает лишь от исполнения чужого типа —
 * Content-Type мы ставим сами. Незнакомое значение сводим к `video/mp4`.
 */
function inlineVideoMime(mime: unknown): string {
  const m = String(mime ?? '').toLowerCase();
  return VIDEO_MIMES.includes(m) ? m : 'video/mp4';
}

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
   * Раньше (до коммита 407a490) эти ручки были @Public(), и картинку по одной ссылке мог
   * открыть кто угодно без входа в аккаунт, а следом уходила presigned-ссылка на сам S3;
   * сейчас шаринга и presigned-отдачи нет, но проверка владельца осталась.
   *
   * Проверка одним запросом по поддереву, а не через `auth.ownsAsset`: тот сначала поднимает
   * все записи ассета, а потом на каждую поднимается по дереву папок — на галерею в 500 плиток
   * это лишняя тысяча запросов к БД.
   */
  private async ownAsset(sha: string, user: RequestUser) {
    const asset = await this.prisma.asset.findUnique({
      where: { sha256: sha },
      select: { id: true, mime: true, ext: true, pageCount: true },
    });
    if (!asset) return null;
    const tree = await this.auth.subtreeIds(user.id);
    if (!tree.length) return null;
    const entry = await this.prisma.fileEntry.findFirst({
      where: { assetId: asset.id, deletedAt: null, folderId: { in: tree } },
      select: { id: true },
    });
    return entry ? asset : null;
  }

  /**
   * Превью для списка или для полного экрана: `?w` — порог размера (фото: `w >= 1080` —
   * полноэкранное 1080, всё меньшее — квадрат сетки GRID_SIZE×GRID_SIZE; видео — постер
   * сетки). Промежуточных размеров нет: в S3 лежат ровно два производных на ассет, поэтому
   * `?w=512` (значение по умолчанию у клиента) — это тот же сеточный вариант, а не отдельный
   * размер. PDF — `?page=N` (страница рисуется только в 1080).
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
    // Фото: сетка (квадрат GRID_SIZE×GRID_SIZE) — по умолчанию, полный экран — 1080.
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

  /** Превью видео для полного экрана: 1080 (H.264, у старых ассетов — AV1), фолбэк — легаси 720 или сам оригинал. */
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
    // ?src=original — фолбэк для браузеров, которым превью не по зубам: собирается оно сейчас
    // в H.264 (играется везде), но у ассетов, пересобранных до этого, в S3 лежит AV1, а Safari
    // и iOS умеют его лишь с 17.0 и не на всяком железе. Производное при этом есть — просто
    // не декодируется, поэтому без параметра такой браузер остаётся без картинки.
    // (Приложение «Медиа» этот параметр пока не передаёт — страховка работает только у тех
    // клиентов, кто её просит: см. деталку файла, где фолбэк двухстадийный.)
    if (srcRaw === 'original') {
      // только видео: оригинал фото отдаётся ручкой `/originals/:sha` (на скачивание)
      if (!isVideoMime(asset.mime)) return res.status(404).end();
      return sendObjectOr404(req, res, this.s3, S3Service.assetKey(sha), {
        mime: inlineVideoMime(asset.mime),
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
    // превью ещё не собрано — играем оригинал (он и есть мастер). Тип берём из белого списка
    // видео, а не из того, что объявил клиент при загрузке: `normalizeMime` пропускает любой
    // `video/*`, и под ним со своего домена может уехать что угодно (nosniff тут не помогает:
    // браузер поверит нашему Content-Type).
    return sendObjectOr404(req, res, this.s3, S3Service.assetKey(sha), {
      mime: inlineVideoMime(asset.mime),
      disposition: 'inline',
      cache: 'private, no-store',
    });
  }

  /**
   * «Оригинал»: исходный файл, как он был загружен. Только на скачивание.
   *
   * Если оригинала в S3 уже нет (легаси: его удаляли после конвертации), отдаём производное,
   * но помечаем это заголовком `X-Cloudly-Original: derived` — иначе «Скачать оригинал»
   * молча отдаёт урезанную картинку, и отличить её от настоящего оригинала нечем.
   */
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
      res.setHeader('X-Cloudly-Original', 'stored');
      return sendObjectOr404(req, res, this.s3, S3Service.assetKey(sha), {
        mime: 'application/octet-stream',
        disposition: 'attachment',
        filename,
      });
    }
    // Легаси: у части старых ассетов оригинал был удалён после конвертации — отдаём мастер.
    const legacy = isVideoMime(asset.mime)
      ? [MediaService.legacyVideoMasterKey(sha), MediaService.video1080Key(sha)]
      : [MediaService.legacyPhotoMasterKey(sha), MediaService.photoFullKey(sha)];
    for (const key of legacy) {
      if (await this.s3.headObject(key).catch(() => false)) {
        const mime = key.endsWith('.avif') ? 'image/avif' : key.endsWith('.mp4') ? 'video/mp4' : 'image/webp';
        const ext = mime === 'image/avif' ? 'avif' : mime === 'video/mp4' ? 'mp4' : 'webp';
        res.setHeader('X-Cloudly-Original', 'derived');
        return sendObjectOr404(req, res, this.s3, key, {
          mime: 'application/octet-stream',
          disposition: 'attachment',
          filename: `original.${ext}`,
        });
      }
    }
    return res.status(404).end();
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
