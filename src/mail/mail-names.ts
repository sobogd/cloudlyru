// Имена вложений в системной папке «Почта».
//
// Файл вложения — обычная запись дерева, а дерево требует уникальное имя внутри папки и
// имя, помещающееся в 255 БАЙТ (assertSafeName). Почта даёт и то и другое «как получится»:
// имена приходят из письма (255 байт в utf8 — легко), бывают пустыми (у инлайн-частей файла
// нет вовсе) и повторяются — два письма за день с одним и тем же «акт.pdf».
//
// Поэтому имя собирается детерминированно: приставка даты + исходное имя, а при совпадении
// внутри папки — ещё и короткий хвост sha256 части. Хвост, а не «(2)»: повторный синк того же
// письма обязан дать то же имя (иначе каждая попытка плодила бы новую копию), а порядок
// обработки частей не гарантирован.

/** Предел имени в байтах utf8 — как в assertSafeName (предел файловых систем телефонов). */
const MAX_NAME_BYTES = 255;

/** Разделитель между датой, необязательным хвостом sha и исходным именем. */
const SEP = '_';

/** Имя по умолчанию, если у MIME-части имени нет: инлайн-картинки и части без filename. */
const FALLBACK_BASE = 'file';

/**
 * Расширение по MIME-типу — для частей без имени файла (инлайн-картинки тела письма имени
 * часто не имеют вовсе). Без расширения файл на телефоне открывается «неизвестным».
 */
const MIME_EXT: Record<string, string> = {
  'image/png': '.png',
  'image/jpeg': '.jpg',
  'image/gif': '.gif',
  'image/webp': '.webp',
  'image/bmp': '.bmp',
  'image/tiff': '.tif',
  'image/heic': '.heic',
  'image/svg+xml': '.svg',
  'application/pdf': '.pdf',
  'text/plain': '.txt',
  'text/html': '.html',
  'text/csv': '.csv',
  'text/calendar': '.ics',
  'message/rfc822': '.eml',
  'application/zip': '.zip',
  'application/gzip': '.gz',
  'application/json': '.json',
  'application/msword': '.doc',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': '.docx',
  'application/vnd.ms-excel': '.xls',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': '.xlsx',
  'application/vnd.ms-powerpoint': '.ppt',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': '.pptx',
};

/** Расширение с точкой по MIME-типу; пустая строка — тип незнакомый. */
export function extensionForMime(mime: string): string {
  return MIME_EXT[String(mime ?? '').toLowerCase()] ?? '';
}

/** Дата в приставке — ГГГГ-ММ-ДД по UTC (все даты в проекте хранятся и сравниваются в UTC). */
export function datePrefix(at: Date): string {
  const iso = at.toISOString();
  return iso.slice(0, 10);
}

/** Расширение с точкой из имени файла ('отчёт.PDF' → '.PDF'), если оно есть и не безумное. */
function extensionOf(name: string): string {
  const dot = name.lastIndexOf('.');
  if (dot <= 0 || dot === name.length - 1) return '';
  const ext = name.slice(dot);
  return ext.length <= 16 ? ext : '';
}

/** Имя без расширения. */
function stemOf(name: string, ext: string): string {
  return ext ? name.slice(0, name.length - ext.length) : name;
}

/**
 * Имя части письма, пригодное для дерева: без разделителей пути и управляющих символов,
 * без ведущих точек и пробелов, с запасным именем вместо пустого. Расширение сохраняем —
 * по нему клиент выбирает приложение для открытия.
 */
export function safeAttachmentName(raw: string | undefined | null): string {
  const cleaned = String(raw ?? '')
    // кавычки и переводы строк приходят из заголовков соседних писем: Content-Disposition
    // в письме — недоверенный ввод, а имя уезжает в S3-ключ, WebDAV и файловую систему телефона
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/[/\\]/g, '-')
    .replace(/^[.\s]+/, '')
    .replace(/\s+/g, ' ')
    .trim();

  if (!cleaned) return FALLBACK_BASE;
  if (cleaned === '.' || cleaned === '..') return FALLBACK_BASE;
  return cleaned;
}

/** Обрезать по байтам utf8, не разрезая символ посередине. */
function truncateBytes(s: string, maxBytes: number): string {
  if (maxBytes <= 0) return '';
  if (Buffer.byteLength(s, 'utf8') <= maxBytes) return s;
  let out = '';
  let used = 0;
  for (const ch of s) {
    const size = Buffer.byteLength(ch, 'utf8');
    if (used + size > maxBytes) break;
    out += ch;
    used += size;
  }
  return out;
}

/**
 * Имя вложения для папки «Почта».
 *
 *   attachmentName(new Date('2025-09-14T21:00:00Z'), 'Акт.pdf')
 *     → '2025-09-14_Акт.pdf'
 *
 * `disambiguator` (первые 8 hex sha256 содержимого части) добавляется, только когда имя
 * в папке уже занято другим вложением:
 *
 *   attachmentName(date, 'Акт.pdf', 'a1b2c3d4')
 *     → '2025-09-14_a1b2c3d4_Акт.pdf'
 */
export function attachmentName(at: Date, rawName: string | undefined | null, disambiguator?: string): string {
  const safe = safeAttachmentName(rawName);
  const ext = extensionOf(safe);
  const stem = stemOf(safe, ext) || FALLBACK_BASE;
  const mark = disambiguator ? disambiguator.slice(0, 8) + SEP : '';

  // Имя уже начинается с даты — своей приставки не добавляем, иначе получалось бы
  // «2026-09-15_2026-09-14_акт.pdf»: так выглядит файл, который мы же и сохранили раньше,
  // когда его пересылают дальше.
  const own = /^(\d{4}-\d{2}-\d{2})_(.*)$/.exec(stem);
  const composed = own
    ? `${own[1]}${SEP}${mark}${own[2]}`
    : `${datePrefix(at)}${SEP}${mark}${stem}`;

  // Расширение не трогаем: без него файл на телефоне открывается «неизвестным».
  const keepExt = truncateBytes(ext, 32);
  const room = MAX_NAME_BYTES - Buffer.byteLength(keepExt, 'utf8');
  return (truncateBytes(composed, room) || FALLBACK_BASE) + keepExt;
}

