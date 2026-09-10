import { Injectable, Logger } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';

/** Цель события журнала: файл в дереве или папка. */
export type ChangeTarget = 'entry' | 'folder';
/**
 * Что произошло. `op` — подсказка клиенту, решение он принимает по снимку в строке:
 *   create  — цель появилась
 *   update  — у той же цели изменились имя/содержимое/keepOffline/clientMtime
 *   move    — цель переехала в другую папку (folderId изменился)
 *   delete  — tombstone: цель удалена (для папки — вместе с поддеревом)
 *   restore — цель вернулась из корзины
 *   pin     — изменился флаг «держать офлайн»
 */
export type ChangeOp = 'create' | 'update' | 'move' | 'delete' | 'restore' | 'pin';

export interface ChangeInput {
  userId: string;
  target: ChangeTarget;
  op: ChangeOp;
  targetId: string;
  folderId: string | null;
  name: string;
  zone?: string | null;
  sha256?: string | null;
  size?: bigint | number | null;
  mime?: string | null;
  clientMtime?: Date | null;
  keepOffline?: boolean;
}

/**
 * Журнал изменений дерева (M3): append-only лента, по которой клиент синхронизации
 * догоняет состояние сервера. Вызывающие обязаны передавать `tx` мутации — тогда запись
 * в журнал и само изменение дерева коммитятся вместе, и «изменение без события»
 * (клиент никогда о нём не узнает) невозможно. Ошибку журнала не глотаем: лучше упавший
 * запрос, чем молчаливое расхождение с клиентом.
 *
 * Tombstones (op = delete) живут вечно и не связаны внешними ключами с деревом: строка
 * должна пережить физическое удаление FileEntry/Folder (trash purge), иначе клиент
 * зальёт удалённый файл обратно.
 */
@Injectable()
export class ChangesService {
  private readonly logger = new Logger(ChangesService.name);

  constructor(private readonly prisma: PrismaService) {}

  async record(input: ChangeInput, tx?: Prisma.TransactionClient): Promise<void> {
    const db = tx ?? this.prisma;
    await db.changeLog.create({
      data: {
        userId: input.userId,
        target: input.target,
        op: input.op,
        targetId: input.targetId,
        folderId: input.folderId ?? null,
        name: input.name,
        zone: input.zone ?? null,
        sha256: input.sha256 ?? null,
        size: input.size === undefined || input.size === null ? null : BigInt(input.size),
        mime: input.mime ?? null,
        clientMtime: input.clientMtime ?? null,
        keepOffline: input.keepOffline ?? false,
      },
    });
  }

  /** Событие по файлу: снимок читается из БД по id (update/delete/restore/pin). */
  async recordEntry(userId: string, entryId: string, op: ChangeOp, tx?: Prisma.TransactionClient): Promise<void> {
    const db = tx ?? this.prisma;
    const entry = await db.fileEntry.findUnique({
      where: { id: entryId },
      include: { asset: true },
    });
    if (!entry) {
      // физическое удаление обязано писать tombstone само (trash purge) — здесь строки уже нет
      this.logger.warn(`change journal: entry ${entryId} not found for op=${op}`);
      return;
    }
    await this.record({
      userId,
      target: 'entry',
      op,
      targetId: entry.id,
      folderId: entry.folderId,
      name: entry.name,
      zone: entry.zone,
      sha256: entry.asset.sha256,
      size: entry.asset.size,
      mime: entry.asset.mime,
      clientMtime: entry.clientMtime,
      keepOffline: entry.keepOffline,
    }, tx);
  }

  /** Событие по папке: снимок читается из БД по id. */
  async recordFolder(userId: string, folderId: string, op: ChangeOp, tx?: Prisma.TransactionClient): Promise<void> {
    const db = tx ?? this.prisma;
    const folder = await db.folder.findUnique({ where: { id: folderId } });
    if (!folder) {
      this.logger.warn(`change journal: folder ${folderId} not found for op=${op}`);
      return;
    }
    await this.record({
      userId,
      target: 'folder',
      op,
      targetId: folder.id,
      folderId: folder.parentId,
      name: folder.name,
      zone: folder.zone,
      keepOffline: folder.keepOffline,
    }, tx);
  }

  /**
   * Мягкое удаление папки — это удаление всего поддерева. Клиенту достаточно одного
   * события на корень поддерева (папка удалена ⇒ всё внутри не существует), поэтому
   * отдельные события по детям не пишем: иначе на большой папке журнал раздувается в тысячи строк.
   */
  async recordFolderTreeDeleted(userId: string, folderId: string, tx?: Prisma.TransactionClient): Promise<void> {
    await this.recordFolder(userId, folderId, 'delete', tx);
  }
}
