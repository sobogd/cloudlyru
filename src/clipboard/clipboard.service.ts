import { Injectable, Logger } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService } from '../auth/auth.service';
import { FilesService } from '../files/files.service';
import { FoldersService } from '../folders/folders.service';
import { ChangesService } from '../sync/changes.service';
import { MediaService } from '../media/media.service';
import { QueueService } from '../queue/queue.service';
import { ZONE_PHOTOS, isHiddenZone, zoneOf } from '../common/zones';
import { badRequest, conflict, notFound } from '../common/errors';

export type ClipboardKind = 'file' | 'folder';
export type ClipboardMode = 'copy' | 'cut';

/**
 * Значения полей буфера — String в БД (в схеме нет enum), поэтому при чтении их надо
 * проверять, а не приводить типом: колонку могло испортить что угодно, а `as ClipboardKind`
 * просто врёт компилятору и отдаёт клиенту несуществующий kind.
 */
function isClipboardKind(v: unknown): v is ClipboardKind {
  return v === 'file' || v === 'folder';
}
function isClipboardMode(v: unknown): v is ClipboardMode {
  return v === 'copy' || v === 'cut';
}

/** Что лежит в буфере: цель, режим и то, что нужно показать в шапке («вырезать: photo.jpg»). */
export interface ClipboardView {
  kind: ClipboardKind;
  mode: ClipboardMode;
  id: string;
  name: string;
  /** false — цель исчезла (удалена, уехала в корзину, переименована другим клиентом). */
  available: boolean;
  at: string | null;
}

/** Сколько «копий» пробуем, прежде чем сдаться: имя (копия), имя (копия 2), … */
const COPY_NAME_ATTEMPTS = 50;
/** Суффикс копии. Скобки и пробел — как в Finder/Explorer, привычно глазу. */
const COPY_SUFFIX = ' (копия)';

/**
 * Буфер копирования/вырезания: «скопировать»/«вырезать» в деталке, «вставить» в шапке папки.
 *
 * Живёт на пользователе в БД, а не в localStorage: буфер должен быть один на аккаунт
 * (скопировал на телефоне — вставил на ноутбуке) и не теряться при перезагрузке страницы.
 *
 * Копирование папок не поддерживается намеренно: это рекурсивная вставка всего поддерева
 * с разбором конфликтов имён внутри — отдельная задача, а не «ещё одна кнопка».
 */
