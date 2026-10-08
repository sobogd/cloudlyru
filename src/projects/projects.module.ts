import { Module } from '@nestjs/common';
import { ProjectsController } from './projects.controller';
import { ProjectsActivityService } from './projects-activity.service';
import { ProjectsService } from './projects.service';

/**
 * Раздел «Проекты»: агент (Claude Code или llm-harness) работает в папке проекта на домашнем маке.
 *
 * Модулю не нужно ничего, кроме самого сервиса: проекты, сессии, история и инструменты живут
 * на маке у агентов, а сервер только проксирует ручки `/projects/*` к мосту
 * (`agents/bridge/server.py`), который виден через reverse-SSH туннель как
 * `http://127.0.0.1:18820`, открытый на loopback самим туннелем.
 *
 * Ни базы, ни ключей: клиент приложения не знает ни адреса моста, ни порта туннеля.
 */
@Module({
  controllers: [ProjectsController],
  providers: [ProjectsService, ProjectsActivityService],
})
export class ProjectsModule {}
