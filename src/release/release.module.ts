import { Module } from '@nestjs/common';
import { AppReleaseController, AppReleaseMacosController } from './app-release.controller';
import { ReleaseDownloadController } from './download.controller';
import { ReleaseService } from './release.service';

@Module({
  controllers: [ReleaseDownloadController, AppReleaseController, AppReleaseMacosController],
  providers: [ReleaseService],
})
export class ReleaseModule {}
