import { Controller, Get, Param, Put, Query, Req, Res } from '@nestjs/common';
import type { Request, Response } from 'express';
import { SharesService } from './shares.service';
import { S3Service } from '../s3/s3.service';
import { Public } from '../common/decorators';
import { sendObjectOr404 } from '../common/http-object';
import { CHUNK_MAX_BYTES } from '../config/env';
import { badRequest, payloadTooLarge } from '../common/errors';

function passwordOf(req: Request): string | undefined {
  const h = req.headers['x-share-password'];
  if (typeof h === 'string' && h.length > 0) return h;
  const q = req.query.password;
  if (typeof q === 'string' && q.length > 0) return q;
  return undefined;
}

/** Публичные (без аккаунта) эндпоинты шаринга. */
@Public()
@Controller('s')
export class SharePublicController {
  constructor(
    private readonly shares: SharesService,
    private readonly s3: S3Service,
  ) {}

  @Get(':token')
  view(@Param('token') token: string, @Req() req: Request) {
    return this.shares.view(token, req.ip ?? 'unknown', passwordOf(req));
  }

  /**
   * Скачивание файла из шаринга. Стримим через сервис: раньше здесь был 302 на
   * presigned-ссылку S3, а такая ссылка ещё 15 минут работает вообще без токена.
   */
  @Get(':token/content/:entryId')
  async content(
    @Param('token') token: string,
    @Param('entryId') entryId: string,
    @Req() req: Request,
    @Res() res: Response,
  ) {
    const { key, name } = await this.shares.content(token, entryId, req.ip ?? 'unknown', passwordOf(req));
    return sendObjectOr404(req, res, this.s3, key, {
      mime: 'application/octet-stream',
      disposition: 'attachment',
      filename: name,
    });
  }

  /** File-drop: PUT сырого тела (≤20 МБ) в расшаренную папку. */
  @Put(':token/upload')
  async upload(
    @Param('token') token: string,
    @Req() req: Request,
    @Query('name') nameQ: unknown,
    @Res({ passthrough: true }) _res: Response,
  ) {
    const name = typeof nameQ === 'string' ? nameQ : '';
    if (!name) throw badRequest('?name= required');
    const cl = Number(req.headers['content-length'] ?? 0);
    if (Number.isFinite(cl) && cl > CHUNK_MAX_BYTES) throw payloadTooLarge('file too large');

    const chunks: Buffer[] = [];
    let total = 0;
    for await (const c of req) {
      const b = Buffer.isBuffer(c) ? c : Buffer.from(c);
      total += b.length;
      if (total > CHUNK_MAX_BYTES) throw payloadTooLarge('file too large');
      chunks.push(b);
    }
    const mime = typeof req.headers['content-type'] === 'string' ? req.headers['content-type'] : 'application/octet-stream';
    return this.shares.upload(token, req.ip ?? 'unknown', name, mime, Buffer.concat(chunks), passwordOf(req));
  }
}
