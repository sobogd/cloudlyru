import {
  BadRequestException,
  HttpException,
  Injectable,
  Logger,
  UnauthorizedException,
} from '@nestjs/common';
import { createHash } from 'crypto';
import { Transform } from 'stream';
import { pipeline } from 'stream/promises';
import { AuthService, ROOT_FOLDER_NAME } from '../auth/auth.service';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { FilesService } from '../files/files.service';
import { MediaService } from '../media/media.service';
import { QueueService } from '../queue/queue.service';
import { ChangesService } from '../sync/changes.service';
import { assertSafeName, randomToken } from '../common/utils';
import { HIDDEN_ZONES, ZONE_PHOTOS, isHiddenZone, zoneOf } from '../common/zones';
import { setCurrentDeviceId } from '../common/request-context';
import { MAX_FILE_BYTES } from '../config/env';
import { notFound, payloadTooLarge } from '../common/errors';

export class DavError extends Error {}

/**
 * Сколько объектов папки готов отдать PROPFIND. Листинг WebDAV не пагинируется, а XML
 * собирается строкой в памяти: папка на 100 000 файлов — это десятки мегабайт строки и
 * минуты ответа. Молча обрезать список нельзя (клиент решит, что файлов нет, и, например,
 * rclone с `--delete` снесёт их у себя), поэтому превышение лимита — честный 507.
 */
const DAV_LIST_LIMIT = 10_000;

/** 507 Insufficient Storage (RFC 4918): в HttpStatus этой версии Nest его нет. */
const INSUFFICIENT_STORAGE = 507;

/**
 * Строгая сверка логина из Basic (DAV_VALIDATE_LOGIN=true). По умолчанию выключена:
 * секрет здесь — токен, а поле «пользователь» в Finder/rclone заполняет человек, и у уже
 * настроенных клиентов там может стоять что угодно. Включённая по умолчанию проверка
 * отдала бы им 401 и «не удалось подключиться».
 */
const DAV_VALIDATE_LOGIN = process.env.DAV_VALIDATE_LOGIN === 'true' || process.env.DAV_VALIDATE_LOGIN === '1';