@Injectable()
export class ClipboardService {
  private readonly logger = new Logger('Clipboard');

  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
    private readonly files: FilesService,
    private readonly folders: FoldersService,
    private readonly changes: ChangesService,
    private readonly media: MediaService,
    private readonly queue: QueueService,
  ) {}

  /** Буфер пользователя; null — пусто. Цель могла исчезнуть: тогда available=false. */
  async get(userId: string): Promise<ClipboardView | null> {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { clipboardKind: true, clipboardId: true, clipboardMode: true, clipboardAt: true },
    });
    const id = user?.clipboardId;
    // Неизвестное значение = буфер пуст: без проверки типовая система поверила бы `as`-приведению
    // и клиент получил бы kind, которого не существует (запись в колонке портит не только API).
    if (!isClipboardKind(user?.clipboardKind) || !isClipboardMode(user?.clipboardMode) || !id) {
      if (user?.clipboardKind || user?.clipboardMode) {
        this.logger.warn(`в буфере неизвестные значения (kind=${user?.clipboardKind}, mode=${user?.clipboardMode}) — считаю пустым`);
      }
      return null;
    }
    const kind = user.clipboardKind;
    const mode = user.clipboardMode;

    const target = kind === 'file'
      ? await this.prisma.fileEntry.findUnique({ where: { id }, select: { name: true, deletedAt: true } })
      : await this.prisma.folder.findUnique({ where: { id }, select: { name: true, deletedAt: true } });
    // Цели нет или она в корзине — буфер бессмысленный, но чистить его молча не будем:
    // пользователь должен увидеть, что вставка невозможна, а не «буфер сам опустел».
    const available = Boolean(target && !target.deletedAt);

    return {
      kind,
      mode,
      id,
      name: target?.name ?? 'недоступно',
      available,
      at: user?.clipboardAt ? user.clipboardAt.toISOString() : null,
    };
  }

  /** Положить в буфер файл или папку. Цель проверяется на своё и живое — иначе 404. */
  async set(userId: string, kind: ClipboardKind, id: string, mode: ClipboardMode): Promise<ClipboardView> {
    if (kind === 'folder' && mode === 'copy') throw badRequest('копирование папок не поддерживается');
    if (kind === 'file') {
      const entry = await this.prisma.fileEntry.findUnique({ where: { id }, select: { deletedAt: true } });
      if (!entry || entry.deletedAt) throw notFound('file not found');
      if (!(await this.auth.ownEntry(userId, id))) throw notFound('file not found');
    } else {
      const folder = await this.prisma.folder.findUnique({ where: { id }, select: { deletedAt: true } });
      if (!folder || folder.deletedAt) throw notFound('folder not found');
      if (!(await this.auth.folderOwnedBy(userId, id))) throw notFound('folder not found');
    }
    await this.prisma.user.update({
      where: { id: userId },
      data: { clipboardKind: kind, clipboardId: id, clipboardMode: mode, clipboardAt: new Date() },
    });
    const view = await this.get(userId);
    this.logger.log(`${mode === 'copy' ? 'копирование' : 'вырезание'}: ${kind} ${id} (${view?.name ?? '?'})`);
    return view!;
  }

  async clear(userId: string): Promise<void> {
    await this.prisma.user.update({
      where: { id: userId },
      data: { clipboardKind: null, clipboardId: null, clipboardMode: null, clipboardAt: null },
    });
  }

  /**
   * Вставка в папку. Вырезание = перенос (запись сохраняет id, другие клиенты видят move,
   * а не «удали + создай»), копирование файла = новая запись на тот же ассет: байты в S3
   * не дублируются, дедуп по sha256. После переноса буфер очищается, после копирования —
   * остаётся: так можно разложить один файл по нескольким папкам.
   */
  async paste(userId: string, folderId: string): Promise<{ ok: true; action: 'moved' | 'copied'; name: string }> {
    const view = await this.get(userId);
    if (!view) throw badRequest('буфер пуст', 'clipboard_empty');
    if (!view.available) throw badRequest('источника больше нет — скопируйте заново', 'clipboard_source_gone');

    const target = await this.prisma.folder.findUnique({ where: { id: folderId } });
    if (!target || target.deletedAt) throw notFound('folder not found');
    if (!(await this.auth.folderOwnedBy(userId, target.id))) throw notFound('folder not found');
    // в скрытую зону («Почта») вставлять нечего: файл там остался бы без письма и не был
    // бы виден ни в одном разделе
    if (isHiddenZone(target.zone)) throw notFound('folder not found');

    if (view.kind === 'folder') {
      await this.folders.move(view.id, target.id, userId);
      await this.clear(userId);
      return { ok: true, action: 'moved', name: view.name };
    }

    if (view.mode === 'cut') {
      await this.files.patch(view.id, userId, { folderId: target.id });
      await this.clear(userId);
      return { ok: true, action: 'moved', name: view.name };
    }

    const name = await this.copyFile(userId, view.id, target.id);
    return { ok: true, action: 'copied', name };
  }

  /**
   * Копия файла: та же запись ассета, новое имя (первое свободное) и папка.
   *
   * Полностью повторить `FilesService.createEntry` здесь нельзя (он про перезапись имени,
   * оптимистичную блокировку и восстановление из корзины — вставке это не нужно), но его
   * поведение повторяем: занятое имя из корзины — это `in_trash`, а не повод придумать
   * «(копия N)», и гонка на уникальном индексе отдаётся как 409, а не как 500 от Prisma.
   * Медиа-шаг нужен только при копировании в «Фото» из обычной зоны: если источник уже
   * в медиазоне, у ассета всё собрано, а вот файл с диска, скопированный в «Фото», без
   * разбора метаданных и задачи превью в ленту не попадёт никогда (см. files.patch).
   *
   * Имя подбирается вне транзакции, потому что это отдельный SELECT на каждого кандидата,
   * а транзакция нужна только чтобы запись и событие журнала появились вместе; окончательную
   * уникальность даёт индекс (folderId, name), а не проверка — она лишь выбирает имя.
   */
  private async copyFile(userId: string, entryId: string, folderId: string): Promise<string> {
    const entry = await this.prisma.fileEntry.findUnique({ where: { id: entryId }, include: { asset: true } });
    if (!entry || entry.deletedAt) throw notFound('file not found');
    const target = await this.prisma.folder.findUnique({ where: { id: folderId }, select: { zone: true } });
    const zone = zoneOf(target?.zone);

    // Имя: сначала как у источника, дальше «(копия)», «(копия 2)»… Длина проверяется
    // тем же assertSafeName, что и везде: 255 байт, из-за чего длинные имена укорачиваем.
    let name = entry.name;
    for (let i = 0; i < COPY_NAME_ATTEMPTS; i++) {
      const candidate = i === 0 ? name : withSuffix(entry.name, i);
      const clash = await this.prisma.fileEntry.findFirst({ where: { folderId, name: candidate } });
      if (!clash) { name = candidate; break; }
      // уникальный индекс распространяется и на корзину: имя, занятое удалённой записью,
      // не «свободно» — клиенту честнее сказать «восстанови или удали насовсем»
      if (clash.deletedAt) {
        throw conflict('file with this name is in trash — restore or purge it first', 'in_trash', {
          entryId: clash.id,
          name: candidate,
        });
      }
      if (i === COPY_NAME_ATTEMPTS - 1) throw badRequest('слишком много копий с таким именем', 'copy_name_exhausted');
    }

    const created = await this.prisma
      .$transaction(async (tx) => {
        const row = await tx.fileEntry.create({
          data: {
            folderId,
            assetId: entry.assetId,
            name,
            zone,
          },
          select: { id: true, name: true, folderId: true, zone: true },
        });
        // Журнал изменений: без записи копия не доедет до других клиентов (Android, WebDAV)
        await this.changes.record(
          {
            userId,
            target: 'entry',
            op: 'create',
            targetId: row.id,
            folderId: row.folderId,
            name: row.name,
            zone: row.zone,
            sha256: entry.asset.sha256,
            size: Number(entry.asset.size),
            mime: entry.asset.mime,
          },
          tx,
        );
        return row;
      })
      .catch((e: unknown) => {
        if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
          throw conflict('file with this name already exists (created concurrently)');
        }
        throw e;
      });

    // Копия попала в медиа-зону из обычной: без метаданных и задачи превью её нет в ленте
    if (created.zone === ZONE_PHOTOS && entry.zone !== ZONE_PHOTOS) {
      await this.media
        .captureAny(entry.assetId, entry.asset.sha256, Number(entry.asset.size), entry.asset.mime)
        .catch(() => undefined);
      await this.queue.enqueue(entry.assetId, entry.asset.sha256, entry.asset.mime).catch(() => undefined);
    }
    this.logger.log(`копия файла: ${entry.name} → ${created.name}`);
    return created.name;
  }
}

/** «photo.jpg» + 2 → «photo (копия 2).jpg»; расширение остаётся на месте. */
function withSuffix(name: string, n: number): string {
  const suffix = n > 1 ? ` (копия ${n})` : COPY_SUFFIX;
  const dot = name.lastIndexOf('.');
  const base = dot > 0 ? name.slice(0, dot) : name;
  const ext = dot > 0 ? name.slice(dot) : '';
  // 255 байт — предел assertSafeName; режем базу, а не расширение
  const candidate = `${base}${suffix}${ext}`;
  if (Buffer.byteLength(candidate, 'utf8') <= 255) return candidate;
  const keep = Math.max(1, 255 - Buffer.byteLength(suffix + ext, 'utf8'));
  const trimmed = Buffer.from(base, 'utf8').subarray(0, keep).toString('utf8').replace(/\uFFFD$/, '');
  return `${trimmed}${suffix}${ext}`;
}
