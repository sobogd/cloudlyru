import { Injectable, Logger } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { FoldersService } from '../folders/folders.service';
import { FilesService } from '../files/files.service';
import { AuthService } from '../auth/auth.service';
import { AuditService } from '../audit/audit.service';
import { ChangesService } from '../sync/changes.service';
import { HIDDEN_ZONES } from '../common/zones';

/** Разбиение на порции: бережём лимит параметров запроса (у Postgres это 65 535). */
function chunksOf<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

/**
 * Выдержка для «осиротевших» ассетов в плановом проходе. Свежая строка Asset без ссылок — это
 * загрузка «в полёте» (объект уже скопирован в files/<sha>, запись дерева создаётся следующим
 * шагом finish), а не мусор: без выдержки проход удалял бы файлы прямо под загрузкой.
 */
const ORPHAN_MIN_AGE_MS = 60 * 60 * 1000;

/** Потолок порций за один проход: остальное доберёт следующая уборка. */
const ORPHAN_SWEEP_BATCH = 1000;
const ORPHAN_SWEEP_MAX_BATCHES = 50;

@Injectable()
export class TrashService {
  private readonly logger = new Logger(TrashService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly folders: FoldersService,
    private readonly files: FilesService,
    private readonly auth: AuthService,
    private readonly changes: ChangesService,
    private readonly audit: AuditService,
  ) {}

  /**
   * Корзина ТОЛЬКО этого пользователя: папки и файлы внутри его дерева.
   *
   * Ответ отдаётся целиком, без пагинации: так устроен контракт ручки и клиент. На очень
   * большой корзине (десятки тысяч записей) это заметный по памяти ответ — пагинация
   * (keyset по `deletedAt`) потребует синхронного изменения клиента, поэтому здесь только
   * нарезка `IN`-списков, чтобы запросы не упирались в лимит параметров Postgres.
   */
  async list(userId: string) {
    const tree = await this.auth.subtreeIds(userId, { includeDeleted: true });
    const deletedFolders: Array<{
      id: string;
      name: string;
      deletedAt: Date | null;
      parent: { deletedAt: Date | null } | null;
    }> = [];
    const deletedEntries: Array<{
      id: string;
      name: string;
      deletedAt: Date | null;
      folder: { id: string; name: string; deletedAt: Date | null };
      asset: { size: bigint };
    }> = [];
    for (const chunk of chunksOf(tree, 5000)) {
      // «корни» удалённых папок: папка удалена, а её родитель — нет
      deletedFolders.push(
        ...(await this.prisma.folder.findMany({
          where: { deletedAt: { not: null }, id: { in: chunk } },
          select: { id: true, name: true, deletedAt: true, parent: { select: { deletedAt: true } } },
          orderBy: { deletedAt: 'desc' },
        })),
      );
      deletedEntries.push(
        ...(await this.prisma.fileEntry.findMany({
          // Вложения удалённых писем в корзине не показываем отдельными файлами: они возвращаются
          // вместе с письмом, а поодиночке в списке это были бы безымянные «2026-09-14_...pdf»
          // без всякой связи с тем, откуда они взялись.
          where: { deletedAt: { not: null }, folderId: { in: chunk }, zone: { notIn: [...HIDDEN_ZONES] } },
          select: {
            id: true,
            name: true,
            deletedAt: true,
            folder: { select: { id: true, name: true, deletedAt: true } },
            asset: { select: { size: true } },
          },
          orderBy: { deletedAt: 'desc' },
        })),
      );
    }
    deletedFolders.sort((a, b) => (b.deletedAt?.getTime() ?? 0) - (a.deletedAt?.getTime() ?? 0));
    deletedEntries.sort((a, b) => (b.deletedAt?.getTime() ?? 0) - (a.deletedAt?.getTime() ?? 0));
    const folders = deletedFolders
      .filter((f) => !f.parent?.deletedAt)
      .map((f) => ({ id: f.id, name: f.name, deletedAt: f.deletedAt, kind: 'folder' as const }));

    const entries = deletedEntries
      .filter((e) => !e.folder.deletedAt)
      .map((e) => ({
        id: e.id,
        name: e.name,
        deletedAt: e.deletedAt,
        kind: 'file' as const,
        size: Number(e.asset.size),
        folderId: e.folder.id,
      }));

    // Письма тут не показываем: у почты своя отдельная корзина (раздел «Почта» → «Корзина»),
    // и удаление письма в файловую корзину больше ничего не кладёт.
    return { folders, entries };
  }

