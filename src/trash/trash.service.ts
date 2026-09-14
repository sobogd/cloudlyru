import { Injectable, Logger } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { MediaService } from '../media/media.service';
import { FoldersService } from '../folders/folders.service';
import { FilesService } from '../files/files.service';
import { AuthService } from '../auth/auth.service';
import { AuditService } from '../audit/audit.service';
import { ChangesService } from '../sync/changes.service';
import { conflict } from '../common/errors';
import { HIDDEN_ZONES } from '../common/zones';

/** Разбиение на порции: бережём лимит параметров запроса (у Postgres это 65 535). */
function chunksOf<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

@Injectable()
export class TrashService {
  private readonly logger = new Logger(TrashService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly folders: FoldersService,
    private readonly files: FilesService,
    private readonly auth: AuthService,
    private readonly changes: ChangesService,
    private readonly audit: AuditService,
  ) {}

  /** Корзина ТОЛЬКО этого пользователя: папки и файлы внутри его дерева. */
  async list(userId: string) {
    const tree = await this.auth.subtreeIds(userId, { includeDeleted: true });
    // «корни» удалённых папок: папка удалена, а её родитель — нет
    const deletedFolders = await this.prisma.folder.findMany({
      where: { deletedAt: { not: null }, id: { in: tree } },
      select: { id: true, name: true, deletedAt: true, parent: { select: { deletedAt: true } } },
      orderBy: { deletedAt: 'desc' },
    });
    const folders = deletedFolders
      .filter((f) => !f.parent?.deletedAt)
      .map((f) => ({ id: f.id, name: f.name, deletedAt: f.deletedAt, kind: 'folder' as const }));

    const deletedEntries = await this.prisma.fileEntry.findMany({
      // Вложения удалённых писем в корзине не показываем отдельными файлами: они возвращаются
      // вместе с письмом, а поодиночке в списке это были бы безымянные «2026-09-14_...pdf»
      // без всякой связи с тем, откуда они взялись.
      where: { deletedAt: { not: null }, folderId: { in: tree }, zone: { notIn: [...HIDDEN_ZONES] } },
      select: {
        id: true,
        name: true,
        deletedAt: true,
        folder: { select: { id: true, name: true, deletedAt: true } },
        asset: { select: { size: true } },
      },
      orderBy: { deletedAt: 'desc' },
    });
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

    // Удалённые письма: своя группа в корзине — у них ни папки, ни файла, а тема и отправитель
    // понятнее любого имени.
    const deletedMessages = await this.prisma.mailMessage.findMany({
      where: { userId, deletedAt: { not: null } },
      select: {
        id: true,
        subject: true,
        fromName: true,
        fromAddr: true,
        box: true,
        sortAt: true,
        deletedAt: true,
        size: true,
      },
      orderBy: { deletedAt: 'desc' },
      take: 1000,
    });
    const messages = deletedMessages.map((m) => ({
      id: m.id,
      kind: 'message' as const,
      subject: m.subject,
      from: m.fromName || m.fromAddr || '',
      box: m.box,
      sortAt: m.sortAt,
      deletedAt: m.deletedAt,
      size: m.size,
    }));

    return { folders, entries, messages };
  }

  async restore(type: 'folder' | 'file', id: string, userId: string) {
    if (type === 'folder') return this.folders.restore(id, userId);
    try {
      return await this.files.restore(id, userId);
    } catch (e) {
      const code = (e as { code?: string }).code;
      if (code === 'P2002') {
        throw conflict('file with this name already exists — rename it first');
      }
      throw e;
    }
  }

