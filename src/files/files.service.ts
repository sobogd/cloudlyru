import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import type { Request, Response } from 'express';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { hasUsefulRaw, mediaKindOf, MediaService } from '../media/media.service';
import { AuthService, ROOT_FOLDER_NAME } from '../auth/auth.service';
import { ChangesService } from '../sync/changes.service';
import { QueueService } from '../queue/queue.service';
import { safeInlineImageMime, sendFirstExisting, sendObjectOr404 } from '../common/http-object';
import { normalizeMime } from '../common/mime';
import { assertSafeName, parseOptionalDate } from '../common/utils';
import { ZONE_PHOTOS, isHiddenZone, zoneOf } from '../common/zones';
import { badRequest, conflict, notFound } from '../common/errors';

/** Снимок содержимого для журнала изменений: без него пришлось бы читать Asset лишний раз. */
export interface AssetSnapshot {
  sha256: string;
  size: number;
  mime: string;
}

/** Параметры создания/перезаписи записи в дереве. */
export interface CreateEntryOptions {
  /**
   * Владелец дерева. Нужен для записи в журнал изменений и для проверки, что папка-приёмник
   * действительно его (см. createEntry). Не задан — проверить владельца нечем и событие в
   * журнал не пишется; такой случай виден в логе предупреждением, молча расходиться с клиентом
   * синхронизации нельзя. Так вызывают внутренние импортёры: разархивирование передаёт
   * `ownerId ?? undefined`, а владелец у старой задачи импорта может быть не задан.
   */
  userId?: string;
  /** Перезаписать существующий файл с тем же именем (а не отдавать 409). */
  replace?: boolean;
  /** mtime файла на устройстве-источнике. */
  clientMtime?: Date | null;
  /** Снимок содержимого — чтобы не читать Asset ради записи в журнал. */
  asset?: AssetSnapshot;
  /**
   * Разрешить вернуть запись из корзины, если имя занято удалённым файлом.
   * WebDAV (Finder/rclone) перезаписывает файл, не зная о нашей корзине, поэтому получает
   * это разрешение всегда; клиент синхронизации — только когда явно попросил
   * (`replaceTrashed: true` в init): имя занято его же удалённой записью, и без этого файл
   * не уехал бы в облако никогда. По умолчанию поведение прежнее — 409 `in_trash`.
   */
  restoreDeleted?: boolean;
  /**
   * Оптимистичная блокировка: какую версию файла клиент считает текущей.
   * `sha256` — содержимое (основной вариант, есть в снимках журнала), `updatedAt` — момент
   * правки (для тех, кто его отслеживает). Любое расхождение → 409 `stale_version`
   * со снимком фактической версии, чтобы клиент сразу сделал конфликтную копию.
   * Не задано — проверки нет (веб-форма, WebDAV, скрипты).
   */
  expect?: { sha256?: string | null; updatedAt?: Date | null };
}

/** Запись дерева вместе с ассетом: то, что нужно для отдачи содержимого. */
type EntryWithAsset = Prisma.FileEntryGetPayload<{ include: { asset: true } }>;

/** Разбиение длинных `IN`-списков: у Postgres лимит параметров запроса — 65 535. */
function chunksOf<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

