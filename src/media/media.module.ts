import { Global, Module } from '@nestjs/common';
import { MediaController } from './media.controller';
import { MediaService } from './media.service';

/**
 * @Global: MediaService (EXIF/таймлайн) нужен во многих модулях — единый инстанс,
 * как Auth/Queue/Prisma/S3.
 */
@Global()
@Module({
  controllers: [MediaController],
  providers: [MediaService],
  exports: [MediaService],
})
export class MediaModule {}
