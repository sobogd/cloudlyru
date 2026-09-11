import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService } from '../auth/auth.service';
import { badRequest } from '../common/errors';

/** Максимум строк журнала за один запрос: клиент догоняет пачками. */
const MAX_CHANGES = 500;
const DEFAULT_CHANGES = 200;
/** Максимум sha256 в одном запросе /sync/have. */
const MAX_HAVE = 500;

export interface SyncChangeDto {
  seq: string;
  target: 'entry' | 'folder';
  op: string;
  targetId: string;
  folderId: string | null;
  name: string;
  zone: string | null;
  sha256: string | null;
  size: number | null;
  mime: string | null;
  clientMtime: string | null;
  keepOffline: boolean;
  /** id ApiToken'а устройства-источника правки; null — правку сделал веб или фон. */
  deviceId: string | null;
  at: string;
}

export interface SyncChangesDto {
  /** С какого seq клиент догоняет состояние (что он прислал). */
  since: string;
  /** Последний отданный seq — его и надо сохранить как курсор. */
  nextSeq: string;
  /** Есть ли ещё строки (клиент должен запросить снова, не дожидаясь следующего прохода). */
  hasMore: boolean;
  /** Самый старый доступный seq журнала: если курсор клиента младше — нужен полный рескан. */
  minSeq: string | null;
  resetRequired: boolean;
  changes: SyncChangeDto[];
}

/** sha256 в нижнем регистре; всё, что не 64 hex-символа, отбрасываем. */
function normalizeSha(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined;
  const s = v.trim().toLowerCase();
  return /^[0-9a-f]{64}$/.test(s) ? s : undefined;
}

/**
 * API синхронизации: журнал изменений с курсором, проверка «что уже есть» и вспомогательные
 * ручки. Клиент (Android) держит курсор по seq и никогда не сканирует дерево целиком,
 * кроме первого раза.
 */
@Injectable()
export class SyncService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
  ) {}

  async changes(userId: string, sinceRaw: unknown, limitRaw: unknown): Promise<SyncChangesDto> {
    const since = this.parseSeq(sinceRaw);
    const limit = this.parseLimit(limitRaw);

    const [rows, oldest, newest] = await Promise.all([
      this.prisma.changeLog.findMany({
        where: { userId, seq: { gt: BigInt(since) } },
        orderBy: { seq: 'asc' },
        take: limit + 1,
      }),
      this.prisma.changeLog.findFirst({
        where: { userId },
        orderBy: { seq: 'asc' },
        select: { seq: true },
      }),
      this.prisma.changeLog.findFirst({
        where: { userId },
        orderBy: { seq: 'desc' },
        select: { seq: true },
      }),
    ]);

    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;
    const minSeq = oldest ? oldest.seq.toString() : null;
    const maxSeq = newest ? newest.seq.toString() : null;
    const sinceN = BigInt(since);
    // Полный рескан обязателен, если по этому курсору часть изменений уже не восстановить:
    //  • курсор старше самого старого события (журнал подрезали по retention);
    //  • журнал пуст, а курсор ненулевой (всё вычищено);
    //  • курсор впереди журнала (БД восстановили из бэкапа, клиента переключили на другой
    //    инстанс) — без этого клиент залипает навсегда: новые seq меньше его курсора.
    const resetRequired =
      (minSeq === null && sinceN > 0n) ||
      (maxSeq !== null && sinceN > BigInt(maxSeq)) ||
      (minSeq !== null && sinceN + 1n < BigInt(minSeq));

    return {
      since: String(since),
      nextSeq: page.length ? page[page.length - 1].seq.toString() : String(since),
      hasMore,
      minSeq,
      resetRequired,
      changes: page.map((c) => ({
        seq: c.seq.toString(),
        target: c.target === 'folder' ? 'folder' : 'entry',
        op: c.op,
        targetId: c.targetId,
        folderId: c.folderId,
        name: c.name,
        zone: c.zone,
        sha256: c.sha256,
        size: c.size === null ? null : Number(c.size),
        mime: c.mime,
        clientMtime: c.clientMtime ? c.clientMtime.toISOString() : null,
        keepOffline: c.keepOffline,
        // клиент сравнивает с собственным deviceId из /auth/me и не применяет свои же правки
        deviceId: c.deviceId,
        at: c.at.toISOString(),
      })),
    };
  }

  /**
   * Текущая голова журнала: с неё клиент начинает догон после полного прохода по папке.
   * Отдельная ручка, а не `changes` без `since`: курсор и голова — разные вещи, и клиенту
   * нужна именно голова, снятая ДО полного прохода (иначе правки во время прохода потеряются).
   */
  async head(userId: string): Promise<{ seq: string }> {
    const newest = await this.prisma.changeLog.findFirst({
      where: { userId },
      orderBy: { seq: 'desc' },
      select: { seq: true },
    });
    return { seq: newest ? newest.seq.toString() : '0' };
  }

  /**
   * Что из списка содержимого у пользователя уже есть. Нужен на первом скане: без него
   * телефон, переустановивший приложение, посылает по одному init на каждый файл.
   * Наличие проверяется по дереву (свои записи), а не по глобальной таблице ассетов.
   */
  async have(userId: string, raw: unknown): Promise<{ present: Array<{ sha256: string; size: number; mime: string }> }> {
    const list = Array.isArray(raw) ? raw : [];
    const shas = [...new Set(list.map(normalizeSha).filter((s): s is string => Boolean(s)))];
    if (!shas.length) return { present: [] };
    if (shas.length > MAX_HAVE) throw badRequest(`too many sha256 in one request (max ${MAX_HAVE})`);

    // Только живое дерево: содержимое, лежащее в корзине, «есть» не считается — иначе клиент
    // пропустил бы заливку, не создал запись в целевой папке, а после retention объект бы исчез.
    // Плюс это согласует ответ с дедуп-путём init (там тоже проверяется только живая запись).
    const tree = await this.auth.subtreeIds(userId);
    const assets = await this.prisma.asset.findMany({
      where: { sha256: { in: shas } },
      select: { id: true, sha256: true, size: true, mime: true },
    });
    if (!assets.length) return { present: [] };

    const owned = await this.prisma.fileEntry.findMany({
      where: {
        assetId: { in: assets.map((a) => a.id) },
        folderId: { in: tree },
        deletedAt: null,
      },
      select: { assetId: true },
    });
    const ownedIds = new Set(owned.map((o) => o.assetId));

    return {
      // отдаём только те, что есть у пользователя: по чужому sha256 наличие не подтверждаем
      present: assets
        .filter((a) => ownedIds.has(a.id))
        .map((a) => ({ sha256: a.sha256, size: Number(a.size), mime: a.mime })),
    };
  }

  /** Максимум BIGINT: 19 цифр могут его превышать, и тогда Postgres ответит ошибкой вместо 400. */
  private static readonly MAX_SEQ = 9223372036854775807n;

  private parseSeq(raw: unknown): string {
    const s = typeof raw === 'string' ? raw.trim() : '';
    if (!/^\d{1,19}$/.test(s)) return '0';
    const clean = s.replace(/^0+(?=\d)/, '');
    return BigInt(clean) > SyncService.MAX_SEQ ? '0' : clean;
  }

  private parseLimit(raw: unknown): number {
    const n = Number(raw);
    if (!Number.isFinite(n) || n <= 0) return DEFAULT_CHANGES;
    return Math.min(Math.floor(n), MAX_CHANGES);
  }
}
