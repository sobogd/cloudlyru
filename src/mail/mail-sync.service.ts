import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { ImapFlow, type FetchMessageObject, type FetchQueryObject } from 'imapflow';
import { PrismaService } from '../prisma/prisma.service';
import { env } from '../config/env';
import { mailCryptoReady } from './mail-crypto';
import { MailAccountsService, type MailAccountRow, type MailBox, type MailSourceFolder } from './mail-accounts.service';
import { MailIngestService, type IngestInput } from './mail-ingest.service';
import { MailPurgeService } from './mail-purge.service';
import type { MailCursor } from '@prisma/client';

/**
 * Синхронизация почты с серверами аккаунтов (IMAP).
 *
 * Это НЕ фаза «только чтение». Письма скачиваются и сохраняются у нас, и сразу после этого
 * их серверные копии убираются у провайдера (`purgeFresh` → `MailPurgeService`), а догоняющий
 * проход той же службы добирает то, что не убралось сразу. То есть худший сбой здесь стоит не
 * «пустой БД», а потерянной переписки, и вся осторожность в этом файле — про это. Само удаление
 * выключено по умолчанию и включается только `MAIL_PURGE_ENABLED=true` (см. mail-purge.service.ts).
 *
 * Инвариант курсора — главное правило файла: `lastUid` и `backfillFrom` не двигаются за письмо,
 * которого у нас нет. Не сохранилось письмо (отказ S3, БД, разбора) — курсор остаётся перед ним
 * и следующий проход пробует снова; чтобы одно «упрямое» письмо не блокировало новые, после
 * INGEST_MAX_TRIES попыток его пропускают, но не молча: причина уходит в лог, а счётчик
 * несохранённых писем — в статус аккаунта (`unsavedFor`). Счётчик живёт в памяти процесса:
 * переживающая перезапуск таблица неудач требует миграции, которой у этого модуля нет.
 *
 * Порядок работы по папке: сначала новое (UID-диапазон от lastUid+1), потом порция истории
 * назад по дате. Историю берём порциями, потому что у Gmail жёсткий лимит на скачивание по
 * IMAP (порядка 2.5 ГБ в сутки на аккаунт): «скачать всё сразу» — это отказ по лимиту на
 * весь день вместо постепенно наполняющегося интерфейса. Бюджет трафика считается на АККАУНТ
 * за проход (`MAIL_PASS_BUDGET_MB`) и делится между его папками — иначе три-четыре папки
 * умножали бы лимит на своё число, а проходы идут каждые MAIL_SYNC_INTERVAL_SEC секунд.
 *
 * Свежее письмо приходит само: на каждый аккаунт держится отдельное соединение, открытое на
 * папку, через которую видно всё новое, — сервер в IDLE сам сообщает о новом письме, и мы
 * запускаем внеочередной проход. Сторожевое соединение отдельное от прохода, потому что
 * открытая под IDLE папка занята: по ней нельзя сделать выборку, не разорвав IDLE. Плановый
 * проход по расписанию остаётся страховкой на случай, когда сторож отвалился, а сервер не
 * умеет IDLE (тогда imapflow сам опрашивает папку NOOP'ом).
 *
 * Состояние аккаунта (`MailAccount.status`) принадлежит этому сервису и означает буквально
 * следующее: `syncing` — идёт проход, `idle` — проход закончился успешно, `error` — проход или
 * папка закончились отказом (`statusError`), либо есть несохранённые письма. `syncing`
 * сбрасывается в `idle` при старте процесса: если предыдущий проход был убит перезапуском,
 * отметка осталась бы висеть навсегда, а интерфейс показывал бы «идёт синхронизация» вечно.
 *
 * Владение жизненным циклом и соединениями: у чистки сервера свой таймер
 * (`MailPurgeService`, MAIL_PURGE_ENABLED, каждые 5 минут) — она сознательно не ждёт приём
 * и не выключается вместе с этим сервисом, потому что её выключатель отдельный. На один
 * аккаунт одновременно живут: сторож (IDLE), соединение прохода и — пока идёт — одно
 * соединение чистки; провайдеры считают одновременные подключения, поэтому чистка свежих
 * писем берёт семафор на аккаунт, а проходное соединение не уходит в IDLE.
 *
 * Восстановление после падения процесса: незавершённый проход продолжается с курсора (письма
 * перекачиваются только те, что не успели сохраниться); частично записанные вложения добирает
 * `ingest` по сырью из хранилища; недоразобранное письмо не удаляется у провайдера, пока
 * вложения не разобраны (`verifyStored`); `remotePurgeTries`/`remotePurgeError` показывают,
 * почему копия осталась. Строка письма без сырья в S3 — это как раз тот случай, который
 * запрещено удалять: копию у провайдера трогать нельзя, пока `verifyStored` не подтвердит байты.
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

/** Координаты только что сохранённого письма: по ним находим строку и убираем серверную копию. */
interface StoredRef {
  folderPath: string;
  uidValidity: bigint;
  uid: number;
}

/** Задержка перед внеочередным проходом после события «появилось письмо», мс. */
const WAKE_DEBOUNCE_MS = 3000;

/**
 * Через сколько переустанавливать IDLE, мс.
 *
 * Провайдеры сами закрывают затянувшийся IDLE (Gmail — на 29-й минуте), поэтому разрываем и
 * заходим заново заранее: так пауза в приходе писем не зависит от прихотей сервера.
 */
const IDLE_RESTART_MS = 24 * 60 * 1000;

/**
 * Задержка перед входом в IDLE после открытия папки, мс.
 *
 * По умолчанию imapflow ждёт 15 с простоя — на сторожевом соединении простоять эти секунды
 * нечего, поэтому слушаем сразу.
 */
const WATCH_AUTO_IDLE_DELAY_MS = 1000;

/**
 * Пауза перед переподключением сторожа, мс.
 *
 * Именно столько нужно серверу, чтобы отпустить прошлое соединение (иначе новый логин
 * отклоняется как «слишком много подключений»); после неудач пауза растёт —
 * см. WATCH_RETRY_DELAYS_MS.
 */
const WATCH_RECONNECT_MS = 15_000;

/**
 * Через сколько пробовать поднять сторожа после неудачи, мс — по нарастающей.
 *
 * Раньше повтор шёл строго каждые 15 с и не считался: при неверном пароле, удалённом или
 * заблокированном аккаунте это ~5760 попыток логина в сутки на ящик, а провайдеры на такое
 * отвечают «слишком много попыток» и блокируют вход по-настоящему. Последняя ступень —
 * фактическая остановка: одна попытка в час до вмешательства человека, о причине сказано
 * в `statusError` аккаунта.
 */
