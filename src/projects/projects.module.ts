import { Module } from '@nestjs/common';
import { ProjectsController } from './projects.controller';
import { ProjectsService } from './projects.service';

/**
 * Раздел «Проекты»: агент pi работает в папке проекта на домашнем маке.
 *
 * Модулю не нужно ничего, кроме самого сервиса: проекты, сессии, история и инструменты живут
 * на маке у pi, а сервер только проксирует ручки `/projects/*` к мосту
 * (`agents/pi-bridge/server.py`), который виден через reverse-SSH туннель как
 * `http://127.0.0.1:18820` — как поиск (18814) и телефон (18816) у раздела «Чат».
 *
 * Ни базы, ни ключей: клиент приложения не знает ни адреса моста, ни порта туннеля.
 */
@Module({
  controllers: [ProjectsController],
  providers: [ProjectsService],
})
export class ProjectsModule {}
