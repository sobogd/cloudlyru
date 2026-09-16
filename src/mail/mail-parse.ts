import { simpleParser, type AddressObject, type Attachment } from 'mailparser';

/**
 * Разбор письма: единственное место, где мы смотрим внутрь MIME.
 *
 * Модуль намеренно чистый (нет ни БД, ни S3): это самая ошибкоопасная часть почты —
 * заголовки, кодировки, вложения, — и её хочется проверять на живом .eml, а не через
 * полсистемы. Всё, что нужно вызывающему, возвращается значениями.
 *
 * Тело в БД не кладём: сырой .eml лежит в S3 и разбирается заново при открытии письма,
 * поэтому здесь возвращаются и полный текст (`fullText` — для «показать как текст» и
 * цитаты ответа), и превью для списка (`bodyText`, первые SNAPSHOT_CHARS символов).
 */

/**
 * Сколько символов тела хранится в БД для превью в списке писем. Это именно превью:
 * показывать обрезанное письмо как полное нельзя, поэтому у `ParsedMessage` есть `fullText`.
 */
export const SNAPSHOT_CHARS = 2000;

/** Вложение письма, готовое к сохранению (в дерево файлов и в S3). */
export interface ParsedAttachment {
  /** Порядковый номер части в письме — стабильный ключ вложения внутри письма. */
  index: number;
  /** Имя из Content-Disposition/Content-Type; null — у инлайн-части имени может не быть. */
  filename: string | null;
  mime: string;
  /** Content-ID без угловых скобок: по нему подменяется cid: при показе письма. */
  contentId: string | null;
  /** Инлайн-картинка тела (Content-Disposition: inline или ссылка по cid). */
  inline: boolean;
  content: Buffer;
}

export interface ParsedMessage {
  subject: string | null;
  fromName: string | null;
  fromAddr: string | null;
  toAddrs: string[];
  ccAddrs: string[];
  replyTo: string | null;
  messageId: string | null;
  inReplyTo: string | null;
  refs: string[];
  /** Date из заголовков: может врать и может отсутствовать — истина в INTERNALDATE. */
  sentAt: Date | null;
  /** Превью текста для списка писем: первые SNAPSHOT_CHARS символов (это же значение в БД). */
  bodyText: string;
  /**
   * Текст письма целиком. Нужен там, где текст показывают или цитируют («показать как текст»,
   * цитата ответа): обрезанное до превью тело в этих местах выглядело бы как потерянные данные.
   */
  fullText: string;
  /**
   * HTML тела письма — как его отдал разборщик. В БД не хранится (письмо целиком лежит
   * в S3 и разбирается при открытии), нужно только отрисовке. Картинки по cid разборщик
   * уже заменил на data:-ссылки, то есть тело самодостаточно и никуда не ходит за картинками.
   */
  html: string | null;
  attachments: ParsedAttachment[];
}

/** Все адреса из адресного поля (у To/Cc их бывает несколько объектов). */
function addressesOf(field: AddressObject | AddressObject[] | undefined): string[] {
  const list = Array.isArray(field) ? field : field ? [field] : [];
  const out: string[] = [];
  for (const obj of list) {
    for (const item of obj.value ?? []) {
      if (item.address) out.push(item.address);
    }
  }
  return out;
}

/** Первый адрес поля (у From он один). */
function firstAddress(field: AddressObject | undefined): { name: string | null; addr: string | null } {
  const item = field?.value?.[0];
  return { name: item?.name?.trim() || null, addr: item?.address?.trim() || null };
}

/**
 * Ссылки треда: mailparser отдаёт строку, если она одна.
 *
 * Угловые скобки снимаем: в заголовках они есть (`<id@host>`), а сборщик письма при отправке
 * добавляет их сам — оставленные дали бы `<<id@host>>`, и тред у получателя развалился бы.
 */
function refsOf(raw: string[] | string | undefined): string[] {
  if (!raw) return [];
  const list = Array.isArray(raw) ? raw : [raw];
  return list.map((r) => String(r).trim().replace(/^<|>$/g, '')).filter(Boolean);
}

/**
 * Текст из HTML — для превью в списке и поиска. Полноценный парсер тут не нужен:
 * показываем первые пару тысяч символов, а теги и служебные блоки только мешают.
 */
