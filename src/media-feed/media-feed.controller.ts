import { Body, Controller, Get, Param, Post, Query, UseGuards } from '@nestjs/common';
import { MediaCursor, MediaFeedService } from './media-feed.service';
import { CurrentUser, RateLimit, RequestUser } from '../common/decorators';
import { RateLimitGuard } from '../common/guards/rate-limit.guard';
import { badRequest, notFound } from '../common/errors';

/**
 * Ручки раздела «Медиа»: курсорная лента, разбивка по месяцам, число кадров, статусы превью
 * и метаданные кадра. Отдача самих превью/оригиналов и удаление — общие низкоуровневые ручки
 * (`/previews/:sha`, `/files/:id`).
 */
@Controller('media')
export class MediaFeedController {
  constructor(private readonly feedService: MediaFeedService) {}

  /** Общее число медиа — по нему прогрев миниатюр показывает ход работы. */
  @Get('count')
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  count(@CurrentUser() user: RequestUser) {
    return this.feedService.count(user.id);
  }

  /**
   * Срез ленты по смещению: `offset` — позиция, `limit` — сколько взять. Прокрутка галереи
   * ходит в `feed`; эту ручку зовёт прогрев миниатюр, который идёт по библиотеке страницами.
   */
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
    return this.feedService.range(user.id, Number.isFinite(off) ? off : 0, Number.isFinite(lim) ? lim : 300);
  }

  /**
   * Курсорная лента: страница кадров старше (`before`) или новее (`after`) указанной позиции.
   *
   * Курсор — пара `(at, id)`: `at` — момент съёмки в UTC (ISO), `id` — id записи. Возможные
   * виды курсора:
   *  • `{at: iso, id}` — позиция кадра;
   *  • `{at: iso, id: ''}` — граница момента: строго до/после него, без разрыва ничьих.
   *    Так клиент прыгает к месяцу: `before` = начало следующего месяца в поясе зрителя;
   *  • `{at: null, id: ''}` — начало хвоста ленты, то есть кадров без даты съёмки;
   *  • `{at: null, id}` — позиция кадра в хвосте.
   *
   * `ids` (`?ids=a,b,c`) — выборка конкретных записей без курсора: так синхронизация клиента
   * забирает изменившееся по журналу одним запросом.
   *
   * Объявлена до `:entryId`, иначе «feed» уйдёт в него как id записи.
   */
  @Get('feed')
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  feed(
    @CurrentUser() user: RequestUser,
    @Query('limit') limit?: string,
    @Query('before') before?: string,
    @Query('beforeId') beforeId?: string,
    @Query('after') after?: string,
    @Query('afterId') afterId?: string,
    @Query('ids') ids?: string,
  ) {
    const lim = Number(limit);
    // Пустая строка — это тоже курсор, поэтому отсутствие параметра и пустое значение
    // различаются: `undefined` — курсора нет вовсе, `{at: null}` — курсор без даты (хвост
    // ленты), `{at: iso, id: ''}` — граница месяца: строго до этого момента, без разрыва ничьих.
    const parseCursor = (at?: string, id?: string, label = 'курсор'): MediaCursor | undefined => {
      if (at === undefined) return undefined;
      const entryId = (id ?? '').trim();
      const value = at.trim();
      if (!value) return { at: null, id: entryId };
      const ms = Date.parse(value);
      if (!Number.isFinite(ms)) throw badRequest(`${label}: дата курсора не разобрана`);
      return { at: new Date(ms).toISOString(), id: entryId };
    };
    return this.feedService.feed(user.id, {
      limit: Number.isFinite(lim) ? lim : 200,
      ids: ids ? ids.split(',').map((s) => s.trim()).filter(Boolean) : undefined,
      before: parseCursor(before, beforeId, 'before'),
      after: parseCursor(after, afterId, 'after'),
    });
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
    return this.feedService.months(user.id, Number.isFinite(tzMin) ? tzMin : 0);
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
    return this.feedService.status(user.id, ids);
  }

  /** Геометки всей ленты — для вкладки «Карта». Объявлена до `:entryId`, иначе «map» уйдёт в неё. */
  @Get('map')
  @UseGuards(RateLimitGuard)
  @RateLimit(120, 60_000)
  map(@CurrentUser() user: RequestUser) {
    return this.feedService.mapPoints(user.id);
  }

  /** Метаданные кадра для футера модалки: своя ручка, а не общий /files/:id. */
  @Get(':entryId')
  async info(@Param('entryId') entryId: string, @CurrentUser() user: RequestUser) {
    const info = await this.feedService.info(user.id, entryId);
    if (!info) throw notFound('media not found');
    return info;
  }
}
