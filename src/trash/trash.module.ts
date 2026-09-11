import { Module } from '@nestjs/common';
import { TrashController } from './trash.controller';
import { TrashService } from './trash.service';
import { RetentionService } from './retention.service';
import { FoldersService } from '../folders/folders.service';
import { FilesService } from '../files/files.service';

@Module({
  controllers: [TrashController],
  providers: [TrashService, RetentionService, FoldersService, FilesService],
})
export class TrashModule {}
