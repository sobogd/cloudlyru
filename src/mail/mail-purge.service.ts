import { Injectable, Logger, type OnModuleDestroy, type OnModuleInit } from '@nestjs/common';
import { ImapFlow } from 'imapflow';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { env } from '../config/env';
import { badRequest } from '../common/errors';
import { S3Service } from '../s3/s3.service';
import { sha256Hex } from '../common/utils';
import { headerMessageId } from './mail-parse';
import { LOCAL_PREFIX } from './mail-ingest.service';
import { MailAccountsService, type MailAccountRow } from './mail-accounts.service';
import { MailIngestService } from './mail-ingest.service';

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

/** До какого размера письмо проверяем целиком (суммой байтов), а не только размером. */
const VERIFY_BYTES = 512 * 1024;

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
  /**
   * Сколько писем уберём вот этой порцией. Это НЕ «сколько можно убрать»: за проход берём
   * не больше MAIL_PURGE_PER_RUN, поэтому цифра здесь маленькая даже когда убирать надо
   * тысячи писем. Всего к удалению — `eligible`.
   */
  candidates: number;
  /** Сколько писем вообще можно убрать (без ограничения порции). */
  eligible: number;
  /**
   * Сколько писем останется у провайдера навсегда: помеченные звёздочкой, письма от
   * провайдеров доступа, наши собственные отправки, те, что не удалось убрать.
   */
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

/** Итог по аккаунту за прогон: сколько убрали, сколько не вышло, что осталось в мусорке. */
interface PurgeStat {
  purged: number;
  failed: number;
  errors: string[];
  trashSwept: number;
}

/** Поля, нужные и отбору, и проверке: их читаем всегда одинаково. */
const CANDIDATE_FIELDS = {
  id: true,
  userId: true,
  folderPath: true,
  uid: true,
  uidValidity: true,
  messageId: true,
  fromAddr: true,
  hasAttachments: true,
  rawAssetId: true,
  size: true,
} as const;

/** Что нужно отчёту: пара полей для примеров и подсчёта. Удалять по этим строкам нельзя. */
interface PlanRow {
  fromAddr: string | null;
  subject: string | null;
  sortAt: Date;
}

interface CandidateRow {
  id: string;
  userId: string;
  folderPath: string;
  uid: bigint;
  uidValidity: bigint;
  messageId: string | null;
  subject: string | null;
  fromAddr: string | null;
  flagged: boolean;
  sortAt: Date;
  /** Для проверки «письмо правда у нас»: вложения, сырьё и его размер. */
  hasAttachments: boolean;
  rawAssetId: string;
  size: number;
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
    private readonly s3: S3Service,
    private readonly ingestService: MailIngestService,
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

