import { Body, Controller, Get, Post, Query, UseGuards } from '@nestjs/common';
import { SyncService } from './sync.service';
import { CurrentUser, RateLimit, ReadOnlyAllowed, RequestUser } from '../common/decorators';
import { isPlainObject } from '../common/utils';
import { RateLimitGuard } from '../common/guards/rate-limit.guard';
import { badRequest } from '../common/errors';

/** API синхронизации для клиентов (Android). Авторизация — ApiToken в Bearer. */
@Controller('sync')
export class SyncController {
  constructor(private readonly sync: SyncService) {}

  /** Изменения дерева после курсора: `GET /sync/changes?since=123&limit=200`. */
  @UseGuards(RateLimitGuard)
  @RateLimit(240, 60_000)
  @Get('changes')
  changes(
    @Query('since') since: string | undefined,
    @Query('limit') limit: string | undefined,
    @CurrentUser() user: RequestUser,
  ) {
    return this.sync.changes(user.id, since, limit);
  }

  /**
   * Голова журнала на текущий момент: клиент включает зеркало так — узнаёт голову, делает
   * полный проход по содержимому папки, потом догоняет журнал с этой головы. Без ручки
   * изменения, случившиеся во время полного прохода, терялись бы.
   */
  @UseGuards(RateLimitGuard)
  @RateLimit(240, 60_000)
  @Get('head')
  head(@CurrentUser() user: RequestUser) {
    return this.sync.head(user.id);
  }

  /** Что из перечисленного содержимого уже есть: `{ sha256: [...] }`. Только чтение. */
  @UseGuards(RateLimitGuard)
  @RateLimit(120, 60_000)
  @ReadOnlyAllowed()
  @Post('have')
  have(@Body() body: Record<string, unknown> = {}, @CurrentUser() user: RequestUser) {
    if (!isPlainObject(body)) throw badRequest('invalid body');
    return this.sync.have(user.id, body.sha256);
  }
}
