import { Module } from '@nestjs/common';
import { DavController } from './dav.controller';
import { DavService } from './dav.service';
import { FilesService } from '../files/files.service';

@Module({
  controllers: [DavController],
  providers: [DavService, FilesService],
})
export class DavModule {}