  /**
   * Полная очистка СВОЕЙ корзины (hard delete) с удалением осиротевших объектов из S3.
   *
   * Порядок важен и был перевёрнут раньше: СНАЧАЛА в одной транзакции пишутся tombstones
   * и удаляются строки БД, и только ПОСЛЕ коммита трогаются объекты в S3 — и то лишь для тех
   * ассетов, строки которых реально исчезли. Обратный порядок (сначала S3) ломался на гонке:
   * параллельный дедуп-upload в этом окне привязывает запись к тому же sha, объект живого
   * файла удалялся, а `asset.deleteMany` падал на FK `Restrict`.
   */
  async purge(userId: string, olderThanDays?: number) {
    // отрицательное/NaN значение раньше означало «вычистить всё» (cutoff в будущем/undefined)
    const days = Number.isFinite(olderThanDays) ? Math.max(0, Number(olderThanDays)) : undefined;
    const cutoff = days === undefined ? undefined : new Date(Date.now() - days * 24 * 60 * 60 * 1000);
    const tree = await this.auth.subtreeIds(userId, { includeDeleted: true });

    const deletedEntries = await this.prisma.fileEntry.findMany({
      where: {
        deletedAt: { not: null },
        folderId: { in: tree },
        ...(cutoff ? { deletedAt: { lt: cutoff } } : {}),
      },
      select: {
        id: true,
        name: true,
        folderId: true,
        zone: true,
        clientMtime: true,
        asset: { select: { sha256: true, size: true, mime: true } },
      },
    });
    const deletedFolders = await this.prisma.folder.findMany({
      where: {
        deletedAt: { not: null },
        id: { in: tree },
        ...(cutoff ? { deletedAt: { lt: cutoff } } : {}),
      },
      select: { id: true, name: true, parentId: true, zone: true },
    });
    const deletedMessages = await this.prisma.mailMessage.findMany({
      where: {
        userId,
        deletedAt: { not: null },
        ...(cutoff ? { deletedAt: { lt: cutoff } } : {}),
      },
      select: { id: true },
    });
    const messageIds = deletedMessages.map((m) => m.id);
    const entryIds = deletedEntries.map((e) => e.id);
    const folderIds = deletedFolders.map((f) => f.id);

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
        const folderRows = deletedFolders.map((f) => ({
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
            await tx.fileEntry.deleteMany({ where: { id: { in: chunk } } });
          }
        }
        // onDelete: Cascade убирает и все FileEntry внутри удалённых папок
        if (folderIds.length) await tx.folder.deleteMany({ where: { id: { in: folderIds } } });
        // Письма: MailAttachment уходит каскадом, а строки вложений уже удалены выше —
        // как раз потому, что письмо мягко удаляется вместе с ними.
        for (const chunk of chunksOf(messageIds, 1000)) {
          await tx.mailMessage.deleteMany({ where: { id: { in: chunk } } });
        }
      },
      { timeout: 120_000, maxWait: 15_000 },
    );

    // Осиротевшие ассеты: строку удаляем под условием «ссылок нет» (никакого FK-500 при гонке),
    // а объекты в S3 трогаем только после коммита и только у реально удалённых строк.
    // `mailRaw: none` обязателен: сырьё письма (.eml) — тоже Asset, но записей дерева у него
    // нет вовсе. Без этого условия чистка считала бы его осиротевшим, а удаление падало бы
    // на внешнем ключе Restrict (и вся очистка корзины — вместе с ним).
    const orphans = await this.prisma.asset.findMany({
      where: { entries: { none: {} }, mailRaw: { none: {} } },
      select: { id: true, sha256: true, pageCount: true },
    });
    let purgedAssets = 0;
    let retryAssets = 0;
    if (orphans.length) {
      const removed: Array<{ id: string; sha256: string; pageCount: number | null }> = [];
      for (const a of orphans) {
        const res = await this.prisma.asset.deleteMany({
          where: { id: a.id, entries: { none: {} }, mailRaw: { none: {} } },
        });
        if (res.count > 0) removed.push(a);
      }
      // Перед удалением объектов перепроверяем, что строки с этим содержимым не появились снова:
      // параллельная загрузка того же sha создаёт новый Asset, и удаление ключей убило бы
      // байты живого файла. Между deleteMany и deleteObjects это окно реально (дедуп по sha).
      const stillAbsent = await this.prisma.asset.findMany({
        where: { sha256: { in: removed.map((a) => a.sha256) } },
        select: { sha256: true },
      });
      const backAgain = new Set(stillAbsent.map((a) => a.sha256));
      if (backAgain.size) {
        this.logger.warn(`${backAgain.size} ассетов вернулись во время очистки — объекты не трогаем`);
      }
      // производные (view/*) и сырьё: у легаси-ассетов «Фото» сырья могло уже не быть
      const keys = removed
        .filter((a) => !backAgain.has(a.sha256))
        .flatMap((a) => [
          S3Service.assetKey(a.sha256),
          ...MediaService.derivativeKeys(a.sha256, a.pageCount),
        ]);
      const failed = keys.length
        ? await this.s3.deleteObjects(keys).catch((e: Error) => {
            this.logger.error(`S3 не ответил на удаление объектов: ${e.message}`);
            return keys;
          })
        : [];
      const failedSet = new Set(failed);
      purgedAssets = removed.filter((a) => !failedSet.has(S3Service.assetKey(a.sha256))).length;
      retryAssets = removed.length - purgedAssets;
      if (retryAssets) {
        // строки уже удалены, объекты остались — их подберёт deploy/scripts/sweep-orphans.mjs
        this.logger.warn(`${retryAssets} объектов S3 не удалились (S3 не подтвердил) — подберёт sweep-orphans`);
      }
    }

    await this.audit.log('trash.purge', {
      entries: entryIds.length,
      folders: folderIds.length,
      messages: messageIds.length,
      assets: purgedAssets,
      olderThanDays: days ?? null,
    });

    return {
      purgedEntries: entryIds.length,
      purgedFolders: folderIds.length,
      purgedMessages: messageIds.length,
      purgedAssets,
      ...(retryAssets ? { retryAssets } : {}),
    };
  }
}
