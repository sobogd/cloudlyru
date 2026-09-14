import { Injectable, Logger, type OnModuleDestroy, type OnModuleInit } from '@nestjs/common';
import { ImapFlow } from 'imapflow';
import { PrismaService } from '../prisma/prisma.service';
import { env } from '../config/env';
import { badRequest } from '../common/errors';
import { headerMessageId } from './mail-parse';
import { LOCAL_PREFIX } from './mail-ingest.service';
import { MailAccountsService, type MailAccountRow } from './mail-accounts.service';

/**
 * Уборка копий с сервера аккаунта — единственная необратимая операция во всём разделе.
 *
 * Поэтому она устроена так:
 *   1. По умолчанию выключена (MAIL_PURGE_ENABLED=false) и не работает без явного `confirm`.
 *   2. Между «письмо сохранено у нас» и «удалено с сервера» есть карантин: свежие письма
 *      не трогаем, у нас есть время заметить, что синхронизация что-то не донесла.
 *   3. Сначала всегда отчёт (`plan`) — сколько писем попадёт под удаление и почему остальные
 *      не попали. Только потом удаление.
 *   4. Предохранитель на долю ящика: если под удаление уходит больше половины (и больше сотни
 *      писем), прогон отказывается работать. Это защита от ошибки в отборе, а не от человека.
 *   5. Письма от провайдеров доступа (коды входа, оповещения о безопасности) не удаляем
 *      никогда: потерять их — значит потерять доступ к самому аккаунту.
 *
 * Удаление в два шага — так устроены Gmail и iCloud: пометка \Deleted + EXPUNGE уносит письмо
 * не в небытие, а в мусорку сервера («Корзина» у Gmail, «Удалённые сообщения» у iCloud),
 * и безобидно лежит там месяц. Поэтому после удаления из папки источника мы проходим по
 * мусорке и добиваем там те письма, которые только что убрали (по Message-ID).
 */

/** Сколько попыток удалить копию делаем, прежде чем оставить письмо в покое навсегда. */
const MAX_TRIES = 3;

/**
 * Письма, хранящиеся только у нас: их никогда не было на сервере, удалять нечего.
 *
 * Условие именно по приставке, а не по одному значению `local:sent`: писем без серверной
 * копии два вида — своя отправка и принятое нашим же сервером (`local:local`), и вторые
 * раньше под предохранитель не попадали. При включённом автоудалении это означало бы
 * попытки удалить письмо из папки, которой на сервере нет.
 */
const ON_SERVER_FOLDER = { not: { startsWith: LOCAL_PREFIX } } as const;

/** Пауза перед разбором мусорки: серверу нужно мгновение на отражение переноса. */
const TRASH_SETTLE_MS = 3000;

/** Порции при разборе мусорки: по столько писем за один FETCH. */
const TRASH_BATCH = 200;

/** Сколько примеров писем показывать в отчёте. */
const SAMPLES = 5;

/** Пауза в асинхронном коде: короткая, поэтому обычный таймер. */
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export interface PurgeExclusions {
  quarantined: number;
  flagged: number;
  protectedSender: number;
  localOnly: number;
  failed: number;
  alreadyPurged: number;
}

export interface PurgePlanAccount {
  accountId: string;
  email: string;
  /** Всего живых писем в аккаунте (без корзины). */
  total: number;
  /** Сколько писем будет удалено этим прогоном (не больше MAIL_PURGE_PER_RUN). */
  candidates: number;
  /** Сколько ещё останется после прогона. */
  remaining: number;
  oldest: string | null;
  newest: string | null;
  excluded: PurgeExclusions;
  samples: Array<{ subject: string | null; from: string | null; receivedAt: string }>;
}

export interface PurgePlan {
  dryRun: true;
  enabled: boolean;
  quarantineHours: number;
  perRun: number;
  accounts: PurgePlanAccount[];
  /** Отказ предохранителя: прогон в таком состоянии не запустится. */
  blocked: string | null;
}

