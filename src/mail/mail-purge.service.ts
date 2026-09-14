import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { ImapFlow } from 'imapflow';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { sha256Hex } from '../common/utils';
import { headerMessageId } from './mail-parse';
import { mailCryptoReady } from './mail-crypto';
import { LOCAL_PREFIX } from './mail-ingest.service';
import { MailAccountsService, type MailAccountRow } from './mail-accounts.service';
import { MailIngestService } from './mail-ingest.service';

/**
 * Удаление серверной копии письма сразу после того, как оно сохранено у нас.
 *
 * Это единственная необратимая операция во всём разделе, поэтому она устроена так:
 *   1. Удаляем только то, что только что сохранено и проверено поимённо (verifyStored):
 *      байты письма лежат в хранилище, размеры сходятся, вложения разобраны.
 *   2. Перед удалением сверяем, что по нашим координатам на сервере лежит именно это письмо
 *      (Message-ID совпадает) — иначе по устаревшим координатам можно снести чужое.
 *   3. Не получилось — копия остаётся у провайдера, а причина пишется в remotePurgeError;
 *      потерять письмо из-за уборки невозможно.
 *
 * Удаление в два шага — так устроены Gmail и iCloud: пометка \Deleted + EXPUNGE уносит письмо
 * в мусорку сервера, поэтому после удаления из папки источника добиваем копию в мусорке
 * (по Message-ID). У Gmail штатный путь — перенос в корзину: пометку во «Всей почте» он
 * молча игнорирует.
 */

/** Сколько попыток удалить копию делаем, прежде чем оставить письмо в покое навсегда. */
const MAX_TRIES = 3;

/** Письма, хранящиеся только у нас: их никогда не было на сервере, удалять нечего. */
const ON_SERVER_FOLDER = { not: { startsWith: LOCAL_PREFIX } } as const;

/** До какого размера письмо проверяем целиком (суммой байтов), а не только размером. */
const VERIFY_BYTES = 512 * 1024;

/** Пауза перед разбором мусорки: серверу нужно мгновение на отражение переноса. */
const TRASH_SETTLE_MS = 5000;

/** Порции при разборе мусорки: по столько писем за один FETCH. */
const TRASH_BATCH = 200;

/** Сколько последних писем мусорки просматриваем: то, что удалили только что, лежит в конце. */
const TRASH_SCAN = 2000;

/**
 * Догоняющий проход: раз в сколько убираем то, что не убралось сразу после сохранения
 * (писем, пришедших в паузе между деплоями, оборванных проходов, повторно разобранных).
 */
const SWEEP_INTERVAL_MS = 5 * 60 * 1000;

/** Сколько писем убираем за один догоняющий проход: остаток доберёт следующий. */
const SWEEP_PER_RUN = 500;

/** Пауза в асинхронном коде: короткая, поэтому обычный таймер. */
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Поля кандидата: нужны и отбору, и проверке перед удалением. */
const CANDIDATE_FIELDS = {
  id: true,
  userId: true,
  folderPath: true,
  uid: true,
  uidValidity: true,
  messageId: true,
  hasAttachments: true,
  rawAssetId: true,
  size: true,
} as const;

interface CandidateRow {
  id: string;
  userId: string;
  folderPath: string;
  uid: bigint;
  uidValidity: bigint;
  messageId: string | null;
  hasAttachments: boolean;
  rawAssetId: string;
  size: number;
}

/** Итог по аккаунту: сколько убрали, сколько не вышло, что осталось в мусорке. */
interface PurgeStat {
  purged: number;
  failed: number;
  errors: string[];
  trashSwept: number;
}

