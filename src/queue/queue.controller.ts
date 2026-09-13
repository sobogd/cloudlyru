import { Body, Controller, Get, Logger, Post, Query } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService } from '../auth/auth.service';
import { QueueService } from './queue.service';
import { IMAGE_MIMES, VIDEO_MIMES, PDF_MIMES, mediaKindOf } from '../media/media.service';
import { ZONE_PHOTOS } from '../common/zones';
import { CONVERT_MAX_BYTES } from '../config/env';
import { CurrentUser, RequestUser } from '../common/decorators';
import { asString, isPlainObject } from '../common/utils';
import { badRequest, notFound } from '../common/errors';

/** Типы, для которых превью собираются вообще. */
const MEDIA_MIMES = [...IMAGE_MIMES, ...VIDEO_MIMES, ...PDF_MIMES];
/** Сколько строк задач создаём одним INSERT: в один запрос больше не влезает по bind-параметрам. */
const INSERT_CHUNK = 5000;

@Controller('queue')
export class QueueController {
  private readonly logger = new Logger('QueueApi');

  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
    private readonly queue: QueueService,
  ) {}

  /**
   * Состояние очереди: сколько осталось, сколько в работе и сколько ошибок. Список файлов тут
   * не отдаём — упавшие живут на странице ошибок, а «где ещё нет превью» считает пересчёт.
   */
  @Get('status')
  async status(@CurrentUser() user: RequestUser) {
    const tree = await this.auth.subtreeIds(user.id);
    // Задачи привязаны к ассету, а ассеты дедуплицируются между всеми: показываем те,
    // на которые у пользователя есть живая запись в его дереве.
    const mine = { entries: { some: { folderId: { in: tree }, deletedAt: null } } };
    const [pending, processing, failed] = await Promise.all([
      this.prisma.job.count({ where: { state: 'pending', asset: mine } }),
      this.prisma.job.count({ where: { state: 'processing', asset: mine } }),
      this.prisma.job.count({ where: { state: 'failed', asset: mine } }),
    ]);
    return {
      paused: await this.queue.isPaused(),
      // Остаток — это строки очереди: успешная задача строку не оставляет, упавшая остаётся
      // (видно в ошибках, можно повторить), а «собрать нельзя» в очередь вообще не попадает.
      remaining: pending + processing,
      processing,
      errors: failed,
      // Место на диске сервера: когда его мало, конвертация встаёт — и это должно быть видно
      // в настройках, а не только в логах на сервере (13.09.2026 диск кончился и уронил всё).
      diskFree: this.queue.freeBytes(),
      diskLow: this.queue.diskLow(),
    };
  }

  /**
   * Ошибки конвертации: постранично, с именем файла. Строка остаётся со статусом failed, пока
   * её не разберут — повтор у файла или «повторить все».
   */
  @Get('errors')
  async errors(
    @CurrentUser() user: RequestUser,
    @Query('limit') limit?: string,
    @Query('offset') offset?: string,
  ) {
    const tree = await this.auth.subtreeIds(user.id);
    const take = Math.min(Math.max(Number(limit) || 50, 1), 200);
    const skip = Math.max(Number(offset) || 0, 0);
    const where: Prisma.JobWhereInput = {
      state: 'failed',
      asset: { entries: { some: { folderId: { in: tree }, deletedAt: null } } },
    };
    const [total, rows] = await Promise.all([
      this.prisma.job.count({ where }),
      this.prisma.job.findMany({
        where,
        orderBy: { finishedAt: 'desc' },
        skip,
        take,
        select: {
          id: true,
          kind: true,
          error: true,
          attempts: true,
          finishedAt: true,
          asset: {
            select: {
              entries: {
                where: { folderId: { in: tree }, deletedAt: null },
                take: 1,
                select: { id: true, name: true },
              },
            },
          },
        },
      }),
    ]);
    return {
      total,
      items: rows.map((j) => ({
        id: j.id,
        kind: j.kind,
        error: (j.error ?? '').slice(0, 400),
        attempts: j.attempts,
        finishedAt: j.finishedAt,
        entryId: j.asset.entries[0]?.id ?? null,
        name: j.asset.entries[0]?.name ?? null,
      })),
    };
  }

  /** Вернуть в очередь все упавшие задачи: то же, что «повторить» у файла, но пачкой. */
  @Post('errors/retry')
  async retryErrors(@CurrentUser() user: RequestUser) {
    const tree = await this.auth.subtreeIds(user.id);
    const res = await this.prisma.job.updateMany({
      where: {
        state: 'failed',
        asset: { entries: { some: { folderId: { in: tree }, deletedAt: null } } },
      },
      data: { state: 'pending', error: null, attempts: 0, startedAt: null, finishedAt: null },
    });
    this.logger.log(`ошибки очереди возвращены в работу: ${res.count}`);
    return { retried: res.count };
  }

  /**
   * Пересчёт: найти файлы, у которых превью нет, и поставить им задачи. Ходит только по БД —
   * ни S3, ни пересборки уже собранного: состояние превью лежит на ассете (Asset.previewState),
   * а строку задачи на ассет создаёт один INSERT. Оригинал проверяет воркер: если его нет,
   * ассет помечается «собрать нельзя» и строка уходит из очереди.
   */
  @Post('rebuild')
  async rebuild(@CurrentUser() user: RequestUser) {
    const tree = await this.auth.subtreeIds(user.id);
    // Превью собираются только для медиа-зоны «Фото»: в «Файлах» файл лежит как есть.
    const inPhotos = { entries: { some: { folderId: { in: tree }, deletedAt: null, zone: ZONE_PHOTOS } } };
    const maxMb = Math.round(CONVERT_MAX_BYTES / 1024 / 1024);

    // Сначала закрываем то, что собрать нельзя. Иначе такие файлы каждый пересчёт попадали бы
    // в очередь заново и вечно висели в остатке. Это свойства содержимого — они не изменятся.
    const [bySize, byType] = await Promise.all([
      this.prisma.asset.updateMany({
        where: { ...inPhotos, previewState: 'none', mime: { in: MEDIA_MIMES }, size: { gt: BigInt(CONVERT_MAX_BYTES) } },
        data: { previewState: 'impossible', previewError: `файл больше ${maxMb} МБ` },
      }),
      this.prisma.asset.updateMany({
        where: { ...inPhotos, previewState: 'none', NOT: { mime: { in: MEDIA_MIMES } } },
        data: { previewState: 'impossible', previewError: 'превью для такого типа файла не собираются' },
      }),
    ]);

    // Кому превью положено и у кого нет ни строки в очереди: строка одна на ассет и живёт
    // до успеха, поэтому «нет строки» = «задачи нет».
    const assets = await this.prisma.asset.findMany({
      where: {
        ...inPhotos,
        previewState: 'none',
        mime: { in: MEDIA_MIMES },
        size: { lte: BigInt(CONVERT_MAX_BYTES) },
        jobs: { none: {} },
      },
      select: { id: true, sha256: true, mime: true },
    });
    // Видео ставим через enqueue: ему нужна строка MediaMeta, иначе ролик не появится в ленте.
    const videos = assets.filter((a) => mediaKindOf(a.mime) === 'video');
    for (const v of videos) await this.queue.enqueue(v.id, v.sha256, v.mime);

    // Остальных — пачкой, без запроса на каждый файл.
    const rows = assets
      .filter((a) => mediaKindOf(a.mime) !== 'video')
      .map((a) => ({ assetId: a.id, kind: mediaKindOf(a.mime) as string, state: 'pending' }));
    let queued = videos.length;
    for (let i = 0; i < rows.length; i += INSERT_CHUNK) {
      const res = await this.prisma.job.createMany({ data: rows.slice(i, i + INSERT_CHUNK), skipDuplicates: true });
      queued += res.count;
    }
    this.logger.log(
      `пересчёт: поставлено задач ${queued}, закрыто как «собрать нельзя» ${bySize.count + byType.count} (по размеру ${bySize.count}, по типу ${byType.count})`,
    );
    return { queued, impossible: bySize.count + byType.count };
  }

  /**
   * Пауза конвертации. Мягкая: очередь перестаёт брать новые задачи, текущая докачивается
   * (прерванный AV1-энкод — это часы работы впустую), PDF останавливается между страницами.
   * Флаг лежит в БД, поэтому переживает рестарт и действует для всех процессов.
   */
  @Post('pause')
  async pause(@Body() body: Record<string, unknown>) {
    if (!isPlainObject(body) || typeof body.paused !== 'boolean') throw badRequest('paused: boolean required');
    return { paused: await this.queue.setPaused(body.paused) };
  }

  /**
   * Пересобрать превью одного файла: он остался без превью после упавшей задачи.
   * Файл свой и не в корзине — иначе 404.
   */
  @Post('retry')
  async retry(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    if (!isPlainObject(body)) throw badRequest('body must be an object');
    const entryId = asString(body.entryId, 'entryId');
    const tree = await this.auth.subtreeIds(user.id);
    const entry = await this.prisma.fileEntry.findFirst({
      where: { id: entryId, deletedAt: null, folderId: { in: tree } },
      select: { assetId: true },
    });
    if (!entry?.assetId) throw notFound('file not found');
    const res = await this.queue.retryPreview(entry.assetId);
    if (!res.ok) throw badRequest(res.reason, 'cannot_retry');
    return { ok: true };
  }
}