  async restore(type: 'folder' | 'file', id: string, userId: string) {
    // Ветка с перехватом P2002 здесь была недостижима и убрана: `@@unique([folderId, name])`
    // учитывает и строки из корзины, поэтому живой тёзка у восстанавливаемой записи появиться
    // не может, и 409 «имя занято» приходит из files.restore обычным конфликтом.
    if (type === 'folder') return this.folders.restore(id, userId);
    return this.files.restore(id, userId);
  }

  /**
   * Полная очистка СВОЕЙ корзины (hard delete) с удалением осиротевших объектов из S3.
   *
   * Порядок важен и был перевёрнут раньше: СНАЧАЛА в одной транзакции пишутся tombstones
   * и удаляются строки БД, и только ПОСЛЕ коммита трогаются объекты в S3 — и то лишь для тех
   * ассетов, строки которых реально исчезли. Обратный порядок (сначала S3) ломался на гонке:
   * параллельный дедуп-upload в этом окне привязывает запись к тому же sha, объект живого
   * файла удалялся, а `asset.deleteMany` падал на FK `Restrict`.
   *
   * Убираются только ассеты, осиротевшие ИЗ-ЗА ЭТОЙ чистки. Общий проход по таблице Asset
   * (в том числе по мусору, оставшемуся от прошлых сбоев) делает отдельный глобальный шаг
   * `sweepOrphanAssets` — он один на сервис и вызывается уборкой вне цикла по пользователям.
   * Раньше purge сканировал всю таблицу Asset на каждого пользователя: любой пользователь
   * одним запросом удалял объекты, осиротевшие секунду назад у кого угодно (усилитель гонки
   * с параллельной загрузкой того же содержимого), а retention на N пользователей делал N
   * полных сканов.
   */
  async purge(
    userId: string,
    olderThanDays?: number,
    opts: { ip?: string; source?: 'user' | 'retention' } = {},
  ) {
    // отрицательное/NaN значение раньше означало «вычистить всё» (cutoff в будущем/undefined)
    const days = Number.isFinite(olderThanDays) ? Math.max(0, Number(olderThanDays)) : undefined;
    const cutoff = days === undefined ? undefined : new Date(Date.now() - days * 24 * 60 * 60 * 1000);
    const tree = await this.auth.subtreeIds(userId, { includeDeleted: true });

    const deletedEntries: Array<{
      id: string;
      name: string;
      folderId: string;
      assetId: string;
      zone: string;
      clientMtime: Date | null;
      asset: { sha256: string; size: bigint; mime: string };
    }> = [];
    const deletedFolders: Array<{ id: string; name: string; parentId: string | null; zone: string }> = [];
    for (const chunk of chunksOf(tree, 5000)) {
      deletedEntries.push(
        ...(await this.prisma.fileEntry.findMany({
          where: {
            deletedAt: { not: null },
            folderId: { in: chunk },
            // Вложения писем (зона MAIL) живут своей корзиной в разделе «Почта» и сюда не попадают:
            // иначе очистка файловой корзины ломала бы письма, чьи вложения ещё можно восстановить.
            zone: { notIn: [...HIDDEN_ZONES] },
            ...(cutoff ? { deletedAt: { lt: cutoff } } : {}),
          },
          select: {
            id: true,
            name: true,
            folderId: true,
            assetId: true,
            zone: true,
            clientMtime: true,
            asset: { select: { sha256: true, size: true, mime: true } },
          },
        })),
      );
      deletedFolders.push(
        ...(await this.prisma.folder.findMany({
          where: {
            deletedAt: { not: null },
            id: { in: chunk },
            ...(cutoff ? { deletedAt: { lt: cutoff } } : {}),
          },
          select: { id: true, name: true, parentId: true, zone: true },
        })),
      );
    }
    const entryIds = deletedEntries.map((e) => e.id);
    // Папку с ЖИВЫМ ребёнком физически не удаляем: FK на родителя объявлен ON DELETE SET NULL,
    // поэтому ребёнок поднялся бы в parentId=NULL и выпал из дерева пользователя навсегда
    // (в корне его не видно, его файлы и объекты в S3 остались бы без единого способа их найти).
    // Такие пары «удалённый родитель + живой ребёнок» появлялись, когда restore дочерней папки
    // при удалённом родителе разрешался; теперь folders.restore это запрещает, но данные,
    // испорченные раньше, надо не добивать, а оставить как есть под предупреждение.
    const blockedParents = await this.foldersWithLiveChildren(deletedFolders.map((f) => f.id));
    const purgeFolders = deletedFolders.filter((f) => !blockedParents.has(f.id));
    if (blockedParents.size) {
      this.logger.warn(
        `purge: ${blockedParents.size} удалённых папок не тронуты — под ними живые подпапки ` +
          `(родителя нужно сначала восстановить из корзины, иначе поддерево выпадет из дерева)`,
      );
    }
    const folderIds = purgeFolders.map((f) => f.id);

    // Tombstones и удаление строк — атомарно: журнал изменений не связан внешними ключами
    // с деревом именно ради того, чтобы tombstone пережил физическое удаление (иначе клиент
    // зальёт удалённое обратно). Ошибку записи не глотаем: без tombstone чистку делать нельзя.
    await this.prisma.$transaction(
      async (tx) => {
        // Tombstone'ы пишем пачками: по одному INSERT на строку корзина на тысячи файлов
        // не укладывалась в дефолтный 5-секундный таймаут транзакции Prisma.
        const entryRows = deletedEntries.map((e) => ({
          userId,
          target: 'entry',
          op: 'delete',
          targetId: e.id,
          folderId: e.folderId,
          name: e.name,
          zone: e.zone,
          sha256: e.asset.sha256,
          size: e.asset.size,
          mime: e.asset.mime,
          clientMtime: e.clientMtime,
        }));
        const folderRows = purgeFolders.map((f) => ({
          userId,
          target: 'folder',
          op: 'delete',
          targetId: f.id,
          folderId: f.parentId,
          name: f.name,
          zone: f.zone,
        }));
        for (const chunk of chunksOf(entryRows, 500)) await tx.changeLog.createMany({ data: chunk });
        for (const chunk of chunksOf(folderRows, 500)) await tx.changeLog.createMany({ data: chunk });
        if (entryIds.length) {
          for (const chunk of chunksOf(entryIds, 1000)) {
            // `deletedAt: { not: null }` обязателен: список id собран ВНЕ транзакции, и между
            // выборкой и чисткой пользователь мог восстановить запись (другое окно, другое
            // устройство). Без условия purge физически удалил бы уже живую строку, увёл бы её
            // объекты в S3 и послал клиентам tombstone — файл исчез бы у того, кто его вернул.
            await tx.fileEntry.deleteMany({ where: { id: { in: chunk }, deletedAt: { not: null } } });
          }
        }
        // Каскад уносит и все FileEntry внутри удалённых папок (у FileEntry.folderId — Cascade).
        // А вот дети-ПАПКИ каскадом не удаляются: у Folder.parentId стоит ON DELETE SET NULL,
        // поэтому живое поддерево папок проверено отдельно выше (foldersWithLiveChildren).
        if (folderIds.length) {
          for (const chunk of chunksOf(folderIds, 1000)) {
            await tx.folder.deleteMany({ where: { id: { in: chunk }, deletedAt: { not: null } } });
          }
        }
      },
      { timeout: 120_000, maxWait: 15_000 },
    );

    // Кандидаты на уборку — ассеты, которые могли осиротеть именно из-за этой чистки:
    // удалённые записи и всё, что было внутри физически удалённых папок (там строки исчезают
    // каскадом, включая живые). Строку удаляем под условием «ссылок нет» (никакого FK-500 при
    // гонке), а объекты в S3 — отложенно, с выдержкой и повторной проверкой (см.
    // FilesService.scheduleObjectDeletion: немедленное удаление гоняется с дедуп-загрузкой).
    const candidates = new Set<string>(deletedEntries.map((e) => e.assetId));
    for (const chunk of chunksOf(folderIds, 5000)) {
      const inside = await this.prisma.fileEntry.findMany({
        where: { folderId: { in: chunk } },
        select: { assetId: true },
      });
      for (const row of inside) candidates.add(row.assetId);
    }
    const purgedAssets = await this.files.gcOrphanAssets([...candidates]).catch((e: Error) => {
      this.logger.warn(`уборка осиротевших ассетов после purge: ${e.message}`);
      return 0;
    });

    await this.audit.log(
      'trash.purge',
      {
        // userId обязателен: безвозвратная чистка необратима, и после «файлы пропали» надо
        // уметь ответить, чьё это дерево. Колонки userId в AuditLog нет (схема — чужой пакет),
        // поэтому владелец и источник идут в meta.
        userId,
        source: opts.source ?? 'user',
        entries: entryIds.length,
        folders: folderIds.length,
        assets: purgedAssets,
        skippedFolders: blockedParents.size,
        olderThanDays: days ?? null,
      },
      opts.ip,
    );

    return {
      purgedEntries: entryIds.length,
      purgedFolders: folderIds.length,
      purgedAssets,
      ...(blockedParents.size ? { skippedFolders: blockedParents.size } : {}),
    };
  }

