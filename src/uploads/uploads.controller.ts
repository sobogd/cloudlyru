import { Body, Controller, Delete, Get, Param, Post, Put, Req, UseGuards } from '@nestjs/common';
import type { Request } from 'express';
import { UploadsService } from './uploads.service';
import { CurrentUser, RateLimit, RequestUser } from '../common/decorators';
import { RateLimitGuard } from '../common/guards/rate-limit.guard';
import { CHUNK_MAX_BYTES } from '../config/env';
import { badRequest, payloadTooLarge } from '../common/errors';

@Controller('uploads')
export class UploadsController {
  constructor(private readonly uploads: UploadsService) {}

  /**
   * Начать загрузку. Если клиент прислал sha256 уже существующего объекта, сервер сразу
   * создаёт запись в дереве (`deduped: true`, `uploadId: null`) — байты не передаются вообще.
   *
   * Ограничение частоты — только на init (создание multipart-сессии в S3 и строки в БД):
   * окно щедрое, потому что это защита от цикла запросов, а не бюджет загрузок. Части и
   * `complete` лимита не требуют: их число ограничено размером файла и проверками частей.
   */
  @Post()
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  init(@Body() body: Record<string, unknown> = {}, @CurrentUser() user: RequestUser) {
    return this.uploads.init(
      {
        folderId: typeof body.folderId === 'string' ? body.folderId : undefined,
        name: typeof body.name === 'string' ? body.name : '',
        size: typeof body.size === 'number' ? body.size : NaN,
        mime: typeof body.mime === 'string' ? body.mime : 'application/octet-stream',
        sha256: typeof body.sha256 === 'string' ? body.sha256 : undefined,
        // Перезапись существующего имени и mtime с устройства — часть контракта синхронизации
        // (контроллер собирает тело руками, поэтому поля надо перечислить здесь явно).
        replace: body.replace === true || body.replace === 'true',
        // имя занято своей же записью из корзины: клиент синхронизации просит занять его,
        // иначе файл с таким именем не уезжает в облако никогда (409 in_trash)
        replaceTrashed: body.replaceTrashed === true || body.replaceTrashed === 'true',
        clientMtime: typeof body.clientMtime === 'string' || body.clientMtime === null ? body.clientMtime : undefined,
        // оптимистичная блокировка: какую версию файла клиент заменяет
        expectedSha256: typeof body.expectedSha256 === 'string' || body.expectedSha256 === null ? body.expectedSha256 : undefined,
        expectedUpdatedAt:
          typeof body.expectedUpdatedAt === 'string' || body.expectedUpdatedAt === null
            ? body.expectedUpdatedAt
            : undefined,
        // Клиенты, не знающие про прямую загрузку (скрипты, старые версии), льют чанки
        // через сервер — это релей-режим, он и остаётся поведением по умолчанию.
        mode: body.mode === 'direct' ? 'direct' : 'relay',
      },
      user.id,
    );
  }

  @Get(':id')
  status(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.uploads.status(id, user.id);
  }

  /** Presigned-ссылка на одну часть: по ней браузер заливает байты прямо в S3. */
  @Get(':id/url/:part')
  partUrl(
    @Param('id') id: string,
    @Param('part') part: string,
    @CurrentUser() user: RequestUser,
  ) {
    const partNumber = Number(part);
    if (!Number.isInteger(partNumber) || partNumber <= 0) throw badRequest('invalid part number');
    return this.uploads.partUrl(id, partNumber, user.id);
  }

  /** ETag части, залитой напрямую в S3 (сервер собирает multipart по этим ETag'ам). */
  @Put(':id/parts/:part')
  registerPart(
    @Param('id') id: string,
    @Param('part') part: string,
    @Body() body: Record<string, unknown> = {},
    @CurrentUser() user: RequestUser,
  ) {
    const partNumber = Number(part);
    if (!Number.isInteger(partNumber) || partNumber <= 0) throw badRequest('invalid part number');
    return this.uploads.registerPart(id, partNumber, body.etag, body.size, user.id);
  }

  /** Чанк через сервер (application/octet-stream) — фолбэк, если браузер не может ходить в S3. */
  @Put(':id/chunks/:part')
  async chunk(
    @Param('id') id: string,
    @Param('part') part: string,
    @Req() req: Request,
    @CurrentUser() user: RequestUser,
  ) {
    const partNumber = Number(part);
    if (!Number.isInteger(partNumber) || partNumber <= 0) throw badRequest('invalid part number');

    const contentLength = Number(req.headers['content-length'] ?? 0);
    if (Number.isFinite(contentLength) && contentLength > CHUNK_MAX_BYTES) {
      throw payloadTooLarge('chunk too large');
    }

    const chunks: Buffer[] = [];
    let total = 0;
    for await (const c of req) {
      const b = Buffer.isBuffer(c) ? c : Buffer.from(c);
      total += b.length;
      if (total > CHUNK_MAX_BYTES) throw payloadTooLarge('chunk too large');
      chunks.push(b);
    }

    return this.uploads.putChunk(id, partNumber, Buffer.concat(chunks), user.id);
  }

  @Post(':id/complete')
  complete(
    @Param('id') id: string,
    @Body() body: Record<string, unknown> = {},
    @CurrentUser() user: RequestUser,
  ) {
    return this.uploads.complete(id, user.id, {
      sha256: typeof body.sha256 === 'string' ? body.sha256 : undefined,
    });
  }

  @Delete(':id')
  abort(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.uploads.abort(id, user.id);
  }
}
