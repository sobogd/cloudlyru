import { Module } from '@nestjs/common';
import { ChatController } from './chat.controller';
import { ChatsService } from './chats.service';
import { LlmService } from './llm.service';
import { AgentService } from './agent.service';
import { PhoneService } from './phone.service';

/**
 * Раздел «Чат»: чаты, история, поиск с чтением страниц и запросы к модели.
 *
 * Ничего, кроме Prisma, модулю не нужно: модель и агент живут на домашнем маке и видны серверу
 * через reverse-SSH туннель (`LLM_BASE_URL` — 127.0.0.1:18812, `AGENT_URL` — 127.0.0.1:18816).
 * Агент открывает сайты в настоящем Chrome на телефоне: ищет в Google, ищет внутри названного
 * сайта и читает страницы. Клиент приложения ходит только в ручки `/chat/*` и ни адресов
 * туннеля, ни ключей не знает.
 */
@Module({
  controllers: [ChatController],
  providers: [ChatsService, LlmService, PhoneService, AgentService],
})
export class ChatModule {}
