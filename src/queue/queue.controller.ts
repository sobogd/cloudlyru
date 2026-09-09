import { Controller, Get } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';

@Controller('queue')
export class QueueController {
  constructor(private readonly prisma: PrismaService) {}

  /** Статус очереди конвертации (для UI-монитора). */
  @Get('status')
  async status() {
    const [groups, processing, recent] = await Promise.all([
      this.prisma.job.groupBy({ by: ['state'], _count: true }),
      this.prisma.job.findFirst({
        where: { state: 'processing' },
        orderBy: { startedAt: 'asc' },
        include: { asset: true },
      }),
      this.prisma.job.findMany({
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