  /** Удалённые папки, под которыми остались живые подпапки (их физически удалять нельзя). */
  private async foldersWithLiveChildren(folderIds: string[]): Promise<Set<string>> {
    const blocked = new Set<string>();
    for (const chunk of chunksOf(folderIds, 5000)) {
      const live = await this.prisma.folder.findMany({
        where: { parentId: { in: chunk }, deletedAt: null },
        select: { parentId: true },
      });
      for (const row of live) if (row.parentId) blocked.add(row.parentId);
    }
    return blocked;
  }

  /**
   * Глобальный проход по осиротевшим ассетам: строки Asset, на которые не ссылается ни запись
   * дерева, ни сырьё письма. Один вызов на весь сервис (вне цикла по пользователям) — вместо
   * прежнего скана всей таблицы на каждого пользователя в purge.
   *
   * Выдержка по `createdAt` обязательна: свежая строка без ссылок — это загрузка «в полёте»
   * (объект уже лежит в files/<sha>, запись дерева создаётся следующим шагом), а не мусор.
   */
  async sweepOrphanAssets(): Promise<number> {
    const cutoff = new Date(Date.now() - ORPHAN_MIN_AGE_MS);
    let removed = 0;
    for (let round = 0; round < ORPHAN_SWEEP_MAX_BATCHES; round++) {
      const batch = await this.prisma.asset.findMany({
        where: {
          entries: { none: {} },
          // `mailRaw: none` обязателен: сырьё письма (.eml) — тоже Asset, но записей дерева
          // у него нет вовсе. Без этого условия проход считал бы его осиротевшим, а удаление
          // падало бы на внешнем ключе Restrict.
          mailRaw: { none: {} },
          createdAt: { lt: cutoff },
        },
        select: { id: true },
        take: ORPHAN_SWEEP_BATCH,
      });
      if (!batch.length) break;
      let inRound = 0;
      try {
        inRound = await this.files.gcOrphanAssets(batch.map((a) => a.id));
      } catch (e) {
        // на ассете может висеть задача (FK Restrict): одна такая строка не должна
        // останавливать уборку остальных и следующую уборку
        this.logger.warn(`проход по осиротевшим ассетам: ${e instanceof Error ? e.message : String(e)}`);
        return removed;
      }
      removed += inRound;
      // ни одна строка не удалилась — дальше идти некуда, иначе цикл никогда не кончится
      if (!inRound || batch.length < ORPHAN_SWEEP_BATCH) break;
    }
    if (removed) this.logger.log(`осиротевшие ассеты: удалено строк ${removed}`);
    return removed;
  }
}
