import { All, Controller, Headers, Req, Res } from '@nestjs/common';
import type { Request, Response } from 'express';
import { DavService } from './dav.service';
import { S3Service } from '../s3/s3.service';
import { Public } from '../common/decorators';
import { safeInlineImageMime, sendObjectOr404 } from '../common/http-object';

const PREFIX = '/api/v1/dav';

function davPathOf(req: Request): string {
  let url = (req.originalUrl || req.url || '/').split('?')[0];
  if (url.startsWith(PREFIX)) url = url.slice(PREFIX.length);
  if (!url.startsWith('/')) url = '/' + url;
  return url;
}

/** WebDAV поверх файлового дерева (Finder/Mac). Basic auth = app-password. */
@Controller('dav')
export class DavController {
  constructor(
    private readonly dav: DavService,
    private readonly s3: S3Service,
  ) {}

  @Public()
  @All('*')
  async handle(@Req() req: Request, @Res() res: Response, @Headers('depth') depth: string | undefined) {
    const davPath = davPathOf(req);
    const method = (req.method || 'GET').toUpperCase();
    try {
      const { userId, scope } = await this.dav.authenticate(req);
      const WRITE = ['MKCOL', 'PUT', 'DELETE', 'MOVE', 'COPY', 'PROPPATCH'];
      if (WRITE.includes(method) && !scope.endsWith(':rw')) {
        return res.status(403).end();
      }

      switch (method) {
        case 'OPTIONS': {
          res.setHeader('Allow', 'PROPFIND, MKCOL, GET, HEAD, PUT, DELETE, MOVE, OPTIONS, LOCK, UNLOCK');
          res.setHeader('DAV', '1, 2');
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
          if (typeof dest !== 'string') throw new Error('no destination');
          const dstPath = '/' + decodeURIComponent(dest.split('/').slice(4).join('/'));
          return res.status(await this.dav.move(userId, davPath, dstPath)).end();
        }
        case 'LOCK':
        case 'UNLOCK':
          // минимальная поддержка: считаем залоченным/разлоченным без реальных блокировок
          return res.status(200).end();
        default:
          return res.status(405).end();
      }
    } catch (e) {
      const status = (e as { status?: number }).status ?? (e as { statusCode?: number }).statusCode ?? 500;
      if (status === 401 || (e as Error).message.includes('Basic auth') || (e as Error).message.includes('invalid token')) {
        res.setHeader('WWW-Authenticate', 'Basic realm="cloudlyru"');
        return res.status(401).end();
      }
      if (status === 404) return res.status(404).end();
      if (status === 400) return res.status(400).end();
      if (status === 409) return res.status(409).end();
      return res.status(500).end();
    }
  }
}
