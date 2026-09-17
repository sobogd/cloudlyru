import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import * as argon2 from 'argon2';
import { env } from '../config/env';
import { PrismaService } from '../prisma/prisma.service';
import { randomToken, sha256Hex, assertSafeName } from '../common/utils';
import { MAIL_FOLDER_NAME, PHOTO_FOLDER_NAME, ZONE_MAIL, ZONE_PHOTOS } from '../common/zones';
import { AuditService } from '../audit/audit.service';
import { ChangesService } from '../sync/changes.service';
import { badRequest, notFound, unauthorized } from '../common/errors';

export const ROOT_FOLDER_NAME = '__root__';

/** Потолок живых device-токенов на пользователя. */
export const MAX_API_TOKENS_PER_USER = 32;

/** Потолок длины метки токена: из неё строится имя папки-зеркала (см. createToken). */
const MAX_TOKEN_LABEL_BYTES = 64;

/** Потолок живых веб-сессий на пользователя (см. login). */
export const MAX_SESSIONS_PER_USER = 32;

/**
 * Минимальная длина пароля владельца. Проверяется в двух местах: при seed на пустой БД
 * в production (иначе на пустом .env создаётся владелец admin/admin и публичный
 * POST /auth/login открывает все файлы и почту) и при смене пароля.
 */
const MIN_PASSWORD_LEN = 12;

/**
 * Потолки входа. Пароль приходит телом запроса, а argon2 считает памятью: без потолка
 * «пароль» на мегабайт — это отказ в обслуживании на каждом логине.
 */
const MAX_LOGIN_LEN = 128;
const MAX_PASSWORD_LEN = 1024;

/** Как часто убирать протухшие сессии: сессии живут неделями, чаще незачем. */
const SESSION_SWEEP_MS = 60 * 60 * 1000;

/**
 * Хеш-заглушка для холостого `argon2.verify` при неизвестном логине: без него ответ
 * возвращался мгновенно (проверка хеша не запускалась вовсе), и логины перечислялись
 * по времени ответа, хотя текст ошибки одинаков.
 */
const DUMMY_PASSWORD_HASH =
  '$argon2id$v=19$m=65536,t=3,p=4$hgjNMO7UeTbZjCd9rBQObA$ekWHM7VM5lQiOxrVC2DaXXyMciPHPCUZOYN/rxw2d5o';

/**
 * Метка токена из запроса → безопасная метка. Из метки строится имя папки-зеркала
 * (`<Метка> - Файлы`), поэтому разделители пути и управляющие символы — это 400:
 * папку с таким именем телефон не создаст, а клиент потом не найдёт свой корень.
 * Концевые точки и пробелы (Windows/SMB их не хранит) и длину санитизируем сами —
 * это не ошибка клиента, а косметика.
 */
function cleanTokenLabel(raw: unknown): string {
  const value = String(raw ?? '');
  if (/[/\\\u0000-\u001f\u007f]/.test(value)) {
    throw badRequest('label must not contain path separators or control characters');
  }
  let clean = value.trim();
  while (clean.endsWith('.') || clean.endsWith(' ')) clean = clean.slice(0, -1);
  if (!clean) return 'app';
  // режем по байтам, а не по символам: 64 кириллических символа — это 128 байт, а имя
  // папки ограничено 255 байтами вместе с суффиксом, и «обрезать» символ пополам нельзя
  while (Buffer.byteLength(clean, 'utf8') > MAX_TOKEN_LABEL_BYTES) clean = clean.slice(0, -1);
  assertSafeName(clean);
  return clean;
}

