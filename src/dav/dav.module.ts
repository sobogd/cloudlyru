import { Module } from '@nestjs/common';
import { DavController } from './dav.controller';
import { DavService } from './dav.service';
import { FilesService } from '../files/files.service';
import { MediaService } from '../media/media.service';

@Module({
  controllers: [DavController],
  providers: [DavService, FilesService, MediaService],
})
export class DavModule {}
