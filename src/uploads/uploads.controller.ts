import { Body, Controller, Delete, Get, Param, Post, Put, Req } from '@nestjs/common';
import type { Request } from 'express';
import { UploadsService } from './uploads.service';
import { CurrentUser, RequestUser } from '../common/decorators';
import { CHUNK_MAX_BYTES } from '../config/env';
import { badRequest, payloadTooLarge } from '../common/errors';

@Controller('uploads')
export class UploadsController {
  constructor(private readonly uploads: UploadsService) {}

  @Post()
  init(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    return this.uploads.init(
      {
        folderId: typeof body.folderId === 'string' ? body.folderId : undefined,
        name: typeof body.name === 'string' ? body.name : '',
        size: typeof body.size === 'number' ? body.size : NaN,
        mime: typeof body.mime === 'string' ? body.mime : 'application/octet-stream',
      },
      user.id,
    );
  }

  @Get(':id')
  status(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.uploads.status(id, user.id);
  }

  /** PUT сырого чанка (application/octet-stream). Части строго последовательны, с resume по статусу. */
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
  complete(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.uploads.complete(id, user.id);
  }

  @Delete(':id')
  abort(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.uploads.abort(id, user.id);
  }
}
