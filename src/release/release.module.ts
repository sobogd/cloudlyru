import { Module } from '@nestjs/common';
import { ApkController } from './apk.controller';
import { AppReleaseController } from './app-release.controller';
import { ReleaseService } from './release.service';

@Module({
  controllers: [ApkController, AppReleaseController],
  providers: [ReleaseService],
})
export class ReleaseModule {}
