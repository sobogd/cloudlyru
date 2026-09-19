import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';

/** Ограничение длины памяти в символах. */
const MEMORY_MAX_CHARS = 20_000;

/**
 * Настройки раздела «Чат»: память владельца.
 *
 * Память — свободный текст, который подмешивается в системную часть каждого запроса
 * (`src/ai/prompts.ts`). Так модель знает контекст («живу в Испании», «мой стек — Flutter и
 * NestJS», «отвечай без вступлений») без того, чтобы повторять это в каждом разговоре.
 *
 * Хранится строкой на пользователя; строки нет — значит память пустая, и создавать её заранее
 * не нужно: запись появляется при первом сохранении.
 */
@Injectable()
export class AiSettingsService {
  constructor(private readonly prisma: PrismaService) {}

  /** Память владельца (пустая строка, если он её ещё не заполнял). */
  async memory(userId: string): Promise<string> {
    const row = await this.prisma.aiSettings.findUnique({
      where: { userId },
      select: { memory: true },
    });
    return row?.memory ?? '';
  }

  /**
   * Записывает память владельца и возвращает её же в сохранённом виде.
   *
   * Обрезаем по потолку символов: память уходит в каждый запрос, то есть оплачивается на каждом
   * сообщении. Двадцать тысяч символов — это уже очень много личного контекста, а всё, что
   * сверх, раздувало бы счёт незаметно для человека.
   */
  async saveMemory(userId: string, memory: string): Promise<string> {
    const value = memory.slice(0, MEMORY_MAX_CHARS);
    const row = await this.prisma.aiSettings.upsert({
      where: { userId },
      create: { userId, memory: value },
      update: { memory: value },
      select: { memory: true },
    });
    return row.memory;
  }
}