  /**
   * То же, что isProtected, но условием для базы: иначе порция за проход тратилась бы на
   * письма, которые всё равно не удаляем (у Gmail таких сотни — коды входа, оповещения).
   */
  private notProtectedFilter(): Prisma.MailMessageWhereInput {
    const domains = this.protectedDomains();
    if (!domains.length) return {};
    // Две формы, как и в isProtected: и «кто-то@apple.com», и «developer@email.apple.com» —
    // у Apple и Google оповещения идут именно с поддоменов.
    const forms = domains.flatMap((d) => [{ fromAddr: { endsWith: `@${d}` } }, { fromAddr: { endsWith: `.${d}` } }]);
    return { NOT: { OR: forms } };
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
      where: { userId, kind: { not: 'smtp' }, imapHost: { not: '' } },
      orderBy: { createdAt: 'asc' },
    });
    const limit = this.limitOf(opts.limit);
    const cutoff = this.quarantineCutoff();
    const out: PurgePlanAccount[] = [];
    let blocked: string | null = null;

    for (const account of accounts) {
      const base = { accountId: account.id, remoteDeletedAt: null as null };
      const [total, alreadyPurged, eligible, quarantined, localOnly, failed, protectedCount, rows] = await Promise.all([
        this.prisma.mailMessage.count({ where: { accountId: account.id } }),
        this.prisma.mailMessage.count({ where: { accountId: account.id, remoteDeletedAt: { not: null } } }),
        // Сколько всего можно убрать: тот же отбор, что и для порции, но без ограничения.
        this.prisma.mailMessage.count({
          where: {
            ...base,
            folderPath: ON_SERVER_FOLDER,
            createdAt: { lt: cutoff },
            remotePurgeTries: { lt: MAX_TRIES },
            ...this.notProtectedFilter(),
          },
        }),
        this.prisma.mailMessage.count({
          where: { ...base, createdAt: { gte: cutoff }, folderPath: ON_SERVER_FOLDER },
        }),
        this.prisma.mailMessage.count({ where: { accountId: account.id, folderPath: { startsWith: LOCAL_PREFIX } } }),
        this.prisma.mailMessage.count({ where: { accountId: account.id, remotePurgeTries: { gte: MAX_TRIES } } }),
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
            ...this.notProtectedFilter(),
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
      const candidates = (rows as PlanRow[]).filter((r) => !this.isProtected(r.fromAddr));
      // Останется у провайдера навсегда — то, что не подлежит удалению вовсе, а не «остаток
      // очереди»: очередь как раз видна в eligible и уменьшается с каждым проходом.
      const remaining = Math.max(0, total - alreadyPurged - eligible);

      const accountPlan: PurgePlanAccount = {
        accountId: account.id,
        email: account.email,
        total,
        candidates: candidates.length,
        eligible,
        remaining,
        oldest: candidates.length ? candidates[0].sortAt.toISOString() : null,
        newest: candidates.length ? candidates[candidates.length - 1].sortAt.toISOString() : null,
        excluded: {
          quarantined,
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
      const stat: PurgeStat & { email: string } = { email: account.email, purged: 0, failed: 0, trashSwept: 0, errors: [] };
      let client: ImapFlow | null = null;
      try {
        client = await this.openClient(account);
        const purgedIds = await this.purgeAccount(client, account, stat, () =>
          this.scheduledCandidates(account, plan.perRun),
        );
        await this.sweepPurged(client, purgedIds, stat);
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
  /**
   * Кандидаты для прохода по расписанию: самая давняя порция из тех, что ещё на сервере.
   *
   * Берём все письма, которые у нас есть, — включая лежащие в нашей корзине и помеченные
   * звёздочкой. Правило одно: есть у нас — у провайдера быть не должно. Единственное, что
   * оставляет копию на месте, — непройденная проверка (нет байтов или не сошлись координаты):
   * это не отбор, а защита от потери.
   */
  private async scheduledCandidates(account: MailAccountRow, limit: number): Promise<CandidateRow[]> {
    const cutoff = this.quarantineCutoff();
    const rows = (await this.prisma.mailMessage.findMany({
      where: {
        accountId: account.id,
        remoteDeletedAt: null,
        folderPath: ON_SERVER_FOLDER,
        ...(cutoff ? { createdAt: { lt: cutoff } } : {}),
        remotePurgeTries: { lt: MAX_TRIES },
      },
      orderBy: { createdAt: 'asc' },
      take: limit,
      select: CANDIDATE_FIELDS,
    })) as CandidateRow[];
    return rows.filter((r) => !this.isProtected(r.fromAddr));
  }

  /** Кандидаты по списку — для свежих писем, которые мы только что сохранили. */
  private async candidatesByIds(account: MailAccountRow, ids: string[]): Promise<CandidateRow[]> {
    const cutoff = this.quarantineCutoff();
    const rows = (await this.prisma.mailMessage.findMany({
      where: {
        id: { in: ids },
        accountId: account.id,
        remoteDeletedAt: null,
        folderPath: ON_SERVER_FOLDER,
        ...(cutoff ? { createdAt: { lt: cutoff } } : {}),
        remotePurgeTries: { lt: MAX_TRIES },
      },
      select: CANDIDATE_FIELDS,
    })) as CandidateRow[];
    return rows.filter((r) => !this.isProtected(r.fromAddr));
  }

  /**
   * Убрать копии конкретных писем — сразу после того, как они сохранены.
   *
   * Расписание добирает всё, что осталось и что не получилось; но свежему письму ждать
   * расписания незачем: оно уже лежит у нас целиком (это и проверяется перед удалением),
   * значит копия у провайдера больше не нужна.
   */
  async purgeMessages(account: MailAccountRow, ids: string[]): Promise<{ purged: number; skipped: number }> {
    const out = { purged: 0, skipped: 0 };
    if (!env.MAIL_PURGE_ENABLED || !ids.length) return out;
    // Аккаунт без IMAP (почту приносит наш сервер): серверных копий у таких писем нет.
    if (!this.accounts.presetOf(account.kind).folders.length) return out;

    const candidates = await this.candidatesByIds(account, ids);
    out.skipped = ids.length - candidates.length;
    if (!candidates.length) return out;

    const stat: PurgeStat = { purged: 0, failed: 0, errors: [], trashSwept: 0 };
    const client = await this.openClient(account);
    try {
      const purgedIds = await this.purgeAccount(client, account, stat, async () => candidates);
      await this.sweepPurged(client, purgedIds, stat);
    } finally {
      try {
        client.close();
      } catch {
        /* соединение могло закрыться само */
      }
    }
    out.purged = stat.purged;
    if (stat.purged || stat.trashSwept || stat.errors.length) {
      this.logger.log(
        `свежие письма ${account.email}: убрано копий ${stat.purged}, добито в мусорке ${stat.trashSwept}`,
      );
    }
    for (const message of stat.errors) this.logger.warn(`${account.email}: ${message}`);
    return out;
  }

  /**
   * Добить в мусорке то, что только что убрали из папки.
   *
   * Перенос в корзину отражается на сервере не мгновенно: без паузы уборка смотрит список,
   * где письма ещё нет, и копия остаётся у провайдера до его собственной автоочистки.
   */
  private async sweepPurged(client: ImapFlow, purgedIds: string[], stat: PurgeStat): Promise<void> {
    if (!purgedIds.length) return;
    await sleep(TRASH_SETTLE_MS);
    stat.trashSwept += await this.sweepTrash(client, purgedIds).catch((e) => {
      stat.errors.push(`мусорка: ${(e as Error).message}`);
      return 0;
    });
  }

  private async purgeAccount(
    client: ImapFlow,
    account: MailAccountRow,
    stat: PurgeStat,
    select: () => Promise<CandidateRow[]>,
  ): Promise<string[]> {
    const candidates = await select();
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

        // Проверка «письмо правда у нас» — обязательная и идёт перед каждым удалением.
        // Карантин тут не нужен: он заменял собой именно эту проверку, а она точнее — смотрит
        // на конкретное письмо, а не на то, сколько времени прошло.
        const checked: CandidateRow[] = [];
        const unchecked: Array<{ id: string; reason: string }> = [];
        for (const row of usable) {
          const reason = await this.verifyStored(row);
          if (reason) unchecked.push({ id: row.id, reason });
          else checked.push(row);
        }
        if (unchecked.length) {
          // Считаем и это попыткой: письмо, которое проверку не проходит, не должно вечно
          // висеть в очереди «можно убрать» — после трёх заходов оно честно попадает
          // в «не удалось» с причиной.
          await this.prisma.mailMessage.updateMany({
            where: { id: { in: unchecked.map((u) => u.id) } },
            data: {
              remotePurgeTries: { increment: 1 },
              remotePurgeError: `копия у нас не подтверждена: ${unchecked[0].reason}`,
            },
          });
          stat.errors.push(`${folderPath}: ${unchecked.length} писем не проверены — копию у провайдера не трогаем`);
          this.logger.warn(
            `${account.email}: не удаляю ${unchecked.length} писем из ${folderPath} — ${unchecked
              .slice(0, 3)
              .map((u) => u.reason)
              .join('; ')}`,
          );
        }
        if (!checked.length) continue;

        // Вторая половина проверки: по нашим координатам на сервере должно лежать ИМЕННО это
        // письмо. Если Message-ID не совпал, координаты устарели — по ним можно снести чужое
        // письмо, и такое письмо мы не трогаем вовсе.
        const byUid = new Map<number, CandidateRow>();
        for (const row of checked) byUid.set(Number(row.uid), row);
        const found = new Set<number>();
        const matched: CandidateRow[] = [];
        const wrong: Array<{ id: string; reason: string }> = [];
        for await (const msg of client.fetch(
          checked.map((r) => Number(r.uid)),
          { uid: true, headers: ['message-id'] },
          { uid: true },
        )) {
          const row = byUid.get(Number(msg.uid));
          if (!row) continue;
          found.add(Number(msg.uid));
          const remoteId = msg.headers ? headerMessageId(msg.headers) : null;
          if (remoteId && row.messageId && remoteId === row.messageId) matched.push(row);
          else wrong.push({ id: row.id, reason: `по координатам на сервере другое письмо (${remoteId ?? 'без Message-ID'})` });
        }
        // Сервер не вернул письмо по нашим координатам — значит копии там уже нет: удалять
        // нечего, но и «удалённым» оно становится честно.
        const gone = checked.filter((r) => !found.has(Number(r.uid)));
        if (gone.length) {
          await this.prisma.mailMessage.updateMany({
            where: { id: { in: gone.map((r) => r.id) } },
            data: { remoteDeletedAt: new Date(), remotePurgeError: null },
          });
          stat.purged += gone.length;
          this.logger.log(`${account.email}: копий уже нет в ${folderPath} — ${gone.length}`);
        }
        if (wrong.length) {
          await this.prisma.mailMessage.updateMany({
            where: { id: { in: wrong.map((w) => w.id) } },
            data: { remotePurgeTries: { increment: 1 }, remotePurgeError: wrong[0].reason },
          });
          stat.errors.push(`${folderPath}: ${wrong.length} писем пропущено — координаты не совпали с сервером`);
          this.logger.warn(`${account.email}: ${wrong.length} писем пропущено в ${folderPath} — ${wrong[0].reason}`);
        }
        if (!matched.length) continue;

        const deleted = await this.removeFromFolder(
          client,
          account,
          matched.map((r) => Number(r.uid)),
          folderPath,
        );
        if (!deleted) throw new Error('сервер отказал в удалении');

        const ids = matched.map((r) => r.id);
        await this.prisma.mailMessage.updateMany({
          where: { id: { in: ids } },
          data: { remoteDeletedAt: new Date(), remotePurgeError: null },
        });
        stat.purged += ids.length;
        purgedIds.push(...matched.map((r) => r.messageId).filter((m): m is string => Boolean(m)));
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
   * Письмо действительно лежит у нас целиком? null — да, иначе причина отказа.
   *
   * Проверяем не «строчку в базе», а сами байты письма в хранилище: строка без содержимого —
   * это ровно тот случай, ради которого удаление копии у провайдера необратимо. Сверяем
   * размеры (записи, учёта и самого объекта) и, для небольших писем, контрольную сумму —
   * объекты у нас адресуются по sha256, так что сумма и есть доказательство целостности.
   *
   * Вложения отдельно не проверяем: они лежат внутри сырого письма, и потеряться отдельно от
   * него не могут. Но если в письме вложения есть, а частей у нас нет — значит разбор не
   * доехал: такое письмо не удаляем, пока оно не разобрано.
   */
  private async verifyStored(row: CandidateRow): Promise<string | null> {
    const asset = await this.prisma.asset.findUnique({
      where: { id: row.rawAssetId },
      select: { sha256: true, size: true },
    });
    if (!asset?.sha256) return 'сырьё письма не учтено';

    const key = S3Service.assetKey(asset.sha256);
    let stored = 0;
    try {
      stored = await this.s3.objectSize(key);
    } catch (e) {
      return `сырья нет в хранилище (${e instanceof Error ? e.message.slice(0, 60) : 'ошибка'})`;
    }
    if (!stored) return 'сырьё в хранилище пустое';
    // Размер в учёте — BigInt (в хранилище бывают файлы больше двух гигабайт), размер письма —
    // обычное число: сравниваем приведённым.
    const known = Number(asset.size);
    if (stored !== known) return `размер сырья не совпал: в учёте ${known}, в хранилище ${stored}`;
    if (known !== row.size) return `размер письма не совпал: в письме ${row.size}, в учёте ${known}`;

    if (row.hasAttachments) {
      let parts = await this.prisma.mailAttachment.count({ where: { messageId: row.id } });
      if (!parts) {
        // Вложения лежат внутри сырого письма, которое у нас есть, поэтому это не потеря,
        // а недоразобранное письмо: пробуем разобрать сейчас, а не отказываемся навсегда.
        const added = await this.ingestService.repairMessage(row.userId, row.id).catch(() => 0);
        parts = await this.prisma.mailAttachment.count({ where: { messageId: row.id } });
        if (!parts) return `вложения письма не разобрались (добрано ${added})`;
      }
    }

    // Небольшие письма проверяем целиком: 512 КБ — это почти вся переписка, а сумма байтов
    // доказывает, что объект именно тот, за который себя выдаёт.
    if (stored <= VERIFY_BYTES) {
      const bytes = await this.s3.getObjectBytes(key).catch(() => null);
      if (!bytes) return 'сырьё не читается из хранилища';
      if (sha256Hex(bytes) !== asset.sha256) return 'содержимое сырья не совпало с учётом';
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
