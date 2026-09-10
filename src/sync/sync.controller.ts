import { Body, Controller, Get, Post, Query } from '@nestjs/common';
import { SyncService } from './sync.service';
import { CurrentUser, ReadOnlyAllowed, RequestUser } from '../common/decorators';
import { isPlainObject } from '../common/utils';
import { badRequest } from '../common/errors';

/** API синхронизации для клиентов (Android). Авторизация — ApiToken в Bearer. */
@Controller('sync')
export class SyncController {
  constructor(private readonly sync: SyncService) {}

  /** Изменения дерева после курсора: `GET /sync/changes?since=123&limit=200`. */
  @Get('changes')
  changes(
    @Query('since') since: string | undefined,
    @Query('limit') limit: string | undefined,
    @CurrentUser() user: RequestUser,
  ) {
    return this.sync.changes(user.id, since, limit);
  }

  /** Что из перечисленного содержимого уже есть: `{ sha256: [...] }`. Только чтение. */
  @ReadOnlyAllowed()
  @Post('have')
  have(@Body() body: Record<string, unknown> = {}, @CurrentUser() user: RequestUser) {
    if (!isPlainObject(body)) throw badRequest('invalid body');
    return this.sync.have(user.id, body.sha256);
  }
}