export interface PurgeReport {
  enabled: boolean;
  purged: number;
  failed: number;
  /** Сколько писем добито в мусорке сервера (второй шаг удаления). */
  trashSwept: number;
  accounts: Array<{ email: string; purged: number; failed: number; trashSwept: number; errors: string[] }>;
}

interface CandidateRow {
  id: string;
  folderPath: string;
  uid: bigint;
  uidValidity: bigint;
  messageId: string | null;
  subject: string | null;
  fromAddr: string | null;
  flagged: boolean;
  sortAt: Date;
}

@Injectable()
export class MailPurgeService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(MailPurgeService.name);
  /** Проход по расписанию: пока автоудаление включено, владелец его уже подтвердил. */
  private timer: NodeJS.Timeout | null = null;

  onModuleInit(): void {
    if (!env.MAIL_PURGE_ENABLED) return;
    this.logger.log(
      `автоудаление копий включено: проход каждые ${env.MAIL_PURGE_INTERVAL_SEC} с, по ${env.MAIL_PURGE_PER_RUN} писем за проход, ` +
        `карантин ${env.MAIL_PURGE_QUARANTINE_HOURS} ч`,
    );
    // Первый проход — не сразу после запуска, а через интервал: перезапуск сервиса не должен
    // означать немедленное удаление. Заодно синхронизация успевает догрузить свежую почту.
    this.timer = setInterval(() => void this.scheduledPass(), env.MAIL_PURGE_INTERVAL_SEC * 1000);
    this.timer.unref();
  }

  onModuleDestroy(): void {
    if (this.timer) clearInterval(this.timer);
  }

  /**
   * Проход по расписанию: подтверждение не спрашиваем — его дал владелец, включив автоудаление.
   * Всё остальное как у ручного запуска: тот же отчёт, тот же предохранитель, тот же карантин.
   */
  private async scheduledPass(): Promise<void> {
    const users = await this.prisma.user.findMany({ select: { id: true, login: true } });
    for (const user of users) {
      try {
        const report = await this.run(user.id, { confirm: true });
        if (report.purged || report.failed) {
          this.logger.log(`автоудаление (${user.login}): удалено ${report.purged}, не получилось ${report.failed}`);
        }
      } catch (e) {
        // Предохранитель или недоступный сервер — не повод ронять расписание: следующий
        // проход попробует снова, а причина видна в логе.
        this.logger.warn(`автоудаление (${user.login}) не прошло: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
  }

  constructor(
    private readonly prisma: PrismaService,
    private readonly accounts: MailAccountsService,
  ) {}

  /** Открыть соединение с аккаунтом. Отдельным методом — чтобы подменять его в проверках. */
  protected async openClient(account: MailAccountRow): Promise<ImapFlow> {
    const { login, password } = this.accounts.credentials(account);
    const client = new ImapFlow({
      host: account.imapHost,
      port: account.imapPort,
      secure: true,
      auth: { user: login, pass: password },
      logger: false,
      clientInfo: { name: 'CloudlyRu', version: '0.1.0' },
      socketTimeout: 300_000,
      greetingTimeout: 20_000,
      // Автоматический IDLE тут не нужен: соединение живёт ровно один прогон и закрывается.
      disableAutoIdle: true,
    });
    client.on('error', (e: Error) => this.logger.warn(`IMAP ${account.email}: ${e.message}`));
    await client.connect();
    return client;
  }

  /** Домены из настроек, письма от которых не удаляем. */
  private protectedDomains(): string[] {
    return String(env.MAIL_PURGE_PROTECT_SENDERS ?? '')
      .split(',')
      .map((d) => d.trim().toLowerCase().replace(/^@/, ''))
      .filter(Boolean);
  }

  private isProtected(fromAddr: string | null): boolean {
    if (!fromAddr) return false;
    const addr = fromAddr.toLowerCase();
    return this.protectedDomains().some((domain) => addr === domain || addr.endsWith(`@${domain}`) || addr.endsWith(`.${domain}`));
  }

  private quarantineCutoff(): Date {
    return new Date(Date.now() - env.MAIL_PURGE_QUARANTINE_HOURS * 60 * 60 * 1000);
  }

  /**
   * Отчёт: что будет удалено и почему остальное не попадёт под удаление.
   * Ничего не меняет — это и есть «прогон на сухую».
   */
  async plan(userId: string, opts: { limit?: number } = {}): Promise<PurgePlan> {
    // Аккаунты «своего сервера» пропускаем: почту принимаем мы сами, чужой копии, которую
    // можно было бы убрать, у таких писем нет вовсе — подключаться некуда (imapHost пуст).
    const accounts = await this.prisma.mailAccount.findMany({
      where: { userId, imapHost: { not: '' } },
      orderBy: { createdAt: 'asc' },
    });
    const limit = this.limitOf(opts.limit);
    const cutoff = this.quarantineCutoff();
    const out: PurgePlanAccount[] = [];
    let blocked: string | null = null;

    for (const account of accounts) {
      const base = { accountId: account.id, deletedAt: null as null, remoteDeletedAt: null as null };
      const [total, alreadyPurged, quarantined, flagged, localOnly, failed, protectedCount, rows] = await Promise.all([
        this.prisma.mailMessage.count({ where: { accountId: account.id, deletedAt: null } }),
        this.prisma.mailMessage.count({ where: { accountId: account.id, deletedAt: null, remoteDeletedAt: { not: null } } }),
        this.prisma.mailMessage.count({
          where: { ...base, createdAt: { gte: cutoff }, folderPath: ON_SERVER_FOLDER },
        }),
        this.prisma.mailMessage.count({ where: { ...base, flagged: true, folderPath: ON_SERVER_FOLDER } }),
        this.prisma.mailMessage.count({ where: { accountId: account.id, deletedAt: null, folderPath: { startsWith: LOCAL_PREFIX } } }),
        this.prisma.mailMessage.count({ where: { accountId: account.id, deletedAt: null, remotePurgeTries: { gte: MAX_TRIES } } }),
        this.prisma.mailMessage.count({
          where: {
            ...base,
            folderPath: ON_SERVER_FOLDER,
            OR: this.protectedDomains().map((d) => ({ fromAddr: { endsWith: `@${d}` } })),
          },
        }),
        this.prisma.mailMessage.findMany({
          where: {
            ...base,
            folderPath: ON_SERVER_FOLDER,
            createdAt: { lt: cutoff },
            remotePurgeTries: { lt: MAX_TRIES },
            flagged: false,
          },
          orderBy: { createdAt: 'asc' },
          take: limit,
          select: {
            id: true,
            folderPath: true,
            uid: true,
            uidValidity: true,
            messageId: true,
            subject: true,
            fromAddr: true,
            flagged: true,
            sortAt: true,
          },
        }),
      ]);

      // Защищённых отправителей отсеиваем в памяти: их немного, а отдельный запрос на каждое
      // письмо был бы дороже. В счётчике отчёта их не приплюсовываем — он уже посчитан выше
      // по всему ящику, и сумма дала бы двойной учёт.
      const candidates = (rows as CandidateRow[]).filter((r) => !this.isProtected(r.fromAddr));
      const remaining = Math.max(0, total - alreadyPurged - candidates.length);

      const accountPlan: PurgePlanAccount = {
        accountId: account.id,
        email: account.email,
        total,
        candidates: candidates.length,
        remaining,
        oldest: candidates.length ? candidates[0].sortAt.toISOString() : null,
        newest: candidates.length ? candidates[candidates.length - 1].sortAt.toISOString() : null,
        excluded: {
          quarantined,
          flagged,
          protectedSender: protectedCount,
          localOnly,
          failed,
          alreadyPurged,
        },
        samples: candidates.slice(0, SAMPLES).map((r) => ({
          subject: r.subject,
          from: r.fromAddr,
          receivedAt: r.sortAt.toISOString(),
        })),
      };
      out.push(accountPlan);

      // Предохранитель: доля ящика. Проверяем то, что реально уйдёт этим прогоном.
      const share = total > 0 ? (candidates.length / total) * 100 : 0;
      if (candidates.length > 100 && share > env.MAIL_PURGE_MAX_SHARE) {
        blocked =
          `под удаление попадает ${candidates.length} из ${total} писем (${Math.round(share)}%) у ${account.email} — ` +
          `это больше предела ${env.MAIL_PURGE_MAX_SHARE}%. Прогон остановлен: сначала посмотри отчёт и проверь, что отбор верный`;
      }
    }

    return {
      dryRun: true,
      enabled: env.MAIL_PURGE_ENABLED,
      quarantineHours: env.MAIL_PURGE_QUARANTINE_HOURS,
      perRun: limit,
      accounts: out,
      blocked,
    };
  }

  private limitOf(limit?: number): number {
    const wanted = Number(limit);
    if (Number.isFinite(wanted) && wanted > 0) return Math.min(Math.floor(wanted), env.MAIL_PURGE_PER_RUN);
    return env.MAIL_PURGE_PER_RUN;
  }

  /**
   * Удалить копии с сервера по отчёту.
   *
   * Без `confirm` не делает ничего: удаление необратимо, и случайный вызов из консоли или
   * из чужого скрипта не должен стирать переписку.
   */
  async run(userId: string, opts: { confirm: boolean; limit?: number }): Promise<PurgeReport> {
    if (!opts.confirm) {
      throw badRequest('удаление с сервера требует подтверждения', 'mail_purge_unconfirmed');
    }
    const report: PurgeReport = { enabled: env.MAIL_PURGE_ENABLED, purged: 0, failed: 0, trashSwept: 0, accounts: [] };
    if (!env.MAIL_PURGE_ENABLED) {
      this.logger.log('чистка сервера выключена (MAIL_PURGE_ENABLED=false) — ничего не делаем');
      return report;
    }

    const plan = await this.plan(userId, { limit: opts.limit });
    if (plan.blocked) throw badRequest(plan.blocked, 'mail_purge_guard');

    for (const accountPlan of plan.accounts) {
      if (!accountPlan.candidates) continue;
      const account = await this.accounts.require(userId, accountPlan.accountId);
      const stat = { email: account.email, purged: 0, failed: 0, trashSwept: 0, errors: [] as string[] };
      let client: ImapFlow | null = null;
      try {
        client = await this.openClient(account);
        const purgedIds = await this.purgeAccount(client, account, plan.perRun, stat);
        if (purgedIds.length) {
          // Перенос в корзину отражается на сервере не мгновенно: без паузы уборка мусорки
          // смотрит список, где письма ещё нет, и оно остаётся у провайдера до автоочистки.
          await sleep(TRASH_SETTLE_MS);
          stat.trashSwept = await this.sweepTrash(client, purgedIds).catch((e) => {
            stat.errors.push(`мусорка: ${(e as Error).message}`);
            return 0;
          });
        }
        report.purged += stat.purged;
        report.failed += stat.failed;
        report.trashSwept += stat.trashSwept;
      } catch (e) {
        const message = (e instanceof Error ? e.message : String(e)).slice(0, 300);
        stat.errors.push(message);
        this.logger.warn(`чистка ${account.email}: ${message}`);
      } finally {
        try {
          client?.close();
        } catch {
          /* соединение могло закрыться само */
        }
      }
      report.accounts.push(stat);
    }

    this.logger.log(
      `чистка сервера: удалено ${report.purged}, не получилось ${report.failed}, добито в мусорке ${report.trashSwept}`,
    );
    return report;
  }

  /**
   * Удаление по одному аккаунту. Возвращает Message-ID удалённых писем — по ним потом
   * добиваем копии в мусорке.
   */
  private async purgeAccount(
    client: ImapFlow,
    account: MailAccountRow,
    limit: number,
    stat: { purged: number; failed: number; errors: string[] },
  ): Promise<string[]> {
    const cutoff = this.quarantineCutoff();
    const rows = (await this.prisma.mailMessage.findMany({
      where: {
        accountId: account.id,
        deletedAt: null,
        remoteDeletedAt: null,
        folderPath: ON_SERVER_FOLDER,
        createdAt: { lt: cutoff },
        remotePurgeTries: { lt: MAX_TRIES },
        flagged: false,
      },
      orderBy: { createdAt: 'asc' },
      take: limit,
      select: { id: true, folderPath: true, uid: true, uidValidity: true, messageId: true, fromAddr: true },
    })) as CandidateRow[];
    const candidates = rows.filter((r) => !this.isProtected(r.fromAddr));
    if (!candidates.length) return [];

    // Группируем по папке: за один SELECT удаляем всё, что в ней лежит
    const byFolder = new Map<string, CandidateRow[]>();
    for (const row of candidates) {
      const list = byFolder.get(row.folderPath) ?? [];
      list.push(row);
      byFolder.set(row.folderPath, list);
    }

    const purgedIds: string[] = [];
    for (const [folderPath, group] of byFolder) {
      let lock: { release: () => void } | null = null;
      try {
        lock = await client.getMailboxLock(folderPath);
        const mailbox = client.mailbox;
        if (!mailbox) throw new Error(`папка ${folderPath} не открылась`);
        // UIDVALIDITY сменилась — координаты писем устарели: удалять «по этим UID» нельзя,
        // можно снести чужие письма
        const currentValidity = BigInt(mailbox.uidValidity);
        const usable = group.filter((r) => r.uidValidity === currentValidity);
        const stale = group.length - usable.length;
        if (stale) {
          await this.prisma.mailMessage.updateMany({
            where: { id: { in: group.filter((r) => r.uidValidity !== currentValidity).map((r) => r.id) } },
            data: { remotePurgeError: 'UIDVALIDITY папки изменилась — координаты письма устарели' },
          });
          stat.errors.push(`${folderPath}: ${stale} писем пропущено (сменилась UIDVALIDITY)`);
        }
        if (!usable.length) continue;

        const deleted = await this.removeFromFolder(
          client,
          account,
          usable.map((r) => Number(r.uid)),
          folderPath,
        );
        if (!deleted) throw new Error('сервер отказал в удалении');

        const ids = usable.map((r) => r.id);
        await this.prisma.mailMessage.updateMany({
          where: { id: { in: ids } },
          data: { remoteDeletedAt: new Date(), remotePurgeError: null },
        });
        stat.purged += ids.length;
        purgedIds.push(...usable.map((r) => r.messageId).filter((m): m is string => Boolean(m)));
        this.logger.log(`${account.email}: удалено из ${folderPath} — ${ids.length}`);
      } catch (e) {
        const message = (e instanceof Error ? e.message : String(e)).slice(0, 300);
        stat.failed += group.length;
        stat.errors.push(`${folderPath}: ${message}`);
        await this.prisma.mailMessage.updateMany({
          where: { id: { in: group.map((r) => r.id) } },
          data: { remotePurgeTries: { increment: 1 }, remotePurgeError: message },
        });
      } finally {
        lock?.release();
      }
    }
    return purgedIds;
  }

  /** Папка-мусорка аккаунта: «Корзина» у Gmail, «Удалённые сообщения» у iCloud. */
  private async trashPath(client: ImapFlow): Promise<string | null> {
    const boxes = await client.list().catch(() => []);
    const byFlag = boxes.find((b) => b.specialUse === '\\Trash');
    if (byFlag) return byFlag.path;
    // Запасной поиск по именам: метка \Trash есть не у всех серверов, а имена локализованы
    const names = ['[Gmail]/Trash', 'Trash', 'Deleted Messages', 'Удалённые', 'Корзина'];
    for (const name of names) {
      const found = boxes.find((b) => b.path.toLowerCase() === name.toLowerCase());
      if (found) return found.path;
    }
    return null;
  }

  /**
   * Убрать письма из папки-источника. Способ зависит от сервера, и это не прихоть:
   *
   *   * Gmail не удаляет письма из «Всей почты» — команда проходит, флаг `\Deleted` молча
   *     игнорируется, и письмо остаётся на месте. Штатный путь у него один: перенос в корзину
   *     (проверено на живом ящике), откуда письмо добирает уборка мусорки.
   *   * Остальные серверы (iCloud и обычный IMAP) понимают пометку с вычисткой.
   *
   * Если корзина не нашлась, Gmail всё равно пробуем убрать пометкой: пусть не сработает,
   * но это лучше, чем не попробовать вовсе.
   */
  private async removeFromFolder(
    client: ImapFlow,
    account: MailAccountRow,
    uids: number[],
    folderPath: string,
  ): Promise<boolean> {
    if (!uids.length) return true;
    if (this.isGmail(account)) {
      const trash = await this.trashPath(client).catch(() => null);
      if (trash && trash !== folderPath) {
        const moved = await client.messageMove(uids, trash, { uid: true });
        return moved !== false;
      }
    }
    return await this.deleteMessages(client, uids);
  }

  /** Gmail узнаём и по виду аккаунта, и по хосту: вид мог остаться «другим IMAP-сервером». */
  private isGmail(account: MailAccountRow): boolean {
    return account.kind === 'gmail' || account.imapHost.toLowerCase().endsWith('gmail.com');
  }

  /**
   * Удалить письма из открытой папки: пометить `\Deleted` и вычистить.
   *
   * Двумя шагами, а не одним `messageDelete`: в imapflow 2 он делает только EXPUNGE, а EXPUNGE
   * уносит лишь то, что уже помечено `\Deleted`. Без пометки он не удаляет ничего, но отвечает
   * успехом — и письмо остаётся на сервере, а у нас помечается удалённым. Проверка на живом
   * ящике это и показала: Gmail ответил «успех», письмо осталось во «Всей почте».
   */
  private async deleteMessages(client: ImapFlow, uids: number[]): Promise<boolean> {
    if (!uids.length) return true;
    const marked = await client.messageFlagsAdd(uids, ['\\Deleted'], { uid: true });
    if (!marked) return false;
    return await client.messageDelete(uids, { uid: true });
  }

  /**
   * Добить удалённое в мусорке: без этого письмо месяц лежит в «Корзине» сервера, то есть
   * копия у провайдера остаётся — ровно то, от чего мы уходим.
   *
   * Ищем по Message-ID: после удаления из папки источника письмо лежит в мусорке с тем же
   * идентификатором, а UID у него там свой.
   */
  private async sweepTrash(client: ImapFlow, messageIds: string[]): Promise<number> {
    const wanted = new Set(messageIds);
    if (!wanted.size) return 0;
    const path = await this.trashPath(client);
    if (!path) {
      this.logger.warn('папка-мусорка не найдена — удалённые письма останутся в ней до автоочистки сервера');
      return 0;
    }

    const lock = await client.getMailboxLock(path);
    let deleted = 0;
    try {
      // client.mailbox — это false, когда папка не выбрана (тип так и говорит)
      const box = client.mailbox;
      const exists = box ? box.exists : 0;
      if (!exists) return 0;
      // Смотрим только хвост мусорки: то, что мы удалили только что, лежит в конце
      const from = Math.max(1, exists - env.MAIL_PURGE_TRASH_SCAN + 1);

      // Сначала собираем все совпадения, и только потом удаляем. Удалять по ходу разбора
      // нельзя: удаление сдвигает нумерацию оставшихся, и следующие порции указывали бы уже
      // не на те письма — часть просто не была бы просмотрена.
      const toDelete: number[] = [];
      for (let start = from; start <= exists; start += TRASH_BATCH) {
        const end = Math.min(exists, start + TRASH_BATCH - 1);
        for await (const msg of client.fetch(`${start}:${end}`, { uid: true, headers: ['message-id'] }, {})) {
          const id = msg.headers ? headerMessageId(msg.headers) : null;
          if (id && wanted.has(id)) toDelete.push(msg.uid);
        }
      }
      if (toDelete.length) {
        const ok = await this.deleteMessages(client, toDelete);
        if (ok) deleted += toDelete.length;
      }
    } finally {
      lock.release();
    }
    this.logger.log(`мусорка ${path}: добито писем — ${deleted}`);
    return deleted;
  }
}
