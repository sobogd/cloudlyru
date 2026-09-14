import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { ImapFlow, type FetchMessageObject, type FetchQueryObject } from 'imapflow';
import { PrismaService } from '../prisma/prisma.service';
import { env } from '../config/env';
import { mailCryptoReady } from './mail-crypto';
import { MailAccountsService, type MailAccountRow, type MailBox, type MailSourceFolder } from './mail-accounts.service';
import { MailIngestService, type IngestInput } from './mail-ingest.service';
import type { MailCursor } from '@prisma/client';

/**
 * Синхронизация почты с серверами аккаунтов (IMAP).
 *
 * Фаза «только чтение»: письма скачиваются и сохраняются у нас, а на сервере не меняется
 * ничего — ни флаги, ни удаление. Это осознанно: пока схема хранения не проверена на живых
 * ящиках, серверные копии остаются нетронутыми, и худший сбой стоит нам пустой БД, а не
 * потерянной переписки.
 *
 * Порядок работы по папке: сначала новое (UID-диапазон от lastUid+1), потом порция истории
 * назад по дате. Историю берём порциями, потому что у Gmail жёсткий лимит на скачивание по
 * IMAP (порядка 2.5 ГБ в сутки на аккаунт): «скачать всё сразу» — это отказ по лимиту на
 * весь день вместо постепенно наполняющегося интерфейса.
 */

/** Что просим у сервера вместе с письмом. UID и уникальный id письма imapflow добавляет сам. */
const SOURCE_QUERY: FetchQueryObject = {
  uid: true,
  source: true,
  internalDate: true,
  size: true,
  flags: true,
  threadId: true,
  labels: true,
};

/** Задержка перед внеочередным проходом после события «появилось письмо», мс. */
const WAKE_DEBOUNCE_MS = 3000;

/** Пауза между письмами внутри прохода: письма идут потоком, сервер этого не любит. */
const PER_MESSAGE_DELAY_MS = 60;

/**
 * Сколько писем забирать «с хвоста», когда курсор отстал (первый проход после подключения
 * ящика или долгая пауза). Дальше за новыми письмами следит уже обычная догрузка.
 */
const TAIL_ON_CATCHUP = 50n;

/**
 * Насколько курсор вправе отставать, прежде чем мы перестанем идти по истории вперёд.
 *
 * Это исправление настоящей ошибки: на новом курсоре lastUid = 0, и «догрузка нового»
 * превращалась в UID FETCH 1:* — обход ящика от САМЫХ СТАРЫХ писем к новым. Свежая почта
 * стояла в конце этой очереди, то есть ждала, пока переберём весь ящик (часы, а с лимитом
 * Gmail на IMAP — сутки). Теперь история — дело бэкфилла (он идёт от свежих к старым),
 * а догрузка занимается только новым.
 */
const CATCHUP_GAP = 1000n;

/** Потолок трафика на догрузку нового за проход: остальное должно остаться истории. */
const INCREMENTAL_BUDGET_BYTES = 50 * 1024 * 1024;

/** Контекст письма внутри папки: то, чего нет в ответе сервера, но нужно при сохранении. */
interface FolderContext {
  account: MailAccountRow;
  folderPath: string;
  uidValidity: bigint;
}

