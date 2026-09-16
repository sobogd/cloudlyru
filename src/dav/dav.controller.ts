import { All, Controller, Headers, Logger, Req, Res } from '@nestjs/common';
import type { Request, Response } from 'express';
import { DavService } from './dav.service';
import { S3Service } from '../s3/s3.service';
import { Public } from '../common/decorators';
import { badRequest } from '../common/errors';
import { safeInlineImageMime, sendObjectOr404 } from '../common/http-object';

/**
 * Монтирование WebDAV: единственная точка, где префикс API указан в этом модуле. Обязан
 * совпадать с `setGlobalPrefix('api/v1')` в main.ts (оттуда его не импортировать — там
 * литерал). `req.baseUrl` тут не помогает: Nest регистрирует маршруты прямо на приложении
 * с полным путём (`routerMethodRef(path, handler)` в router-explorer), поэтому baseUrl пуст.
 */
const API_PREFIX = '/api/v1/dav';

/** Статусы, которые WebDAV-клиенты понимают: отдаём как есть, а не превращаем в 500. */
const DAV_STATUSES = new Set([400, 403, 404, 405, 409, 412, 413, 423, 507]);

/**
 * Путь запроса без префикса API.
 *
 * КОНТРАКТ КОДИРОВАНИЯ: клиент (Finder, rclone, ОС) присылает путь percent-encoded
 * (`/%D1%84%D0%BE%D1%82%D0%BE/a%20b.txt`), а href'ы мы отдаём ему тоже закодированными
 * (`encodeURIComponent` в propfind), и он возвращает ровно их. Express отдаёт
 * `originalUrl`/`url` в исходном (закодированном) виде, nginx (`proxy_pass` без URI)
 * передаёт запрос как есть. Поэтому путь декодируется РОВНО ОДИН РАЗ — в `decodeDavPath`.
 */
function davPathOf(req: Request): string {
  let url = (req.originalUrl || req.url || '/').split('?')[0];
  if (url.startsWith(API_PREFIX)) url = url.slice(API_PREFIX.length);
  if (!url.startsWith('/')) url = '/' + url;
  return url;
}

/**
 * Декодировать путь один раз. Раньше декодирование было точечным: `mkcol`/`put`/`move`
 * разбирали только последний сегмент, `delete` — вовсе нет, а родительские сегменты —
 * никогда. Из-за этого папка с пробелом или кириллицей не находилась (404) на
 * GET/HEAD/PROPFIND/DELETE, хотя запись в корень с таким же именем работала.
 */
function decodeDavPath(raw: string): string {
  try {
    return decodeURIComponent(raw);
  } catch {
    // «плохой» процент (`%zz`) — ошибка клиента, а не сбой сервера: 400, а не 500
    throw badRequest('некорректное кодирование пути');
  }
}

/** WebDAV поверх файлового дерева (Finder/Mac). Basic auth = app-password. */
@Controller('dav')
export class DavController {
  private readonly logger = new Logger('Dav');

  constructor(
    private readonly dav: DavService,
    private readonly s3: S3Service,
  ) {}

