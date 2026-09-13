import { Body, Controller, Get, Param, Post, Query, UseGuards } from '@nestjs/common';
import { MediaFeedService } from './media-feed.service';
import { CurrentUser, RateLimit, RequestUser } from '../common/decorators';
import { RateLimitGuard } from '../common/guards/rate-limit.guard';
import { notFound } from '../common/errors';

/**
 * Ручки раздела «Медиа». Изолированы от «Фото» (`MediaController` / `/timeline`):
 * общее число, срез по смещению и метаданные кадра. Отдача самих превью/оригиналов и
 * удаление — общие низкоуровневые ручки (`/previews/:sha`, `/files/:id`).
 */
@Controller('media')
export class MediaFeedController {
  constructor(private readonly feed: MediaFeedService) {}

  /** Общее число медиа — клиент по нему считает полную высоту скролла. */
  @Get('count')
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  count(@CurrentUser() user: RequestUser) {
    return this.feed.count(user.id);
  }

  /** Срез ленты по смещению: `offset` — позиция, `limit` — сколько взять. */
  @Get('range')
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  range(
    @CurrentUser() user: RequestUser,
    @Query('offset') offset?: string,
    @Query('limit') limit?: string,
  ) {
    const off = Number(offset);
    const lim = Number(limit);
    return this.feed.range(user.id, Number.isFinite(off) ? off : 0, Number.isFinite(lim) ? lim : 300);
  }

  /** Индекс по месяцам — для подписи у ползунка и прыжка к месяцу. */
  @Get('months')
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  months(@CurrentUser() user: RequestUser) {
    return this.feed.months(user.id);
  }

  /** Статусы превью по списку записей: клиент переспрашивает только неготовые снимки. */
  @Post('status')
  @UseGuards(RateLimitGuard)
  @RateLimit(1200, 60_000)
  status(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    const ids = body && typeof body === 'object' ? (body as { entryIds?: unknown }).entryIds : undefined;
    return this.feed.status(user.id, ids);
  }

  /** Метаданные кадра для панели «Инфо»: своя ручка, а не общий /files/:id. */
  @Get(':entryId')
  async info(@Param('entryId') entryId: string, @CurrentUser() user: RequestUser) {
    const info = await this.feed.info(user.id, entryId);
    if (!info) throw notFound('media not found');
    return info;
  }
}
