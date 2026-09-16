import { Injectable, Logger } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService } from '../auth/auth.service';
import { FilesService } from '../files/files.service';
import { S3Service } from '../s3/s3.service';
import { ApiError } from '../common/errors';
import { normalizeMime } from '../common/mime';
import { sha256Hex } from '../common/utils';
import { ZONE_MAIL } from '../common/zones';
import { attachmentName, extensionForMime } from './mail-names';
import { headerMessageId, parseMessage, threadKeyOf, type ParsedAttachment } from './mail-parse';
import type { MailAccountRow, MailBox } from './mail-accounts.service';

/**
 * Сохранение письма у нас: сырой .eml в S3 как Asset, вложения — записями дерева в скрытой
 * папке «Почта», письмо — строкой MailMessage.
 *
 * Порядок здесь важнее скорости: сначала байты письма гарантированно легли в хранилище,
 * только потом появляется строка в БД. Обратный порядок дал бы «письмо есть, содержимого нет» —
 * а именно такие строки потом удаляются с сервера в фазе очистки, то есть теряются навсегда.
 *
 * Ключи, по которым письмо считается уже сохранённым, делятся на две группы, и разница
 * принципиальна:
 *   * сильные — координаты на сервере (`folderPath` + `uidValidity` + `uid`) и X-GM-MSGID:
 *     их назначает сервер, подделать их отправитель не может;
 *   * слабый — заголовок Message-ID: его пишет отправитель, и повторить чужой он может.
 * Совпадение только по слабому ключу — это повод заподозрить дубль, а не признать его: письмо
 * сохраняется отдельно (иначе третья сторона тихо выкидывала бы из архива и чужие письма,
 * повторяя их Message-ID). Дублем считаем те случаи, когда видно, что это буквально то же
 * письмо: совпал размер сырья (одна и та же копия в двух папках сервера) или найденная строка —
 * наша собственная отправленная копия (`local:sent`), к которой провайдер мог дописать свои
 * заголовки.
 */

/** Что делать с письмом по итогам прохода. */
export type IngestResult = 'stored' | 'skipped' | 'trashed' | 'attachments-repaired';

export interface IngestInput {
  userId: string;
  account: MailAccountRow;
  box: MailBox;
  /**
   * Папки сверх основной, если письмо лежит сразу в двух. Заполняется, когда это известно
   * уже при сохранении: у Gmail письмо себе лежит в одной папке All Mail с двумя метками
   * (\Inbox и \Sent). Во всех остальных случаях вторая папка находится дедупом по Message-ID.
   */
  alsoBoxes?: MailBox[];
  /** Папка источника: письмо можно встретить в разных папках (спам → входящие). */
  folderPath: string;
  uid: number;
  uidValidity: bigint;
  /** Полный источник письма (RFC822). */
  source: Buffer;
  seen: boolean;
  flagged: boolean;
  /** X-GM-MSGID у Gmail (imapflow отдаёт его как emailId) — стабильный ключ дедупа. */
  emailId?: string | null;
  /** X-GM-THRID у Gmail. */
  threadId?: string | null;
  /** INTERNALDATE: время прихода на сервер, ему и верим как дате письма. */
  receivedAt: Date;
}

/** Имена наших двух папок внутри системной «Почты». `trash` сюда не ходит (это состояние
 *  письма, а не папка источника), ключ оставлен только чтобы тип Record<MailBox, string> сходился. */
export const MAIL_BOX_FOLDER: Record<MailBox, string> = { inbox: 'Входящие', sent: 'Исходящие', trash: 'Корзина' };

/**
 * Что нужно, чтобы разложить части письма по дереву: только координаты.
 *
 * Отдельный тип, а не `IngestInput` с пустым буфером: добор вложений идёт по уже сохранённому
 * сырью из хранилища, и подсовывать в общий путь фиктивное `source` нельзя — первое же
 * обращение к нему (сейчас или после правки) молча сохранило бы пустое письмо.
 */