  @Public()
  @All('*')
  async handle(@Req() req: Request, @Res() res: Response, @Headers('depth') depth: string | undefined) {
    const method = (req.method || 'GET').toUpperCase();
    let davPath = '';
    try {
      // сначала авторизация, потом разбор пути: неаутентифицированный клиент не должен
      // получать разницу между «плохой путь» и «плохой токен»
      const { userId, scope } = await this.dav.authenticate(req);
      davPath = decodeDavPath(davPathOf(req));
      // COPY и PROPPATCH не реализованы (уходят в 405 ниже) — в списке «пишущих» им делать
      // нечего, иначе они попадали бы в 403 вместо честного 405 и висели бы в Allow
      const WRITE = ['MKCOL', 'PUT', 'DELETE', 'MOVE'];
      if (WRITE.includes(method) && !scope.endsWith(':rw')) {
        return res.status(403).end();
      }

      switch (method) {
        case 'OPTIONS': {
          res.setHeader('Allow', 'OPTIONS, PROPFIND, MKCOL, GET, HEAD, PUT, DELETE, MOVE, LOCK, UNLOCK');
          // DAV: 1 (без класса 2): класс 2 — это честные блокировки, а их у нас нет
          // (см. LOCK/UNLOCK ниже). Заявляя класс 2, мы обещали клиентам то, чего не делаем:
          // Finder и офисные редакторы полагались на локи при конкурентной записи.
          res.setHeader('DAV', '1');
          res.setHeader('MS-Author-Via', 'DAV');
          return res.status(200).end();
        }
        case 'PROPFIND': {
          const xml = await this.dav.propfind(userId, davPath, depth || '1');
          res.setHeader('Content-Type', 'application/xml; charset=utf-8');
          res.setHeader('DAV', '1');
          return res.status(207).send(xml);
        }
        case 'MKCOL':
          return res.status(await this.dav.mkcol(userId, davPath)).end();
        case 'PUT': {
          const clRaw = req.headers['content-length'];
          const cl = clRaw ? Number(clRaw) : null;
          const ct = (req.headers['content-type'] as string) || 'application/octet-stream';
          const status = await this.dav.put(userId, davPath, req, cl, ct);
          return res.status(status).end();
        }
        case 'GET': {
          const { key, mime, name } = await this.dav.getContent(userId, davPath);
          // inline только для безопасных картинок: HTML/SVG, отданный inline с нашего
          // домена, исполнился бы в браузере с сохранёнными Basic-кредами
          const safe = safeInlineImageMime(mime);
          return sendObjectOr404(req, res, this.s3, key, safe
            ? { mime: safe, disposition: 'inline', filename: name }
            : { mime: 'application/octet-stream', disposition: 'attachment', filename: name });
        }
        case 'HEAD': {
          const meta = await this.dav.headMeta(userId, davPath);
          res.setHeader('Content-Length', String(meta.size));
          res.setHeader('Content-Type', meta.mime);
          return res.status(200).end();
        }
        case 'DELETE':
          return res.status(await this.dav.delete(userId, davPath)).end();
        case 'MOVE': {
          const dest = req.headers['destination'];
          // 400, а не 500: заголовка нет или он пуст — это ошибка запроса
          if (typeof dest !== 'string' || !dest) throw badRequest('MOVE без заголовка Destination');
          // Destination — абсолютный URL (RFC 4918): разбираем путь, а не режем сегменты наугад
          let rawPath: string;
          try {
            rawPath = new URL(dest).pathname;
          } catch {
            rawPath = dest;
          }
          const prefixIdx = rawPath.indexOf(API_PREFIX);
          const davPart = prefixIdx >= 0 ? rawPath.slice(prefixIdx + API_PREFIX.length) : rawPath;
          // `URL.pathname` остаётся закодированным — декодируем тем же правилом, что и путь запроса
          const dstPath = decodeDavPath('/' + davPart.replace(/^\/+/, ''));
          return res.status(await this.dav.move(userId, davPath, dstPath)).end();
        }
        case 'LOCK':
        case 'UNLOCK':
          // Реальных блокировок нет: отвечаем 200 «считаем залоченным», чтобы Finder и
          // офисные редакторы не отказывались писать (RFC 4918 разрешает и 501, но тогда
          // клиент считает ресурс недоступным для записи). Заголовок `DAV: 1, 2` при этом
          // не выставляем — клиенты не должны полагаться на локи, которых нет.
          return res.status(200).end();
        default:
          return res.status(405).end();
      }
    } catch (e) {
      // WebDAV-клиент показывает пользователю только «не удалось», поэтому диагноз должен
      // попадать в лог: метод, путь и причина. Токен не логируем — он в заголовке Authorization.
      const err = e as { status?: unknown; statusCode?: unknown } | null | undefined;
      const status =
        typeof err?.status === 'number' ? err.status : typeof err?.statusCode === 'number' ? err.statusCode : 500;
      const message = e instanceof Error ? e.message : String(e);
      if (status >= 500) this.logger.error(`${method} ${davPath} → ${status}: ${message}`);
      else this.logger.warn(`${method} ${davPath} → ${status}: ${message}`);
      if (status === 401 || message.includes('Basic auth') || message.includes('invalid token')) {
        res.setHeader('WWW-Authenticate', 'Basic realm="cloudlyru"');
        return res.status(401).end();
      }
      if (DAV_STATUSES.has(status)) return res.status(status).end();
      return res.status(500).end();
    }
  }
}
