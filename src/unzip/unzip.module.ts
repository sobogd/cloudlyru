import { Module } from '@nestjs/common';
import { UnzipController } from './unzip.controller';
import { UnzipService } from './unzip.service';
import { FilesModule } from '../files/files.module';

@Module({
  imports: [FilesModule],
  controllers: [UnzipController],
  providers: [UnzipService],
  exports: [UnzipService],
})
export class UnzipModule {}