@Injectable()
export class DavService {
  private readonly logger = new Logger('Dav');
  /**
   * Логин владельца токена, по userId. WebDAV-клиенты (Finder, rclone) делают сотни запросов
   * за проход, и лишний запрос в БД на каждый из них был бы заметен: логин меняется разве что
   * руками в БД, поэтому кэш в памяти процесса уместен (живёт до рестарта).
   */
  private readonly loginCache = new Map<string, string>();

  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly files: FilesService,
    private readonly auth: AuthService,
    private readonly media: MediaService,
    private readonly queue: QueueService,
    private readonly changes: ChangesService,
  ) {}

  /**
   * Проверка Authorization: Basic login:apptoken → владелец и scope токена.
   * Схема разбирается регистронезависимо (`basic` тоже принимается), а логин по умолчанию
   * не сверяется — см. DAV_VALIDATE_LOGIN.
   */
  async authenticate(req: { headers: Record<string, unknown> }): Promise<{ userId: string; scope: string }> {
    const h = req.headers['authorization'];
    if (typeof h !== 'string' || !/^basic\s+/i.test(h)) throw new UnauthorizedException('Basic auth required');
    const decoded = Buffer.from(h.replace(/^basic\s+/i, ''), 'base64').toString('utf8');
    const idx = decoded.indexOf(':');
    const login = idx >= 0 ? decoded.slice(0, idx) : '';
    const token = idx >= 0 ? decoded.slice(idx + 1) : decoded;
    const auth = await this.auth.resolveApiToken(token);
    if (!auth) throw new UnauthorizedException('invalid token');
    // deviceId в журнале изменений: тот же смысл, что у Bearer-гарда (AuthGuard). Без этого
    // правки из Finder уходили клиентам синхронизации без источника (deviceId = null).
    setCurrentDeviceId(auth.tokenId);
    await this.checkLogin(login, auth.userId);
    return auth;
  }

  /** Сверка логина из Basic с логином владельца токена (поведение задаёт DAV_VALIDATE_LOGIN). */
  private async checkLogin(login: string, userId: string): Promise<void> {
    if (!login) return;
    let ownerLogin = this.loginCache.get(userId);
    if (ownerLogin === undefined) {
      const user = await this.prisma.user.findUnique({ where: { id: userId }, select: { login: true } });
      ownerLogin = user?.login ?? '';
      this.loginCache.set(userId, ownerLogin);
    }
    if (!ownerLogin || ownerLogin.toLowerCase() === login.toLowerCase()) return;
    if (DAV_VALIDATE_LOGIN) throw new UnauthorizedException('invalid login');
    this.logger.warn(
      `WebDAV: логин «${login}» не совпадает с логином владельца токена — вход разрешён, потому что DAV_VALIDATE_LOGIN не включён`,
    );
  }

  // ---- path → сущность ----
  // '/' — корень; '/a/b.txt' — вложенные папки/файл. Путь приходит уже декодированным
  // (см. davPathOf в контроллере) — повторно decodeURIComponent здесь вызывать нельзя.

  private async folderByPath(userId: string, parts: string[]) {
    const rootId = await this.auth.rootFolderId(userId);
    const photoId = await this.auth.photoRootIdOrNull(userId);
    let folderId = rootId;
    for (const name of parts) {
      const f = await this.prisma.folder.findFirst({ where: { parentId: folderId, name, deletedAt: null } });
      if (!f) return null;
      // системная медиатека «Фото» скрыта в WebDAV (как и в разделе «Файлы»). Отсекается
      // именно корень (`f.id === photoId`): дочерние папки под ним недостижимы лишь потому,
      // что обход спотыкается на самом корне. Если из этой функции когда-нибудь уберут
      // пошаговый обход, «Фото» станет доступно снаружи — проверку надо будет повторить.
      if (photoId && f.id === photoId) return null;
      // скрытые зоны (папка «Почта» с вложениями писем) недостижимы и по прямому пути:
      // в листинге их нет, но клиент мог бы угадать имя
      if (isHiddenZone(f.zone)) return null;
      folderId = f.id;
    }
    return folderId;
  }

  private async entryByPath(userId: string, parts: string[]) {
    if (parts.length === 0) return null;
    const parentParts = parts.slice(0, -1);
    const parentId = await this.folderByPath(userId, parentParts);
    if (!parentId) return null;
    const name = parts[parts.length - 1];
    return this.prisma.fileEntry.findFirst({
      where: { folderId: parentId, name, deletedAt: null },
      // размер и тип нужны PROPFIND: у файла их больше взять негде, а без них клиент
      // (Finder, rclone) видит файл пустым и переливает его при каждом проходе
      include: { asset: { select: { size: true, mime: true } } },
    });
  }

  private async folderMeta(folderId: string) {
    const f = await this.prisma.folder.findUnique({ where: { id: folderId } });
    return f;
  }

  /**
   * Листинг папки или свойства файла.
   *
   * `Depth` больше единицы намеренно трактуется как один уровень: клиенты (Finder, rclone)
   * просят `Depth: infinity`, а рекурсивный обход всего дерева в одном ответе — это XML на
   * десятки мегабайт и минуты работы. RFC 4918 разрешает отвечать только на запрошенный
   * ресурс и его детей, поэтому `infinity` = `1`.
   */
  async propfind(userId: string, davPath: string, depth: string) {
    const parts = davPath.split('/').filter(Boolean);
    const entry = await this.entryByPath(userId, parts);
    const rootId = await this.auth.rootFolderId(userId);
    const photoId = await this.auth.photoRootIdOrNull(userId);

    let responses: Array<{
      href: string;
      isCollection: boolean;
      name: string;
      size?: number;
      mime?: string;
      mtime?: Date;
    }> = [];

    if (entry) {
      // настоящие размер и mtime: раньше здесь стояли `size: 0` и отсутствие getlastmodified,
      // то есть для клиента файл выглядел пустым и «изменившимся» — rclone переливал его
      // при каждом проходе, Finder показывал 0 байт
      responses.push({
        href: davPath,
        isCollection: false,
        name: entry.name,
        size: Number(entry.asset.size),
        mime: entry.asset.mime,
        mtime: entry.updatedAt,
      });
    } else {
      const folderId = parts.length ? await this.folderByPath(userId, parts) : rootId;
      if (!folderId) throw notFound('path not found');
      const folder = await this.folderMeta(folderId);
      if (!folder || folder.deletedAt || isHiddenZone(folder.zone)) throw notFound('path not found');
      const href = '/' + parts.join('/');
      responses.push({ href: href === '/' ? '/' : href, isCollection: true, name: folder.name, mtime: folder.updatedAt });
      if (depth !== '0') {
        const [folders, entries] = await Promise.all([
          this.prisma.folder.findMany({
            where: { parentId: folderId, deletedAt: null, zone: { notIn: [...HIDDEN_ZONES] } },
            orderBy: { name: 'asc' },
            take: DAV_LIST_LIMIT + 1,
          }),
          this.prisma.fileEntry.findMany({
            where: { folderId, deletedAt: null, zone: { notIn: [...HIDDEN_ZONES] } },
            orderBy: { name: 'asc' },
            include: { asset: { select: { size: true, mime: true } } },
            take: DAV_LIST_LIMIT + 1,
          }),
        ]);
        // обрезанный листинг опаснее ошибки: клиент считает отсутствующие в ответе файлы
        // удалёнными и (rclone с --delete, Finder при синхронизации) может снести их у себя
        if (folders.length + entries.length > DAV_LIST_LIMIT) {
          throw new HttpException(
            {
              statusCode: INSUFFICIENT_STORAGE,
              message: `в папке больше ${DAV_LIST_LIMIT} объектов — WebDAV-листинг столько не отдаёт`,
              code: 'listing_too_large',
            },
            INSUFFICIENT_STORAGE,
          );
        }
        for (const c of folders) {
          if (photoId && c.id === photoId) continue; // системная «Фото» не показывается в Finder
          responses.push({ href: `${href === '/' ? '' : href}/${encodeURIComponent(c.name)}`, isCollection: true, name: c.name, mtime: c.updatedAt });
        }
        for (const c of entries) {
          responses.push({
            href: `${href === '/' ? '' : href}/${encodeURIComponent(c.name)}`,
            isCollection: false,
            name: c.name,
            size: Number(c.asset.size),
            mime: c.asset.mime,
            // updatedAt, а не createdAt: перезапись через PUT (Finder/rclone) меняет
            // содержимое, и с датой создания «mtime» навсегда остался бы в прошлом
            mtime: c.updatedAt,
          });
        }
      }
    }
    return this.renderMultistatus(responses);
  }

  async mkcol(userId: string, davPath: string) {
    const parts = davPath.split('/').filter(Boolean);
    if (parts.length === 0) throw new BadRequestException('invalid path');
    const parentId = await this.folderByPath(userId, parts.slice(0, -1));
    if (!parentId) throw notFound('parent not found');
    const name = parts[parts.length - 1]; // путь уже декодирован контроллером
    try {
      assertSafeName(name);
    } catch {
      throw new BadRequestException('invalid name');
    }
    const dup = await this.prisma.folder.findFirst({ where: { parentId, name } });
    if (dup) throw new BadRequestException('already exists');
    // имя системного корня зарезервировано: папка с ним считается корнем и становится
    // неуправляемой (её нельзя переименовать, переместить или удалить)
    if (name === ROOT_FOLDER_NAME) throw new BadRequestException('reserved name');
    const parent = await this.prisma.folder.findUnique({ where: { id: parentId }, select: { zone: true } });
    const zone = zoneOf(parent?.zone);
    await this.prisma.$transaction(async (tx) => {
      const created = await tx.folder.create({
        data: { parentId, name, zone },
        select: { id: true },
      });
      await this.changes.record(
        {
          userId,
          target: 'folder',
          op: 'create',
          targetId: created.id,
          folderId: parentId,
          name,
          zone,
        },
        tx,
      );
    });
    return 201;
  }

  /**
   * Запись файла целиком (Finder и rclone перезаписывают содержимое, а не патчат его).
   *
   * Размер ограничен MAX_FILE_BYTES, как и у `/uploads`: `Content-Length` приходит не всегда
   * (`Transfer-Encoding: chunked` у rclone), поэтому байты считаются на лету и запись рвётся
   * на превышении — иначе одним PUT можно положить в бакет десятки гигабайт (это ещё и
   * оплачиваемый трафик), тогда как через `/uploads` тот же файл получил бы 413.
   */
  async put(userId: string, davPath: string, body: NodeJS.ReadableStream, contentLength: number | null, contentType: string) {
    const parts = davPath.split('/').filter(Boolean);
    if (parts.length === 0) throw new BadRequestException('invalid path');
    const parentId = await this.folderByPath(userId, parts.slice(0, -1));
    if (!parentId) throw notFound('parent not found');
    const parent = await this.prisma.folder.findUnique({ where: { id: parentId }, select: { zone: true } });
    const zone = zoneOf(parent?.zone);
    const name = parts[parts.length - 1]; // путь уже декодирован контроллером
    try {
      assertSafeName(name);
    } catch {
      throw new BadRequestException('invalid name');
    }
    const maxGb = Math.floor(MAX_FILE_BYTES / 1024 ** 3);
    if (contentLength !== null && contentLength <= 0) throw new BadRequestException('empty body');
    if (contentLength !== null && contentLength > MAX_FILE_BYTES) {
      throw payloadTooLarge(`файл больше ${maxGb} ГиБ`);
    }

    // Стримим в S3 с инкрементальным sha256: счётчик байтов и хэш идут одним трансформом.
    // pipeline, а не `tee.write(...)`: он держит backpressure (на медленном S3 тело PUT
    // иначе копилось в памяти процесса) и корректно разрушает поток при ошибке.
    const hash = createHash('sha256');
    let seen = 0;
    const meter = new Transform({
      transform(chunk, _enc, cb) {
        const b = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        seen += b.length;
        if (seen > MAX_FILE_BYTES) {
          cb(payloadTooLarge(`файл больше ${maxGb} ГиБ — запись прервана`));
          return;
        }
        hash.update(b);
        cb(null, b);
      },
    });

    // случайный ключ: хэш от имени и времени у двух параллельных PUT одного имени совпадал,
    // и клиенты писали в один объект, портя друг другу байты
    const tmpKey = `files/tmp/${randomToken(16)}`;
    const mime = contentType || 'application/octet-stream';

    // Оба промиса ждём ВМЕСТЕ. Если ждать их по очереди, отменённая клиентом загрузка
    // (Finder отменил копирование, rclone получил Ctrl-C, сеть упала) роняет процесс:
    // `reader` отклонялся раньше, чем до его `await` доходило управление, и отклонение
    // оставалось необработанным (ERR_UNHANDLED_REJECTION в Node 18+ — фатально).
    try {
      await Promise.all([
        this.s3.putObjectStream(tmpKey, meter, mime, contentLength ?? undefined),
        pipeline(body, meter),
      ]);
    } catch (e) {
      // недозалитый объект во временном префиксе не нужен: подобрать его некому
      await this.s3.deleteObject(tmpKey).catch(() => undefined);
      throw e;
    }

    const sha256 = hash.digest('hex');
    const finalKey = S3Service.assetKey(sha256);
    // Размер — сколько байт реально прошло через поток. При chunked `Content-Length` не
    // приходит вовсе, и раньше размер узнавался отдельным запросом в S3 уже после загрузки;
    // для «файл перезаливается вечно» в журнале синхронизации это и был источник нулей.
    const size = seen;

    const existing = await this.prisma.asset.findUnique({ where: { sha256 } });
    let assetId: string;
    let deduped = false;
    if (existing) {
      deduped = true;
      assetId = existing.id;
    } else {
      await this.s3.copyObject(tmpKey, finalKey);
      assetId = await this.files.ensureAsset(sha256, size, mime, this.extOf(name));
    }
    await this.s3.deleteObject(tmpKey).catch(() => undefined);

    // Метаданные — для любых фото и видео, независимо от зоны
    await this.media.captureAny(assetId, sha256, size, mime).catch(() => undefined);

    // Превью и конвертация — только для медиа-зоны («Фото»); в «Файлы» файл ложится как есть
    if (zone === ZONE_PHOTOS) {
      await this.queue.enqueue(assetId, sha256, mime);
    }

    // перезапись существующего файла с тем же именем — обновляем entry на новый asset.
    // Через FilesService.createEntry(replace): id записи сохраняется, а в журнал изменений
    // уходит update (а не «удали + создай»), иначе клиенты синхронизации перекачивали бы файл.
    const existed = await this.prisma.fileEntry.findFirst({ where: { folderId: parentId, name } });
    await this.files.createEntry(parentId, name, assetId, {
      userId,
      replace: true,
      // Finder/rclone перезаписывают файл, не зная про корзину: возврат из неё для них —
      // ожидаемое поведение (раньше так и было). Клиент синхронизации такого флага не шлёт.
      restoreDeleted: true,
      asset: { sha256, size, mime },
    });
    return existed ? 204 : 201;
  }

  /**
   * Содержимое файла для GET: ключ в S3 и имя. Байты отдаёт контроллер потоком —
   * раньше здесь выдавалась presigned-ссылка, которая живёт 15 минут без авторизации.
   */
  async getContent(
    userId: string,
    davPath: string,
  ): Promise<{ key: string; mime: string; size: number; name: string }> {
    const parts = davPath.split('/').filter(Boolean);
    const entry = await this.entryByPath(userId, parts);
    if (!entry) throw notFound('file not found');
    const asset = await this.prisma.asset.findUnique({ where: { id: entry.assetId } });
    if (!asset) throw notFound('file not found');
    return {
      key: S3Service.assetKey(asset.sha256),
      mime: asset.mime,
      size: Number(asset.size),
      name: entry.name,
    };
  }

  async headMeta(userId: string, davPath: string): Promise<{ mime: string; size: number }> {
    const parts = davPath.split('/').filter(Boolean);
    const entry = await this.entryByPath(userId, parts);
    if (!entry) throw notFound('file not found');
    const asset = await this.prisma.asset.findUnique({ where: { id: entry.assetId } });
    if (!asset) throw notFound('file not found');
    return { mime: asset.mime, size: Number(asset.size) };
  }

  async delete(userId: string, davPath: string) {
    const parts = davPath.split('/').filter(Boolean);
    if (parts.length === 0) throw new BadRequestException('cannot delete root');
    const entry = await this.entryByPath(userId, parts);
    if (entry) {
      await this.prisma.$transaction(async (tx) => {
        await tx.fileEntry.update({ where: { id: entry.id }, data: { deletedAt: new Date() } });
        await this.changes.recordEntry(userId, entry.id, 'delete', tx);
      });
      return 204;
    }
    const parentId = await this.folderByPath(userId, parts.slice(0, -1));
    const name = parts[parts.length - 1];
    const folder = parentId
      ? await this.prisma.folder.findFirst({ where: { parentId, name, deletedAt: null } })
      : await this.prisma.folder.findFirst({ where: { parentId: null, name, deletedAt: null } });
    if (!folder) throw notFound('path not found');
    if (folder.name === '__root__') throw new BadRequestException('cannot delete root');
    // корни «Фото», «Телефон» и зеркал устройств — одним списком (см. protectedFolderIds)
    const protectedIds = await this.auth.protectedFolderIds(userId);
    if (protectedIds.has(folder.id)) throw new BadRequestException(`cannot delete system folder "${folder.name}"`);
    // мягкое удаление поддерева
    const ids: string[] = [folder.id];
    const seen = new Set<string>([folder.id]);
    let frontier = [folder.id];
    while (frontier.length) {
      const children = await this.prisma.folder.findMany({ where: { parentId: { in: frontier } }, select: { id: true } });
      // seen — защита от вечного цикла, если дерево уже успели испортить конкурентные перемещения
      const next = children.map((c) => c.id).filter((cid) => !seen.has(cid));
      if (!next.length) break;
      for (const cid of next) seen.add(cid);
      ids.push(...next);
      frontier = next;
    }
    await this.prisma.$transaction(async (tx) => {
      await tx.folder.updateMany({ where: { id: { in: ids } }, data: { deletedAt: new Date() } });
      // одно событие на корень поддерева: «папка удалена» ⇒ всего её содержимого нет
      await this.changes.recordFolderTreeDeleted(userId, folder.id, tx);
    });
    return 204;
  }

  /** Находится ли папка внутри поддерева другой (защита от перемещения папки в саму себя). */
  private async isInside(folderId: string, candidateId: string): Promise<boolean> {
    let current: string | null = candidateId;
    for (let i = 0; i < 64 && current; i++) {
      if (current === folderId) return true;
      const row: { parentId: string | null } | null = await this.prisma.folder.findUnique({
        where: { id: current },
        select: { parentId: true },
      });
      current = row?.parentId ?? null;
    }
    return false;
  }

  async move(userId: string, srcPath: string, dstPath: string) {
    // rename/move в пределах дерева: переименование конечного сегмента (папки или файла)
    const srcParts = srcPath.split('/').filter(Boolean);
    const dstParts = dstPath.split('/').filter(Boolean);
    if (!srcParts.length || !dstParts.length) throw new BadRequestException('invalid path');
    const newName = dstParts[dstParts.length - 1]; // путь уже декодирован контроллером
    try {
      assertSafeName(newName);
    } catch {
      throw new BadRequestException('invalid name');
    }
    // Папка назначения: MOVE может быть не только переименованием, но и переносом в другой
    // каталог — раньше она игнорировалась и rclone/Finder получали «переименовал» вместо переноса.
    const dstParentId = await this.folderByPath(userId, dstParts.slice(0, -1));
    if (!dstParentId) throw notFound('destination folder not found');

    const entry = await this.entryByPath(userId, srcParts);
    if (entry) {
      const targetFolderId = dstParentId;
      const dup = await this.prisma.fileEntry.findFirst({
        where: { folderId: targetFolderId, name: newName, id: { not: entry.id } },
      });
      if (dup) throw new BadRequestException('already exists');
      const moved = entry.folderId !== targetFolderId;
      await this.prisma.$transaction(async (tx) => {
        await tx.fileEntry.update({
          where: { id: entry.id },
          data: { name: newName, folderId: targetFolderId },
        });
        await this.changes.recordEntry(userId, entry.id, moved ? 'move' : 'update', tx);
      });
      return 204;
    }
    const parentId = await this.folderByPath(userId, srcParts.slice(0, -1));
    const folder = parentId
      ? await this.prisma.folder.findFirst({ where: { parentId, name: srcParts[srcParts.length - 1], deletedAt: null } })
      : await this.prisma.folder.findFirst({ where: { parentId: null, name: srcParts[srcParts.length - 1], deletedAt: null } });
    if (!folder) throw notFound('path not found');
    if (folder.name === ROOT_FOLDER_NAME) throw new BadRequestException('cannot rename root');
    const protectedIds = await this.auth.protectedFolderIds(userId);
    if (protectedIds.has(folder.id)) {
      throw new BadRequestException(`cannot rename/move system folder "${folder.name}"`);
    }
    const dup = await this.prisma.folder.findFirst({ where: { parentId: dstParentId, name: newName, id: { not: folder.id } } });
    if (dup) throw new BadRequestException('already exists');
    if (newName === ROOT_FOLDER_NAME) throw new BadRequestException('reserved name');
    if (dstParentId === folder.id) throw new BadRequestException('cannot move folder into itself');
    const subtree = await this.auth.subtreeIds(userId, { includeDeleted: true });
    if (subtree.includes(folder.id) && (await this.isInside(folder.id, dstParentId))) {
      throw new BadRequestException('cannot move folder into its own subtree');
    }
    const moved = folder.parentId !== dstParentId;
    await this.prisma.$transaction(async (tx) => {
      await tx.folder.update({ where: { id: folder.id }, data: { name: newName, parentId: dstParentId } });
      await this.changes.recordFolder(userId, folder.id, moved ? 'move' : 'update', tx);
    });
    return 204;
  }

  // ============ XML ============

  private esc(s: string): string {
    return s
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  private renderMultistatus(
    items: Array<{ href: string; isCollection: boolean; name: string; size?: number; mime?: string; mtime?: Date }>,
  ): string {
    const rows = items
      .map((it) => {
        const type = it.isCollection ? '<D:collection/>' : '';
        const len = it.isCollection ? '' : `<D:getcontentlength>${it.size ?? 0}</D:getcontentlength>`;
        // тип берём у ассета: захардкоженный application/octet-stream заставлял Finder
        // показывать файлы без иконок и «неизвестного типа»
        const ct = it.isCollection
          ? ''
          : `<D:getcontenttype>${this.esc(it.mime ?? 'application/octet-stream')}</D:getcontenttype>`;
        const mtime = it.mtime ? `<D:getlastmodified>${it.mtime.toUTCString()}</D:getlastmodified>` : '';
        return `<D:response><D:href>${this.esc(it.href)}</D:href><D:propstat><D:prop><D:displayname>${this.esc(it.name)}</D:displayname><D:resourcetype>${type}</D:resourcetype>${len}${ct}${mtime}</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>`;
      })
      .join('');
    return `<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">${rows}</D:multistatus>`;
  }

  private extOf(name: string): string | undefined {
    const i = name.lastIndexOf('.');
    if (i <= 0 || i === name.length - 1) return undefined;
    return name.slice(i + 1).toLowerCase().slice(0, 16);
  }
}