export function htmlToText(html: string): string {
  return html
    .replace(/<(script|style|head)[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|tr|li|h[1-6])>/gi, '\n')
    .replace(/<[^>]*>/g, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/[ \t\u00a0]+/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/** Превью тела: без хвостовых пробелов, не длиннее SNAPSHOT_CHARS. */
function snapshot(text: string): string {
  const clean = text.replace(/\r\n/g, '\n').trim();
  return clean.length > SNAPSHOT_CHARS ? clean.slice(0, SNAPSHOT_CHARS) : clean;
}

/** Полный текст письма без хвостовых пробелов (та же нормализация переносов, что и у превью). */
function fullTextOf(text: string): string {
  return text.replace(/\r\n/g, '\n').trim();
}

/** Вложение в терминах приложения: инлайн-картинки тела — тоже файлы, и тоже сохраняются. */
function toAttachment(att: Attachment, index: number): ParsedAttachment {
  const contentId = (att.cid ?? att.contentId ?? null)?.replace(/^<|>$/g, '').trim() || null;
  const disposition = String(att.contentDisposition ?? '').toLowerCase();
  const inline = att.related === true || disposition === 'inline' || Boolean(contentId);
  return {
    index,
    filename: att.filename?.trim() || null,
    mime: String(att.contentType || 'application/octet-stream').toLowerCase(),
    contentId,
    inline,
    content: att.content,
  };
}

/**
 * Разобрать письмо целиком.
 *
 * `simpleParser` разбирает буфер в память: у почты это норма (предел письма у Gmail 25 МБ,
 * у iCloud 20 МБ), а альтернатива — потоковый разбор с ручным учётом частей, где ошибиться
 * проще, чем выиграть.
 */
export async function parseMessage(source: Buffer): Promise<ParsedMessage> {
  const parsed = await simpleParser(source);
  const from = firstAddress(parsed.from);

  // Текст письма: у multipart/alternative обычно есть обе версии, у HTML-only — только html.
  const text = parsed.text && parsed.text.trim() ? parsed.text : parsed.html ? htmlToText(parsed.html) : '';

  // Пустые части (например, вложение нулевой длины) не сохраняем: файла нет, а запись в дереве
  // была бы пустышкой, по которой нечего открыть.
  const attachments = parsed.attachments
    .map((att, i) => toAttachment(att, i))
    .filter((att) => att.content.length > 0);

  return {
    subject: parsed.subject?.trim() || null,
    fromName: from.name,
    fromAddr: from.addr,
    toAddrs: addressesOf(parsed.to),
    ccAddrs: addressesOf(parsed.cc),
    replyTo: firstAddress(parsed.replyTo).addr,
    // Без угловых скобок: так же выглядит Message-ID, который мы генерируем при отправке,
    // и по нему дедуп находит свою же копию письма, встретив её на сервере.
    messageId: parsed.messageId?.trim().replace(/^<|>$/g, '') || null,
    inReplyTo: parsed.inReplyTo?.trim().replace(/^<|>$/g, '') || null,
    refs: refsOf(parsed.references),
    sentAt: parsed.date && !Number.isNaN(parsed.date.getTime()) ? parsed.date : null,
    bodyText: snapshot(text),
    fullText: fullTextOf(text),
    html: typeof parsed.html === 'string' && parsed.html.trim() ? parsed.html : null,
    attachments,
  };
}

/** Сколько байт заголовков читаем в поисках Message-ID: больше не бывает даже у спама. */
const HEADER_SCAN_BYTES = 64 * 1024;

/**
 * Message-ID из заголовков — до полного разбора письма.
 *
 * Нужен, чтобы узнать письмо, которое у нас уже есть (например, отправленное отсюда же:
 * свою копию мы сохраняем сразу, а синхронизация потом встречает её на сервере). Полный
 * разбор ради этого делать незачем — Message-ID виден в первых строках, а разбор письма,
 * которое всё равно будет пропущено, — это лишняя работа на каждой повторной встрече.
 */
export function headerMessageId(source: Buffer): string | null {
  const head = source.subarray(0, Math.min(source.length, HEADER_SCAN_BYTES)).toString('latin1');
  const end = head.search(/\r?\n\r?\n/);
  const block = end >= 0 ? head.slice(0, end) : head;
  // Заголовок может быть свёрнут на следующую строку с пробелом — склеиваем перед разбором
  const unfolded = block.replace(/\r?\n[ \t]+/g, ' ');
  const match = /^message-id:[ \t]*(.+)$/im.exec(unfolded);
  if (!match) return null;
  const value = match[1].trim().replace(/^<|>$/g, '');
  return value || null;
}

/**
 * Адрес получателя из самого письма: `Delivered-To` (ставит LDA) или `X-Original-To`
 * (ставит Postfix на приёме).
 *
 * Нужен ручке `inbound`: адрес из query-строки проходит через декодирование URL, где `+`
 * превращается в пробел, поэтому письмо на `user+tag@domain` не находило бы свой аккаунт.
 * Заголовок от нашего же сервера надёжнее ещё и тем, что не зависит от того, как адрес передан
 * в запросе. Берём первое вхождение: Postfix добавляет свой заголовок сверху, выше всего,
 * что написал отправитель.
 */
export function envelopeRecipient(source: Buffer): string | null {
  const head = source.subarray(0, Math.min(source.length, HEADER_SCAN_BYTES)).toString('latin1');
  const end = head.search(/\r?\n\r?\n/);
  const block = end >= 0 ? head.slice(0, end) : head;
  const unfolded = block.replace(/\r?\n[ \t]+/g, ' ');
  for (const name of ['delivered-to', 'x-original-to']) {
    const match = new RegExp(`^${name}:[ \t]*(.+)$`, 'im').exec(unfolded);
    if (!match) continue;
    const angle = /<([^>]+)>/.exec(match[1]);
    const addr = (angle ? angle[1] : match[1]).trim().replace(/^[<"']+|[>"']+$/g, '').trim().toLowerCase();
    if (addr.includes('@')) return addr;
  }
  return null;
}

/**
 * Ключ треда для писем без серверного треда (iCloud его не отдаёт): нормализованная тема
 * плюс, если есть, корень References. Грубо, но заметно лучше, чем «каждое письмо отдельно»:
 * «Re: Договор» и «RE: Re: Договор» попадают в одну цепочку.
 */
export function threadKeyOf(subject: string | null, refs: string[]): string | null {
  const base = refs[0] ?? null;
  const cleanSubject = (subject ?? '')
    .replace(/^((re|fwd?|fw|ответ|пересл)\s*(\[\d+\])?\s*:\s*)+/i, '')
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase();
  if (base) return `ref:${base.toLowerCase()}`;
  return cleanSubject ? `subj:${cleanSubject}` : null;
}