@Injectable()
export class MailSyncService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(MailSyncService.name);
  private readonly clients = new Map<string, ImapFlow>();
  private timer: NodeJS.Timeout | null = null;
  private wakeTimer: NodeJS.Timeout | null = null;
  /**
   * Проходы не пересекаются: два параллельных прохода по одному ящику — верный способ
   * получить от сервера отказ по частоте и разреженные курсоры.
   */
  private busy = false;
  private stopped = false;

  constructor(
    private readonly prisma: PrismaService,
    private readonly accounts: MailAccountsService,
    private readonly ingestService: MailIngestService,
  ) {}

  onModuleInit(): void {
    if (!env.MAIL_SYNC_ENABLED) {
      this.logger.log('синхронизация почты выключена (MAIL_SYNC_ENABLED=false)');
      return;
    }
    if (!mailCryptoReady()) {
      this.logger.error('MAIL_SECRET_KEY не задан — синхронизация почты не запущена');
      return;
    }
    this.timer = setInterval(() => void this.runPass('по расписанию'), env.MAIL_SYNC_INTERVAL_SEC * 1000);
    this.timer.unref();
    this.logger.log(
      `синхронизация почты запущена: проход каждые ${env.MAIL_SYNC_INTERVAL_SEC} с, ` +
        `истории за проход — ${env.MAIL_BACKFILL_PER_PASS} писем`,
    );
    void this.runPass('старт');
  }

  onModuleDestroy(): void {
    this.stopped = true;
    if (this.timer) clearInterval(this.timer);
    if (this.wakeTimer) clearTimeout(this.wakeTimer);
    for (const [id, client] of this.clients) {
      try {
        client.close();
      } catch {
        /* соединение могло закрыться само */
      }
      this.clients.delete(id);
    }
  }

  /** Проход по всем включённым аккаунтам. Параллельные вызовы схлопываются в один. */
  async runPass(reason: string): Promise<void> {
    if (this.stopped) return;
    if (this.busy) {
      this.logger.log(`проход пропущен (${reason}): предыдущий ещё идёт`);
      return;
    }
    this.busy = true;
    try {
      const accounts = await this.prisma.mailAccount.findMany({ where: { enabled: true } });
      for (const account of accounts) {
        // Аккаунт без IMAP (почту приносит наш сервер) в расписании не участвует:
        // качать из него нечего, а соединение к пустому хосту — это ошибка в статусе.
        if (!this.accounts.presetOf(account.kind).folders.length) continue;
        try {
          await this.syncAccount(account);
        } catch (e) {
          await this.markError(account.id, e);
        }
      }
    } finally {
      this.busy = false;
    }
  }

  private async markError(accountId: string, e: unknown): Promise<void> {
    // Текст ошибки провайдера полезен («Too many simultaneous connections»), а пароль в него
    // попасть не должен: imapflow креденшелы скрывает, длину мы обрезаем.
    const message = (e instanceof Error ? e.message : String(e)).slice(0, 400);
    this.logger.warn(`аккаунт ${accountId}: ${message}`);
    await this.prisma.mailAccount
      .update({ where: { id: accountId }, data: { status: 'error', statusError: message } })
      .catch(() => undefined);
    this.dropClient(accountId);
  }

  private dropClient(accountId: string): void {
    const client = this.clients.get(accountId);
    if (!client) return;
    try {
      client.close();
    } catch {
      /* уже закрыто */
    }
    this.clients.delete(accountId);
  }

  private async syncAccount(account: MailAccountRow): Promise<void> {
    const preset = this.accounts.presetOf(account.kind);
    await this.prisma.mailAccount.update({
      where: { id: account.id },
      data: { status: 'syncing', statusError: null },
    });

    let stored = 0;
    let failed: string | null = null;

    // Прогон с одним повтором: серверы почты (и особенно Gmail) рвут соединение посреди
    // долгой выборки, и раньше это выглядело как «аккаунт сломан» до следующего прохода
    // по расписанию — через пять минут. Данные не теряются: курсор двигается после каждого
    // письма, поэтому продолжение с него ничего не перекачивает.
    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        const client = await this.connect(account);
        const folders = await this.resolveFolders(client, preset.folders);
        for (const folder of folders) {
          try {
            stored += await this.syncFolder(client, account, folder);
          } catch (e) {
            // Обрыв соединения — не ошибка папки: повторяем проход целиком (свежее
            // соединение), и только если и он не удался, показываем ошибку.
            if (isConnectionError(e)) throw e;
            // Одна недоступная папка (у iCloud «Junk» может отсутствовать) не должна ронять
            // весь аккаунт: остальные папки синхронизируем, а причину показываем в статусе.
            failed = (e instanceof Error ? e.message : String(e)).slice(0, 400);
            this.logger.warn(`${account.email}, папка ${folder.path}: ${failed}`);
          }
        }
        if (failed === null) break;
        break;
      } catch (e) {
        const message = (e instanceof Error ? e.message : String(e)).slice(0, 400);
        this.dropClient(account.id);
        if (attempt === 1) {
          this.logger.warn(`${account.email}: соединение оборвалось (${message}) — переподключаюсь и продолжаю`);
          await sleep(RECONNECT_DELAY_MS);
          continue;
        }
        failed = message;
        this.logger.warn(`${account.email}: повтор не помог — ${message}`);
      }
    }

    await this.prisma.mailAccount.update({
      where: { id: account.id },
      data: {
        status: failed ? 'error' : 'idle',
        statusError: failed,
        lastSyncAt: new Date(),
      },
    });
    if (stored) this.logger.log(`${account.email}: сохранено писем за проход — ${stored}`);
  }

  /**
   * Папки источника с реальными именами.
   *
   * Имена системных папок у Gmail и iCloud локализованы: в русском ящике All Mail — это
   * «[Gmail]/Вся почта», а Sent Messages — «Отправленные». Поэтому ищем по стандартной метке
   * (RFC 6154: \All, \Junk, \Sent), а строку пути используем только как запасной вариант.
   * Папки, которой нет ни по метке, ни по имени, просто нет в списке — сервер вправе её
   * не иметь (у iCloud «Junk» появляется не всегда).
   */
  private async resolveFolders(client: ImapFlow, wanted: MailSourceFolder[]): Promise<MailSourceFolder[]> {
    let boxes: Awaited<ReturnType<ImapFlow['list']>> | null = null;
    try {
      boxes = await client.list();
    } catch (e) {
      // Список не получен — доверяем именам из настроек целиком: отфильтровать их «по факту
      // отсутствия в списке», которого нет, значило бы не синхронизировать вообще ничего.
      this.logger.warn(`список папок не получен, работаем по именам из настроек: ${(e as Error).message}`);
    }
    if (!boxes) return wanted;

    const byPath = new Set(boxes.map((b) => b.path));
    const bySpecial = new Map<string, string>();
    for (const b of boxes) {
      if (b.specialUse) bySpecial.set(b.specialUse, b.path);
    }

    const out: MailSourceFolder[] = [];
    for (const folder of wanted) {
      const byFlag = folder.specialUse ? bySpecial.get(folder.specialUse) : undefined;
      if (byFlag) {
        out.push({ ...folder, path: byFlag });
        continue;
      }
      if (byPath.has(folder.path)) {
        out.push(folder);
        continue;
      }
      // Папки нет вовсе: молча пропускаем, но пишем — иначе «почему не видно спама»
      // будет неоткуда узнать.
      this.logger.warn(`папки ${folder.path} (${folder.specialUse ?? 'без метки'}) нет в аккаунте — пропускаем`);
    }
    return out;
  }

  /** Живое соединение аккаунта; при обрыве — новое. */
  private async connect(account: MailAccountRow): Promise<ImapFlow> {
    const existing = this.clients.get(account.id);
    if (existing?.usable) return existing;
    this.dropClient(account.id);

    const { login, password } = this.accounts.credentials(account);
    const client = new ImapFlow({
      host: account.imapHost,
      port: account.imapPort,
      secure: true,
      auth: { user: login, pass: password },
      // Логгер imapflow пишет команды целиком — вместе с ним в лог уехал бы и пароль
      logger: false,
      clientInfo: { name: 'CloudlyRu', version: '0.1.0' },
      socketTimeout: 300_000,
      greetingTimeout: 20_000,
    });
    client.on('error', (e: Error) => this.logger.warn(`IMAP ${account.email}: ${e.message}`));
    client.on('close', () => {
      if (this.clients.get(account.id) === client) this.clients.delete(account.id);
    });
    // Сервер сам сообщает о новом письме в открытой папке — забираем его вне расписания
    client.on('exists', () => this.wake());
    await client.connect();
    this.clients.set(account.id, client);
    return client;
  }

  /** Внеочередной проход с задержкой-склейкой: письма обычно приходят пачками. */
  private wake(): void {
    if (this.stopped || this.wakeTimer) return;
    this.wakeTimer = setTimeout(() => {
      this.wakeTimer = null;
      void this.runPass('новое письмо');
    }, WAKE_DEBOUNCE_MS);
    this.wakeTimer.unref();
  }

  /** Одна папка источника: сначала новое, потом кусок истории. */
  private async syncFolder(
    client: ImapFlow,
    account: MailAccountRow,
    folder: MailSourceFolder,
  ): Promise<number> {
    const lock = await client.getMailboxLock(folder.path);
    let stored = 0;
    try {
      const mailbox = client.mailbox;
      if (!mailbox) throw new Error(`папка ${folder.path} не открылась`);
      const ctx: FolderContext = { account, folderPath: folder.path, uidValidity: BigInt(mailbox.uidValidity) };
      const cursor = await this.cursorFor(account.id, folder, ctx.uidValidity);

      const passBudget = env.MAIL_PASS_BUDGET_MB * 1024 * 1024;

      // 1. Новое. UIDNEXT — следующий свободный UID: если он не больше lastUid+1, нового нет,
      //    и запрос можно не делать вовсе. Проверка нужна не для экономии: «*» в IMAP — это
      //    максимальный UID папки, поэтому UID FETCH <n>:* при n больше максимума вернул бы
      //    последнее письмо (диапазон разворачивается), и мы качали бы его каждый проход.
      const status = await client.status(folder.path, { uidNext: true, messages: true });
      const uidNext = BigInt(status.uidNext ?? 1);
      const maxUid = uidNext > 0n ? uidNext - 1n : 0n;

      // Курсор отстал настолько, что догонять историю «вперёд» бессмысленно: свежая почта
      // ждала бы в конце очереди. Переставляем его к хвосту и забираем только хвост —
      // остальное доберёт бэкфилл, который идёт от свежих к старым.
      let lastUid = cursor.lastUid;
      if (maxUid - lastUid > CATCHUP_GAP) {
        const tailFrom = maxUid > TAIL_ON_CATCHUP ? maxUid - TAIL_ON_CATCHUP + 1n : 1n;
        this.logger.log(
          `${folder.path}: курсор отстал на ${maxUid - lastUid} писем — забираю хвост с ${tailFrom}, историю доберёт бэкфилл`,
        );
        lastUid = tailFrom - 1n;
        await this.prisma.mailCursor.update({
          where: { id: cursor.id },
          data: { lastUid, lastSeenAt: new Date() },
        });
      }

      const from = lastUid + 1n;
      // Догрузка нового — своя небольшая доля трафика: раньше она съедала бюджет целиком,
      // и история не двигалась вовсе.
      const incrementalCap = Math.min(passBudget, INCREMENTAL_BUDGET_BYTES);
      let spent = 0;
      if (uidNext > from) {
        for await (const msg of client.fetch(`${from}:*`, SOURCE_QUERY, { uid: true })) {
          if (BigInt(msg.uid) <= cursor.lastUid) continue;
          const item = this.messageOf(msg, ctx);
          if (!item) continue;
          // Бюджет проверяем до обработки: иначе за проход уезжает на одно письмо больше
          // лимита, и на большом ящике это заметно.
          if (spent > 0 && spent + item.bytes > incrementalCap) break;
          try {
            const result = await this.ingestService.ingest(item.input);
            if (result === 'stored' || result === 'attachments-repaired') {
              stored += 1;
            }
          } catch (e) {
            // Курсор двигаем и при ошибке: иначе одно «упрямое» письмо заставляло бы
            // перекачивать его на каждом проходе и никогда не пропускать дальше.
            this.logger.warn(`${ctx.folderPath}: новое письмо ${msg.uid} не сохранено — ${(e as Error).message}`);
          }
          // Курсор двигаем сразу за письмом: падение на следующем не заставит перекачивать
          // всё заново (у Gmail это ещё и лимит трафика на сутки).
          if (BigInt(msg.uid) > lastUid) {
            lastUid = BigInt(msg.uid);
            await this.prisma.mailCursor.update({
              where: { id: cursor.id },
              data: { lastUid, lastSeenAt: new Date() },
            });
          }
          spent += item.bytes;
          await sleep(PER_MESSAGE_DELAY_MS);
        }
      }

      // 2. История: порция за проход, от свежих к старым. Ей достаётся весь остаток
      // бюджета прохода — история и есть основная работа, пока она не добрана.
      const leftForHistory = passBudget - spent;
      if (leftForHistory > 0 && !cursor.backfillDone) {
        stored += await this.backfill(client, ctx, cursor, leftForHistory);
      }
    } finally {
      lock.release();
    }
    return stored;
  }

  /**
   * Кусок истории за проход.
   *
   * Идём назад по дате: берём UID-и старше границы, которых у нас ещё нет, и скачиваем самые
   * свежие из них. Границу сдвигаем на день вперёд от самого старого скачанного письма, а не
   * ровно на его дату: у IMAP-поиска BEFORE точность — сутки, и «BEFORE 14 сентября» не
   * включает 14 сентября. Лишний день пересматривается, но не перекачивается (дедуп по UID).
   */
  private async backfill(client: ImapFlow, ctx: FolderContext, cursor: MailCursor, budget: number): Promise<number> {
    const walkBefore = cursor.backfillFrom ?? new Date();
    const floor = this.backfillFloor();
    if (floor && walkBefore <= floor) {
      await this.finishBackfill(cursor.id);
      return 0;
    }

    // search отдаёт false, если сервер отказал: это не «писем нет», но и не повод падать —
    // следующий проход попробует снова, а история просто не сдвинется.
    const found = await client.search({ before: walkBefore }, { uid: true });
    const uids = Array.isArray(found) ? found : [];
    if (!uids.length) {
      await this.finishBackfill(cursor.id);
      return 0;
    }

    // Что из этого уже есть. Один запрос на папку за проход и только пока идёт бэкфилл:
    // после его завершения сюда не заходим вообще.
    const known = new Set(
      (
        await this.prisma.mailMessage.findMany({
          where: { accountId: ctx.account.id, folderPath: ctx.folderPath, uidValidity: ctx.uidValidity },
          select: { uid: true },
        })
      ).map((r) => Number(r.uid)),
    );
    const missing = uids.filter((u) => !known.has(u));
    if (!missing.length) {
      // Старше границы ничего не осталось — история пройдена целиком.
      await this.finishBackfill(cursor.id);
      return 0;
    }
    // Остаток истории в письмах, а не в датах: по одной границе понять, сколько ещё качать,
    // невозможно, а вопрос «когда уже можно уходить с сервера» возникает каждый раз.
    this.logger.log(
      `${ctx.folderPath}: истории осталось ${missing.length} писем (граница ${walkBefore.toISOString().slice(0, 10)})`,
    );

    const batch = missing.slice(-env.MAIL_BACKFILL_PER_PASS).reverse();
    let stored = 0;
    let failed = 0;
    let oldest: Date | null = null;

    // Одной командой на всю порцию, а не по команде на письмо. Раньше здесь было 200
    // отдельных UID FETCH за проход — Gmail на такое отвечает обрывом соединения
    // («Connection not available» посреди прохода), и проход умирал, не добрав порцию.
    for await (const fetched of client.fetch(batch, SOURCE_QUERY, { uid: true })) {
      if (budget <= 0) break;
      const item = this.messageOf(fetched, ctx);
      if (!item) continue;
      try {
        const result = await this.ingestService.ingest(item.input);
        if (result === 'stored' || result === 'attachments-repaired') stored += 1;
      } catch (e) {
        // Одно проблемное письмо не имеет права останавливать выгрузку: история дойдёт
        // до него ещё раз (его UID остаётся в окне), а остальные письма поедут дальше.
        // Раньше исключение убивало весь проход, и граница истории не двигалась вовсе —
        // архив вставал намертво на одном письме.
        failed += 1;
        this.logger.warn(`${ctx.folderPath}: письмо ${fetched.uid} не сохранено — ${(e as Error).message}`);
      }
      budget -= item.bytes;
      const received = item.input.receivedAt;
      if (!oldest || received < oldest) oldest = received;
      await sleep(PER_MESSAGE_DELAY_MS);
    }

    if (oldest) {
      await this.prisma.mailCursor.update({
        where: { id: cursor.id },
        data: { backfillFrom: new Date(oldest.getTime() + 24 * 60 * 60 * 1000), lastSeenAt: new Date() },
      });
    }
    if (failed) this.logger.warn(`${ctx.folderPath}: за проход не сохранилось писем — ${failed}`);
    return stored;
  }

  private async finishBackfill(cursorId: string): Promise<void> {
    await this.prisma.mailCursor.update({ where: { id: cursorId }, data: { backfillDone: true } });
  }

  /** Нижняя граница истории: MAIL_BACKFILL_DAYS=0 — без ограничения. */
  private backfillFloor(): Date | null {
    const days = env.MAIL_BACKFILL_DAYS;
    if (!days) return null;
    return new Date(Date.now() - days * 24 * 60 * 60 * 1000);
  }

  /**
   * Письмо из ответа сервера в терминах сохранения. null — сохранять нечего:
   * черновик (Gmail держит их и в All Mail, откуда мы читаем всё подряд) или пустой ответ.
   */
  private messageOf(msg: FetchMessageObject, ctx: FolderContext): { input: IngestInput; bytes: number } | null {
    const source = msg.source;
    if (!source?.length) return null;
    const flags = msg.flags ?? new Set<string>();
    if (flags.has('\\Draft')) return null;

    // Папка источника уже говорит, что это «Исходящие» (iCloud Sent Messages). А в All Mail
    // у Gmail письма лежат вперемешку, поэтому там смотрим системную метку \Sent.
    const labels = msg.labels ?? new Set<string>();
    const sent = ctx.folderPath.toLowerCase().includes('sent') || labels.has('\\Sent') || flags.has('\\Sent');
    // Письмо себе у Gmail лежит в All Mail одной копией с двумя метками сразу. Наша папка
    // одна на письмо, поэтому вторую метку запоминаем как дополнительную папку — иначе такое
    // письмо показывалось бы только в «Исходящих».
    const alsoBoxes: MailBox[] =
      sent && (labels.has('\\Inbox') || flags.has('\\Inbox')) ? ['inbox'] : [];

    const internal = msg.internalDate ? new Date(msg.internalDate) : new Date();
    return {
      input: {
        userId: ctx.account.userId,
        account: ctx.account,
        box: sent ? 'sent' : 'inbox',
        alsoBoxes,
        folderPath: ctx.folderPath,
        uid: msg.uid,
        uidValidity: ctx.uidValidity,
        source,
        seen: flags.has('\\Seen'),
        flagged: flags.has('\\Flagged'),
        emailId: msg.emailId ?? null,
        threadId: msg.threadId ?? null,
        receivedAt: Number.isNaN(internal.getTime()) ? new Date() : internal,
      },
      bytes: source.length,
    };
  }

  /** Курсор папки: создаём при первом обращении, сбрасываем при смене UIDVALIDITY. */
  private async cursorFor(accountId: string, folder: MailSourceFolder, uidValidity: bigint): Promise<MailCursor> {
    const existing = await this.prisma.mailCursor.findUnique({
      where: { accountId_imapPath: { accountId, imapPath: folder.path } },
    });
    if (!existing) {
      return this.prisma.mailCursor.create({
        data: {
          accountId,
          imapPath: folder.path,
          box: folder.box,
          uidValidity,
          lastUid: 0n,
          backfillFrom: new Date(),
        },
      });
    }
    // UIDVALIDITY сменилась — прежние UID в этой папке недействительны, нужен пересинк.
    // Строки писем при этом не трогаем: дедуп по X-GM-MSGID не даст им задвоиться.
    if (existing.uidValidity !== uidValidity) {
      this.logger.warn(`папка ${folder.path}: UIDVALIDITY сменилась (${existing.uidValidity} → ${uidValidity})`);
      return this.prisma.mailCursor.update({
        where: { id: existing.id },
        data: { uidValidity, lastUid: 0n, backfillFrom: new Date(), backfillDone: false },
      });
    }
    return existing;
  }
}

/** Пауза перед повторным подключением: серверу нужно отпустить прошлое соединение. */
const RECONNECT_DELAY_MS = 5000;

/**
 * Похоже ли на обрыв соединения, а не на отказ по существу.
 *
 * Разница важна: обрыв лечится переподключением и повтором, а «папки нет» или «сервер
 * отказал в удалении» повтором не лечится — на них мы просто показываем ошибку.
 */
function isConnectionError(e: unknown): boolean {
  const text = (e instanceof Error ? `${e.name} ${e.message}` : String(e)).toLowerCase();
  return /connection not available|connection closed|connection lost|not connected|econnreset|econnrefused|epipe|etimedout|socket hang up|timeout/.test(
    text,
  );
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
