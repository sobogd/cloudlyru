import { Module } from '@nestjs/common';
import { NotesController } from './notes.controller';
import { NotesService } from './notes.service';

/**
 * Раздел «Заметки»: короткие тексты с приоритетом.
 *
 * Ничего, кроме Prisma, модулю не нужно: заметки лежат в БД и доступны с любого устройства.
 * Ручки закрыты веб-сессией (`@SessionOnly` в контроллере), device-токен синхронизатора к ним
 * не пускается.
 */
@Module({
  controllers: [NotesController],
  providers: [NotesService],
})
export class NotesModule {}