@Injectable()
export class AuthService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(AuthService.name);
  private sessionSweep: NodeJS.Timeout | null = null;

  constructor(
    private readonly prisma: PrismaService,
    private readonly audit: AuditService,
    private readonly changes: ChangesService,
  ) {}

  /** При первом старте создаёт владельца, корневую папку и системную папку «Фото». */
  async onModuleInit() {
    const count = await this.prisma.user.count();
    if (count === 0) {
      this.assertSeedCredentialsUsable();
      const passwordHash = await argon2.hash(env.ADMIN_PASSWORD);
      const user = await this.prisma.user.create({
        data: { login: env.ADMIN_LOGIN, passwordHash },
      });
      const root = await this.prisma.folder.create({
        data: { name: ROOT_FOLDER_NAME, parentId: null },
      });
      const photo = await this.prisma.folder.create({
        data: { parentId: root.id, name: PHOTO_FOLDER_NAME, zone: ZONE_PHOTOS },
      });
      // «Телефон» больше не заводим: корень зеркала теперь свой у каждого устройства
      // (ApiToken.mirrorFolderId), а общая на всех папка означала бы, что удаление файла
      // на одном телефоне уносит файлы другого.
      await this.prisma.user.update({
        where: { id: user.id },
        data: { rootFolderId: root.id, photoFolderId: photo.id },
      });
      this.logger.log(
        `Создан владелец "${env.ADMIN_LOGIN}", корневая папка и системная «${PHOTO_FOLDER_NAME}»`,
      );
    }
    // Протухшие сессии убираем сами: иначе они копятся вечно (logout — единственное, что
    // их удаляет, а он не единственный способ расстаться с браузером). Первый проход сразу,
    // дальше по таймеру; unref — чтобы таймер не держал процесс при выключении.
    await this.pruneExpiredSessions().catch((e) => this.logger.warn(`уборка сессий: ${e.message}`));
    this.sessionSweep = setInterval(() => {
      void this.pruneExpiredSessions().catch((e) => this.logger.warn(`уборка сессий: ${e.message}`));
    }, SESSION_SWEEP_MS);
    this.sessionSweep.unref();
  }

  onModuleDestroy() {
    if (this.sessionSweep) clearInterval(this.sessionSweep);
    this.sessionSweep = null;
  }

  /** Сессии с истёкшим сроком мертвы по определению — строка нужна только для удаления. */
  private async pruneExpiredSessions(): Promise<number> {
    const res = await this.prisma.session.deleteMany({ where: { expiresAt: { lte: new Date() } } });
    if (res.count) this.logger.log(`убрано протухших сессий: ${res.count}`);
    return res.count;
  }

  /**
   * Проверка учётки, которой будет создан владелец. Стоит только на пути seed (пустая БД):
   * ADMIN_PASSWORD читается ровно один раз — при создании владельца, — поэтому на живой базе
   * (а значит, и на существующем .env прода) эта проверка ничего не меняет и старт не ломает.
   * Сменить пароль потом можно ручкой POST /auth/password, не трогая .env.
   *
   * По смыслу это страховка на месте действия: та же проверка есть в src/config/env.ts на
   * старте процесса, но она смотрит переменные окружения, а здесь — то, чем реально создаётся
   * владелец. Фатально только небезопасное при любом раскладе (дефолт, плейсхолдер, пароль
   * равен логину); короткий пароль — предупреждение: отказ старта на нём означал бы, что
   * первый же деплой на пустую БД не поднимается вовсе.
   */
  private assertSeedCredentialsUsable(): void {
    const login = env.ADMIN_LOGIN.trim();
    const password = env.ADMIN_PASSWORD.trim();
    if (login.length < 3 || login.length > MAX_LOGIN_LEN) {
      throw new Error(`[auth] ADMIN_LOGIN: длина от 3 до ${MAX_LOGIN_LEN} символов`);
    }
    if (password.length > MAX_PASSWORD_LEN) {
      throw new Error(`[auth] ADMIN_PASSWORD: не длиннее ${MAX_PASSWORD_LEN} символов`);
    }
    // Вне прода дефолты admin/admin — рабочий сценарий локального запуска, там проверка не нужна
    if (env.NODE_ENV !== 'production') return;
    if (password === 'admin' || password.toLowerCase().startsWith('change_me') || password === login) {
      throw new Error(
        '[auth] отказ создавать владельца с дефолтным паролем (или паролем, равным логину): ' +
          'на пустой БД POST /auth/login публичный, и такой пароль перебирается словарём — ' +
          'это доступ ко всем файлам, почте и вложениям. Задайте ADMIN_LOGIN и ADMIN_PASSWORD.',
      );
    }
    if (password.length < MIN_PASSWORD_LEN) {
      this.logger.warn(
        `ADMIN_PASSWORD короче ${MIN_PASSWORD_LEN} символов — вход ограничен 5 попытками в минуту на IP, ` +
          'то есть пароль перебирается по словарю. Смените его (POST /auth/password) на длинный и случайный.',
      );
    }
  }


  /**
   * Логин по паролю: заводит сессию и отдаёт её токен (в БД уходит только sha256).
   *
   * Инварианты сессии: срок абсолютный и продления нет — после `expiresAt` строка мертва,
   * оживить её нельзя, а продлить только повторным логином; отозвать сессию можно ровно
   * одним способом — logout (строка удаляется); число сессий ограничено MAX_SESSIONS_PER_USER,
   * при переполнении вытесняется самая старая (иначе каждый вход навсегда добавлял строку).
   * Протухшие сессии подчищает таймер в onModuleInit.
   * Хеш здесь без pepper'а и без argon2 намеренно: токен — это 32 случайных байта (256 бит),
   * к такому пространству ни перебор, ни радужные таблицы неприменимы, а медленный хеш
   * только добавил бы работы на каждый запрос.
   */
  async login(login: string, password: string, ip?: string) {
    if (login.length > MAX_LOGIN_LEN || password.length > MAX_PASSWORD_LEN) {
      throw badRequest(`login max ${MAX_LOGIN_LEN}, password max ${MAX_PASSWORD_LEN} characters`);
    }
    const user = await this.prisma.user.findUnique({ where: { login } });
    if (!user) {
      // Холостая проверка по хешу-заглушке: иначе неизвестный логин отвечал мгновенно
      // (argon2 не запускался), и логины перечислялись по времени ответа.
      await argon2.verify(DUMMY_PASSWORD_HASH, password).catch(() => false);
      await this.audit.log('auth.login.failed', { login }, ip);
      throw unauthorized('invalid credentials');
    }
    const ok = await argon2.verify(user.passwordHash, password).catch(() => false);
    if (!ok) {
      await this.audit.log('auth.login.failed', { login }, ip);
      throw unauthorized('invalid credentials');
    }

    const token = randomToken(32);
    const ttlMs = env.SESSION_TTL_DAYS * 24 * 60 * 60 * 1000;
    await this.prisma.session.create({
      data: {
        userId: user.id,
        tokenHash: sha256Hex(token),
        expiresAt: new Date(Date.now() + ttlMs),
      },
    });
    await this.pruneOldSessions(user.id);
    await this.audit.log('auth.login', { login }, ip);
    return { token, expiresInMs: ttlMs, user: { id: user.id, login: user.login } };
  }

  /**
   * Кап на число живых сессий. Каждый вход добавляет строку, а живут они до 30 дней, поэтому
   * без потолка таблица растёт от одного повторного логина; вытесняем самые старые.
   */
  private async pruneOldSessions(userId: string): Promise<void> {
    const keep = await this.prisma.session.findMany({
      where: { userId },
      orderBy: { createdAt: 'desc' },
      take: MAX_SESSIONS_PER_USER,
      select: { id: true },
    });
    if (keep.length < MAX_SESSIONS_PER_USER) return;
    const res = await this.prisma.session.deleteMany({
      where: { userId, id: { notIn: keep.map((s) => s.id) } },
    });
    if (res.count) this.logger.log(`вытеснено старых сессий (потолок ${MAX_SESSIONS_PER_USER}): ${res.count}`);
  }

  /**
   * Выход. Идемпотентен: без токена (или с уже удалённой сессией) отвечает 200, а не 400 —
   * выход не то действие, где клиенту полезно разбираться, почему его cookie уже мертва.
   * Событие уходит в аудит: раньше выход не оставлял следа, а это штатный способ закрыть
   * доступ по украденной cookie.
   */
  async logout(token: string, ip?: string) {
    if (!token) return { ok: false };
    const res = await this.prisma.session.deleteMany({ where: { tokenHash: sha256Hex(token) } });
    await this.audit.log('auth.logout', { sessions: res.count }, ip);
    return { ok: res.count > 0 };
  }

  /**
   * Смена пароля владельца (только веб-сессия). ADMIN_PASSWORD читается лишь при seed на
   * пустой БД, поэтому смена секрета в .env ничего не меняла: пароль в БД оставался прежним,
   * а инвалидировать чужие сессии было нечем. Здесь меняем хеш и гасим ВСЕ прочие сессии,
   * оставляя живой только ту, из которой пришёл запрос (иначе владелец выкинул бы и себя,
   * а действие казалось бы неудавшимся).
   */
  async changePassword(
    userId: string,
    currentRaw: unknown,
    nextRaw: unknown,
    keepSessionToken: string,
    ip?: string,
  ): Promise<{ ok: true; sessionsRevoked: number }> {
    const current = typeof currentRaw === 'string' ? currentRaw : '';
    const next = typeof nextRaw === 'string' ? nextRaw : '';
    if (!current || !next) throw badRequest('currentPassword and newPassword are required');
    if (next.length < MIN_PASSWORD_LEN) throw badRequest(`new password must be at least ${MIN_PASSWORD_LEN} characters`);
    if (next.length > MAX_PASSWORD_LEN) throw badRequest(`new password must be at most ${MAX_PASSWORD_LEN} characters`);
    const user = await this.prisma.user.findUnique({ where: { id: userId } });
    if (!user) throw unauthorized();
    const ok = await argon2.verify(user.passwordHash, current).catch(() => false);
    if (!ok) {
      await this.audit.log('auth.password.change.failed', { userId }, ip);
      throw unauthorized('invalid credentials');
    }
    const passwordHash = await argon2.hash(next);
    await this.prisma.user.update({ where: { id: userId }, data: { passwordHash } });
    const res = await this.prisma.session.deleteMany({
      where: { userId, tokenHash: keepSessionToken ? { not: sha256Hex(keepSessionToken) } : undefined },
    });
    await this.audit.log('auth.password.change', { userId, sessionsRevoked: res.count }, ip);
    return { ok: true, sessionsRevoked: res.count };
  }

  /**
   * Гасит все веб-сессии владельца, кроме той, из которой пришёл запрос.
   *
   * Зачем отдельная ручка, если то же самое делает смена пароля: пароль меняют редко, а
   * выкинуть чужие входы нужно сразу, как только появилось подозрение (потерянный телефон,
   * чужой браузер, вход с рабочего компьютера). До этого единственным способом погасить чужую
   * сессию была смена пароля — то есть смена того, что человек помнит наизусть, ради уборки
   * входов. Сессию, из которой пришёл запрос, оставляем живой: иначе владелец выкинул бы и
   * себя, а действие выглядело бы неудавшимся.
   *
   * Что НЕ трогается: app-токены устройств (WebDAV, Finder) — у них своя таблица и свой отзыв
   * (`DELETE /auth/tokens/:id`). Сессия и токен — разные вещи, и обещать здесь «выход со всех
   * устройств» было бы враньём: синхронизация телефона ходит именно токеном.
   *
   * Побочно: удаление строк сессий и запись в аудит. Возвращает, сколько сессий погашено, —
   * по этому числу интерфейс говорит, было ли что гасить.
   */
  async revokeOtherSessions(
    userId: string,
    keepSessionToken: string,
    ip?: string,
  ): Promise<{ ok: true; sessionsRevoked: number }> {
    const res = await this.prisma.session.deleteMany({
      where: { userId, tokenHash: keepSessionToken ? { not: sha256Hex(keepSessionToken) } : undefined },
    });
    await this.audit.log('auth.sessions.revoked', { userId, sessionsRevoked: res.count }, ip);
    return { ok: true, sessionsRevoked: res.count };
  }

  /**
   * Свои данные и id системных папок. `deviceId` — id ApiToken'а, которым пришёл запрос
   * (Bearer): по нему отдаётся корень зеркала этого устройства.
   *
   * Папку зеркала (`‹Имя устройства› - Файлы`) сервер больше не заводит: что с чем
   * синхронизировать, клиент спрашивает у человека связками «папка устройства ↔ папка облака»
   * (см. `SyncLinks` в приложении). Поле в ответе остаётся только на чтение — им пользуются
   * прежние сборки приложения, у которых корень заводил сервер.
   */
  async me(userId: string, deviceId?: string | null) {
    const user = await this.prisma.user.findUnique({ where: { id: userId } });
    if (!user) throw unauthorized();
    const photoFolderId = await this.optionalSystemFolder('«Фото»', () => this.photoFolderId(userId));
    // «Телефон» только читаем: папка больше не создаётся (корень зеркала свой у каждого
    // устройства), но поле в ответе остаётся — на него завязан веб и старые сборки клиента
    const phoneFolderId = await this.optionalSystemFolder('«Телефон»', () => this.phoneRootIdOrNull(userId));
    const mirrorFolderId = await this.optionalSystemFolder('корень зеркала', () =>
      this.deviceMirrorFolderIdOrNull(deviceId),
    );
    return {
      id: user.id,
      login: user.login,
      rootFolderId: user.rootFolderId,
      photoFolderId,
      phoneFolderId,
      mirrorFolderId,
      deviceId: deviceId ?? null,
    };
  }

  /**
   * Ленивое создание системной папки в read-пути: падение одной папки не должно ронять
   * весь `GET /auth/me` (по нему клиент узнаёт свои id и без него не может синхронизироваться).
   * Но и молчать нельзя: `catch(() => null)` прятал вообще всё — и гонку за имя, и недоступную
   * БД, — а клиент получал урезанный ответ без единого следа причины в логах.
   */
  private async optionalSystemFolder(what: string, load: () => Promise<string | null>): Promise<string | null> {
    try {
      return await load();
    } catch (e) {
      this.logger.warn(`GET /auth/me: ${what} — ${(e as Error).message}`);
      return null;
    }
  }

  /** Корневая папка пользователя (создаётся лениво, если отсутствует). */
  async rootFolderId(userId: string): Promise<string> {
    const user = await this.prisma.user.findUnique({ where: { id: userId } });
    if (!user) throw unauthorized();
    if (user.rootFolderId) {
      const root = await this.prisma.folder.findUnique({ where: { id: user.rootFolderId } });
      if (root && !root.deletedAt) return root.id;
    }
    const root = await this.prisma.folder.create({ data: { name: ROOT_FOLDER_NAME, parentId: null } });
    await this.prisma.user.update({ where: { id: userId }, data: { rootFolderId: root.id } });
    return root.id;
  }

  /** id системной папки «Фото», если она уже есть (без побочных эффектов; для гардов). */
  async photoRootIdOrNull(userId: string): Promise<string | null> {
    const user = await this.prisma.user.findUnique({ where: { id: userId }, select: { photoFolderId: true } });
    return user?.photoFolderId ?? null;
  }

  /**
   * id легаси-папки «Телефон», если она уже есть (без побочных эффектов). Папка больше не
   * создаётся и не защищается от удаления: корень зеркала теперь свой у каждого устройства,
   * а старая общая папка нужна только чтобы веб и старые сборки клиента её видели.
   */
  async phoneRootIdOrNull(userId: string): Promise<string | null> {
    const user = await this.prisma.user.findUnique({ where: { id: userId }, select: { phoneFolderId: true } });
    if (!user?.phoneFolderId) return null;
    const folder = await this.prisma.folder.findUnique({
      where: { id: user.phoneFolderId },
      select: { id: true, deletedAt: true },
    });
    return folder && !folder.deletedAt ? folder.id : null;
  }

  /**
   * Корень зеркала устройства «<Имя> - Файлы», если он уже есть (без побочных эффектов).
   *
   * Папка больше не заводится: зеркало ходит по связкам «папка устройства ↔ папка облака»,
   * которые выбирает человек (см. `SyncLinks` в приложении). Здесь только чтение — по
   * ApiToken.mirrorFolderId, чтобы прежние сборки продолжали видеть свою папку. Папку убрали
   * в корзину — тоже отдаём null: корня у устройства нет.
   */
  async deviceMirrorFolderIdOrNull(tokenId?: string | null): Promise<string | null> {
    if (!tokenId) return null;
    const token = await this.prisma.apiToken.findUnique({ where: { id: tokenId } });
    if (!token?.mirrorFolderId) return null;
    const folder = await this.prisma.folder.findUnique({
      where: { id: token.mirrorFolderId },
      select: { id: true, deletedAt: true },
    });
    return folder && !folder.deletedAt ? folder.id : null;
  }

  /**
   * Свободное имя папки в корне пользователя: «Имя (2)», «(3)»… Общее и для корня зеркала,
   * и для системной «Почты»: обе заводятся в корне, и обеим может помешать тёзка — в том числе
   * лежащая в корзине, потому что уникальный индекс (parentId, name) её тоже учитывает.
   * Уточнение дописывается в конец, а не перед расширением (как в клиенте): у папки
   * расширения нет, а точка в метке устройства встречается («Pixel 7.2»).
   */
  private async freeChildFolderName(rootId: string, base: string): Promise<string> {
    const siblings = await this.prisma.folder.findMany({
      where: { parentId: rootId },
      select: { name: true },
    });
    const taken = new Set(siblings.map((f) => f.name));
    if (!taken.has(base)) return base;
    for (let i = 2; i < 1000; i++) {
      const candidate = `${base} (${i})`;
      if (!taken.has(candidate)) return candidate;
    }
    // тысяча тёзок в корне: время как уточнение (как и в android-клиенте) гарантирует свободу
    return `${base} (${Date.now()})`;
  }

  /**
   * Папки, которые нельзя удалять, переименовывать и переносить: корень пользователя, «Фото»
   * и «Почта». Собрано одним методом намеренно: пока гарды в Folders и Dav проверяли папки
   * по отдельности, новую системную папку забывали защитить в одном из мест — и клиент терял
   * адресацию.
   *
   * Папок, которые заводил сервер для синхронизации, в списке больше нет: прежний корень
   * зеркала устройства (`‹Имя устройства› - Файлы`) и легаси-«Телефон» — обычные папки, и
   * владелец вправе их удалить. Приложение их больше не заводит: что с чем синхронизировать,
   * оно спрашивает связками (см. ApiToken.mirrorFolderId — поле читается только для прежних
   * сборок клиента).
   */
  async protectedFolderIds(userId: string): Promise<Set<string>> {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { rootFolderId: true, photoFolderId: true, mailFolderId: true },
    });
    const ids = new Set<string>();
    if (user?.rootFolderId) ids.add(user.rootFolderId);
    // «Фото» и «Почта» — только живые: удалённую системную папку незачем защищать от восстановления
    const systemIds = [user?.photoFolderId, user?.mailFolderId].filter((id): id is string => Boolean(id));
    if (systemIds.length) {
      const alive = await this.prisma.folder.findMany({
        where: { id: { in: systemIds }, deletedAt: null },
        select: { id: true },
      });
      for (const f of alive) ids.add(f.id);
    }
    return ids;
  }

  /**
   * Владелец дерева, в котором лежит папка. Нужен там, где известна только папка, а журнал
   * изменений требует userId (распаковка архивов и прочие служебные записи).
   * Один рекурсивный запрос вверх: раньше это был цикл с лимитом 64 уровня, из-за чего на
   * глубоком дереве владелец не находился и событие журнала молча терялось.
   */
  async ownerOfFolder(folderId: string): Promise<string | null> {
    const rows = await this.prisma.$queryRaw<Array<{ userId: string }>>`
      WITH RECURSIVE up AS (
        SELECT f.id, f."parentId" FROM "Folder" f WHERE f.id = ${folderId}
        UNION ALL
        SELECT f.id, f."parentId" FROM "Folder" f JOIN up ON f.id = up."parentId"
      )
      SELECT u.id AS "userId" FROM "User" u JOIN up ON u."rootFolderId" = up.id LIMIT 1`;
    return rows[0]?.userId ?? null;
  }

  // ===== Принадлежность файлов пользователю =====
  // В схеме у папки нет userId: дерево пользователя — это поддерево его корневой папки
  // (users.rootFolderId). Поэтому «свой файл» = живой FileEntry, чья папка поднимается
  // по parentId до корня этого пользователя.

  /**
   * Корень пользователя, если он уже есть (без создания нового). Публичный намеренно:
   * по нему строятся запросы «фильтр по всему дереву» в БД (см. SyncService.have) —
   * так id дерева не гоняются через Node.
   */
  async rootIdOrNull(userId: string): Promise<string | null> {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { rootFolderId: true },
    });
    if (!user?.rootFolderId) return null;
    const root = await this.prisma.folder.findUnique({
      where: { id: user.rootFolderId },
      select: { id: true, deletedAt: true },
    });
    return root && !root.deletedAt ? root.id : null;
  }

  /**
   * Папка лежит в дереве пользователя и не в корзине (сама и все её родители)?
   * Один рекурсивный запрос вверх, как в соседнем ownerOfFolder: раньше это был цикл по
   * одному SELECT на уровень, а вызывается метод в цикле по записям (ownsAsset) — на глубоком
   * дереве это сотни запросов на одну проверку. UNION (а не UNION ALL) заодно не даёт запросу
   * зациклиться, если гонка перемещений всё-таки сшила петлю в parentId.
   */
  async folderOwnedBy(userId: string, folderId: string): Promise<boolean> {
    const rootId = await this.rootIdOrNull(userId);
    if (!rootId) return false;
    const rows = await this.prisma.$queryRaw<Array<{ id: string }>>`
      WITH RECURSIVE up AS (
        SELECT f.id, f."parentId" FROM "Folder" f WHERE f.id = ${folderId} AND f."deletedAt" IS NULL
        UNION
        SELECT f.id, f."parentId" FROM "Folder" f JOIN up ON f.id = up."parentId"
          WHERE f."deletedAt" IS NULL
      )
      SELECT id FROM up WHERE id = ${rootId} LIMIT 1`;
    return rows.length > 0;
  }

  /**
   * Есть ли у пользователя живой файл с этим содержимым (ассеты дедуплицируются между всеми).
   * Цена растёт с числом копий: записи одного ассета перебираются по очереди, а каждая проверка
   * владельца — это подъём по дереву (folderOwnedBy), поэтому успешный первый же кандидат
   * прерывает перебор.
   */
  async ownsAsset(userId: string, assetId: string): Promise<boolean> {
    const entries = await this.prisma.fileEntry.findMany({
      where: { assetId, deletedAt: null },
      select: { folderId: true },
    });
    for (const entry of entries) {
      if (await this.folderOwnedBy(userId, entry.folderId)) return true;
    }
    return false;
  }

  /**
   * Все папки дерева пользователя (рекурсивный CTE).
   * includeDeleted=true нужен корзине: удалённая папка со всем поддеревом тоже «своя».
   * Нужен там, где фильтровать надо не по одной записи, а по всему дереву
   * (лента фото, поездки, корзина, очередь).
   *
   * UNION, а не UNION ALL: гонка двух одновременных перемещений папок (folders.move проверяет
   * «цель не внутри собственного поддерева» вне транзакции) может сшить в parentId петлю, и
   * UNION ALL по ней не завершился бы никогда — запрос занял бы соединение навсегда, а ручки
   * файлов этого пользователя перестали бы отвечать. UNION отбрасывает уже виденные строки,
   * поэтому на петле обход просто останавливается.
   *
   * Внимание: метод возвращает id в Node (десятки тысяч uuid на большом дереве). Если по дереву
   * фильтруются строки в БД, лучше отфильтровать их самим CTE — пример в SyncService.have.
   */
  async subtreeIds(userId: string, opts: { includeDeleted?: boolean } = {}): Promise<string[]> {
    const rootId = await this.rootIdOrNull(userId);
    if (!rootId) return [];
    const sql = opts.includeDeleted
      ? `WITH RECURSIVE t AS (
           SELECT f.id, f."parentId" FROM "Folder" f WHERE f.id = $1
           UNION
           SELECT f.id, f."parentId" FROM "Folder" f JOIN t ON f."parentId" = t.id
         ) SELECT id FROM t`
      : `WITH RECURSIVE t AS (
           SELECT f.id, f."parentId" FROM "Folder" f WHERE f.id = $1
           UNION
           SELECT f.id, f."parentId" FROM "Folder" f JOIN t ON f."parentId" = t.id WHERE f."deletedAt" IS NULL
         ) SELECT id FROM t`;
    const rows = await this.prisma.$queryRawUnsafe<Array<{ id: string }>>(sql, rootId);
    return rows.map((r) => r.id);
  }

  /** Своя папка или 404 (deletedOk — для восстановления из корзины). */
  async assertFolderOwned(userId: string, folderId: string, opts: { deletedOk?: boolean } = {}): Promise<void> {
    if (opts.deletedOk) {
      const ids = await this.subtreeIds(userId, { includeDeleted: true });
      if (!ids.includes(folderId)) throw notFound('folder not found');
      return;
    }
    if (!(await this.folderOwnedBy(userId, folderId))) throw notFound('folder not found');
  }

  /** Своя запись файла или null (deletedOk — для восстановления из корзины). */
  async ownEntry(userId: string, entryId: string, opts: { deletedOk?: boolean } = {}) {
    const entry = await this.prisma.fileEntry.findUnique({ where: { id: entryId }, include: { asset: true } });
    if (!entry) return null;
    if (!opts.deletedOk && entry.deletedAt) return null;
    if (!(await this.folderOwnedBy(userId, entry.folderId))) return null;
    return entry;
  }

  /**
   * Системная папка «Фото» (медиа-зона). Создаётся лениво как ребёнок корня;
   * существующую папку с таким именем «усыновляем» (делаем её медиа-корнем).
   * Её нельзя переименовать/переместить/удалить (гарды в Folders/Dav).
   */
  async photoFolderId(userId: string): Promise<string> {
    const user = await this.prisma.user.findUnique({ where: { id: userId } });
    if (!user) throw unauthorized();
    if (user.photoFolderId) {
      const current = await this.prisma.folder.findUnique({ where: { id: user.photoFolderId } });
      if (current && !current.deletedAt && current.zone === ZONE_PHOTOS) return current.id;
    }
    const rootId = await this.rootFolderId(userId);

    let photo = await this.prisma.folder.findFirst({
      where: { parentId: rootId, name: PHOTO_FOLDER_NAME },
    });
    if (photo) {
      // обычная папка с именем «Фото» уже существует — делаем её медиа-корнем
      photo = await this.prisma.folder.update({
        where: { id: photo.id },
        data: { zone: ZONE_PHOTOS, deletedAt: null },
      });
    } else {
      photo = await this.prisma.folder.create({
        data: { parentId: rootId, name: PHOTO_FOLDER_NAME, zone: ZONE_PHOTOS },
      });
    }
    await this.prisma.user.update({ where: { id: userId }, data: { photoFolderId: photo.id } });
    await this.rezoneSubtree(photo.id, ZONE_PHOTOS);
    return photo.id;
  }

  /**
   * Системная папка «Почта» (скрытая зона MAIL) — корень для вложений писем. Создаётся
   * лениво, как «Фото», но в отличие от неё не попадает в `GET /auth/me`: клиенту незачем
   * знать про папку, которой он всё равно не увидит (она скрыта из листингов, WebDAV
   * и журнала изменений).
   *
   * Имя «Почта» зарезервировано (folders.create/rename), но одного этого мало: `ensure-path`
   * эту проверку обходит — а именно им клиент синхронизации создаёт папки телефона, и папка
   * «Почта» на телефоне обычное дело. Поэтому «усыновляем» тёзку только пустой: перевод
   * непустой пользовательской папки в скрытую зону унёс бы её файлы из «Файлов», поиска,
   * WebDAV и журнала — выглядело бы как пропажа без возможности восстановления. Непустая
   * тёзка остаётся пользователю, а системная заводится рядом под свободным именем.
   */
  async mailFolderId(userId: string): Promise<string> {
    const user = await this.prisma.user.findUnique({ where: { id: userId } });
    if (!user) throw unauthorized();
    if (user.mailFolderId) {
      const current = await this.prisma.folder.findUnique({ where: { id: user.mailFolderId } });
      if (current && !current.deletedAt && current.zone === ZONE_MAIL) return current.id;
    }
    const rootId = await this.rootFolderId(userId);

    const namesake = await this.prisma.folder.findFirst({
      where: { parentId: rootId, name: MAIL_FOLDER_NAME },
    });
    let mail: { id: string };
    if (namesake && (await this.folderIsEmpty(namesake.id))) {
      mail = await this.prisma.folder.update({
        where: { id: namesake.id },
        data: { zone: ZONE_MAIL, deletedAt: null },
      });
    } else {
      if (namesake) {
        this.logger.warn(
          `в корне уже есть непустая папка «${MAIL_FOLDER_NAME}» — системная заводится под другим именем`,
        );
      }
      mail = await this.prisma.folder.create({
        data: {
          parentId: rootId,
          name: await this.freeChildFolderName(rootId, MAIL_FOLDER_NAME),
          zone: ZONE_MAIL,
        },
      });
    }
    await this.prisma.user.update({ where: { id: userId }, data: { mailFolderId: mail.id } });
    await this.rezoneSubtree(mail.id, ZONE_MAIL);
    return mail.id;
  }

  /** Пустая ли папка (нет живых подпапок и записей) — см. «усыновление» в mailFolderId. */
  private async folderIsEmpty(folderId: string): Promise<boolean> {
    const [folders, entries] = await Promise.all([
      this.prisma.folder.count({ where: { parentId: folderId, deletedAt: null } }),
      this.prisma.fileEntry.count({ where: { folderId, deletedAt: null } }),
    ]);
    return folders === 0 && entries === 0;
  }

  /** Проставить зону всему поддереву папки (BFS) — используется при «усыновлении» корня. */
  private async rezoneSubtree(rootFolderId: string, zone: string): Promise<void> {
    const all = [rootFolderId];
    let frontier = [rootFolderId];
    while (frontier.length) {
      const children = await this.prisma.folder.findMany({
        where: { parentId: { in: frontier }, deletedAt: null },
        select: { id: true },
      });
      const ids = children.map((c) => c.id);
      if (!ids.length) break;
      all.push(...ids);
      frontier = ids;
    }
    await this.prisma.folder.updateMany({ where: { id: { in: all } }, data: { zone } });
    await this.prisma.fileEntry.updateMany({ where: { folderId: { in: all } }, data: { zone } });
  }

  // ============ App-password / device-токены (WebDAV, клиенты) ============

  async createToken(userId: string, label: string): Promise<{ id: string; token: string; label: string }> {
    // метка раньше просто резалась до 64 символов и не проверялась, а из неё строится имя
    // папки-зеркала: «..» или «имя/2» давали папку, которую телефон не создаст
    const clean = cleanTokenLabel(label);
    // кап на число живых токенов: без него выпуск токенов бесконечен, а отзыв одного
    // ничего не значит (владелец не видит, сколько их всего)
    const alive = await this.prisma.apiToken.count({ where: { userId, revokedAt: null } });
    if (alive >= MAX_API_TOKENS_PER_USER) {
      throw badRequest(`слишком много активных токенов (${alive}) — отзовите ненужные (лимит ${MAX_API_TOKENS_PER_USER})`);
    }
    const token = randomToken(32);
    const t = await this.prisma.apiToken.create({
      data: {
        userId,
        label: clean,
        tokenHash: sha256Hex(token),
        scope: 'files:rw',
        expiresAt: new Date(Date.now() + env.API_TOKEN_TTL_DAYS * 24 * 60 * 60 * 1000),
      },
    });
    await this.audit.log('auth.token.create', { label: clean, tokenId: t.id });
    // plain-токен показывается один раз
    return { id: t.id, token, label: t.label };
  }

  async listTokens(userId: string) {
    const rows = await this.prisma.apiToken.findMany({
      where: { userId, revokedAt: null },
      orderBy: { createdAt: 'desc' },
      select: { id: true, label: true, scope: true, expiresAt: true, lastUsedAt: true, createdAt: true },
    });
    return rows;
  }

  /**
   * Отзыв токена. `bySelf` — токен отозвал сам себя (выход на телефоне, DELETE /auth/me/token):
   * в аудите это отдельная причина, иначе «токен исчез» не отличить от отзыва из веба.
   */
  async revokeToken(userId: string, tokenId: string, bySelf = false) {
    const res = await this.prisma.apiToken.updateMany({
      where: { id: tokenId, userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
    // 400 «token not found», а не 404: id пришёл от клиента, который сам получил его из
    // /auth/tokens, а сюда попадают повторный отзыв уже отозванного токена, чужой id и
    // опечатка — это расхождение с данными запроса, а не отсутствие ресурса по адресу.
    if (res.count === 0) throw badRequest('token not found');
    await this.audit.log('auth.token.revoke', { tokenId, ...(bySelf ? { bySelf: true } : {}) });
    return { ok: true };
  }

  /**
   * Проверка Basic-токена (WebDAV). Возвращает владельца, scope и id строки токена или null.
   * Раньше поле scope было декоративным и не читалось, а срок жизни отсутствовал.
   * tokenId нужен как identity устройства: по нему берётся корень зеркала и пишется deviceId
   * в журнал изменений.
   */
  async resolveApiToken(token: string): Promise<{ userId: string; scope: string; tokenId: string } | null> {
    if (!token) return null;
    const t = await this.prisma.apiToken.findUnique({ where: { tokenHash: sha256Hex(token) } });
    if (!t || t.revokedAt) return null;
    if (t.expiresAt && t.expiresAt.getTime() <= Date.now()) return null;
    if (!String(t.scope).startsWith('files:')) return null;
    // Телефон синхронизации делает сотни запросов за проход — писать в БД на каждый незачем
    const stale = !t.lastUsedAt || Date.now() - t.lastUsedAt.getTime() > 5 * 60 * 1000;
    if (stale) {
      await this.prisma.apiToken
        .update({ where: { id: t.id }, data: { lastUsedAt: new Date() } })
        .catch(() => undefined);
    }
    return { userId: t.userId, scope: t.scope, tokenId: t.id };
  }
}
