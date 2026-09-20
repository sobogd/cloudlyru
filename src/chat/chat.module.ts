import { Module } from '@nestjs/common';
import { ChatController } from './chat.controller';
import { ChatsService } from './chats.service';
import { LlmService } from './llm.service';
import { WebSearchService } from './websearch.service';

/**
 * Раздел «Чат»: чаты, история, поиск с чтением страниц и запросы к модели.
 *
 * Ничего, кроме Prisma, модулю не нужно: модель и поиск живут на домашнем маке и видны серверу
 * через reverse-SSH туннель (`LLM_BASE_URL` — 127.0.0.1:18812, `WEBSEARCH_URL` — 127.0.0.1:18814).
 * Клиент приложения ходит только в ручки `/chat/*` и ни адресов туннеля, ни ключей не знает.
 */
@Module({
  controllers: [ChatController],
  providers: [ChatsService, LlmService, WebSearchService],
})
export class ChatModule {}
