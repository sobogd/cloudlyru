import { Body, Controller, Get, Post } from '@nestjs/common';
import { TrashService } from './trash.service';
import { CurrentUser, RequestUser } from '../common/decorators';
import { isPlainObject } from '../common/utils';
import { badRequest } from '../common/errors';

@Controller('trash')
export class TrashController {
  constructor(private readonly trash: TrashService) {}

  @Get()
  list(@CurrentUser() user: RequestUser) {
    return this.trash.list(user.id);
  }

  @Post('restore')
  restore(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    if (!isPlainObject(body)) throw badRequest('invalid body');
    if (body.type !== 'folder' && body.type !== 'file') throw badRequest('type must be folder|file');
    if (typeof body.id !== 'string') throw badRequest('id required');
    return this.trash.restore(body.type, body.id, user.id);
  }

  @Post('purge')
  purge(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    const days = body && typeof (body as { olderThanDays?: unknown }).olderThanDays === 'number'
      ? (body as { olderThanDays: number }).olderThanDays
      : undefined;
    return this.trash.purge(user.id, days);
  }
}
