import { Module } from '@nestjs/common';
import { MediaController } from './media.controller';
import { MediaService } from './media.service';
import { AlbumsService } from './albums.service';

@Module({
  controllers: [MediaController],
  providers: [MediaService, AlbumsService],
  exports: [MediaService],
})
export class MediaModule {}
