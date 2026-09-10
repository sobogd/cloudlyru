import { Body, Controller, Get, Post } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService } from '../auth/auth.service';
import { QueueService } from './queue.service';
import { CurrentUser, RequestUser } from '../common/decorators';
import { asString, isPlainObject } from '../common/utils';
import { badRequest, notFound } from '../common/errors';

@Controller('queue')
export class QueueController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
    private readonly queue: QueueService,
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
