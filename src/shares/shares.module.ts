import { Module } from '@nestjs/common';
import { SharesController } from './shares.controller';
import { SharePublicController } from './share-public.controller';
import { SharesService } from './shares.service';
import { FilesService } from '../files/files.service';
import { MediaService } from '../media/media.service';

@Module({
  controllers: [SharesController, SharePublicController],
  providers: [SharesService, FilesService, MediaService],
  exports: [SharesService],
})
export class SharesModule {}
