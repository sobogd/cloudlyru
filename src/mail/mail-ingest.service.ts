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
 */

/** Что делать с письмом по итогам прохода. */
export type IngestResult = 'stored' | 'skipped' | 'trashed' | 'attachments-repaired';

export interface IngestInput {
  userId: string;
  account: MailAccountRow;
  box: MailBox;
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

/** Имена наших двух папок внутри системной «Почты». */
export const MAIL_BOX_FOLDER: Record<MailBox, string> = { inbox: 'Входящие', sent: 'Исходящие' };

/**
 * Псевдо-папка для писем, пришедших не по IMAP: наша отправка и приём своим сервером.
 * Курсоров у неё нет — это просто координата, чтобы строка письма была полной.
 */
export const LOCAL_FOLDER = 'local:local';

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

@Injectable()
export class MailIngestService {
  private readonly logger = new Logger(MailIngestService.name);
  /** Кэш папок-корзин на время прохода: иначе на каждое письмо два лишних запроса. */
  private readonly boxFolders = new Map<string, string>();

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
    if (cached) return cached;

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
    this.boxFolders.set(cacheKey, folder.id);
    return folder.id;
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
  private identityOf(input: IngestInput): string {
    const own = input.emailId ?? `${input.folderPath}:${input.uidValidity}:${input.uid}`;
    return `${input.account.id}:${own}`;
  }

