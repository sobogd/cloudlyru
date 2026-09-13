import { Module } from '@nestjs/common';
import { MediaFeedController } from './media-feed.controller';
import { MediaFeedService } from './media-feed.service';

/**
 * Раздел «Медиа»: изолированный модуль со своими ручками и SQL.
 * Prisma/Auth глобальные, поэтому импортировать их не нужно.
 */
@Module({
  controllers: [MediaFeedController],
  providers: [MediaFeedService],
})
export class MediaFeedModule {}
