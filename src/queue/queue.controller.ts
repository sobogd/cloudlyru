import { Body, Controller, Get, Post } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService } from '../auth/auth.service';
import { S3Service } from '../s3/s3.service';
import { QueueService } from './queue.service';
import { PDF_MIMES, mediaKindOf } from '../media/media.service';
import { CurrentUser, RequestUser } from '../common/decorators';
import { asString, isPlainObject } from '../common/utils';
import { badRequest, notFound } from '../common/errors';

@Controller('queue')
export class QueueController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
    private readonly queue: QueueService,
    private readonly s3: S3Service,
  ) {}

  /** Статус очереди конвертации (для UI-монитора) — только по своим файлам. */
  @Get('status')
  async status(@CurrentUser() user: RequestUser) {
    const tree = await this.auth.subtreeIds(user.id);
    // job'ы привязаны к ассету, а ассеты дедуплицируются между всеми: показываем те,
    // на которые у пользователя есть живая запись в его дереве
    const mine = { entries: { some: { folderId: { in: tree }, deletedAt: null } } };
    const [groups, processing, recent] = await Promise.all([
      this.prisma.job.groupBy({ by: ['state'], _count: true, where: { asset: mine } }),
      this.prisma.job.findFirst({
        where: { state: 'processing', asset: mine },
        orderBy: { startedAt: 'asc' },
        include: { asset: true },
      }),
      this.prisma.job.findMany({
        where: { asset: mine },
        orderBy: { updatedAt: 'desc' },
        take: 15,
        include: { asset: { select: { sha256: true, masterReadyAt: true } } },
      }),
    ]);
    const byState: Record<string, number> = { pending: 0, processing: 0, done: 0, failed: 0 };
    for (const g of groups) byState[g.state] = g._count;

    return {
      paused: await this.queue.isPaused(),
      byState,
      processing: processing
        ? {
            id: processing.id,
            kind: processing.kind,
            sha256: processing.asset.sha256.slice(0, 10),
            startedMinAgo: Math.max(0, Math.round((Date.now() - (processing.startedAt?.getTime() ?? Date.now())) / 60000)),
            progress: processing.progress,
          }
        : null,
      recent: recent.map((j) => ({
        id: j.id,
        kind: j.kind,
        state: j.state,
        error: j.state === 'failed' ? (j.error || '').slice(0, 220) : null,
        updatedAt: j.updatedAt,
        sha256: j.asset.sha256.slice(0, 10),
        progress: j.progress,
        masterReady: Boolean(j.asset.masterReadyAt),
      })),
    };
  }

  /**
   * Что именно означает «нет превью»: ассет своего дерева, который конвейер так и не
   * обработал, либо PDF без отрисованных страниц. Одно условие на счётчик и на пересбор,
   * иначе кнопка и число рядом с ней говорили бы о разном.
   */
  private missingWhere(tree: string[]): Prisma.AssetWhereInput {
    return {
      entries: { some: { folderId: { in: tree }, deletedAt: null } },
      OR: [
        { masterReadyAt: null },
        // PDF мог отрисоваться частично (страницы добираются задачами): догоняем остаток
        { mime: { in: PDF_MIMES }, pageCount: null },
      ],
    };
  }

  /** Сколько файлов осталось без превью — число для кнопки пересбора (без походов в S3). */
  @Get('missing')
  async missing(@CurrentUser() user: RequestUser) {
    const tree = await this.auth.subtreeIds(user.id);
    const groups = await this.prisma.asset.groupBy({
      by: ['mime'],
      _count: true,
      where: this.missingWhere(tree),
    });
    const byKind: Record<string, number> = { photo: 0, video: 0, pdf: 0 };
    let total = 0;
    for (const g of groups) {
      const kind = mediaKindOf(g.mime);
      if (!kind) continue; // типы, для которых превью не собираются вообще
      byKind[kind] += g._count;
      total += g._count;
    }
    return { total, byKind };
  }

  /**
   * Пересобрать превью у уже загруженных файлов: очередь ставит задачи тем ассетам своего
   * дерева, у которых превью так и не собрались (в т.ч. всем PDF — до появления их рендера
   * они лежали без превью). Дальше это видно в /queue/status.
   */
  @Post('rebuild')
  async rebuild(@CurrentUser() user: RequestUser) {
    const tree = await this.auth.subtreeIds(user.id);
    const assets = await this.prisma.asset.findMany({
      where: this.missingWhere(tree),
      select: { id: true, sha256: true, mime: true },
    });
    let queued = 0;
    let skipped = 0;
    // Проверяем оригиналы пачками: на большой медиатеке последовательные HEAD-запросы
    // к S3 растянули бы ответ ручки на минуты.
    const candidates = assets.filter((a) => mediaKindOf(a.mime));
    skipped += assets.length - candidates.length;
    for (let i = 0; i < candidates.length; i += 8) {
      const chunk = candidates.slice(i, i + 8);
      const alive = await Promise.all(
        chunk.map((a) => this.s3.headObject(S3Service.assetKey(a.sha256)).catch(() => false)),
      );
      for (let j = 0; j < chunk.length; j++) {
        // без оригинала превью не собрать: он единственный источник пикселей
        if (!alive[j]) {
          skipped++;
          continue;
        }
        await this.queue.enqueue(chunk[j].id, chunk[j].sha256, chunk[j].mime);
        queued++;
      }
    }
    return { queued, skipped, total: assets.length };
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
   * Очистить очередь: отменить всё, что ждёт, и остановить текущую задачу. Жёстче паузы —
   * активный процесс убивается, иначе очередь не опустеет. Собранные превью не трогаются,
   * так что отменённое можно вернуть кнопкой пересбора.
   */
  @Post('cancel')
  async cancel(@CurrentUser() user: RequestUser) {
    const tree = await this.auth.subtreeIds(user.id);
    return { cancelled: await this.queue.cancelAll(tree) };
  }

  /**
   * Пересобрать превью: файл остался без превью после падения задачи (или задача
   * была отменена при удалении в корзину). Файл свой и не в корзине — иначе 404.
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