const WATCH_RETRY_DELAYS_MS = [15_000, 60_000, 5 * 60_000, 15 * 60_000, 60 * 60_000];

/**
 * Пауза между письмами внутри прохода, мс.
 *
 * Пришла из наблюдения: Gmail на плотный поток FETCH отвечает обрывом соединения
 * («Connection not available» посреди прохода), и проход умирал, не добрав порцию. Письма
 * приходят пачками, поэтому 60 мс между ними стоят немного, а выборку делают «человеческой».
 */
const PER_MESSAGE_DELAY_MS = 60;

/**
 * Сколько ждём папку под блокировкой, мс.
 *
 * У imapflow ожидание лока по умолчанию бесконечное: чужой незакрытый лок (или наш же проход,
 * застрявший на сети) подвесил бы `syncFolder` навсегда вместе с флагом `busy`, и синхронизация
 * молча встала бы до перезапуска процесса.
 */
const LOCK_ACQUIRE_TIMEOUT_MS = 30_000;

/**
 * Потолок длительности прохода, мс. Больше — значит где-то завис `await` (лок, S3, пул БД):
 * сторож снимает `busy`, закрывает соединения аккаунтов и пишет причину в `statusError`.
 */
const PASS_WATCHDOG_MS = 15 * 60_000;

/** Сколько ждём текущий проход при остановке процесса, мс: дальше закрываем соединения. */
const SHUTDOWN_WAIT_MS = 10_000;

/**
 * Сколько раз пробуем сохранить одно и то же письмо, прежде чем пропустить его.
 *
 * Курсор за несохранённое письмо не двигается (это инвариант файла), поэтому у «упрямого»
 * письма должен быть предел: иначе одно битое письмо навсегда остановило бы приход новых.
 * После предела курсор идёт дальше, а письмо остаётся в списке несохранённых — оно видно
 * в статусе аккаунта, и на сервере его копия цела.
 */
const INGEST_MAX_TRIES = 3;

/** Сколько несохранённых писем держим для отчёта в статусе аккаунта. */
const UNSAVED_KEEP = 50;

/**
 * Потолок размера письма для IMAP-пути, МБ.
 *
 * `source: true` тянет письмо в память целиком, поэтому размер узнаётся ДО скачивания тела:
 * письмо на сотни мегабайт (свой IMAP-сервер, крупная корпоративная рассылка) иначе уносит
 * с собой весь процесс API — вместе с файлами, фото и загрузками. В ручке приёма свой лимит
 * (64 МБ), здесь такой же по умолчанию. Переменная читается тут, а не в `src/config/env.ts`,
 * с безопасным дефолтом.
 */
const MAX_MESSAGE_MB = readPositiveInt('MAIL_MAX_MESSAGE_MB', 64);
const MAX_MESSAGE_BYTES = MAX_MESSAGE_MB * 1024 * 1024;

/** Число из окружения с безопасным значением по умолчанию (env.ts — чужой файл). */
function readPositiveInt(name: string, fallback: number): number {
  const raw = Number(process.env[name]);
  return Number.isFinite(raw) && raw > 0 ? Math.floor(raw) : fallback;
}

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

/**
 * Потолок трафика на догрузку нового за проход.
 *
 * 50 МБ — это малая доля бюджета аккаунта (`MAIL_PASS_BUDGET_MB`): раньше догрузка съедала
 * бюджет целиком, и история не двигалась вовсе. Столько хватает на письма, пришедшие за
 * интервал прохода, даже с вложениями.
 */
const INCREMENTAL_BUDGET_BYTES = 50 * 1024 * 1024;

/** Контекст письма внутри папки: то, чего нет в ответе сервера, но нужно при сохранении. */
interface FolderContext {
  account: MailAccountRow;
  folderPath: string;
  /** Наша папка для писем отсюда (`box` пресета): «исходящее» она знает точно, в отличие от имени. */
  box: MailBox;
  uidValidity: bigint;
}

/**
 * Бюджет трафика: один на аккаунт за проход, общий для всех его папок.
 *
 * Мутируемый объект, а не число, потому что папки идут одна за другой и должны делить остаток
 * (`MAIL_PASS_BUDGET_MB` описана в env как потолок прохода — на папку она множилась бы на их
 * число, а у Gmail это суточный лимит скачивания).
 */
interface PassBudget {
  left: number;
}

/**
 * Письмо, которое не удалось сохранить: координаты, число попыток и причина.
 *
 * Живёт в памяти процесса (переживающая перезапуск таблица неудач требует миграции) и нужна
 * для двух вещей: повторить письмо следующим проходом и показать счётчик в статусе аккаунта,
 * чтобы дырка в архиве не осталась незамеченной.
 */
interface UnsavedLetter {
  folderPath: string;
  uid: number;
  uidValidity: bigint;
  tries: number;
  error: string;
  at: Date;
  /** Письмо пропущено окончательно (попытки кончились) — курсор ушёл дальше. */
  givenUp: boolean;
}

