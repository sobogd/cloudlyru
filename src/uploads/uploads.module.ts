import { Module } from '@nestjs/common';
import { UploadsController } from './uploads.controller';
import { UploadsService } from './uploads.service';
import { FilesService } from '../files/files.service';

@Module({
  controllers: [UploadsController],
  providers: [UploadsService, FilesService],
  exports: [UploadsService],
})
export class UploadsModule {}
