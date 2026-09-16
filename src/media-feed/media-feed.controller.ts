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

  /**
   * Индекс по месяцам — для подписи у ползунка и прыжка к месяцу.
   *
   * `tz` — сдвиг пояса клиента в минутах на восток от UTC (Москва: `tz=180`). Месяц считается
   * в поясе клиента, иначе кадр, снятый 01.01 в 01:30 +03:00, попадал в бакет предыдущего
   * месяца, хотя в просмотрщике дата 01.01. Без параметра — UTC, как было до этой правки.
   */
  @Get('months')
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  months(@CurrentUser() user: RequestUser, @Query('tz') tz?: string) {
    const tzMin = Number(tz);
    return this.feed.months(user.id, Number.isFinite(tzMin) ? tzMin : 0);
  }

  /**
   * Статусы превью по списку записей: клиент переспрашивает только неготовые снимки.
   * Список сверх MEDIA_STATUS_MAX обрезается (в логе предупреждение), поэтому присылать
   * id нужно пачками не больше этого числа.
   */
  @Post('status')
  @UseGuards(RateLimitGuard)
  @RateLimit(1200, 60_000)
  status(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    const ids = body && typeof body === 'object' ? (body as { entryIds?: unknown }).entryIds : undefined;
    return this.feed.status(user.id, ids);
  }

  /** Геометки всей ленты — для вкладки «Карта». Объявлена до `:entryId`, иначе «map» уйдёт в неё. */
  @Get('map')
  @UseGuards(RateLimitGuard)
  @RateLimit(120, 60_000)
  map(@CurrentUser() user: RequestUser) {
    return this.feed.mapPoints(user.id);
  }

  /** Метаданные кадра для футера модалки: своя ручка, а не общий /files/:id. */
  @Get(':entryId')
  async info(@Param('entryId') entryId: string, @CurrentUser() user: RequestUser) {
    const info = await this.feed.info(user.id, entryId);
    if (!info) throw notFound('media not found');
    return info;
  }
}
