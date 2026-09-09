import { Body, Controller, Get, Post } from '@nestjs/common';
import { TrashService } from './trash.service';
import { isPlainObject } from '../common/utils';
import { badRequest } from '../common/errors';

@Controller('trash')
export class TrashController {
  constructor(private readonly trash: TrashService) {}

  @Get()
  list() {
    return this.trash.list();
  }

  @Post('restore')
  restore(@Body() body: Record<string, unknown>) {
    if (!isPlainObject(body)) throw badRequest('invalid body');
    if (body.type !== 'folder' && body.type !== 'file') throw badRequest('type must be folder|file');
    if (typeof body.id !== 'string') throw badRequest('id required');
    return this.trash.restore(body.type, body.id);
  }

  @Post('purge')
  purge(@Body() body: Record<string, unknown>) {
    const days = body && typeof (body as { olderThanDays?: unknown }).olderThanDays === 'number'
      ? (body as { olderThanDays: number }).olderThanDays
      : undefined;
    return this.trash.purge(days);
  }
}