interface AttachmentTarget {
  userId: string;
  box: MailBox;
  accountId: string;
  folderPath: string;
  uid: bigint;
  uidValidity: bigint;
  emailId: string | null;
}

/** Поля уже сохранённого письма, нужные и дедупу, и добору вложений. */
const EXISTING_FIELDS = {
  id: true,
  deletedAt: true,
  box: true,
  alsoBoxes: true,
  folderPath: true,
  uid: true,
  uidValidity: true,
  seen: true,
  rawAssetId: true,
  hasAttachments: true,
  sortAt: true,
  size: true,
  _count: { select: { attachments: true } },
} as const;

/** Строка письма, найденная дедупом (структурно совпадает с выборкой EXISTING_FIELDS). */
interface ExistingLetter {
  id: string;
  deletedAt: Date | null;
  box: string;
  alsoBoxes: string[];
  folderPath: string;
  uid: bigint;
  uidValidity: bigint;
  seen: boolean;
  rawAssetId: string;
  hasAttachments: boolean;
  sortAt: Date;
  size: number;
  _count: { attachments: number };
}

/**
 * Псевдо-папка для писем, пришедших не по IMAP: наша отправка и приём своим сервером.
 * Курсоров у неё нет — это просто координата, чтобы строка письма была полной.
 *
 * Приставка общая для всех таких пометок (`local:sent` у отправки), по ней и отличаем
 * «письмо пришло не из IMAP» от настоящей серверной папки.
 */
export const LOCAL_PREFIX = 'local:';
export const LOCAL_FOLDER = `${LOCAL_PREFIX}local`;

/**
 * uid для писем, у которых нет серверного UID: стабильный и уникальный, выведенный из
 * Message-ID (или из содержимого, если заголовка нет). 48 бит — с запасом от коллизий
 * и в пределах безопасного целого в JS: интерфейс хранения принимает uid обычным числом.
 */
export function uidOfMessageId(messageId: string): number {
  return Number(BigInt('0x' + sha256Hex(messageId).slice(0, 12)));
}

/** Длинная строка MIME в БД не нужна: тип части — это ярлык для интерфейса. */
const MAX_MIME = 120;

/**
 * Сколько живёт кэш id папки «Почта/Входящие».
 *
 * Кэш нужен, чтобы не искать папку на каждое письмо, но вечным он быть не может: папку можно
 * удалить и пересоздать (например, очисткой зоны MAIL), и мёртвый id ломал бы сохранение
 * вложений до перезапуска процесса.
 */
const BOX_FOLDER_TTL_MS = 5 * 60 * 1000;

