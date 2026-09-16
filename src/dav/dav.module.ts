import { Module } from '@nestjs/common';
import { DavController } from './dav.controller';
import { DavService } from './dav.service';
import { FilesModule } from '../files/files.module';
import { MediaModule } from '../media/media.module';

/**
 * FilesService и MediaService берём импортом, а не повторным `providers`: сервис,
 * зарегистрированный в нескольких модулях, живёт в нескольких инстансах, и любое состояние
 * внутри (кэш, лок, таймер) немедленно размножилось бы по ним.
 */
@Module({
  imports: [FilesModule, MediaModule],
  controllers: [DavController],
  providers: [DavService],
})
export class DavModule {}
