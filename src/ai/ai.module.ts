import { Module } from '@nestjs/common';
import { AiController } from './ai.controller';
import { ChatsService } from './chats.service';
import { GrokService } from './grok.service';

/**
 * Раздел «Чат»: чаты, история и запросы к модели.
 *
 * Провайдер ИИ подключён на стороне сервера (ключ в его окружении), поэтому модуль ни от
 * чего не зависит, кроме Prisma: клиент приложения ходит только в наши ручки.
 */
@Module({
  controllers: [AiController],
  providers: [GrokService, ChatsService],
})
export class AiModule {}
