import { Module } from '@nestjs/common';
import { ClipboardController } from './clipboard.controller';
import { ClipboardService } from './clipboard.service';
import { FilesModule } from '../files/files.module';
import { FoldersModule } from '../folders/folders.module';

/** Буфер копирования/вырезания переиспользует перенос файла и папки, а не пишет свой. */
@Module({
  imports: [FilesModule, FoldersModule],
  controllers: [ClipboardController],
  providers: [ClipboardService],
})
export class ClipboardModule {}
