import { Module } from '@nestjs/common';
import { AiController } from './ai.controller';
import { AiSettingsService } from './ai-settings.service';
import { AgentService } from './agent.service';
import { ChatsService } from './chats.service';
import { LlmService } from './llm.service';
import { SearchService } from './search.service';

/**
 * Раздел «Чат»: чаты, история, поиск и запросы к модели.
 *
 * Сама модель живёт не на сервере, а на домашнем маке: сюда она приходит через reverse-SSH
 * туннель (`LLM_BASE_URL`, по умолчанию 127.0.0.1:18812), поиск — оттуда же (18814), агент на
 * телефоне — тоже оттуда (18816: цикл на маке управляет подключённым по USB телефоном, см.
 * `agents/android-agent/`). Модуль по-прежнему не зависит ни от чего, кроме Prisma: клиент
 * приложения ходит только в наши ручки и ни адресов туннеля, ни ключей не знает.
 */
@Module({
  controllers: [AiController],
  providers: [LlmService, SearchService, AgentService, ChatsService, AiSettingsService],
})
export class AiModule {}
