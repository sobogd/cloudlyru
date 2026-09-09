import { Module } from '@nestjs/common';
import { UploadsController } from './uploads.controller';
import { UploadsService } from './uploads.service';
import { FilesService } from '../files/files.service';
import { MediaService } from '../media/media.service';

@Module({
  controllers: [UploadsController],
  providers: [UploadsService, FilesService, MediaService],
  exports: [UploadsService],
})
export class UploadsModule {}
