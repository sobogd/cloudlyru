/**
 * Что мы готовы записать в Asset.mime.
 *
 * MIME приходит от клиента (браузер, телефон, публичная ссылка на загрузку) и до этой правки
 * попадал в БД как есть. А дальше он решает три вещи: какая задача конвертации ставится
 * (mediaKindOf), каким типом отдаётся файл в /video-preview?src=original и что показывает
 * телефон. Объявив произвольный тип, можно было поставить тяжёлую задачу на что угодно —
 * а задача качает объект из S3 целиком, — или подсунуть браузеру свой тип.
 *
 * Поэтому знакомые типы пропускаем, незнакомые сводим к application/octet-stream: файл
 * остаётся целым и скачивается как есть, просто без превью и с общим значком.
 */
const KNOWN_MIMES = new Set([
  'application/octet-stream',
  'application/pdf',
  'application/zip',
  'application/x-zip-compressed',
  'application/gzip',
  'application/x-tar',
  'application/x-7z-compressed',
  'application/x-rar-compressed',
  'application/json',
  'application/rtf',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'application/vnd.oasis.opendocument.text',
  'application/vnd.oasis.opendocument.spreadsheet',
  'application/epub+zip',
  'application/x-mobipocket-ebook',
  'application/vnd.android.package-archive',
  'text/plain',
  'text/csv',
  'text/markdown',
  'text/calendar',
  'text/vcard',
  // Сырое письмо: тип важен для скачивания .eml и для того, чтобы такие ассеты не считались
  // «неизвестными» при отдаче (в сжатом виде письмо не читается ничем, кроме почтового клиента).
  'message/rfc822',
]);

/** Сколько символов допускаем в типе: заголовок не должен приезжать из данных. */
const MAX_MIME_LENGTH = 120;

export function normalizeMime(raw: unknown): string {
  const mime = String(raw ?? '').trim().toLowerCase();
  // Управляющие символы (в том числе CR/LF) в заголовок не пускаем: это готовая инъекция
  // заголовков, если тип окажется в Content-Type.
  if (!mime || mime.length > MAX_MIME_LENGTH || /[\u0000-\u001f\u007f]/.test(mime)) {
    return 'application/octet-stream';
  }
  // Картинки пропускаем любые: конвертируем мы только то, что умеем (mediaKindOf), а RAW
  // камер должен хотя бы попадать в ленту и открываться по кнопке «скачать оригинал».
  if (/^(image|video|audio)\//.test(mime)) return mime;
  return KNOWN_MIMES.has(mime) ? mime : 'application/octet-stream';
}
