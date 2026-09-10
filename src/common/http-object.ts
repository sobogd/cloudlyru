import type { Request, Response } from 'express';
import { pipeline } from 'stream/promises';
import type { S3Service } from '../s3/s3.service';

/**
 * Content-Disposition с именем файла. Имя приходит от пользователя, поэтому:
 * переводы строк и кавычки вырезаем (иначе можно подсунуть свои заголовки), не-ASCII
 * отдаём вторым параметром filename* по RFC 5987 (русские имена в filename= ломаются).
 */
export function contentDisposition(kind: 'inline' | 'attachment', filename?: string): string {
  if (kind === 'inline' || !filename) return kind;
  const clean = filename
    .replace(/[\r\n\t]/g, ' ')
    .replace(/[\\/]/g, '_')
    .replace(/"/g, "'")
    .trim()
    .slice(0, 150) || 'download';
  const ascii = clean.replace(/[^\x20-\x7E]/g, '_');
  const utf8 = encodeURIComponent(clean).replace(
    /['()!*]/g,
    (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`,
  );
  return `attachment; filename="${ascii}"; filename*=UTF-8''${utf8}`;
}

/**
 * Типы, которые безопасно показывать прямо в браузере (на нашем домене).
 * SVG/HTML/PDF сюда не входят намеренно: они исполняют скрипты или открывают
 * сторонний рендер, а отдаём мы их со своего origin.
 */
const INLINE_IMAGE_MIMES: Record<string, string> = {
  'image/jpeg': 'image/jpeg',
  'image/png': 'image/png',
  'image/gif': 'image/gif',
  'image/webp': 'image/webp',
  'image/avif': 'image/avif',
  'image/bmp': 'image/bmp',
  'image/tiff': 'image/tiff',
  'image/heic': 'image/heic',
  'image/heif': 'image/heif',
};

/** Безопасный для inline тип или null (тогда файл отдаём только на скачивание). */
export function safeInlineImageMime(mime: unknown): string | null {
  return INLINE_IMAGE_MIMES[String(mime ?? '').toLowerCase()] ?? null;
}

export interface SendObjectOptions {
  /**
   * Content-Type для браузера. Всегда задаётся сервером, а не берётся из S3/из того,
   * что объявил клиент при загрузке: иначе залитый HTML/SVG исполнится на нашем домене.
   */
  mime: string;
  disposition: 'inline' | 'attachment';
  filename?: string;
  /** Cache-Control; по умолчанию не кэшируем (скачивание личных файлов). */
  cache?: string;
}

/**
 * Отдать объект из S3 через сервис: заголовки (тип, имя, nosniff) ставим сами,
 * Range-запросы клиента пробрасываем в S3 — браузер тогда умеет перематывать видео.
 */
export async function sendObject(
  req: Request,
  res: Response,
  s3: S3Service,
  key: string,
  opts: SendObjectOptions,
): Promise<void> {
  const range = typeof req.headers.range === 'string' ? req.headers.range : undefined;
  const obj = await s3.getObjectStream(key, range);

  res.status(obj.contentRange ? 206 : 200);
  res.setHeader('Content-Type', opts.mime);
  res.setHeader('Content-Disposition', contentDisposition(opts.disposition, opts.filename));
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Accept-Ranges', 'bytes');
  res.setHeader('Cache-Control', opts.cache ?? 'private, no-store');
  if (obj.contentRange) res.setHeader('Content-Range', obj.contentRange);
  if (obj.contentLength != null) res.setHeader('Content-Length', String(obj.contentLength));

  try {
    await pipeline(obj.body as NodeJS.ReadableStream, res);
  } catch {
    // клиент закрыл вкладку/отменил скачивание — заголовки уже ушли, отвечать нечем
    if (!res.writableEnded) res.destroy();
  }
}

/**
 * То же, но отсутствие объекта в S3 превращаем в 404, а не в 500: у части старых
 * ассетов производных нет, и это нормальная ситуация (код ответа уже не отправить
 * после начала стрима — поэтому проверка ошибок только на открытии объекта).
 */
export async function sendObjectOr404(
  req: Request,
  res: Response,
  s3: S3Service,
  key: string,
  opts: SendObjectOptions,
): Promise<void> {
  try {
    await sendObject(req, res, s3, key, opts);
  } catch (e) {
    if (res.headersSent) return;
    const name = (e as { name?: string }).name ?? '';
    const status = name === 'NoSuchKey' || name === 'NotFound' ? 404 : 500;
    res.status(status).end();
  }
}
