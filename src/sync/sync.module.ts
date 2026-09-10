import { Global, Module } from '@nestjs/common';
import { SyncController } from './sync.controller';
import { SyncService } from './sync.service';
import { ChangesService } from './changes.service';

/**
 * @Global: журнал изменений пишут почти все модули (Folders/Files/Uploads/Dav/Trash/Unzip),
 * поэтому ChangesService доступен везде без импорта — как PrismaService и AuthService.
 */
@Global()
@Module({
  controllers: [SyncController],
  providers: [SyncService, ChangesService],
  exports: [SyncService, ChangesService],
})
export class SyncModule {}
