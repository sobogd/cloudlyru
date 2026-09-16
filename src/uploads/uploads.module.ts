import { Module } from '@nestjs/common';
import { UploadsController } from './uploads.controller';
import { UploadsService } from './uploads.service';
import { FilesModule } from '../files/files.module';
import { MediaModule } from '../media/media.module';

/**
 * FilesService и MediaService берём из их модулей, а не объявляем провайдерами у себя:
 * повторная регистрация создаёт в этом модуле ВТОРОЙ экземпляр сервиса, и любой кэш, лок
 * или таймер внутри него немедленно размножился бы по инстансам (DavModule делает так же —
 * это его дело). Работает это лишь до первого состояния в сервисе, поэтому импорт модуля.
 */
@Module({
  imports: [FilesModule, MediaModule],
  controllers: [UploadsController],
  providers: [UploadsService],
  exports: [UploadsService],
})
export class UploadsModule {}
