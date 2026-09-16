import { Module } from '@nestjs/common';
import { TrashController } from './trash.controller';
import { TrashService } from './trash.service';
import { RetentionService } from './retention.service';
import { FoldersModule } from '../folders/folders.module';
import { FilesModule } from '../files/files.module';
import { MailModule } from '../mail/mail.module';

/**
 * Модули подключаем, а не перечисляем их сервисы в `providers`: иначе Nest создаёт ВТОРЫЕ
 * экземпляры FilesService и FoldersService (сейчас они без состояния, но у FilesService есть
 * отложенное удаление объектов и свой таймер — с двумя экземплярами оно бы дублировалось и
 * терялось при остановке не того инстанса).
 */
@Module({
  imports: [MailModule, FilesModule, FoldersModule],
  controllers: [TrashController],
  providers: [TrashService, RetentionService],
})
export class TrashModule {}
