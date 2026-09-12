import { Body, Controller, Get, Logger, Post, Query } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService } from '../auth/auth.service';
import { S3Service } from '../s3/s3.service';
import { QueueService } from './queue.service';
import { IMAGE_MIMES, VIDEO_MIMES, PDF_MIMES, mediaKindOf } from '../media/media.service';
import { CurrentUser, RequestUser } from '../common/decorators';
import { asString, isPlainObject } from '../common/utils';
import { badRequest, notFound } from '../common/errors';

@Controller('queue')
export class QueueController {
  private readonly logger = new Logger('QueueApi');

  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
    private readonly queue: QueueService,
    private readonly s3: S3Service,
  ) {}

  /**
   * Статус очереди: цифры, скорость и остаток. Список файлов здесь не отдаём — для ошибок
   * есть отдельная ручка /queue/errors, а прогресс считается как «собрано из всего, что
   * требует превью».
   */
  @Get('status')
  async status(@CurrentUser() user: RequestUser) {
    const tree = await this.auth.subtreeIds(user.id);
    // job'ы привязаны к ассету, а ассеты дедуплицируются между всеми: показываем те,
    // на которые у пользователя есть живая запись в его дереве
    const mine = { entries: { some: { folderId: { in: tree }, deletedAt: null } } };
    const [groups, processingRows, doneCount, missingGroups, errorCount, speed] = await Promise.all([
      this.prisma.job.groupBy({ by: ['state', 'kind'], _count: true, where: { asset: mine } }),
      this.prisma.job.findMany({
        where: { state: 'processing', asset: mine },
        orderBy: { startedAt: 'asc' },
        select: {
          id: true,
          kind: true,
          progress: true,
          startedAt: true,
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
      this.prisma.asset.count({ where: { ...this.mediaWhere(tree), masterReadyAt: { not: null } } }),
      this.prisma.asset.groupBy({ by: ['mime'], _count: true, where: this.missingWhere(tree) }),
      this.prisma.job.count({ where: { state: 'failed', asset: mine, ...this.realErrorWhere() } }),
      this.speedByKind(tree),
    ]);

    const counts = { pending: 0, processing: 0, done: 0, failed: 0, cancelled: 0 };
    const byKind: Record<string, { pending: number }> = { photo: { pending: 0 }, video: { pending: 0 }, pdf: { pending: 0 } };
    let failedTotal = 0;
    for (const g of groups) {
      if (!(g.state in counts)) continue;
      counts[g.state as keyof typeof counts] += g._count;
      if (g.state === 'pending' && byKind[g.kind]) byKind[g.kind].pending += g._count;
      if (g.state === 'failed') failedTotal += g._count;
    }
    // «отменённые» — это не ошибки: их снял пользователь (очистка очереди, удаление файла)
    counts.cancelled = Math.max(0, failedTotal - errorCount);
    counts.failed = errorCount;

    // сколько всего требует превью = уже собранные + те, у кого превью нет
    let missing = 0;
    for (const g of missingGroups) if (mediaKindOf(g.mime)) missing += g._count;

    // Остаток по видам. Фото идут параллельно, видео и PDF — по одному, поэтому время
    // фото делится на число слотов; суммарный остаток — максимум, а не сумма: виды
    // считаются одновременно и не ждут друг друга.
    const par = this.queue.parallelism;
    const etaSec: Record<string, number | null> = { photo: null, video: null, pdf: null, total: null };
    for (const kind of ['photo', 'video', 'pdf'] as const) {
      const sp = speed[kind];
      const pend = byKind[kind].pending;
      if (!sp || !pend) continue;
      const slots = kind === 'photo' ? Math.max(1, par.photo) : 1;
      etaSec[kind] = Math.round((sp.avgSec * pend) / slots);
    }
    // Как складывать общий остаток, зависит от порядка работ: PDF идёт вместе с фото,
    // а видео — только после фото (если не разрешено параллельно). Поэтому либо максимум
    // по видам (они идут одновременно), либо сумма фото и видео.
    const maxAlong = Math.max(etaSec.photo ?? 0, etaSec.video ?? 0, etaSec.pdf ?? 0);
    etaSec.total = par.videoAlongsidePhotos
      ? maxAlong || null
      : ((etaSec.photo ?? 0) + (etaSec.video ?? 0)) || maxAlong || null;

    return {
      paused: await this.queue.isPaused(),
      counts,
      progress: { done: doneCount, total: doneCount + missing },
      byKind,
      speed,
      etaSec,
      parallelism: par,
      processing: processingRows.map((j) => ({
        id: j.id,
        kind: j.kind,
        progress: j.progress,
        startedSecAgo: Math.max(0, Math.round((Date.now() - (j.startedAt?.getTime() ?? Date.now())) / 1000)),
        entryId: j.asset.entries[0]?.id ?? null,
        name: j.asset.entries[0]?.name ?? null,
      })),
      errors: { total: errorCount },
    };
  }

  /** Ошибка конвертации — всё, кроме отменённых вручную задач. */
  private realErrorWhere(): Prisma.JobWhereInput {
    return { OR: [{ error: null }, { error: { not: { startsWith: 'cancelled' } } }] };
  }

  /** Ассеты под превью: картинки, видео и PDF. */
  private mediaWhere(tree: string[]): Prisma.AssetWhereInput {
    return {
      entries: { some: { folderId: { in: tree }, deletedAt: null } },
      OR: [
        { mime: { in: IMAGE_MIMES } },
        { mime: { in: VIDEO_MIMES } },
        { mime: { in: PDF_MIMES } },
      ],
    };
  }

  /**
   * Средняя длительность задачи по видам. Окно у видов разное, и это важно: фото считаются
   * секунды, поэтому за 15 минут данных достаточно; видео идёт часами, и в короткое окно
   * его задачи просто не попадают — по нему смотрим сутки. Результат кэшируется на 10 секунд:
   * статус спрашивают каждые пару секунд.
   */
  private speedCache: { at: number; value: Record<string, { avgSec: number; perMin: number }> } | null = null;

  private async speedByKind(tree: string[]): Promise<Record<string, { avgSec: number; perMin: number }>> {
    if (this.speedCache && Date.now() - this.speedCache.at < 10_000) return this.speedCache.value;
    const mine = { entries: { some: { folderId: { in: tree }, deletedAt: null } } };
    const since = (ms: number) => new Date(Date.now() - ms);
    const [fast, slow] = await Promise.all([
      this.prisma.job.findMany({
        where: { state: 'done', startedAt: { not: null }, finishedAt: { gt: since(15 * 60 * 1000) }, kind: { in: ['photo', 'pdf'] }, asset: mine },
        orderBy: { finishedAt: 'desc' },
        take: 500,
        select: { kind: true, startedAt: true, finishedAt: true },
      }),
      this.prisma.job.findMany({
        where: { state: 'done', startedAt: { not: null }, finishedAt: { gt: since(24 * 60 * 60 * 1000) }, kind: 'video', asset: mine },
        orderBy: { finishedAt: 'desc' },
        take: 200,
        select: { kind: true, startedAt: true, finishedAt: true },
      }),
    ]);
    const windowMin: Record<string, number> = { photo: 15, pdf: 15, video: 24 * 60 };
    const acc: Record<string, { n: number; sec: number }> = {};
    for (const r of [...fast, ...slow]) {
      if (!r.startedAt || !r.finishedAt) continue;
      const sec = (r.finishedAt.getTime() - r.startedAt.getTime()) / 1000;
      if (!Number.isFinite(sec) || sec < 0) continue;
      const a = (acc[r.kind] ??= { n: 0, sec: 0 });
      a.n += 1;
      a.sec += sec;
    }
    const value: Record<string, { avgSec: number; perMin: number }> = {};
    for (const [kind, a] of Object.entries(acc)) {
      if (!a.n) continue;
      value[kind] = {
        avgSec: Math.round((a.sec / a.n) * 10) / 10,
        perMin: Math.round((a.n / (windowMin[kind] ?? 15)) * 10) / 10,
      };
    }
    this.speedCache = { at: Date.now(), value };
    return value;
  }

  /**
   * Ошибки очереди: постранично, с именем файла. Отменённые задачи (очистка очереди,
   * удаление файла) по умолчанию не показываем — это не ошибки конвертации.
   */
  @Get('errors')
  async errors(
    @CurrentUser() user: RequestUser,
    @Query('limit') limit?: string,
    @Query('offset') offset?: string,
    @Query('include') include?: string,
  ) {
    const tree = await this.auth.subtreeIds(user.id);
    const take = Math.min(Math.max(Number(limit) || 50, 1), 200);
    const skip = Math.max(Number(offset) || 0, 0);
    const where: Prisma.JobWhereInput = {
      state: 'failed',
      asset: { entries: { some: { folderId: { in: tree }, deletedAt: null } } },
      ...(include === 'cancelled' ? {} : this.realErrorWhere()),
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

  /** Вернуть в очередь все настоящие ошибки: то же, что «повторить» у файла, но пачкой. */
  @Post('errors/retry')
  async retryErrors(@CurrentUser() user: RequestUser) {
    const tree = await this.auth.subtreeIds(user.id);
    const rows = await this.prisma.job.findMany({
      where: {
        state: 'failed',
        asset: { entries: { some: { folderId: { in: tree }, deletedAt: null } } },
        ...this.realErrorWhere(),
      },
      select: { id: true, asset: { select: { sha256: true } } },
    });
    if (!rows.length) return { retried: 0, skipped: 0 };
    // Оригинал мог исчезнуть (KEEP_ORIGINALS=false): без него задача снова упадёт три раза.
    // HEAD-запросы идут пачками, иначе на сотнях задач ручка отвечала бы минутами.
    const alive: string[] = [];
    let skipped = 0;
    for (let i = 0; i < rows.length; i += 8) {
      const chunk = rows.slice(i, i + 8);
      const heads = await Promise.all(chunk.map((r) => this.s3.headObject(S3Service.assetKey(r.asset.sha256)).catch(() => false)));
      chunk.forEach((r, j) => (heads[j] ? alive.push(r.id) : (skipped += 1)));
    }
    // Пачками по 5000: список id в одном UPDATE упирается в предел Postgres по bind-параметрам
    for (let i = 0; i < alive.length; i += 5000) {
      await this.prisma.job.updateMany({
        where: { id: { in: alive.slice(i, i + 5000) } },
        data: { state: 'pending', error: null, attempts: 0, progress: 0, startedAt: null, finishedAt: null },
      });
    }
    this.logger.log(`ошибки очереди возвращены в работу: ${alive.length}${skipped ? `, пропущено ${skipped}` : ''}`);
    return { retried: alive.length, skipped };
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