@Injectable()
export class MailSyncService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(MailSyncService.name);
  private readonly clients = new Map<string, ImapFlow>();
  /** Сторожевые соединения аккаунтов: по одному на аккаунт, живут постоянно, держат IDLE. */
  private readonly watchers = new Map<string, ImapFlow>();
  /** Аккаунты, для которых сторож сейчас поднимается: второй параллельный подъём не нужен. */
  private readonly watchPending = new Set<string>();
  /** Неудачи подъёма сторожа по аккаунту: пауза растёт, чтобы не долбить сервер логинами. */
  private readonly watchFailures = new Map<string, { count: number; until: number }>();
  /** Несохранённые письма по аккаунтам: ключ — координаты письма. */
  private readonly unsaved = new Map<string, UnsavedLetter>();
  private timer: NodeJS.Timeout | null = null;
  private wakeTimer: NodeJS.Timeout | null = null;
  private watchRetryTimer: NodeJS.Timeout | null = null;
  /**
   * Проходы не пересекаются — внутри процесса. Два параллельных прохода по одному ящику верный
   * способ получить от сервера отказ по частоте и разреженные курсоры; защита — флаг `busy`,
   * в БД замка нет, поэтому второй процесс (кластер, dev рядом с prod) её не видит.
   */
  private busy = false;
  private stopped = false;
  /** Когда начался текущий проход и его «поколение»: сторож и остановка отменяют устаревшее. */
  private passStartedAt = 0;
  private passToken = 0;
  private passRunning: Promise<void> | null = null;

  constructor(
    private readonly prisma: PrismaService,
    private readonly accounts: MailAccountsService,
    private readonly ingestService: MailIngestService,
    private readonly purgeService: MailPurgeService,
  ) {}

  onModuleInit(): void {
    if (!env.MAIL_SYNC_ENABLED) {
      // Синхронизация выключена — но статус мог остаться `syncing` от прошлого процесса:
      // сбрасываем, иначе интерфейс вечно показывал бы «идёт синхронизация».
      void this.resetStaleStatus('синхронизация почты выключена (MAIL_SYNC_ENABLED=false)');
      this.logger.log('синхронизация почты выключена (MAIL_SYNC_ENABLED=false)');
      return;
    }
    if (!mailCryptoReady()) {
      // Тот же сброс: синхронизация не стартует вовсе, и подвисший `syncing` остался бы навсегда.
      void this.resetStaleStatus('MAIL_SECRET_KEY не задан — синхронизация почты не запущена');
      this.logger.error('MAIL_SECRET_KEY не задан — синхронизация почты не запущена');
      return;
    }
    this.timer = setInterval(() => void this.runPass('по расписанию'), env.MAIL_SYNC_INTERVAL_SEC * 1000);
    this.timer.unref();
    this.logger.log(
      `синхронизация почты запущена: проход каждые ${env.MAIL_SYNC_INTERVAL_SEC} с (страховка), ` +
        `новые письма — по IDLE, истории за проход — ${env.MAIL_BACKFILL_PER_PASS} писем`,
    );
    void this.runPass('старт');
  }

  /**
   * Остановка процесса: текущий проход не бросаем на полуслове.
   *
   * Сначала помечаем остановку и отменяем «поколение» прохода — циклы внутри увидят это и
   * выйдут, не начиная новых писем. Затем ждём проход ограниченное время, и только потом
   * закрываем соединения: закрыть их под работающим `await` — это потерять письмо в работе
   * (курсор за него не двинулся, но и письмо не сохранено).
   */
  async onModuleDestroy(): Promise<void> {
    this.stopped = true;
    this.passToken += 1;
    if (this.timer) clearInterval(this.timer);
    if (this.wakeTimer) clearTimeout(this.wakeTimer);
    if (this.watchRetryTimer) clearTimeout(this.watchRetryTimer);
    if (this.passRunning) {
      await Promise.race([this.passRunning.catch(() => undefined), sleep(SHUTDOWN_WAIT_MS)]);
    }
    this.busy = false;
    for (const [id, client] of this.clients) {
      try {
        client.close();
      } catch {
        /* соединение могло закрыться само */
      }
      this.clients.delete(id);
    }
    for (const id of [...this.watchers.keys()]) this.dropWatcher(id);
  }

  /** Сбросить подвисший `syncing` (прошлый процесс умер посреди прохода). */
  private async resetStaleStatus(reason: string): Promise<void> {
    await this.prisma.mailAccount
      .updateMany({
        where: { status: 'syncing' },
        data: { status: 'idle', statusError: `прошлый проход был прерван: ${reason}` },
      })
      .catch((e) => this.logger.warn(`сброс статуса «syncing» не удался — ${errorText(e, 200)}`));
  }

  /** Проход по всем включённым аккаунтам. Параллельные вызовы схлопываются в один. */
  async runPass(reason: string): Promise<void> {
    if (this.stopped) return;

    // Список аккаунтов — первое обращение к БД, и оно может отказать (рестарт Postgres,
    // исчерпанный пул). Раньше это был необработанный reject: вызов идёт из таймера и с
    // `void`, то есть падал весь процесс — файлы, фото и загрузки вместе с почтой.
    let accounts: MailAccountRow[];
    try {
      accounts = await this.prisma.mailAccount.findMany({ where: { enabled: true } });
    } catch (e) {
      this.logger.warn(`проход (${reason}) не начался: список аккаунтов не получен — ${errorText(e, 300)}`);
      return;
    }

    // Сторожа поднимаем до проверки на занятость: проход может идти минутами, и всё это время
    // новые письма должны приходить. Аккаунт, который выключили или удалили, лишается и
    // сторожа, и постоянного соединения: держать аутентифицированное подключение к ящику,
    // которым система уже не управляет, нельзя (и провайдеры считают такие соединения).
    const enabled = new Set(accounts.map((a) => a.id));
    for (const id of [...this.watchers.keys()]) {
      if (!enabled.has(id)) this.dropWatcher(id);
    }
    for (const id of [...this.clients.keys()]) {
      if (!enabled.has(id)) this.dropClient(id);
    }
    for (const account of accounts) {
      if (!this.accounts.presetOf(account.kind).folders.length) continue;
      void this.ensureWatcher(account);
    }

    if (this.busy) {
      // Сторож по занятости: если проход идёт дольше PASS_WATCHDOG_MS, значит где-то завис
      // `await` (лок папки, S3, пул БД). Без этого `busy` остался бы `true` навсегда, и
      // синхронизация молча встала бы до перезапуска — в логе только «проход пропущен».
      const spent = Date.now() - this.passStartedAt;
      if (spent > PASS_WATCHDOG_MS) {
        await this.abortStuckPass(accounts, spent, reason);
      } else {
        this.logger.log(`проход пропущен (${reason}): предыдущий ещё идёт`);
      }
      return;
    }

    this.busy = true;
    this.passStartedAt = Date.now();
    const token = (this.passToken += 1);
    const running = (async () => {
      try {
        // Бюджет трафика — на аккаунт за проход: `MAIL_PASS_BUDGET_MB` описана как потолок
        // прохода, а не папки, и у Gmail это суточный лимит скачивания.
        const perAccount = env.MAIL_PASS_BUDGET_MB * 1024 * 1024;
        for (const account of accounts) {
          if (this.isCancelled(token)) {
            this.logger.warn(`проход (${reason}) прерван: остановка процесса или сторож`);
            return;
          }
          // Аккаунт без IMAP (почту приносит наш сервер) в расписании не участвует:
          // качать из него нечего, а соединение к пустому хосту — это ошибка в статусе.
          if (!this.accounts.presetOf(account.kind).folders.length) continue;
          try {
            await this.syncAccount(account, { left: perAccount }, token);
          } catch (e) {
            await this.markError(account.id, e);
          }
        }
      } finally {
        // Снимаем занятость только своему поколению: если сторож уже отменил этот проход и
        // запустил новый, `busy` принадлежит новому.
        if (this.passToken === token) {
          this.busy = false;
          this.passRunning = null;
        }
      }
    })();
    this.passRunning = running;
    await running;
  }

  /** Проход отменён (остановка процесса или сторож) — дальше циклы не продолжают работу. */
  private isCancelled(token: number): boolean {
    return this.stopped || this.passToken !== token;
  }

  /**
   * Сторож сработал: проход висит дольше PASS_WATCHDOG_MS.
   *
   * Отменяем его поколение (циклы выйдут на ближайшей проверке), снимаем `busy`, закрываем
   * соединения аккаунтов — именно они чаще всего и виноваты — и пишем причину в статус, чтобы
   * это не выглядело как «синхронизация работает».
   */
  private async abortStuckPass(accounts: MailAccountRow[], spentMs: number, reason: string): Promise<void> {
    const minutes = Math.round(spentMs / 60_000);
    this.logger.error(`проход (${reason}) висит ${minutes} мин — отменяю, соединения закрываю`);
    this.passToken += 1;
    for (const account of accounts) this.dropClient(account.id);
    this.busy = false;
    this.passRunning = null;
    const message = `проход не завершился за ${minutes} мин — соединения закрыты, попробую снова`;
    for (const account of accounts) {
      await this.prisma.mailAccount
        .update({ where: { id: account.id }, data: { status: 'error', statusError: message } })
        .catch(() => undefined);
    }
  }

  private async markError(accountId: string, e: unknown): Promise<void> {
    // Текст ошибки провайдера полезен («Too many simultaneous connections»), а пароль в него
    // попасть не должен: imapflow креденшелы скрывает, длину мы обрезаем.
    const message = errorText(e, 400);
    this.logger.warn(`аккаунт ${accountId}: ${message}`);
    await this.prisma.mailAccount
      .update({ where: { id: accountId }, data: { status: 'error', statusError: message } })
      .catch(() => undefined);
    this.dropClient(accountId);
  }

  /**
   * Письма, которые не удалось сохранить, — для отчёта в статусе аккаунта.
   *
   * Публичный вход, чтобы контроллер мог показать «есть несохранённые письма: N» рядом с
   * остальным статусом (сам контроллер — не мой файл, сейчас он этого не делает).
   */
  unsavedFor(accountId: string): UnsavedLetter[] {
    const out: UnsavedLetter[] = [];
    for (const [key, item] of this.unsaved) {
      if (key.startsWith(`${accountId}|`)) out.push(item);
    }
    return out;
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

  private async syncAccount(account: MailAccountRow, budget: PassBudget, token: number): Promise<void> {
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
    // сохранённого письма, поэтому продолжение с него ничего не перекачивает.
    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        const client = await this.connect(account);
        const folders = await this.resolveFolders(client, preset.folders);
        for (const folder of folders) {
          if (this.isCancelled(token)) break;
          try {
            // Письма, сохранённые в этом проходе: их серверные копии убираем сразу, не ожидая
            // никакого расписания. Ждём только новых писем — история идёт своим чередом.
            const fresh: StoredRef[] = [];
            stored += await this.syncFolder(client, account, folder, fresh, budget, token);
            // Не ждём чистку: у неё свои соединение и паузы (перенос в мусорку отражается не
            // мгновенно), и блокировать ими проход/кнопку «Обновить» нельзя — письмо уже у нас,
            // а копия уйдёт в фоне. Ошибка не теряет письмо: его доберёт догоняющий проход.
            if (fresh.length) void this.purgeFresh(account, fresh);
          } catch (e) {
            // Обрыв соединения — не ошибка папки: повторяем проход целиком (свежее
            // соединение), и только если и он не удался, показываем ошибку.
            if (isConnectionError(e)) throw e;
            // Одна недоступная папка (у iCloud «Junk» может отсутствовать) не должна ронять
            // весь аккаунт: остальные папки синхронизируем, а причину показываем в статусе.
            failed = errorText(e, 400);
            this.logger.warn(`${account.email}, папка ${folder.path}: ${failed}`);
          }
        }
        // Папки пройдены. Второй attempt нужен только при обрыве соединения — он бросает
        // исключение и обрабатывается ниже; отказ отдельной папки повтора не требует,
        // причина уже записана в `failed`.
        break;
      } catch (e) {
        const message = errorText(e, 400);
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

    // Несохранённые письма — это дырка в архиве, о которой иначе никто не узнает: показываем
    // счётчик в статусе аккаунта (подробности с координатами — в логе).
    const unsaved = this.unsavedFor(account.id).length;
    await this.prisma.mailAccount.update({
      where: { id: account.id },
      data: {
        status: failed || unsaved ? 'error' : 'idle',
        statusError: failed ?? (unsaved ? `есть несохранённые письма: ${unsaved} — копии остались на сервере` : null),
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
      this.logger.warn(`список папок не получен, работаем по именам из настроек: ${errorText(e, 200)}`);
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
      // Флаг пресета, а не жёсткое true: у обычного IMAP-сервера бывает и STARTTLS.
      secure: this.accounts.presetOf(account.kind).secure,
      auth: { user: login, pass: password },
      // Логгер imapflow пишет команды целиком — вместе с ним в лог уехал бы и пароль
      logger: false,
      clientInfo: { name: 'CloudlyRu', version: '0.1.0' },
      // 5 минут простоя на сокете: дольше держать соединение без команд смысла нет, а короткий
      // таймаут рвал бы выборку большого письма на медленном канале. Приветствие сервера ждём
      // 20 с — у почтовых серверов бывает и больше, но столько уже выглядит как «сервер лежит».
      socketTimeout: 300_000,
      greetingTimeout: 20_000,
      // IDLE этому соединению не нужен: оно живёт ради выборок во время прохода, а
      // автоматический IDLE через 15 с простоя держал бы его открытым вечно — в дополнение
      // к сторожу и трём соединениям на аккаунт (провайдеры это считают).
      disableAutoIdle: true,
    });
    client.on('error', (e: Error) => this.logger.warn(`IMAP ${account.email}: ${e.message}`));
    client.on('close', () => {
      if (this.clients.get(account.id) === client) this.clients.delete(account.id);
    });
    await client.connect();
    this.clients.set(account.id, client);
    return client;
  }

  /**
   * Сторожевое соединение аккаунта: папка, через которую видно всё новое, открыта в IDLE.
   *
   * Письмо не ждёт расписания: сервер в IDLE сам присылает EXISTS, событие будит внеочередной
   * проход. Соединение живёт постоянно и не пересекается с проходом — папка, открытая под IDLE,
   * занята (выборку по ней сервер не примет, пока не разорвём IDLE), поэтому у прохода своё
   * соединение (`clients`), у сторожа своё (`watchers`).
   *
   * Подъём идёт в фоне и никогда не роняет проход: не получилось — попробуем на следующем
   * расписании (повтор по своему таймеру — только для сторожа, который был и отвалился:
   * биться в закрытую дверь каждые 15 секунд незачем).
   */
  private async ensureWatcher(account: MailAccountRow): Promise<void> {
    if (this.stopped) return;
    if (this.watchers.get(account.id)?.usable) return;
    if (this.watchPending.has(account.id)) return;

    // Пауза после неудач. Без неё неверный пароль или удалённый аккаунт превращались в
    // непрерывные попытки логина (каждые 15 с, ~5760 в сутки), на которые провайдеры
    // отвечают блокировкой входа — то есть мы сами ломали себе доступ.
    const failures = this.watchFailures.get(account.id);
    if (failures && failures.until > Date.now()) return;

    const folder = this.watchFolderOf(account.kind);
    // Нечего стеречь: у аккаунта без IMAP папок нет вовсе.
    if (!folder) return;

    this.watchPending.add(account.id);
    // Соединение, которое надо прикрыть при неудаче: подняться оно могло успеть, а папка — нет.
    let opened: ImapFlow | null = null;
    try {
      this.dropWatcher(account.id);

      const { login, password } = this.accounts.credentials(account);
      const client = new ImapFlow({
        host: account.imapHost,
        port: account.imapPort,
        // Флаг пресета, а не жёсткое true: у обычного IMAP-сервера бывает и STARTTLS.
        secure: this.accounts.presetOf(account.kind).secure,
        auth: { user: login, pass: password },
        // Логгер imapflow пишет команды целиком — вместе с ним в лог уехал бы и пароль
        logger: false,
        clientInfo: { name: 'CloudlyRu', version: '0.1.0' },
        // Таймаут простоя тут работает на пользу: пока мы в IDLE, imapflow посылает NOOP,
        // то есть соединение ещё и не даёт себя молча прикрыть посреднику.
        socketTimeout: 300_000,
        greetingTimeout: 20_000,
        maxIdleTime: IDLE_RESTART_MS,
        autoIdleDelay: WATCH_AUTO_IDLE_DELAY_MS,
      });
      opened = client;
      client.on('error', (e: Error) => this.logger.warn(`IMAP (сторож) ${account.email}: ${e.message}`));
      client.on('exists', () => this.wake());
      client.on('close', () => this.onWatcherClosed(account.id, client));

      await client.connect();
      // Имя системной папки локализовано («[Gmail]/Вся почта»), поэтому ищем её по метке
      // RFC 6154, как и в проходе, а строку из настроек держим запасным вариантом.
      const resolved = await this.resolveFolders(client, [folder]);
      const path = resolved[0]?.path ?? folder.path;
      await client.mailboxOpen(path);

      this.watchers.set(account.id, client);
      this.watchFailures.delete(account.id);
      this.logger.log(`${account.email}: сторож на папке ${path} — новые письма пойдут сразу`);
    } catch (e) {
      try {
        opened?.close();
      } catch {
        /* уже закрыто */
      }
      this.dropWatcher(account.id);
      const message = errorText(e, 400);
      // Повтор — по нарастающей, а не «каждые 15 секунд»: последняя ступень это одна попытка
      // в час, то есть фактическая остановка до вмешательства человека.
      const count = (this.watchFailures.get(account.id)?.count ?? 0) + 1;
      const delay = WATCH_RETRY_DELAYS_MS[Math.min(count, WATCH_RETRY_DELAYS_MS.length) - 1];
      this.watchFailures.set(account.id, { count, until: Date.now() + delay });
      this.logger.warn(
        `${account.email}: сторож не поднялся (попытка ${count}) — ${message}; следующая через ${Math.round(delay / 1000)} с`,
      );
      if (count >= WATCH_RETRY_DELAYS_MS.length) {
        // Отдельно и явно: причина видна в статусе аккаунта, а не только в логе — иначе
        // «почта приходит с задержкой» выглядит как случайность.
        await this.prisma.mailAccount
          .update({
            where: { id: account.id },
            data: { status: 'error', statusError: `сторож не поднимается (${count} попыток): ${message}` },
          })
          .catch(() => undefined);
      }
    } finally {
      this.watchPending.delete(account.id);
    }
  }

  /**
   * За какой папкой следить.
   *
   * Соединение стережёт одну папку, поэтому берём ту, через которую видно всё новое: у Gmail
   * это All Mail (в неё попадает любое письмо), у остальных — INBOX. Спам и корзину отдельно
   * не стережём: письма оттуда добирает плановый проход.
   */
  private watchFolderOf(kind: string): MailSourceFolder | null {
    const folders = this.accounts.presetOf(kind).folders;
    return folders.find((f) => f.specialUse === '\\All') ?? folders.find((f) => f.path === 'INBOX') ?? null;
  }

  private onWatcherClosed(accountId: string, client: ImapFlow): void {
    if (this.watchers.get(accountId) !== client) return;
    this.watchers.delete(accountId);
    // Соединение закрылось само (сервер, сеть, простой) — возвращаемся через паузу, а не
    // ждём следующего расписания: иначе письма «пропадают» до пяти минут.
    this.scheduleWatchRetry();
  }

  private dropWatcher(accountId: string): void {
    const client = this.watchers.get(accountId);
    this.watchers.delete(accountId);
    if (!client) return;
    try {
      client.close();
    } catch {
      /* уже закрыто */
    }
  }

  /** Повтор подъёма сторожей — один таймер на всех: поднимаем то, чего не хватает. */
  private scheduleWatchRetry(): void {
    if (this.stopped || this.watchRetryTimer) return;
    this.watchRetryTimer = setTimeout(() => {
      this.watchRetryTimer = null;
      void this.rearmWatchers();
    }, WATCH_RECONNECT_MS);
    this.watchRetryTimer.unref();
  }

  private async rearmWatchers(): Promise<void> {
    if (this.stopped) return;
    let accounts: MailAccountRow[];
    try {
      accounts = await this.prisma.mailAccount.findMany({ where: { enabled: true } });
    } catch (e) {
      // Раньше ошибка молча превращалась в «нет аккаунтов»: сторожей просто не было, и в логе
      // не оставалось ни следа причины.
      this.logger.warn(`повторный подъём сторожей: список аккаунтов не получен — ${errorText(e, 200)}`);
      return;
    }
    for (const account of accounts) {
      if (!this.accounts.presetOf(account.kind).folders.length) continue;
      void this.ensureWatcher(account);
    }
  }

  /** Внеочередной проход с задержкой-склейкой: письма обычно приходят пачками. Зовёт сторож. */
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
    fresh: StoredRef[],
    budget: PassBudget,
    token: number,
  ): Promise<number> {
    // acquireTimeout обязателен: без него ожидание лока бесконечное, и чужой незакрытый лок
    // подвесил бы проход вместе с флагом busy.
    const lock = await client.getMailboxLock(folder.path, { acquireTimeout: LOCK_ACQUIRE_TIMEOUT_MS });
    let stored = 0;
    try {
      const mailbox = client.mailbox;
      if (!mailbox) throw new Error(`папка ${folder.path} не открылась`);
      const ctx: FolderContext = {
        account,
        folderPath: folder.path,
        box: folder.box,
        uidValidity: BigInt(mailbox.uidValidity),
      };
      const cursor = await this.cursorFor(account.id, folder, ctx.uidValidity);

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
      const incrementalCap = Math.min(budget.left, INCREMENTAL_BUDGET_BYTES);
      let spent = 0;
      if (uidNext > from) {
        // Сначала только метаданные (uid + размер): тело тянем лишь у тех писем, что проходят
        // потолок размера. `source: true` забирает письмо в память целиком, поэтому проверять
        // размер после скачивания — уже поздно: одно письмо на сотни мегабайт уносит процесс.
        const fits: number[] = [];
        let oversized = 0;
        for await (const meta of client.fetch(`${from}:*`, { uid: true, size: true }, { uid: true })) {
          if (BigInt(meta.uid) <= cursor.lastUid) continue;
          if (meta.size && meta.size > MAX_MESSAGE_BYTES) {
            oversized += 1;
            const reason = `размер ${Math.round((meta.size ?? 0) / 1024 / 1024)} МБ больше потолка ${MAX_MESSAGE_MB} МБ (MAIL_MAX_MESSAGE_MB)`;
            this.logger.warn(`${ctx.folderPath}: письмо ${meta.uid} — ${reason}`);
            const givenUp = await this.noteUnsaved(ctx, Number(meta.uid), reason);
            if (!givenUp) {
              // Письмо ещё в списке на повтор: курсор оставляем перед ним, дальше не идём.
              break;
            }
            // Попытки кончились — пропускаем окончательно, иначе одно огромное письмо
            // навсегда закрыло бы дорогу всем следующим.
            if (BigInt(meta.uid) > lastUid) {
              lastUid = BigInt(meta.uid);
              await this.prisma.mailCursor.update({
                where: { id: cursor.id },
                data: { lastUid, lastSeenAt: new Date() },
              });
            }
            continue;
          }
          fits.push(meta.uid);
        }
        if (oversized) {
          this.logger.warn(`${ctx.folderPath}: пропущено по размеру писем — ${oversized}`);
        }

        for await (const msg of this.sourceStream(client, fits)) {
          if (this.isCancelled(token)) break;
          if (BigInt(msg.uid) <= cursor.lastUid) continue;
          const item = this.messageOf(msg, ctx);
          // Сохранять нечего (черновик или пустой ответ) — это не потеря, и курсор за таким
          // письмом двигается: иначе черновик в All Mail навсегда закрыл бы дорогу новым.
          if (!item) {
            if (BigInt(msg.uid) > lastUid) {
              lastUid = BigInt(msg.uid);
              await this.prisma.mailCursor.update({
                where: { id: cursor.id },
                data: { lastUid, lastSeenAt: new Date() },
              });
            }
            continue;
          }
          // Бюджет проверяем до обработки: иначе за проход уезжает на одно письмо больше
          // лимита, и на большом ящике это заметно.
          if (spent > 0 && spent + item.bytes > incrementalCap) break;

          // Двигаем курсор только за письмо, которое либо сохранилось, либо окончательно
          // пропущено: инвариант файла в одном месте.
          let advance = false;
          try {
            const result = await this.ingestService.ingest(item.input);
            advance = true;
            if (result === 'stored' || result === 'attachments-repaired') {
              stored += 1;
              fresh.push({ folderPath: ctx.folderPath, uidValidity: ctx.uidValidity, uid: Number(msg.uid) });
            }
            this.clearUnsaved(ctx, Number(msg.uid));
          } catch (e) {
            // Инвариант курсора: за письмо, которого у нас нет, курсор не двигается. Иначе
            // письмо выпадает из архива навсегда — ни догрузка, ни бэкфилл его больше не
            // увидят, и о дырке никто не узнает.
            const givenUp = await this.noteUnsaved(ctx, Number(msg.uid), errorText(e, 200));
            if (!givenUp) {
              this.logger.warn(
                `${ctx.folderPath}: новое письмо ${msg.uid} не сохранено — ${errorText(e, 200)}; ` +
                  'курсор оставляю перед ним, попробую следующим проходом',
              );
              break;
            }
            // Попытки кончились: письмо пропускаем, иначе одно битое письмо навсегда
            // остановило бы приход новых. Оно остаётся в списке несохранённых.
            advance = true;
          }

          // Курсор двигаем сразу за письмом: падение на следующем не заставит перекачивать
          // всё заново (у Gmail это ещё и лимит трафика на сутки).
          if (advance && BigInt(msg.uid) > lastUid) {
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

      budget.left -= spent;
      // 2. История: порция за проход, от свежих к старым. Ей достаётся весь остаток бюджета
      // аккаунта — история и есть основная работа, пока она не добрана.
      if (budget.left > 0 && !cursor.backfillDone) {
        stored += await this.backfill(client, ctx, cursor, budget, token);
      }
    } finally {
      lock.release();
    }
    return stored;
  }

  /** Письма порции: пустой список UID imapflow не принимает, а он бывает — если все письма
   *  диапазона не прошли потолок размера или были ниже курсора. */
  private sourceStream(client: ImapFlow, uids: number[]): AsyncIterable<FetchMessageObject> {
    return uids.length ? client.fetch(uids, SOURCE_QUERY, { uid: true }) : emptyStream();
  }

  /** Размер и дата писем — до скачивания тел (своей командой на порцию). */
  private async metaOf(
    client: ImapFlow,
    uids: number[],
  ): Promise<Map<number, { size: number; internalDate: Date | null }>> {
    const out = new Map<number, { size: number; internalDate: Date | null }>();
    if (!uids.length) return out;
    for await (const meta of client.fetch(uids, { uid: true, size: true, internalDate: true }, { uid: true })) {
      out.set(Number(meta.uid), {
        size: meta.size ?? 0,
        internalDate: meta.internalDate ? new Date(meta.internalDate) : null,
      });
    }
    return out;
  }

  /**
   * Запомнить письмо, которое не удалось сохранить. Возвращает `true`, если попытки кончились
   * и курсор можно двигать дальше.
   *
   * Счётчик попыток живёт в памяти процесса: переживающая перезапуск таблица неудач требует
   * миграции (её у этого модуля нет). После перезапуска письмо просто получит ещё три попытки —
   * это безопасно, курсор за ним всё равно не уходил.
   */
  private async noteUnsaved(ctx: FolderContext, uid: number, error: string): Promise<boolean> {
    const key = unsavedKey(ctx, uid);
    const known = this.unsaved.get(key);
    const item: UnsavedLetter = {
      folderPath: ctx.folderPath,
      uid,
      uidValidity: ctx.uidValidity,
      tries: (known?.tries ?? 0) + 1,
      error,
      at: known?.at ?? new Date(),
      givenUp: (known?.tries ?? 0) + 1 >= INGEST_MAX_TRIES,
    };
    this.unsaved.set(key, item);
    // Ограничиваем размер: отчёт нужен про свежие неудачи, а не про всю историю.
    while (this.unsaved.size > UNSAVED_KEEP) {
      const oldest = this.unsaved.keys().next();
      if (oldest.done) break;
      this.unsaved.delete(oldest.value);
    }
    if (item.givenUp) {
      // Курсор пойдёт дальше, а письмо останется только в этом списке и в логе — поэтому
      // про него пишем уровнем выше: иначе дырка в архиве никому не видна.
      this.logger.error(
        `${ctx.folderPath}: письмо ${uid} не сохранено (попыток ${item.tries}) — ${error}; ` +
          'письмо пропущено, его копия на сервере осталась',
      );
    }
    return item.givenUp;
  }

  /** Письмо сохранилось — убираем его из списка несохранённых. */
  private clearUnsaved(ctx: FolderContext, uid: number): void {
    const key = unsavedKey(ctx, uid);
    if (this.unsaved.has(key)) this.unsaved.delete(key);
  }

  /**
   * Убрать серверные копии только что сохранённых писем — сразу, а не проходом по расписанию.
   *
   * Письмо проверяется поимённо (в чистке): есть ли байты у нас и лежит ли по координатам на
   * сервере именно оно. Не получилось убрать копию — не беда: письмо важнее уборки, оно
   * остаётся у провайдера, а причина видна в логе.
   */
  private async purgeFresh(account: MailAccountRow, fresh: StoredRef[]): Promise<void> {
    try {
      const rows = await this.prisma.mailMessage.findMany({
        where: {
          OR: fresh.map((f) => ({
            accountId: account.id,
            folderPath: f.folderPath,
            uidValidity: f.uidValidity,
            uid: BigInt(f.uid),
          })),
        },
        select: { id: true },
      });
      if (!rows.length) return;
      const result = await this.purgeService.purgeMessages(
        account,
        rows.map((r) => r.id),
      );
      if (result.purged) this.logger.log(`${account.email}: свежих писем убрано с сервера — ${result.purged}`);
    } catch (e) {
      this.logger.warn(`${account.email}: не удалось убрать копии свежих писем — ${errorText(e, 300)}`);
    }
  }

  /**
   * Кусок истории за проход.
   *
   * Идём назад по дате: берём UID-и старше границы, которых у нас ещё нет, и скачиваем самые
   * свежие из них. Границу сдвигаем на день вперёд от самого старого ОБРАБОТАННОГО письма, а не
   * ровно на его дату: у IMAP-поиска BEFORE точность — сутки, и «BEFORE 14 сентября» не
   * включает 14 сентября. Учитывать только успешно сохранённые письма здесь нельзя: граница
   * уехала бы за несохранённое, и письмо выпало бы из истории навсегда — а с учётом неудачных
   * оно остаётся внутри окна поиска и будет перекачано следующим проходом.
   *
   * Список UID-ов приходит целиком (так устроен IMAP SEARCH), но `known` считается по одной
   * порции: раньше здесь выгружались ВСЕ uid папки в память — на ящике в 300-500 тысяч писем
   * это десятки мегабайт на каждый проход каждые две минуты. Чанки перебираем от свежих к
   * старым и останавливаемся на первом, где есть чего добрать: письма между ним и границей
   * уже у нас.
   */
  private async backfill(
    client: ImapFlow,
    ctx: FolderContext,
    cursor: MailCursor,
    passBudget: PassBudget,
    token: number,
  ): Promise<number> {
    const walkBefore = cursor.backfillFrom ?? new Date();
    const floor = this.backfillFloor();
    if (floor && walkBefore <= floor) {
      await this.finishBackfill(cursor.id);
      return 0;
    }

    // search отдаёт false при отказе сервера и пустой массив, когда писем правда нет. Разница
    // принципиальная: в первом случае история просто не сдвинется и следующий проход попробует
    // снова, во втором она пройдена целиком. Раньше отказ сервера помечал историю пройденной
    // навсегда (backfillDone = true), и архив молча оставался неполным.
    const found = await client.search({ before: walkBefore }, { uid: true });
    if (!Array.isArray(found)) {
      this.logger.warn(
        `${ctx.folderPath}: поиск по истории не удался (сервер отказал) — попробую следующим проходом`,
      );
      return 0;
    }
    const uids = found;
    if (!uids.length) {
      // Вот здесь писем старше границы действительно нет: история пройдена.
      await this.finishBackfill(cursor.id);
      return 0;
    }

    // UID-ы приходят по возрастанию (это порядок сервера), поэтому «свежие» — в конце массива.
    const perPass = env.MAIL_BACKFILL_PER_PASS;
    const missing = await this.missingInWindow(ctx, uids, perPass);
    if (!missing.length) {
      // Старше границы ничего не осталось — история пройдена целиком.
      await this.finishBackfill(cursor.id);
      return 0;
    }
    // Остаток истории в письмах, а не в датах: по одной границе понять, сколько ещё качать,
    // невозможно, а вопрос «когда уже можно уходить с сервера» возникает каждый раз.
    this.logger.log(
      `${ctx.folderPath}: истории осталось не больше ${uids.length} писем, к загрузке ${missing.length} ` +
        `(граница ${walkBefore.toISOString().slice(0, 10)})`,
    );

    let stored = 0;
    let failed = 0;
    let oldest: Date | null = null;

    // Размер письма узнаём до скачивания тела — по той же причине, что и в догрузке нового:
    // `source: true` тянет письмо в память целиком. Дату берём в том же запросе: она нужна,
    // чтобы слишком большое письмо не осталось позади границы истории.
    const meta = await this.metaOf(client, missing);
    const fits: number[] = [];
    for (const uid of missing) {
      const info = meta.get(uid);
      if (info?.size && info.size > MAX_MESSAGE_BYTES) {
        failed += 1;
        const reason = `размер ${Math.round(info.size / 1024 / 1024)} МБ больше потолка ${MAX_MESSAGE_MB} МБ (MAIL_MAX_MESSAGE_MB)`;
        this.logger.warn(`${ctx.folderPath}: письмо ${uid} — ${reason}`);
        const givenUp = await this.noteUnsaved(ctx, uid, reason);
        // Пока письмо в списке на повтор, граница за него не уходит: иначе оно выпало бы
        // из окна поиска и потерялось бы окончательно. После отказа границу отпускаем.
        if (!givenUp && info.internalDate && (!oldest || info.internalDate < oldest)) {
          oldest = info.internalDate;
        }
        continue;
      }
      fits.push(uid);
    }

    // Одной командой на всю порцию, а не по команде на письмо. Раньше здесь было 200
    // отдельных UID FETCH за проход — Gmail на такое отвечает обрывом соединения
    // («Connection not available» посреди прохода), и проход умирал, не добрав порцию.
    for await (const fetched of this.sourceStream(client, fits)) {
      if (this.isCancelled(token) || passBudget.left <= 0) break;
      const item = this.messageOf(fetched, ctx);
      if (!item) continue;
      let ok = false;
      let givenUp = false;
      try {
        const result = await this.ingestService.ingest(item.input);
        ok = true;
        if (result === 'stored' || result === 'attachments-repaired') stored += 1;
        this.clearUnsaved(ctx, Number(fetched.uid));
      } catch (e) {
        // Одно проблемное письмо не имеет права останавливать выгрузку: история дойдёт
        // до него ещё раз — окно поиска определяется датой, а дата неудачного письма
        // учитывается ниже наравне с успешными. Раньше исключение убивало весь проход,
        // и граница истории не двигалась вовсе — архив вставал намертво на одном письме.
        failed += 1;
        givenUp = await this.noteUnsaved(ctx, Number(fetched.uid), errorText(e, 200));
      }
      passBudget.left -= item.bytes;
      const received = item.input.receivedAt;
      // Границу двигаем по всем обработанным письмам, включая неудачные (см. комментарий
      // выше). Исключение — письмо, от которого мы отказались: за него граница уходит,
      // иначе оно возило бы за собой перекачивание всей порции каждый проход.
      if (!(givenUp && !ok) && (!oldest || received < oldest)) oldest = received;
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

  /**
   * UID-ы окна истории, которых у нас нет, — начиная с самых свежих.
   *
   * Чанками по `perPass` от конца массива (там свежие UID) и до первого чанка, где есть чего
   * добрать: письма выше него уже сохранены, а значит искать среди них нечего. В память
   * попадает только текущий чанк, а не вся папка.
   */
  private async missingInWindow(ctx: FolderContext, uids: number[], perPass: number): Promise<number[]> {
    for (let end = uids.length; end > 0; end -= perPass) {
      const chunk = uids.slice(Math.max(0, end - perPass), end);
      const known = new Set(
        (
          await this.prisma.mailMessage.findMany({
            where: {
              accountId: ctx.account.id,
              folderPath: ctx.folderPath,
              uidValidity: ctx.uidValidity,
              uid: { in: chunk.map((u) => BigInt(u)) },
            },
            select: { uid: true },
          })
        ).map((r) => Number(r.uid)),
      );
      const gaps = chunk.filter((u) => !known.has(u));
      // Свежие — в конце, скачивать их и надо первыми.
      if (gaps.length) return gaps.reverse();
    }
    return [];
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

    // Папка источника уже говорит, что это «Исходящие» (iCloud Sent Messages) — это первое и
    // самое надёжное основание, оно берётся из пресета, а не из имени папки. А в All Mail
    // у Gmail письма лежат вперемешку, поэтому там смотрим системную метку \Sent. Имя папки —
    // только третий, запасной признак: подстроку «sent» находили и в «Sentinel», и в «Consent».
    const labels = msg.labels ?? new Set<string>();
    const sent = ctx.box === 'sent' || labels.has('\\Sent') || flags.has('\\Sent') || looksLikeSentFolder(ctx.folderPath);
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

/** Пустой поток писем: imapflow на пустой список UID ругается, а цикл должен просто не пойти. */
async function* emptyStream(): AsyncGenerator<FetchMessageObject> {
  /* писем нет */
}

/** Ключ несохранённого письма: аккаунт + координаты (uid без папки и uidValidity не уникален). */
function unsavedKey(ctx: FolderContext, uid: number): string {
  return `${ctx.account.id}|${ctx.folderPath}|${ctx.uidValidity}|${uid}`;
}

/**
 * Похоже ли имя папки на «Исходящие» — третий, запасной признак после метки `box` пресета и
 * флага `\Sent`. Сравниваем последний сегмент пути и требуем границу слова: раньше проверялась
 * подстрока, и «Sent Items Archive», «Consent», «Sentinel» попадали в исходящие.
 */
function looksLikeSentFolder(folderPath: string): boolean {
  const last = folderPath.split(/[/.]/).pop()?.trim().toLowerCase() ?? '';
  return last === 'sent' || last.startsWith('sent ');
}

/** Текст ошибки для лога: `throw 'строка'` и `throw {}` тоже встречаются. */
function errorText(e: unknown, limit: number): string {
  return (e instanceof Error ? e.message : String(e)).slice(0, limit);
}
