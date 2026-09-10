import { Controller, Get } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService } from '../auth/auth.service';
import { CurrentUser, RequestUser } from '../common/decorators';

@Controller('queue')
export class QueueController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
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
}