  /**
   * Сохранить письмо. Возвращает:
   *   stored             — письма у нас ещё не было;
   *   skipped            — уже есть (обычный случай повторного прохода);
   *   trashed            — есть, но лежит в корзине: удалённое не воскрешаем;
   *   attachments-repaired — строка была, вложений не было (прошлый проход оборвался).
   */
  async ingest(input: IngestInput): Promise<IngestResult> {
    const uid = BigInt(input.uid);
    // Message-ID достаём из заголовков заранее, до разбора: он третий ключ дедупа и
    // единственный, который ловит письмо, встреченное в другой папке источника (или свою же
    // отправленную копию, которую синхронизация нашла на сервере).
    const messageId = headerMessageId(input.source);
    const existing = await this.prisma.mailMessage.findFirst({
      where: {
        accountId: input.account.id,
        OR: [
          { folderPath: input.folderPath, uidValidity: input.uidValidity, uid },
          ...(input.emailId ? [{ gmailMsgId: input.emailId }] : []),
          ...(messageId ? [{ messageId }] : []),
        ],
      },
      select: {
        id: true,
        deletedAt: true,
        folderPath: true,
        uid: true,
        uidValidity: true,
        seen: true,
        rawAssetId: true,
        hasAttachments: true,
        sortAt: true,
        _count: { select: { attachments: true } },
      },
    });

    if (existing) {
      if (existing.deletedAt) return 'trashed';
      // Письмо переехало между папками (спам → входящие, перенос метки в Gmail): обновляем
      // координаты, иначе следующий проход будет считать его новым в старой папке.
      const moved =
        existing.folderPath !== input.folderPath ||
        existing.uid !== uid ||
        existing.uidValidity !== input.uidValidity;
      // Прочитанность берём с сервера только в одну сторону: «там прочитано» — значит и у нас
      // прочитано; «там не прочитано» локальную отметку не снимает. Иначе письмо, прочитанное
      // в нашем интерфейсе (флаги на сервер мы пока не пишем), каждым проходом снова
      // становилось бы непрочитанным.
      const adoptSeen = input.seen && !existing.seen;
      if (moved || adoptSeen) {
        await this.prisma.mailMessage.update({
          where: { id: existing.id },
          data: {
            ...(moved
              ? {
                  folderPath: input.folderPath,
                  uid,
                  uidValidity: input.uidValidity,
                  // У своей отправленной копии X-GM-MSGID неизвестен: подставляем, когда
                  // синхронизация встретила то же письмо на сервере.
                  ...(input.emailId ? { gmailMsgId: input.emailId } : {}),
                }
              : {}),
            ...(adoptSeen ? { seen: true } : {}),
          },
        });
      }
      // Вложения могли не доехать в прошлый раз (обрыв между строкой письма и частями).
      // Сырьё у нас уже есть в S3, поэтому перебираем части из хранилища, а не с сервера.
      if (existing.hasAttachments && existing._count.attachments === 0) {
        await this.repairAttachments(input.userId, existing.id, existing.rawAssetId, existing.sortAt, input);
        return 'attachments-repaired';
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
    await this.storeAttachments(input, created.id, sortAt, parsed.attachments);

    return 'stored';
  }

  /**
   * Письмо, которое принёс наш собственный сервер (Postfix → pipe → эта ручка).
   *
   * Отличие от IMAP-пути только в координатах: у письма нет ни UID сервера, ни папки,
   * поэтому uid берём из Message-ID, а вместо папки ставим пометку «локальная». Дедуп
   * по Message-ID не даёт одному и тому же письму появиться дважды при повторе доставки.
   */
  async ingestInbound(recipient: string, source: Buffer): Promise<'stored' | 'duplicate' | 'unknown-account'> {
    const email = String(recipient ?? '').trim().toLowerCase();
    const account = await this.prisma.mailAccount.findFirst({ where: { email } });
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

  /** Добор вложений по уже сохранённому сырью (прошлый проход оборвался на середине). */
  private async repairAttachments(
    userId: string,
    messageId: string,
    rawAssetId: string,
    sortAt: Date,
    input: IngestInput,
  ): Promise<void> {
    const asset = await this.prisma.asset.findUnique({ where: { id: rawAssetId }, select: { sha256: true } });
    if (!asset) {
      this.logger.warn(`письмо ${messageId}: сырьё не найдено в учёте, вложения не добрать`);
      return;
    }
    const source = await this.s3.getObjectBytes(S3Service.assetKey(asset.sha256));
    const parsed = await parseMessage(source);
    await this.storeAttachments(input, messageId, sortAt, parsed.attachments);
    this.logger.log(`письмо ${messageId}: вложения добраны (${parsed.attachments.length}) для ${userId}`);
  }

  /** Сохранить части письма: S3 → Asset → запись дерева в «Почте» → связь с письмом. */
  private async storeAttachments(
    input: IngestInput,
    messageId: string,
    sortAt: Date,
    attachments: ParsedAttachment[],
  ): Promise<void> {
    if (!attachments.length) return;
    const folderId = await this.boxFolderId(input.userId, input.box);
    const identity = this.identityOf(input);

    for (const att of attachments) {
      // Идемпотентность: та же часть того же письма уже сохранена — выходим.
      const already = await this.prisma.mailAttachment.findUnique({
        where: { messageId_partIndex: { messageId, partIndex: att.index } },
        select: { id: true },
      });
      if (already) continue;

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
      const entryId = await this.resolveAttachmentEntry(folderId, baseName, assetId, sortAt, identity, att, input.userId);

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
  ): Promise<string> {
    const candidates = [
      attachmentName(sortAt, baseName),
      attachmentName(sortAt, baseName, sha256Hex(`${identity}#${att.index}`)),
    ];

    for (const name of candidates) {
      const existing = await this.prisma.fileEntry.findFirst({
        where: { folderId, name, deletedAt: null },
        select: { id: true },
      });
      if (!existing) continue;
      const linked = await this.prisma.mailAttachment.findUnique({
        where: { entryId: existing.id },
        select: { id: true },
      });
      // связь есть — имя занято другим письмом, пробуем следующий вариант имени;
      // связи нет — это наш осиротевший файл от оборванного прохода, забираем его
      if (!linked) return existing.id;
    }

    // Приставка «-N» на случай, когда заняты оба осмысленных имени (например, тёзка лежит
    // в корзине и слот имени всё равно занят). До этого был тупик: письмо попадало в историю
    // и каждый проход умирал на нём же, не добирая остальную почту.
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
    throw new Error('не удалось подобрать имя вложения');
  }
}

/** Тип части для БД: без управляющих символов и не длиннее разумного. */
function safeMime(raw: string): string {
  const mime = String(raw ?? '').trim().toLowerCase();
  if (!mime || mime.length > MAX_MIME || /[\u0000-\u001f\u007f]/.test(mime)) return 'application/octet-stream';
  // Тип идёт не только в БД, но и в заголовок отдачи — проверяем и по белому списку
  return normalizeMime(mime);
}