@Injectable()
export class MailIngestService {
  private readonly logger = new Logger(MailIngestService.name);
  /**
   * Кэш папок-корзин: иначе на каждое письмо два лишних запроса. Живёт ограниченное время
   * (BOX_FOLDER_TTL_MS): папку могут удалить и пересоздать, а мёртвый id в кэше ломал бы
   * сохранение вложений до перезапуска процесса.
   */
  private readonly boxFolders = new Map<string, { id: string; at: number }>();

  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
    private readonly files: FilesService,
    private readonly s3: S3Service,
  ) {}

  /** Папка «Почта/Входящие» или «Почта/Исходящие» (создаётся лениво, зона MAIL). */
  private async boxFolderId(userId: string, box: MailBox): Promise<string> {
    const cacheKey = `${userId}:${box}`;
    const cached = this.boxFolders.get(cacheKey);
    if (cached && Date.now() - cached.at < BOX_FOLDER_TTL_MS) return cached.id;

    const rootId = await this.auth.mailFolderId(userId);
    const name = MAIL_BOX_FOLDER[box];
    let folder = await this.prisma.folder.findFirst({ where: { parentId: rootId, name } });
    if (!folder) {
      try {
        folder = await this.prisma.folder.create({ data: { parentId: rootId, name, zone: ZONE_MAIL } });
      } catch {
        // гонка с параллельным проходом: папку создал он
        folder = await this.prisma.folder.findFirst({ where: { parentId: rootId, name } });
        if (!folder) throw new Error(`не удалось создать папку «${name}» в «Почте»`);
      }
    }
    this.boxFolders.set(cacheKey, { id: folder.id, at: Date.now() });
    return folder.id;
  }

  /**
   * Письмо, которое уже лежит у нас, по СИЛЬНЫМ ключам: координаты на сервере и X-GM-MSGID.
   *
   * Message-ID здесь намеренно не участвует: он от отправителя, и совпадение по нему ещё не
   * значит «это то же письмо» (см. шапку файла).
   */
  private async findExisting(input: IngestInput, uid: bigint): Promise<ExistingLetter | null> {
    return this.prisma.mailMessage.findFirst({
      where: {
        accountId: input.account.id,
        OR: [
          { folderPath: input.folderPath, uidValidity: input.uidValidity, uid },
          ...(input.emailId ? [{ gmailMsgId: input.emailId }] : []),
        ],
      },
      select: EXISTING_FIELDS,
    });
  }

  /**
   * Похоже ли, что найденное по Message-ID письмо — то же самое, а не подделка заголовка.
   *
   * Два случая, когда это точно то же письмо:
   *   * наша собственная отправленная копия (`local:sent`): провайдер мог дописать к письму
   *     свои заголовки, поэтому размеры могут отличаться, а совпадения Message-ID достаточно;
   *   * сырьё совпало байт в байт — на сервере это буквально одна и та же копия в двух папках.
   * Во всех остальных случаях письмо сохраняется отдельно: у разных писем одинаковый размер —
   * совпадение, а вот у одной копии в двух папках он обязан совпасть. Цена ошибки в другую
   * сторону выше: задвоенная строка видна в интерфейсе, а выброшенное письмо — нет.
   */
  private looksLikeSameLetter(row: ExistingLetter, input: IngestInput): boolean {
    if (row.folderPath.startsWith(LOCAL_PREFIX) && row.box === 'sent') return true;
    return row.size === input.source.length;
  }

  /**
   * Сколько частей в письме по его же разбору. Нужно, чтобы поймать оборванный прошлый проход:
   * строки частей могли создаться не все, и «parts > 0» такую неполноту не видит.
   * Разбор не должен ронять сохранение: не получилось — считаем, что сведений нет.
   */
  private async expectedAttachments(source: Buffer): Promise<number> {
    if (!source.length) return 0;
    try {
      return (await parseMessage(source)).attachments.length;
    } catch (e) {
      this.logger.warn(`разбор письма для сверки вложений не удался — ${errorText(e)}`);
      return 0;
    }
  }

  /**
   * Ключ письма для детерминированных имён вложений, когда чистое имя занято.
   *
   * Аккаунт в ключе обязателен. Папка «Почта/Входящие» — одна на пользователя для всех
   * его ящиков, а X-GM-MSGID уникален только внутри ящика: одно и то же письмо, отправленное
   * и на личный Gmail, и на рабочий, даёт одинаковые номера частей и одинаковые имена.
   * Без аккаунта в ключе второе письмо упиралось в «file name already exists» и роняло
   * весь проход синхронизации.
   */
  private identityOf(target: AttachmentTarget): string {
    const own = target.emailId ?? `${target.folderPath}:${target.uidValidity}:${target.uid}`;
    return `${target.accountId}:${own}`;
  }

  /**
   * Координаты письма, нужные для раскладки частей (само письмо для этого не нужно).
   * `uid` передаём явно: в редком случае коллизии он отличается от `input.uid`.
   */
  private targetOf(input: IngestInput, uid: bigint): AttachmentTarget {
    return {
      userId: input.userId,
      box: input.box,
      accountId: input.account.id,
      folderPath: input.folderPath,
      uid,
      uidValidity: input.uidValidity,
      emailId: input.emailId ?? null,
    };
  }

  /**
   * Сохранить письмо. Возвращает:
   *   stored             — письма у нас ещё не было;
   *   skipped            — уже есть (обычный случай повторного прохода);
   *   trashed            — есть, но лежит в корзине: удалённое не воскрешаем;
   *   attachments-repaired — строка была, а частей у неё меньше, чем в письме (прошлый проход
   *                          оборвался посередине): недостающие добрали.
   */
  async ingest(input: IngestInput): Promise<IngestResult> {
    let uid = BigInt(input.uid);
    // Message-ID достаём из заголовков заранее, до разбора: это слабый ключ дедупа — он ловит
    // письмо, встреченное в другой папке источника (или свою же отправленную копию, которую
    // синхронизация нашла на сервере), но подделать его может кто угодно (см. шапку файла).
    const messageId = headerMessageId(input.source);
    const existing = await this.findExisting(input, uid);

    // Координата локального письма — не UID сервера, а хеш от Message-ID (48 бит): совпадение
    // по ней без совпадения размера означает коллизию, а не то же письмо. Тогда берём
    // координату от содержимого — она детерминирована (повторная доставка того же письма даст
    // её же), но два разных письма с одинаковым Message-ID больше не столкнутся.
    const coordinateCollision =
      existing !== null &&
      input.folderPath.startsWith(LOCAL_PREFIX) &&
      existing.size !== input.source.length;
    if (coordinateCollision) {
      uid = BigInt(uidOfMessageId(`${messageId ?? ''}#${sha256Hex(input.source)}`));
      this.logger.warn(
        `письмо ${messageId ?? '(без Message-ID)'}: координаты заняты другим письмом (${existing?.size} против ${input.source.length} байт) — сохраняю отдельно`,
      );
    }

    // Совпадение только по Message-ID: дублем признаём, лишь когда видно, что это то же письмо.
    // Иначе отправитель, повторив чужой заголовок, тихо выкидывал бы письмо из архива.
    let match = coordinateCollision ? null : existing;
    if (!match && messageId) {
      const twin = await this.prisma.mailMessage.findFirst({
        where: {
          accountId: input.account.id,
          messageId,
          ...(existing ? { NOT: { id: existing.id } } : {}),
        },
        select: EXISTING_FIELDS,
      });
      if (twin && this.looksLikeSameLetter(twin, input)) {
        match = twin;
      } else if (twin) {
        this.logger.warn(
          `письмо ${messageId}: Message-ID уже занят письмом ${twin.id} (${twin.size} байт против ${input.source.length}) — сохраняю как отдельное письмо`,
        );
      }
    }

    if (match) {
      if (match.deletedAt) return 'trashed';
      // Письмо переехало между папками (спам → входящие, перенос метки в Gmail): обновляем
      // координаты, иначе следующий проход будет считать его новым в старой папке.
      //
      // Но не для писем, пришедших не по IMAP: у них координата — просто пометка «локальная»,
      // и перезапись стёрла бы происхождение (у отправленной копии это `local:sent`). Письмо,
      // отправленное себе, приходит обратно именно так — это не переезд, а вторая папка.
      const moved =
        !input.folderPath.startsWith(LOCAL_PREFIX) &&
        (match.folderPath !== input.folderPath ||
          match.uid !== uid ||
          match.uidValidity !== input.uidValidity);
      // Папки, которых у письма ещё нет: вторая копия того же письма (отправленное себе,
      // две копии у iCloud) — это то же письмо в другой папке, а не другое письмо.
      const extraBoxes = [...new Set([input.box, ...(input.alsoBoxes ?? [])])].filter(
        (b) => b !== match.box && !match.alsoBoxes.includes(b),
      );
      // Прочитанность берём с сервера только в одну сторону: «там прочитано» — значит и у нас
      // прочитано; «там не прочитано» локальную отметку не снимает. Иначе письмо, прочитанное
      // в нашем интерфейсе (флаги на сервер мы пока не пишем), каждым проходом снова
      // становилось бы непрочитанным.
      const adoptSeen = input.seen && !match.seen;
      if (moved || adoptSeen || extraBoxes.length) {
        await this.prisma.mailMessage.update({
          where: { id: match.id },
          data: {
            ...(moved
              ? {
                  folderPath: input.folderPath,
                  uid,
                  uidValidity: input.uidValidity,
                  // У своей отправленной копии X-GM-MSGID неизвестен: подставляем, когда
                  // синхронизация встретила то же письмо на сервере.
                  ...(input.emailId ? { gmailMsgId: input.emailId } : {}),
                  // Письмо теперь лежит по новым координатам — значит у провайдера появилась
                  // ещё одна копия, и прежняя отметка «копий нет» к нему больше не относится:
                  // снимаем её, иначе письмо навсегда выпадет из очереди чистки (она выбирает
                  // кандидатов по `remoteDeletedAt: null`).
                  remoteDeletedAt: null,
                  remotePurgeTries: 0,
                  remotePurgeError: null,
                }
              : {}),
            ...(extraBoxes.length ? { alsoBoxes: { push: extraBoxes } } : {}),
            ...(adoptSeen ? { seen: true } : {}),
          },
        });
      }
      // Вложения могли не доехать в прошлый раз: обрыв случился между строкой письма и частями,
      // поэтому частей меньше, чем в самом письме (а не обязательно ноль). Сверяем с разбором
      // того же сырья — оно у нас в руках, из хранилища его доставать не нужно.
      if (match.hasAttachments) {
        const expected = await this.expectedAttachments(input.source);
        if (expected > 0 && match._count.attachments < expected) {
          await this.repairAttachments(input.userId, match.id, match.rawAssetId, match.sortAt, this.targetOf(input, uid));
          return 'attachments-repaired';
        }
      }
      return 'skipped';
    }

    // 1. Байты письма: content-addressed, как у любого файла в этом хранилище.
    const rawSha = sha256Hex(input.source);
    const rawKey = S3Service.assetKey(rawSha);
    if (!(await this.s3.headObject(rawKey))) {
      await this.s3.putObject(rawKey, input.source, 'message/rfc822');
    }
    const rawAssetId = await this.files.ensureAsset(rawSha, input.source.length, 'message/rfc822', 'eml');

    // 2. Разбор. Отдельным шагом, чтобы ошибка разбора не оставила полстроки в БД.
    const parsed = await parseMessage(input.source);

    // Дата ленты: у входящих — время прихода на сервер (заголовку Date верить нельзя),
    // у исходящих — время отправки из заголовка, если оно есть.
    const sortAt = input.box === 'sent' ? (parsed.sentAt ?? input.receivedAt) : input.receivedAt;
    const hasAttachments = parsed.attachments.some((a) => !a.inline);

    const created = await this.prisma.mailMessage.create({
      data: {
        userId: input.userId,
        accountId: input.account.id,
        box: input.box,
        alsoBoxes: input.alsoBoxes ?? [],
        folderPath: input.folderPath,
        uid,
        uidValidity: input.uidValidity,
        gmailMsgId: input.emailId ?? null,
        messageId: parsed.messageId,
        threadKey: input.threadId ?? threadKeyOf(parsed.subject, parsed.refs),
        subject: parsed.subject,
        fromName: parsed.fromName,
        fromAddr: parsed.fromAddr,
        toAddrs: parsed.toAddrs,
        ccAddrs: parsed.ccAddrs,
        replyTo: parsed.replyTo,
        inReplyTo: parsed.inReplyTo,
        refs: parsed.refs,
        sentAt: parsed.sentAt,
        receivedAt: input.receivedAt,
        sortAt,
        size: input.source.length,
        hasAttachments,
        seen: input.seen,
        flagged: input.flagged,
        bodyText: parsed.bodyText,
        rawAssetId,
      },
      select: { id: true },
    });

    // 3. Вложения. Падение тут не откатывает письмо: строка останется, а следующий проход
    //    доберёт части (см. ветку attachments-repaired выше) — терять письмо нельзя.
    await this.storeAttachments(this.targetOf(input, uid), created.id, sortAt, parsed.attachments);

    return 'stored';
  }

  /**
   * Письмо, которое принёс наш собственный сервер (Postfix → pipe → эта ручка).
   *
   * Отличие от IMAP-пути только в координатах: у письма нет ни UID сервера, ни папки,
   * поэтому uid берём из Message-ID, а вместо папки ставим пометку «локальная». Повтор
   * доставки ловится координатой (тот же Message-ID даёт тот же uid), а не Message-ID как
   * ключом — совпадение по нему одного письма с другим не значит «это дубль».
   *
   * Получатель приходит из адреса доставки, и сравнивать его нужно без учёта регистра: в схеме
   * адрес уникален только в пределах пользователя (`@@unique([userId, email])`), поэтому
   * «User@Example.com» и «user@example.com» — это две разные строки. Если под один адрес
   * подходит несколько аккаунтов, письмо не отдаём ни одному: отдать чужую переписку хуже,
   * чем попросить администратора развести адреса (Postfix на этом ответе повторит доставку).
   */
  async ingestInbound(recipient: string, source: Buffer): Promise<'stored' | 'duplicate' | 'unknown-account'> {
    const email = String(recipient ?? '').trim().toLowerCase();
    const account = await this.accountForRecipient(email);
    // Аккаунт ещё не заведён в приложении: отвечаем «временно не можем», чтобы Postfix
    // подержал письмо в очереди и повторил — терять его из-за настройки нельзя.
    if (!account) return 'unknown-account';

    const messageId = headerMessageId(source) ?? sha256Hex(source);
    const result = await this.ingest({
      userId: account.userId,
      account,
      box: 'inbox',
      folderPath: LOCAL_FOLDER,
      uid: uidOfMessageId(messageId),
      uidValidity: 0n,
      source,
      seen: false,
      flagged: false,
      emailId: null,
      threadId: null,
      receivedAt: new Date(),
    });
    return result === 'skipped' || result === 'attachments-repaired' ? 'duplicate' : 'stored';
  }

  /**
   * Аккаунт по адресу доставки.
   *
   * Сравнение без учёта регистра и с запасной попыткой без plus-метки: `user+tag@домен` — это
   * тот же ящик (`user@домен`), и если такого аккаунта нет, письмо уходило бы в отказ, а
   * Postfix — в ретраи и bounce.
   */
  private async accountForRecipient(email: string): Promise<MailAccountRow | null> {
    const candidates = await this.accountsByEmail(email);
    if (candidates.length === 1) return candidates[0];
    if (candidates.length > 1) {
      this.logger.error(
        `письмо на ${email}: под адрес подходит аккаунтов — ${candidates.length}; доставку не выполняю, разведите адреса`,
      );
      return null;
    }
    const plus = email.indexOf('+');
    const at = email.lastIndexOf('@');
    if (plus > 0 && at > plus) {
      const base = `${email.slice(0, plus)}${email.slice(at)}`;
      const fallback = await this.accountsByEmail(base);
      if (fallback.length === 1) return fallback[0];
      if (fallback.length > 1) {
        this.logger.error(`письмо на ${email}: под адрес ${base} подходит аккаунтов — ${fallback.length}; доставку не выполняю`);
        return null;
      }
    }
    return null;
  }

  /** Поиск аккаунта по адресу без учёта регистра; больше двух совпадений нам знать не нужно. */
  private async accountsByEmail(email: string): Promise<MailAccountRow[]> {
    return this.prisma.mailAccount.findMany({
      where: { email: { equals: email, mode: 'insensitive' } },
      take: 2,
    });
  }

  /**
   * Добрать вложения письма, которое уже лежит у нас, по его же сырью.
   *
   * Штатный случай — обрыв прошлого прохода между строкой письма и частями: сырьё в хранилище
   * уже есть, а вложений в дереве нет. Повторный разбор идемпотентен (имя файла выводится из
   * письма), поэтому вызов безопасен и для письма, у которого всё на месте.
   *
   * Отдельный публичный вход нужен чистке сервера: она не удаляет копию письма, пока вложения
   * не разобраны, и должна уметь этот разбор запустить, а не просто отказаться.
   */
  async repairMessage(userId: string, id: string): Promise<number> {
    const row = await this.prisma.mailMessage.findFirst({
      where: { id, userId },
      select: {
        id: true,
        box: true,
        folderPath: true,
        uid: true,
        uidValidity: true,
        gmailMsgId: true,
        receivedAt: true,
        sortAt: true,
        rawAssetId: true,
        seen: true,
        flagged: true,
        account: true,
      },
    });
    if (!row) return 0;
    const account = row.account as MailAccountRow;
    const before = await this.prisma.mailAttachment.count({ where: { messageId: row.id } });
    await this.repairAttachments(userId, row.id, row.rawAssetId, row.sortAt, {
      userId,
      box: row.box as MailBox,
      accountId: account.id,
      folderPath: row.folderPath,
      uid: row.uid,
      uidValidity: row.uidValidity,
      emailId: row.gmailMsgId,
    });
    return (await this.prisma.mailAttachment.count({ where: { messageId: row.id } })) - before;
  }

  /** Добор вложений по уже сохранённому сырью (прошлый проход оборвался на середине). */
  private async repairAttachments(
    userId: string,
    messageId: string,
    rawAssetId: string,
    sortAt: Date,
    target: AttachmentTarget,
  ): Promise<void> {
    const asset = await this.prisma.asset.findUnique({ where: { id: rawAssetId }, select: { sha256: true } });
    if (!asset) {
      this.logger.warn(`письмо ${messageId}: сырьё не найдено в учёте, вложения не добрать`);
      return;
    }
    const source = await this.s3.getObjectBytes(S3Service.assetKey(asset.sha256));
    const parsed = await parseMessage(source);
    await this.storeAttachments(target, messageId, sortAt, parsed.attachments);
    this.logger.log(`письмо ${messageId}: вложения добраны (${parsed.attachments.length}) для ${userId}`);
  }

  /** Сохранить части письма: S3 → Asset → запись дерева в «Почте» → связь с письмом. */
  private async storeAttachments(
    target: AttachmentTarget,
    messageId: string,
    sortAt: Date,
    attachments: ParsedAttachment[],
  ): Promise<void> {
    if (!attachments.length) return;
    const folderId = await this.boxFolderId(target.userId, target.box);
    const identity = this.identityOf(target);

    // Что уже сохранено — одним запросом на письмо, а не по запросу на часть: у письма с
    // тремя десятками вложений это была бы сотня round-trip внутри прохода.
    const existingParts = new Set(
      (
        await this.prisma.mailAttachment.findMany({
          where: { messageId },
          select: { partIndex: true },
        })
      ).map((r) => r.partIndex),
    );

    for (const att of attachments) {
      // Идемпотентность: та же часть того же письма уже сохранена — выходим.
      if (existingParts.has(att.index)) continue;

      const mime = safeMime(att.mime);
      const sha = sha256Hex(att.content);
      const key = S3Service.assetKey(sha);
      if (!(await this.s3.headObject(key))) {
        await this.s3.putObject(key, att.content, mime);
      }
      const assetId = await this.files.ensureAsset(sha, att.content.length, mime, undefined);

      // Имя: приставка даты письма + исходное имя части. Про имя из письма известно только
      // то, что оно недоверенное, поэтому его чистит safeAttachmentName (внутри attachmentName).
      const baseName = att.filename?.trim() || `file-${att.index + 1}${extensionForMime(mime)}`;
      const entryId = await this.resolveAttachmentEntry(folderId, baseName, assetId, sortAt, identity, att, target.userId);
      // Имя подобрать не удалось (заняты все варианты): письмо из-за одной части не теряем —
      // часть останется неразобранной, причина уже в логе.
      if (!entryId) continue;

      await this.prisma.mailAttachment.create({
        data: {
          messageId,
          entryId,
          partIndex: att.index,
          filename: att.filename ?? baseName,
          mime,
          size: att.content.length,
          contentId: att.contentId,
          inline: att.inline,
        },
      });
      existingParts.add(att.index);
    }
  }

  /**
   * Запись в дереве для части письма. Имя свободное подбирается так: сначала чистое
   * «дата_имя», при занятости — с коротким хвостом от письма. Хвост от письма, а не «(2)»:
   * повторный разбор того же письма обязан дать то же имя, иначе каждая попытка плодила бы
   * новую копию файла.
   *
   * Перед созданием проверяем оба имени на «осиротевшую» запись — файл, который уже лежит
   * в папке, но ни с каким письмом не связан. Такой остаётся, если прошлый проход оборвался
   * между созданием файла и связью с письмом; без этой проверки повторный проход оставил бы
   * в папке дубль под именем с хвостом.
   */
  private async resolveAttachmentEntry(
    folderId: string,
    baseName: string,
    assetId: string,
    sortAt: Date,
    identity: string,
    att: ParsedAttachment,
    userId: string,
  ): Promise<string | null> {
    const candidates = [
      attachmentName(sortAt, baseName),
      attachmentName(sortAt, baseName, sha256Hex(`${identity}#${att.index}`)),
    ];

    // Оба имени проверяем одним запросом, а связи — ещё одним: по запросу на имя было бы
    // четыре round-trip на каждую часть письма.
    const named = await this.prisma.fileEntry.findMany({
      where: { folderId, name: { in: candidates }, deletedAt: null },
      select: { id: true },
    });
    if (named.length) {
      const links = await this.prisma.mailAttachment.findMany({
        where: { entryId: { in: named.map((e) => e.id) } },
        select: { entryId: true },
      });
      const linked = new Set(links.map((l) => l.entryId));
      // связи нет — это наш осиротевший файл от оборванного прохода, забираем его;
      // связь есть — имя занято другим письмом, пробуем варианты ниже
      const orphan = named.find((e) => !linked.has(e.id));
      if (orphan) return orphan.id;
    }

    // Приставка «-N» на случай, когда заняты оба осмысленных имени (например, тёзка лежит
    // в корзине и слот имени всё равно занят). До этого был тупик: письмо попадало в историю
    // и каждый проход умирал на нём же, не добирая остальную почту. Теперь тупик не роняет
    // сохранение письма: часть останется неразобранной, а причина попадёт в лог.
    for (let attempt = 0; attempt < 6; attempt++) {
      const name = attempt < candidates.length ? candidates[attempt] : `${candidates[candidates.length - 1]}-${attempt - candidates.length + 2}`;
      try {
        const entry = await this.files.createEntry(folderId, name, assetId, { userId });
        return entry.id;
      } catch (e) {
        if (e instanceof ApiError && e.getStatus() === 409) continue;
        throw e;
      }
    }
    this.logger.error(`часть ${att.index} письма: не удалось подобрать имя вложения — оставляю неразобранной`);
    return null;
  }
}

/** Тип части для БД: без управляющих символов и не длиннее разумного. */
function safeMime(raw: string): string {
  const mime = String(raw ?? '').trim().toLowerCase();
  if (!mime || mime.length > MAX_MIME || /[\u0000-\u001f\u007f]/.test(mime)) return 'application/octet-stream';
  // Тип идёт не только в БД, но и в заголовок отдачи — проверяем и по белому списку
  return normalizeMime(mime);
}

/** Текст ошибки для лога: `throw 'строка'` и `throw {}` тоже встречаются. */
function errorText(e: unknown): string {
  return (e instanceof Error ? e.message : String(e)).slice(0, 200);
}