@Injectable()
export class FilesService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(FilesService.name);

  /**
   * Выдержка перед удалением объектов S3 и период проверки отложенных удалений
   * (зачем — в комментарии scheduleObjectDeletion).
   */
  private static readonly OBJECT_GC_GRACE_MS = 60_000;
  private static readonly OBJECT_GC_FLUSH_MS = 30_000;
  /** Пауза между двумя проверками «строк с таким sha нет» перед удалением объектов. */
  private static readonly OBJECT_GC_RECHECK_MS = 2_000;

  /** Ассеты, чьи объекты ждут выдержки: sha256 → ключи и время, раньше которого не удаляем. */
  private readonly pendingObjectDeletion = new Map<string, { keys: string[]; notBefore: number }>();
  private gcTimer: NodeJS.Timeout | null = null;

  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly media: MediaService,
    private readonly auth: AuthService,
    private readonly changes: ChangesService,
    private readonly queue: QueueService,
  ) {}

  onModuleInit() {
    // Отложенные удаления объектов подчищаем сами, не дожидаясь шестичасовой уборки:
    // в памяти живёт только список ключей, состояние БД — источник истины.
    this.gcTimer = setInterval(() => void this.flushOrphanObjects().catch(() => undefined), FilesService.OBJECT_GC_FLUSH_MS);
    this.gcTimer.unref();
  }

  onModuleDestroy() {
    // Отложенные удаления НЕ сбрасываем на остановке: при `pm2 reload` в этот момент может
    // идти загрузка того же содержимого, и удаление объектов «на выходе» — ровно та гонка,
    // от которой выдержка и защищает. Лучше оставить объект в бакете без строки: его подберёт
    // deploy/scripts/sweep-orphans.mjs (для бакета он и есть осиротевший).
    if (this.gcTimer) clearInterval(this.gcTimer);
  }

  /** Папка-приёмник: существует и не в корзине. */
  private async ensureFolder(folderId: string) {
    const folder = await this.prisma.folder.findUnique({ where: { id: folderId } });
    if (!folder || folder.deletedAt) throw notFound('folder not found');
    return folder;
  }

  /**
   * Asset по хэшу; если нет — создаёт запись (объект в S3 уже должен лежать под files/<sha256>).
   *
   * Тип здесь же приводим к известному (normalizeMime): это единственная точка, где создаётся
   * Asset, поэтому объявленный клиентом произвольный mime дальше не проходит — ни в выбор
   * задачи конвертации, ни в Content-Type при отдаче.
   */
  async ensureAsset(sha256: string, size: number, mime: string, ext?: string): Promise<string> {
    const cleanMime = normalizeMime(mime);
    const existing = await this.prisma.asset.findUnique({ where: { sha256 } });
    if (existing) return existing.id;
    try {
      const asset = await this.prisma.asset.create({
        data: { sha256, size: BigInt(size), mime: cleanMime, ext },
      });
      return asset.id;
    } catch (e) {
      // два устройства залили одно содержимое одновременно: строку создал кто-то другой
      if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
        const raced = await this.prisma.asset.findUnique({ where: { sha256 } });
        if (raced) return raced.id;
      }
      throw e;
    }
  }

  /**
   * Событие в журнал изменений по уже существующей записи. Владельца знать обязательно:
   * без него событие не попало бы ни одному клиенту, поэтому такой случай — это ошибка
   * в коде вызова, и мы о ней громко пишем в лог, а не молчим.
   *
   * Скрытые зоны (вложения писем) в журнал не пишутся вовсе: клиенты синхронизации получили
   * бы события про папки, которых у них нет, и потащили бы к себе всю почту. Это не ошибка
   * вызова, поэтому и предупреждения тут нет.
   */
  private async recordEntryChange(input: {
    userId?: string;
    op: 'create' | 'update' | 'move' | 'restore';
    targetId: string;
    folderId: string;
    name: string;
    zone: string;
    sha256: string;
    size: number;
    mime: string;
    clientMtime?: Date | null;
    /** Транзакция мутации: журнал должен писаться вместе с ней, а не после. */
    tx?: Prisma.TransactionClient;
  }): Promise<void> {
    if (isHiddenZone(input.zone)) return;
    if (!input.userId) {
      // Имя файла в лог не пишем: в логах остаётся id записи и папка, этого достаточно для
      // разбора, а имена пользовательских файлов — персональные данные.
      this.logger.warn(
        `журнал изменений: неизвестен владелец дерева для записи ${input.targetId} (папка ${input.folderId}) — событие не записано`,
      );
      return;
    }
    await this.changes.record(
      {
        userId: input.userId,
        target: 'entry',
        op: input.op,
        targetId: input.targetId,
        folderId: input.folderId,
        name: input.name,
        zone: input.zone,
        sha256: input.sha256,
        size: input.size,
        mime: input.mime,
        clientMtime: input.clientMtime ?? null,
      },
      input.tx,
    );
  }

  /**
   * Вложение письма живёт в скрытой зоне MAIL и меняется только вместе с письмом (через
   * почтовый модуль). Прямая правка или удаление разорвали бы связь MailAttachment.entryId:
   * письмо осталось бы без вложения, а корзина — с осиротевшим файлом.
   */
  private assertEntryMutable(entry: { zone: string; name: string }, action: string): void {
    if (isHiddenZone(entry.zone)) throw badRequest(`cannot ${action} a mail attachment`);
  }

  /** Конфликт имени: корзина и занятое имя — разные ситуации, клиент реагирует по-разному. */
  private nameConflict(entryId: string, inTrash: boolean, name: string, inTarget = false): Error {
    if (inTrash) {
      return conflict('file with this name is in trash — restore or purge it first', 'in_trash', {
        entryId,
        name,
      });
    }
    return conflict(
      inTarget ? 'file name already exists in the target folder' : 'file name already exists',
      'conflict',
      { entryId, name },
    );
  }

  /** Единый ответ на расхождение версий: клиенту нужен снимок фактической версии. */
  private staleVersionError(current: {
    entryId: string | null;
    name: string;
    sha256: string | null;
    size?: number;
    mime?: string;
    clientMtime?: Date | null;
    updatedAt?: Date;
  }): Error {
    return conflict(
      current.entryId
        ? 'на сервере уже другая версия файла — сохраните свою как конфликтную копию'
        : 'файла на сервере нет — версия разошлась, синхронизируйте состояние',
      'stale_version',
      current,
    );
  }

  /** Имя занято записью из корзины: отказ до передачи байтов, со ссылкой на запись. */
  async assertNameNotInTrash(folderId: string, name: string): Promise<void> {
    const trashed = await this.prisma.fileEntry.findFirst({
      where: { folderId, name, deletedAt: { not: null } },
      select: { id: true },
    });
    if (trashed) {
      throw conflict('file with this name is in trash — restore or purge it first', 'in_trash', {
        entryId: trashed.id,
        name,
      });
    }
  }

  /**
   * Проверка предусловия перезаписи ДО начала загрузки: клиент не должен потратить
   * гигабайты на файл, который всё равно не примут из-за расхождения версий.
   * Та же проверка повторяется в createEntry — между init и complete версия могла измениться.
   * `allowTrashed` — имя занято записью из корзины, которую клиент разрешил занять
   * (replaceTrashed): живой версии, с которой можно сверяться, нет, запись будет
   * восстановлена и перезаписана.
   */
  async assertExpectedVersion(
    folderId: string,
    name: string,
    expect?: { sha256?: string | null; updatedAt?: Date | null },
    opts: { allowTrashed?: boolean } = {},
  ): Promise<void> {
    if (!expect) return;
    const existing = await this.prisma.fileEntry.findFirst({ where: { folderId, name } });
    if (!existing) throw this.staleVersionError({ entryId: null, name, sha256: null });
    if (existing.deletedAt) {
      if (opts.allowTrashed) return;
      throw conflict('file with this name is in trash — restore or purge it first', 'in_trash', {
        entryId: existing.id,
        name,
      });
    }
    const snap = await this.assetSnapshot(existing.assetId);
    const wantSha = expect.sha256 === undefined ? undefined : (expect.sha256 ?? '');
    const shaMismatch = wantSha !== undefined && wantSha !== snap.sha256;
    const mtimeMismatch =
      expect.updatedAt != null && existing.updatedAt.getTime() !== expect.updatedAt.getTime();
    if (shaMismatch || mtimeMismatch) {
      throw this.staleVersionError({
        entryId: existing.id,
        name,
        sha256: snap.sha256,
        size: snap.size,
        mime: snap.mime,
        clientMtime: existing.clientMtime,
        updatedAt: existing.updatedAt,
      });
    }
  }

  /**
   * Снимок содержимого ассета (для журнала изменений). Строки Asset нет — это расхождение
   * данных, а не «пустая версия»: раньше здесь возвращалась пустышка `{sha256: '', size: 0}`,
   * она уходила клиенту событием с фиктивным sha256, а оптимистичная блокировка с
   * `expect.sha256: ''` могла «совпасть» с ней и пропустить настоящее расхождение версий.
   */
  private async assetSnapshot(assetId: string, known?: AssetSnapshot): Promise<AssetSnapshot> {
    if (known) return known;
    const asset = await this.prisma.asset.findUnique({
      where: { id: assetId },
      select: { sha256: true, size: true, mime: true },
    });
    if (!asset) throw new Error(`asset ${assetId} not found — данные записи и ассетов разошлись`);
    return { sha256: asset.sha256, size: Number(asset.size), mime: asset.mime };
  }

  /**
   * Создание FileEntry (после того, как объект в S3 готов или найден по хэшу).
   * `replace` перезаписывает существующее имя, сохраняя id записи: иначе для всех устройств
   * правка файла выглядела бы как «удали + создай» (новая запись, новый путь в истории).
   *
   * ПРЕДУСЛОВИЕ, которое метод проверяет сам: папка-приёмник существует, не в корзине и
   * принадлежит владельцу из `opts.userId` (иначе 404). Проверка живёт здесь, а не у
   * вызывающих: `FilesService` экспортируется из модуля наружу, и первый же новый вызов с
   * `folderId` из тела запроса иначе стал бы записью в чужое дерево (IDOR на запись).
   * `userId` не передан — проверить владельца нечем, это случай внутренних импортёров
   * (разархивирование без владельца задачи).
   *
   * Скрытую зону (MAIL) метод намеренно НЕ запрещает: вложение письма — такая же запись дерева,
   * и её создаёт почтовый модуль со своим `userId`. Наружу такие записи не видны: листинги,
   * поиск, WebDAV и журнал изменений фильтруют зону MAIL.
   */
  async createEntry(
    folderId: string,
    name: string,
    assetId: string,
    opts: CreateEntryOptions,
  ): Promise<{ id: string; deduped: boolean; zone: string; replaced: boolean }> {
    const folder = await this.ensureFolder(folderId);
    if (opts.userId && !(await this.auth.folderOwnedBy(opts.userId, folderId))) {
      throw notFound('folder not found');
    }
    assertSafeName(name);
    const zone = zoneOf(folder.zone);
    const existing = await this.prisma.fileEntry.findFirst({ where: { folderId, name } });
    const snap = await this.assetSnapshot(assetId, opts.asset);
    const previousAssetId = existing?.assetId ?? null;

    // Мутация и запись в журнал — в одной транзакции: иначе падение между ними теряет
    // событие навсегда, а для delete/move это расхождение клиента с сервером.
    const result = await this.prisma
      .$transaction(async (tx) => {
        if (existing) {
          // предусловие проверяем ДО любых изменений: расхождение — это конфликт версий,
          // а не повод молча затереть чужую правку
          if (!existing.deletedAt && opts.expect) {
            const current = await this.assetSnapshot(existing.assetId);
            const wantSha = opts.expect.sha256 === undefined ? undefined : (opts.expect.sha256 ?? '');
            const shaMismatch = wantSha !== undefined && wantSha !== current.sha256;
            const mtimeMismatch =
              opts.expect.updatedAt !== undefined &&
              opts.expect.updatedAt !== null &&
              existing.updatedAt.getTime() !== opts.expect.updatedAt.getTime();
            if (shaMismatch || mtimeMismatch) {
              throw this.staleVersionError({
                entryId: existing.id,
                name: existing.name,
                sha256: current.sha256,
                size: current.size,
                mime: current.mime,
                clientMtime: existing.clientMtime,
                updatedAt: existing.updatedAt,
              });
            }
          }
          if (existing.deletedAt && !opts.restoreDeleted) {
            // молча воскрешать удалённое нельзя: корзина — единственная точка восстановления,
            // решение «вернуть» принимает пользователь (или явный флаг от WebDAV-клиента)
            throw conflict('file with this name is in trash — restore or purge it first', 'in_trash', {
              entryId: existing.id,
              name,
            });
          }
          if (!existing.deletedAt && !opts.replace) {
            throw conflict('file name already exists');
          }
          const wasDeleted = Boolean(existing.deletedAt);
          const updated = await tx.fileEntry.update({
            where: { id: existing.id },
            data: {
              assetId,
              zone,
              deletedAt: null,
              ...(opts.clientMtime !== undefined ? { clientMtime: opts.clientMtime } : {}),
            },
            select: { id: true, zone: true, clientMtime: true },
          });
          await this.recordEntryChange({
            userId: opts.userId,
            op: wasDeleted ? 'restore' : 'update',
            targetId: updated.id,
            folderId,
            name,
            zone: updated.zone,
            sha256: snap.sha256,
            size: snap.size,
            mime: snap.mime,
            // фактическое значение из БД: в снимок нельзя класть аргумент (DAV PUT его не шлёт)
            clientMtime: updated.clientMtime,
            tx,
          });
          return {
            id: updated.id,
            deduped: existing.assetId === assetId,
            zone: updated.zone,
            replaced: true,
          };
        }

        // предусловие задано, а записи нет: клиент считал, что файл на сервере есть
        if (opts.expect?.sha256 !== undefined) {
          throw this.staleVersionError({ entryId: null, name, sha256: null });
        }

        // если на одно содержимое уже есть живой entry в этой папке с другим именем — дедуп по содержимому
        const sameAssetLive = await tx.fileEntry.findFirst({
          where: { folderId, assetId, deletedAt: null, name: { not: name } },
        });
        const entry = await tx.fileEntry.create({
          data: { folderId, assetId, name, zone, clientMtime: opts.clientMtime ?? null },
          select: { id: true },
        });
        await this.recordEntryChange({
          userId: opts.userId,
          op: 'create',
          targetId: entry.id,
          folderId,
          name,
          zone,
          sha256: snap.sha256,
          size: snap.size,
          mime: snap.mime,
          clientMtime: opts.clientMtime ?? null,
          tx,
        });
        return { id: entry.id, deduped: Boolean(sameAssetLive), zone, replaced: false };
      })
      .catch(async (e: unknown) => {
        // гонка на @@unique([folderId, name]): два устройства грузят одно имя одновременно —
        // наружу должен уйти 409 с внятным текстом, а не 500 от Prisma
        if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
          throw conflict('file name already exists (created concurrently)');
        }
        throw e;
      });

    // прежнее содержимое могло остаться без ссылок — тогда его надо убрать из S3.
    // Владелец для этого не нужен: в журнал пишет recordEntryChange, а мусор в бакете
    // копится независимо от того, известен ли владелец дерева (импорт без владельца).
    if (previousAssetId && previousAssetId !== assetId) {
      await this.safeGcOrphanAsset(previousAssetId);
    }
    return result;
  }

  /**
   * GC без риска уронить процесс: сбой уборки не должен превращать успешную запись файла
   * в ошибку для клиента (и не должен всплывать необработанным отклонением промиса).
   */
  async safeGcOrphanAsset(assetId: string): Promise<void> {
    await this.gcOrphanAsset(assetId).catch((e: unknown) =>
      this.logger.warn(`gc ассета ${assetId}: ${e instanceof Error ? e.message : String(e)}`),
    );
  }

  /**
   * Убрать ассет, на который больше никто не ссылается: и сырьё files/<sha>, и все производные
   * view/*. Нужно после перезаписи файла — иначе старые объекты остаются в бакете навсегда
   * (плановый GC есть только в очистке корзины, а перезапись при синхронизации — частый путь).
   *
   * Строку Asset удаляем сразу, а объекты в S3 — отложенно: см. scheduleObjectDeletion.
   */
  async gcOrphanAsset(assetId: string): Promise<boolean> {
    const asset = await this.prisma.asset.findUnique({
      where: { id: assetId },
      select: { sha256: true, pageCount: true, mime: true },
    });
    if (!asset) return false;
    // строка удаляется только при отсутствии ссылок (двойная защита: условие в where + FK Restrict).
    // mailRaw: none — на ассет может ссылаться письмо (сырое .eml): у него нет записей дерева,
    // и без этой проверки удаление упало бы на FK, а объект в S3 остался бы без строки.
    const res = await this.prisma.asset.deleteMany({
      where: { id: assetId, entries: { none: {} }, mailRaw: { none: {} } },
    });
    if (res.count === 0) return false;
    await this.scheduleObjectDeletion(asset.sha256, asset.pageCount, asset.mime);
    return true;
  }

  /** Пакетная версия gcOrphanAsset: для очистки корзины, где кандидатов тысячи. */
  async gcOrphanAssets(assetIds: string[]): Promise<number> {
    let removed = 0;
    for (const chunk of chunksOf(assetIds, 5000)) {
      const rows = await this.prisma.asset.findMany({
        where: { id: { in: chunk }, entries: { none: {} }, mailRaw: { none: {} } },
        select: { id: true, sha256: true, pageCount: true, mime: true },
      });
      if (!rows.length) continue;
      const res = await this.prisma.asset.deleteMany({
        where: { id: { in: rows.map((r) => r.id) }, entries: { none: {} }, mailRaw: { none: {} } },
      });
      if (res.count === 0) continue;
      removed += res.count;
      // Между deleteMany и удалением объектов строку мог создать параллельный дедуп-upload:
      // сам вызов deleteObjects отложен, а на выдержке мы ещё раз проверим, что строк нет.
      for (const row of rows) await this.scheduleObjectDeletion(row.sha256, row.pageCount, row.mime);
    }
    return removed;
  }

  /**
   * Ключи объекта и его производных, включая страницы PDF, которых нет в pageCount.
   * Лишний LIST в S3 делаем только для PDF без pageCount: у остальных типов страничных
   * превью не бывает, а уборка идёт пачками и по одному запросу на ассет — это дорого.
   */
  private async keysOfAsset(sha256: string, pageCount: number | null, mime?: string): Promise<string[]> {
    const keys = [S3Service.assetKey(sha256), ...MediaService.derivativeKeys(sha256, pageCount)];
    if (!pageCount && mime !== undefined && mediaKindOf(mime) === 'pdf') {
      // Страничные превью PDF перечисляются по числу страниц из БД, а оно пишется только при
      // удачном рендере (finishPdf). Задача могла отрисовать часть страниц и упасть — тогда
      // pageCount = null, и уже созданные view/<sha>-p* никто бы не удалил. Берём их префиксом
      // (как convertPdf) и отбираем по шаблону: префикс `-p` перехватывает ещё и `-poster.webp`.
      const listed = await this.s3.listKeys(`view/${sha256}-p`).catch(() => [] as string[]);
      for (const key of listed) if (new RegExp(`^view/${sha256}-p\\d+-.+\\.webp$`).test(key)) keys.push(key);
    }
    return keys;
  }

  /**
   * Отложить удаление объектов ассета на GC_OBJECT_GRACE_MS.
   *
   * Немедленное удаление — это check-then-act: между проверкой «строк с таким sha больше нет»
   * и deleteObjects параллельная загрузка того же содержимого успевает создать НОВУЮ строку
   * Asset с тем же ключом files/<sha> (uploads: findUnique не нашёл → headObject видит живой
   * объект → server-side copy пропускается, строка создаётся). Удаление ключей в этом окне
   * убивает байты живого файла: загрузка ответила успехом, а скачивание и превью дают 404
   * навсегда, причём ни внутренний GC, ни sweep-orphans такое уже не найдут (строка есть).
   * Закрыть окно насовсем можно только блокировкой по sha с обеих сторон (advisory-lock в
   * загрузке — src/uploads/**, чужой модуль), поэтому здесь выдержка и повторная проверка:
   * окно загрузки «findUnique → ensureAsset» — миллисекунды, выдержка в минуты его перекрывает.
   * Не дождались (рестарт процесса) — объект остаётся без строки, его подберёт
   * deploy/scripts/sweep-orphans.mjs: для бакета он и есть осиротевший.
   */
  private async scheduleObjectDeletion(
    sha256: string,
    pageCount: number | null,
    mime: string,
  ): Promise<void> {
    const keys = await this.keysOfAsset(sha256, pageCount, mime);
    this.pendingObjectDeletion.set(sha256, {
      keys,
      notBefore: Date.now() + FilesService.OBJECT_GC_GRACE_MS,
    });
  }

  /**
   * Удалить объекты, выдержка которых истекла. Глобальный проход (один на сервис, вне цикла
   * по пользователям): вызывается таймером и уборкой RetentionService.
   *
   * Перед удалением дважды проверяем, что строк с таким sha нет, с паузой между проверками:
   * за паузу параллельная загрузка того же содержимого успевает создать свою строку Asset
   * (окно «findUnique → ensureAsset»), и тогда объект живой — ключи не трогаем. Проверки
   * пакетные (по одному запросу на все просроченные sha), поэтому пауза стоит один раз
   * на проход, а не на каждый ассет.
   */
  async flushOrphanObjects(): Promise<number> {
    const now = Date.now();
    const due = [...this.pendingObjectDeletion].filter(([, item]) => item.notBefore <= now);
    if (!due.length) return 0;

    const goneAfter = await this.absentShas(due.map(([sha256]) => sha256));
    await new Promise((resolve) => setTimeout(resolve, FilesService.OBJECT_GC_RECHECK_MS));
    const stillAbsent = await this.absentShas([...goneAfter]);

    let deleted = 0;
    let returned = 0;
    for (const [sha256, item] of due) {
      this.pendingObjectDeletion.delete(sha256);
      if (!stillAbsent.has(sha256)) {
        returned += 1;
        continue;
      }
      const failed = await this.s3.deleteObjects(item.keys).catch((e: Error) => {
        this.logger.warn(`S3 не подтвердил удаление объектов ${sha256}: ${e.message}`);
        return item.keys;
      });
      if (failed.length) {
        // строки уже нет, объекты остались — их подберёт deploy/scripts/sweep-orphans.mjs
        this.logger.warn(`${failed.length} объектов S3 осиротели (${sha256}) — подберёт sweep-orphans`);
        continue;
      }
      deleted += item.keys.length;
    }
    if (returned) {
      this.logger.warn(`gc: ${returned} ассетов появились снова за время выдержки — объекты не трогали`);
    }
    return deleted;
  }

  /** Из списка sha — те, для которых в БД нет ни одной строки Asset. */
  private async absentShas(candidates: string[]): Promise<Set<string>> {
    const absent = new Set(candidates);
    for (const chunk of chunksOf([...new Set(candidates)], 5000)) {
      const alive = await this.prisma.asset.findMany({
        where: { sha256: { in: chunk } },
        select: { sha256: true },
      });
      for (const row of alive) absent.delete(row.sha256);
    }
    return absent;
  }

  /** Полные метаданные файла для деталки: путь, размер/тип/хэш, EXIF/видео и метаданные Google. */
  async getEntryMeta(entryId: string, userId: string) {
    const entry = await this.prisma.fileEntry.findUnique({
      where: { id: entryId },
      include: {
        asset: { include: { media: true } },
        folder: true,
        // Вложение письма: деталка файла показывает, из какого письма он пришёл, и умеет
        // провалиться в него. У обычных файлов связи нет, поэтому это просто null.
        mailAttachment: {
          select: {
            message: { select: { id: true, subject: true, fromName: true, fromAddr: true, sortAt: true, box: true } },
          },
        },
      },
    });
    if (!entry || entry.deletedAt) throw notFound('file not found');
    // чужой файл не должен отличаться от несуществующего (внутри ещё и ленивый EXIF/ffprobe)
    if (!(await this.auth.folderOwnedBy(userId, entry.folderId))) throw notFound('file not found');

    // Подробные метаданные извлекаем лениво при первом открытии деталки и кэшируем в БД.
    // Раньше EXIF парсился только для зоны «Фото», поэтому у файлов в «Файлах» деталка была пустой.
    // Пустой raw (например, `{"kind":"image"}` из разбора обрезанного начала HEIC) за разбор
    // не считаем: иначе деталка навсегда оставалась без даты, камеры и кадра.
    if (!hasUsefulRaw(entry.asset.media?.raw)) {
      await this.media.extractDetail(
        entry.assetId,
        entry.asset.sha256,
        Number(entry.asset.size),
        entry.asset.mime,
      );
      entry.asset.media = await this.prisma.mediaMeta.findUnique({ where: { assetId: entry.assetId } });
    }

    const m = entry.asset.media;
    return {
      id: entry.id,
      name: entry.name,
      createdAt: entry.createdAt,
      updatedAt: entry.updatedAt,
      clientMtime: entry.clientMtime,
      folderId: entry.folderId,
      zone: entry.zone,
      path: await this.folderPath(entry.folder),
      size: Number(entry.asset.size),
      mime: entry.asset.mime,
      ext: entry.asset.ext ?? undefined,
      sha256: entry.asset.sha256,
      pageCount: entry.asset.pageCount ?? undefined,
      mail: entry.mailAttachment
        ? {
            id: entry.mailAttachment.message.id,
            subject: entry.mailAttachment.message.subject,
            fromName: entry.mailAttachment.message.fromName,
            fromAddr: entry.mailAttachment.message.fromAddr,
            sortAt: entry.mailAttachment.message.sortAt,
            box: entry.mailAttachment.message.box,
          }
        : null,
      media: m
        ? {
            capturedAt: m.capturedAt ? m.capturedAt.toISOString() : null,
            latitude: m.latitude ?? undefined,
            longitude: m.longitude ?? undefined,
            make: m.make ?? undefined,
            model: m.model ?? undefined,
            width: m.width ?? undefined,
            height: m.height ?? undefined,
            raw: (m.raw as Record<string, unknown> | null) ?? null,
          }
        : null,
    };
  }

  /** Человекочитаемый путь файла: «Главная / папка / …». */
  private async folderPath(folder: { id: string; parentId: string | null; name: string }): Promise<string> {
    const names: string[] = [];
    let cur: { id: string; parentId: string | null; name: string } = folder;
    for (let i = 0; i < 32 && cur.name !== ROOT_FOLDER_NAME; i++) {
      names.unshift(cur.name);
      if (!cur.parentId) break;
      const parent = await this.prisma.folder.findUnique({
        where: { id: cur.parentId },
        select: { id: true, parentId: true, name: true },
      });
      if (!parent) break;
      cur = parent;
    }
    return ['Главная', ...names].join(' / ');
  }

  /**
   * Самый полный доступный объект ассета: оригинал (он и есть мастер), а если его нет —
   * лучшая из производных. У части легаси-ассетов оригинал удалялся прежним кодом сразу
   * после конвертации. Возвращаем также признак «это оригинал»: для него S3 отдаёт
   * content-disposition: attachment (скачивание), для производных — inline (превью).
   *
   * Цена: один HEAD в S3 по ключу оригинала и, только если оригинала нет (легаси), до пяти
   * HEAD по производным — то есть на обычном файле это один round-trip, а на легаси-ассете
   * пять. Таблица «ключ → mime» ниже задана строковыми литералами суффиксов: её место —
   * рядом с теми, кто эти ключи создаёт (MediaService), иначе новая схема производных
   * потребует правки здесь.
   */
  async resolveContentKey(asset: {
    sha256: string;
    mime: string;
  }): Promise<{ key: string; mime: string; original: boolean }> {
    const sha = asset.sha256;
    const rawKey = S3Service.assetKey(sha);
    if (await this.s3.headObject(rawKey).catch(() => false)) {
      return { key: rawKey, mime: asset.mime, original: true };
    }

    const isVideo = String(asset.mime).startsWith('video/');
    const fallback = isVideo
      ? [
          MediaService.legacyVideoMasterKey(sha),
          MediaService.video1080Key(sha),
          MediaService.legacyVideo720Key(sha),
          MediaService.videoPosterKey(sha),
        ]
      : [
          MediaService.legacyPhotoMasterKey(sha),
          MediaService.photoFullKey(sha),
          MediaService.legacyPhotoFull2048Key(sha),
          MediaService.legacyPhotoFullWebpKey(sha),
          MediaService.gridKey(sha),
          MediaService.legacyGridKey(sha),
        ];
    for (const key of fallback) {
      if (await this.s3.headObject(key).catch(() => false)) {
        const mime = key.endsWith('.avif') ? 'image/avif' : key.endsWith('.mp4') ? 'video/mp4' : 'image/webp';
        return { key, mime, original: false };
      }
    }
    // ничего нет — вернём ключ оригинала, чтобы вызывающий получил ошибку S3
    return { key: rawKey, mime: asset.mime, original: true };
  }

  /**
   * Содержимое записи для отдачи клиенту: ключ в S3, тип и имя файла.
   * Presigned-ссылки наружу не выдаём (см. download/inlineImage) — по такой ссылке
   * объект качается вообще без авторизации, поэтому байты идут через сервис.
   *
   * Владельца проверяет сам (requireOwnEntry): по одному entryId ключ и тип иначе отдались бы
   * кому угодно, то есть метод был бы готовым IDOR «из коробки».
   */
  async contentForEntry(entryId: string, userId: string): Promise<{ key: string; mime: string; name: string }> {
    const entry = await this.requireOwnEntry(entryId, userId);
    const { key, mime } = await this.resolveContentKey(entry.asset);
    return { key, mime, name: entry.name };
  }

  /** Свой живой файл: вход по id с проверкой, что он в дереве этого пользователя. */
  private async requireOwnEntry(entryId: string, userId: string) {
    const entry = await this.prisma.fileEntry.findUnique({
      where: { id: entryId },
      include: { asset: true },
    });
    // 404, а не 403: чужой файл не должен отличаться от несуществующего
    if (!entry || entry.deletedAt) throw notFound('file not found');
    if (!(await this.auth.folderOwnedBy(userId, entry.folderId))) throw notFound('file not found');
    return entry;
  }

  /**
   * Отдача содержимого уже загруженной записи. Принимает запись, а не id: иначе «небезопасный»
   * тип в inlineImage уходил бы в download(), и запись с ключом читались бы из БД и S3 дважды.
   */
  private async sendEntry(
    entry: EntryWithAsset,
    req: Request,
    res: Response,
    opts: { mime: string; disposition: 'inline' | 'attachment'; cache?: string },
  ): Promise<void> {
    const { key } = await this.resolveContentKey(entry.asset);
    await sendObjectOr404(req, res, this.s3, key, {
      mime: opts.mime,
      disposition: opts.disposition,
      filename: entry.name,
      ...(opts.cache ? { cache: opts.cache } : {}),
    });
  }

  /**
   * Скачивание файла: байты идут через сервис (не отдаём наружу presigned-ссылку на S3,
   * она живёт без авторизации), тип — octet-stream, имя — из дерева, disposition: attachment.
   * Так браузер сохраняет файл, а не открывает новую вкладку и не рендерит содержимое.
   */
  async download(entryId: string, userId: string, req: Request, res: Response): Promise<void> {
    const entry = await this.requireOwnEntry(entryId, userId);
    await this.sendEntry(entry, req, res, { mime: 'application/octet-stream', disposition: 'attachment' });
  }

  /**
   * Показ файла в интерфейсе (миниатюры альбомов): только «безопасные» картинки и только
   * с типом из белого списка. Всё остальное (SVG, HTML, PDF, видео) уходит на скачивание.
   */
  async inlineImage(entryId: string, userId: string, req: Request, res: Response): Promise<void> {
    const entry = await this.requireOwnEntry(entryId, userId);
    const mime = safeInlineImageMime(entry.asset.mime);
    // «небезопасный» тип отдаём тем же уже загруженным entry: раньше здесь вызывался download()
    // с id, и запись с ключом читались из БД и S3 второй раз на каждый показ
    if (!mime) {
      return this.sendEntry(entry, req, res, { mime: 'application/octet-stream', disposition: 'attachment' });
    }
    await this.sendEntry(entry, req, res, {
      mime,
      disposition: 'inline',
      // содержимое неизменяемо (ключ = sha256), но приватно: кэширует только браузер
      cache: 'private, max-age=600',
    });
  }

  /**
   * Миниатюра для списка файлов (50×50): производные, собранные очередью, а не оригинал.
   * Одна ручка на все типы, потому что в списке известен только id записи, а не sha256.
   * Нет превью (задача ещё идёт или упала) — 404, клиент показывает иконку.
   */
  /**
   * Миниатюра для списка файлов (квадрат GRID_SIZE×GRID_SIZE): производные, собранные
   * очередью, а не оригинал.
   *
   * Одна ручка на все типы, потому что в списке известен только id записи, а не sha256.
   * Нет превью (задача ещё идёт или упала) — 404, клиент показывает иконку.
   *
   * Кандидаты перебираются во время отдачи (`sendFirstExisting`), а не через `headObject`:
   * список файлов спрашивает миниатюру на каждую строку, и лишний round-trip к S3 на каждую
   * из них — это ровно та задержка, которую видно при прокрутке. Порядок — «текущий формат,
   * потом прежний»: под легаси-ключом лежит рабочее превью, пока библиотека не пересобрана,
   * и отдавать вместо него 404 нельзя.
   */
  async thumb(entryId: string, userId: string, req: Request, res: Response): Promise<void> {
    const entry = await this.requireOwnEntry(entryId, userId);
    if (entry.asset.previewState !== 'done') {
      res.status(404).end();
      return;
    }
    const sha = entry.asset.sha256;
    const isVideo = String(entry.asset.mime).startsWith('video/');
    // У видео миниатюра — постер, у фото и PDF — превью для сетки. Постер пока WebP: его
    // собирает ffmpeg, и перевод на AVIF — отдельная правка конвейера видео.
    const candidates = isVideo
      ? [
          { key: MediaService.videoPosterKey(sha), mime: 'image/webp' },
          { key: MediaService.gridKey(sha), mime: 'image/avif' },
          { key: MediaService.legacyGridKey(sha), mime: 'image/webp' },
        ]
      : [
          { key: MediaService.gridKey(sha), mime: 'image/avif' },
          { key: MediaService.legacyGridKey(sha), mime: 'image/webp' },
        ];
    const sent = await sendFirstExisting(req, res, this.s3, candidates, {
      disposition: 'inline',
      // ключ = sha256, содержимое неизменяемо: кэширует только браузер пользователя
      cache: 'private, max-age=600',
    });
    if (!sent) res.status(404).end();
  }

  async softDelete(entryId: string, userId: string) {
    const owned = await this.auth.ownEntry(userId, entryId);
    if (!owned) throw notFound('file not found');
    this.assertEntryMutable(owned, 'delete');
    await this.prisma.$transaction(async (tx) => {
      await tx.fileEntry.update({ where: { id: entryId }, data: { deletedAt: new Date() } });
      await this.changes.recordEntry(userId, entryId, 'delete', tx);
    });
    return { ok: true };
  }

  async restore(entryId: string, userId: string) {
    // проверяем по дереву с удалёнными папками: запись из корзины может лежать
    // внутри уже удалённой папки, и тогда нужен понятный конфликт, а не 404
    const tree = await this.auth.subtreeIds(userId, { includeDeleted: true });
    const entry = await this.prisma.fileEntry.findUnique({ where: { id: entryId } });
    if (!entry || !tree.includes(entry.folderId)) throw notFound('file not found');
    if (entry.deletedAt) {
      const folder = await this.prisma.folder.findUnique({ where: { id: entry.folderId } });
      if (!folder || folder.deletedAt) throw conflict('parent folder is deleted — restore folder first');
    }
    await this.prisma.$transaction(async (tx) => {
      await tx.fileEntry.update({ where: { id: entryId }, data: { deletedAt: null } });
      await this.changes.recordEntry(userId, entryId, 'restore', tx);
    });
    return { ok: true };
  }

  /**
   * Правка записи клиентом синхронизации: переименование, перенос в другую папку и запись
   * mtime с устройства. Перенос — отдельная операция, а не «удали + создай»: id записи
   * сохраняется, другие устройства видят move, а не новый файл.
   */
  async patch(
    entryId: string,
    userId: string,
    body: { folderId?: unknown; name?: unknown; clientMtime?: unknown } = {},
  ) {
    const entry = await this.prisma.fileEntry.findUnique({
      where: { id: entryId },
      include: { asset: true },
    });
    if (!entry || entry.deletedAt) throw notFound('file not found');
    if (!(await this.auth.folderOwnedBy(userId, entry.folderId))) throw notFound('file not found');
    this.assertEntryMutable(entry, 'rename or move');

    const data: { folderId?: string; name?: string; zone?: string; clientMtime?: Date | null } = {};
    let op: 'update' | 'move' = 'update';

    if (typeof body.name === 'string' && body.name !== entry.name) {
      try {
        assertSafeName(body.name);
      } catch {
        throw badRequest('invalid name');
      }
      const clash = await this.prisma.fileEntry.findFirst({
        where: { folderId: entry.folderId, name: body.name, id: { not: entryId } },
      });
      if (clash) throw this.nameConflict(clash.id, clash.deletedAt !== null, body.name);
      data.name = body.name;
    }

    if (typeof body.folderId === 'string' && body.folderId !== entry.folderId) {
      const target = await this.prisma.folder.findUnique({ where: { id: body.folderId } });
      if (!target || target.deletedAt) throw notFound('folder not found');
      if (!(await this.auth.folderOwnedBy(userId, target.id))) throw notFound('folder not found');
      // В скрытую зону («Почта») файл переносить нельзя: folderOwnedBy для своей же папки
      // «Почта» возвращает true, а запись там исчезает из всех листингов, поиска, WebDAV и
      // журнала изменений — то есть файл пропадает безвозвратно и восстановить его нечем.
      // Остальные пути записи (uploads, dav, clipboard) закрыты так же — 404, как у чужой папки.
      if (isHiddenZone(target.zone)) throw notFound('folder not found');
      const clash = await this.prisma.fileEntry.findFirst({
        where: { folderId: target.id, name: data.name ?? entry.name },
      });
      if (clash) throw this.nameConflict(clash.id, clash.deletedAt !== null, data.name ?? entry.name, true);
      data.folderId = target.id;
      data.zone = zoneOf(target.zone);
      op = 'move';
    }

    if (body.clientMtime !== undefined) {
      const mtime = parseOptionalDate(body.clientMtime);
      if (mtime !== undefined) data.clientMtime = mtime;
    }

    if (!Object.keys(data).length) return { ok: true, changed: false };

    const updated = await this.prisma
      .$transaction(async (tx) => {
        const row = await tx.fileEntry.update({
          where: { id: entryId },
          data,
          select: { id: true, name: true, folderId: true, zone: true, clientMtime: true },
        });
        await this.changes.record(
          {
            userId,
            target: 'entry',
            op,
            targetId: row.id,
            folderId: row.folderId,
            name: row.name,
            zone: row.zone,
            sha256: entry.asset.sha256,
            size: Number(entry.asset.size),
            mime: entry.asset.mime,
            clientMtime: row.clientMtime,
          },
          tx,
        );
        return row;
      })
      .catch((e: unknown) => {
        // Проверка конфликта имени выше не атомарна с update: два параллельных rename/move
        // в одно имя оба проходят findFirst, и один из update падает на @@unique([folderId, name]).
        // Наружу должен уйти 409 (как в createEntry), а не 500 от Prisma.
        if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
          throw conflict('file name already exists (renamed or moved concurrently)');
        }
        throw e;
      });

    // Файл переехал в медиа-зону: без EXIF и превью он не попадёт в таймлайн
    if (updated.zone === ZONE_PHOTOS && entry.zone !== ZONE_PHOTOS) {
      await this.media
        .captureAny(entry.assetId, entry.asset.sha256, Number(entry.asset.size), entry.asset.mime)
        .catch(() => undefined);
      await this.queue.enqueue(entry.assetId, entry.asset.sha256, entry.asset.mime).catch(() => undefined);
    }

    return { ok: true, changed: true, entry: updated };
  }
}