@Injectable()
export class MailPurgeService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(MailPurgeService.name);
  private timer: NodeJS.Timeout | null = null;
  /** Проходы не пересекаются: один догоняющий проход на ящик за раз. */
  private busy = false;

  constructor(
    private readonly prisma: PrismaService,
    private readonly accounts: MailAccountsService,
    private readonly s3: S3Service,
    private readonly ingestService: MailIngestService,
  ) {}

  onModuleInit(): void {
    if (!mailCryptoReady()) {
      this.logger.error('MAIL_SECRET_KEY не задан — чистка сервера не запущена');
      return;
    }
    this.timer = setInterval(() => void this.scheduledPass(), SWEEP_INTERVAL_MS);
    this.timer.unref();
    this.logger.log(`чистка сервера: проход каждые ${SWEEP_INTERVAL_MS / 1000} с, по ${SWEEP_PER_RUN} писем за проход`);
  }

  onModuleDestroy(): void {
    if (this.timer) clearInterval(this.timer);
  }

  /**
   * Догоняющий проход по всем ящикам: подбирает то, что не ушло сразу.
   *
   * Порция за проход ограничена (SWEEP_PER_RUN), поэтому на большом отставании очередь
   * разбирается постепенно, а не одним долгим прогоном. Письмо уходит только после той же
   * поимённой проверки, что и у немедленной чистки (verifyStored + совпадение Message-ID).
   */
  private async scheduledPass(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const accounts = await this.prisma.mailAccount.findMany({
        where: { enabled: true, kind: { not: 'smtp' }, imapHost: { not: '' } },
      });
      for (const account of accounts) {
        try {
          const stat: PurgeStat = { purged: 0, failed: 0, errors: [], trashSwept: 0 };
          const client = await this.openClient(account);
          try {
            const purgedIds = await this.purgeAccount(client, account, stat, () =>
              this.scheduledCandidates(account, SWEEP_PER_RUN),
            );
            await this.sweepPurged(client, purgedIds, stat);
          } finally {
            try {
              client.close();
            } catch {
              /* соединение могло закрыться само */
            }
          }
          if (stat.purged || stat.failed || stat.errors.length) {
            this.logger.log(
              `чистка ${account.email}: удалено ${stat.purged}, не получилось ${stat.failed}, добито в мусорке ${stat.trashSwept}`,
            );
          }
          for (const message of stat.errors) this.logger.warn(`${account.email}: ${message}`);
        } catch (e) {
          this.logger.warn(`чистка ${account.email}: ${(e as Error).message}`);
        }
      }
    } finally {
      this.busy = false;
    }
  }

  /** Кандидаты догоняющего прохода: самые старые из тех, что ещё лежат на сервере. */
  private async scheduledCandidates(account: MailAccountRow, limit: number): Promise<CandidateRow[]> {
    const rows = (await this.prisma.mailMessage.findMany({
      where: {
        accountId: account.id,
        remoteDeletedAt: null,
        folderPath: ON_SERVER_FOLDER,
        remotePurgeTries: { lt: MAX_TRIES },
      },
      orderBy: { createdAt: 'asc' },
      take: limit,
      select: CANDIDATE_FIELDS,
    })) as CandidateRow[];
    return rows;
  }

  /** Открыть соединение с аккаунтом. */
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

  /**
   * Убрать копии только что сохранённых писем — сразу, не ожидая никакого расписания.
   *
   * Свежее письмо уже лежит у нас целиком (это проверяется перед удалением), значит копия
   * у провайдера больше не нужна.
   */
  async purgeMessages(account: MailAccountRow, ids: string[]): Promise<{ purged: number; skipped: number }> {
    const out = { purged: 0, skipped: 0 };
    if (!ids.length) return out;
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

  /** Кандидаты по списку: только письма с серверной копией, ещё не убранной. */
  private async candidatesByIds(account: MailAccountRow, ids: string[]): Promise<CandidateRow[]> {
    const rows = (await this.prisma.mailMessage.findMany({
      where: {
        id: { in: ids },
        accountId: account.id,
        remoteDeletedAt: null,
        folderPath: ON_SERVER_FOLDER,
        remotePurgeTries: { lt: MAX_TRIES },
      },
      select: CANDIDATE_FIELDS,
    })) as CandidateRow[];
    return rows;
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
    const swept = await this.sweepTrash(client, purgedIds).catch((e) => {
      stat.errors.push(`мусорка: ${(e as Error).message}`);
      return 0;
    });
    stat.trashSwept += swept;
    // Не всех нашли — значит сервер ещё не показал часть переноса в корзине. Одна повторная
    // попытка: письмо, помеченное у нас убранным, больше в очередь не попадёт, и его копия
    // иначе осталась бы в корзине провайдера до его собственной автоочистки (месяц).
    if (swept < purgedIds.length) {
      await sleep(TRASH_SETTLE_MS * 3);
      stat.trashSwept += await this.sweepTrash(client, purgedIds).catch(() => 0);
    }
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
        const checked: CandidateRow[] = [];
        const unchecked: Array<{ id: string; reason: string }> = [];
        for (const row of usable) {
          const reason = await this.verifyStored(row);
          if (reason) unchecked.push({ id: row.id, reason });
          else checked.push(row);
        }
        if (unchecked.length) {
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
   * успехом — и письмо остаётся на сервере, а у нас помечается удалённым.
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
      const from = Math.max(1, exists - TRASH_SCAN + 1);

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
