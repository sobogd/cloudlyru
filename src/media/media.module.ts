import { Global, Module } from '@nestjs/common';
import { MediaController } from './media.controller';
import { MediaService } from './media.service';
import { AlbumsService } from './albums.service';

/**
 * @Global: MediaService (EXIF/таймлайн) нужен во многих модулях — единый инстанс,
 * как Auth/Queue/Prisma/S3.
 */
@Global()
@Module({
  controllers: [MediaController],
  providers: [MediaService, AlbumsService],
  exports: [MediaService],
})
export class MediaModule {}
