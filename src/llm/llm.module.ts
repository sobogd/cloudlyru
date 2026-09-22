import { Module } from '@nestjs/common';
import { LlmService } from './llm.service';

/**
 * Модуль локальной модели на маке (llama.cpp).
 *
 * Отделён от почты намеренно: модель — это общий ресурс (перевод писем сегодня, что-то ещё
 * завтра), и её адрес, бюджет окна и клиент не должны жить внутри раздела, который к ним просто
 * обращается. Модуль не импортирует ничего: у модели нет ни БД, ни файлов — только HTTP.
 */
@Module({
  providers: [LlmService],
  exports: [LlmService],
})
export class LlmModule {}
