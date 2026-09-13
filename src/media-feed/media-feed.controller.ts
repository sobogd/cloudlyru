import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { MediaFeedService } from './media-feed.service';
import { CurrentUser, RateLimit, RequestUser } from '../common/decorators';
import { RateLimitGuard } from '../common/guards/rate-limit.guard';

/**
 * Ручки раздела «Медиа». Изолированы от «Фото» (`MediaController` / `/timeline`):
 * здесь только лента и окно просмотра. Отдача самих превью/оригиналов и удаление —
 * общие низкоуровневые ручки (`/previews/:sha`, `/files/:id`), они к разделу не относятся.
 */
@Controller('media')
export class MediaFeedController {
  constructor(private readonly feed: MediaFeedService) {}

  /** Страница ленты: `limit` — размер, `cursor` — entryId последней показанной записи. */
  @Get('timeline')
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  timeline(
    @CurrentUser() user: RequestUser,
    @Query('limit') limit?: string,
    @Query('cursor') cursor?: string,
  ) {
    const lim = limit ? Number(limit) : 300;
    return this.feed.timeline(
      user.id,
      Number.isFinite(lim) ? lim : 300,
      typeof cursor === 'string' && cursor ? cursor : undefined,
    );
  }

  /** Окно вокруг кадра для полноэкранного просмотра: `before` новее, `after` старее. */
  @Get('window')
  @UseGuards(RateLimitGuard)
  @RateLimit(1200, 60_000)
  window(
    @CurrentUser() user: RequestUser,
    @Query('entryId') entryId?: string,
    @Query('before') before?: string,
    @Query('after') after?: string,
  ) {
    return this.feed.window(
      user.id,
      typeof entryId === 'string' && entryId ? entryId : undefined,
      before,
      after,
    );
  }
}
