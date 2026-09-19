import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { badRequest, notFound } from '../common/errors';

/**
 * Роль сообщения в том виде, в каком её понимает API провайдера: эти же имена лежат в колонке
 * `ai_messages.role`, поэтому контекст запроса собирается без перевода ролей.
 */
export type ChatRole = 'system' | 'user' | 'assistant';

/** Модель, которой отвечает новый чат, пока владелец не выбрал другую. */
export const DEFAULT_AI_MODEL = 'grok-4.6';

/** Чат в списке: без сообщений — их подтягивает экран чата. */
export interface ChatSummary {
  id: string;
  title: string;
  model: string;
  updatedAt: Date;
  messages: number;
}

/** Ограничение окна контекста, отправляемого провайдеру. */
const CONTEXT_MESSAGES = 40;
const CONTEXT_CHARS = 60_000;

/**
 * Хранилище чатов и сообщений.
 *
 * Переписка лежит в БД, а не в приложении: одна история на все устройства владельца, и она
 * переживает переустановку. Модель данных описана в `prisma/migrations/20260918140000_ai_chat`.
 *
 * Все методы принимают `userId` и проверяют владельца: ручки чата доступны по id, а id чата
 * приходит из клиента, то есть может быть чужим. Отвечаем 404, а не 403 — существование
 * чужого чата клиенту знать незачем.
 */
@Injectable()
export class ChatsService {
  constructor(private readonly prisma: PrismaService) {}

  /** Чаты владельца, свежие сверху — в том порядке, в каком их показывает список. */
  async list(userId: string): Promise<ChatSummary[]> {
    const rows = await this.prisma.aiChat.findMany({
      where: { userId },
      orderBy: { updatedAt: 'desc' },
      select: {
        id: true,
        title: true,
        model: true,
        updatedAt: true,
        _count: { select: { messages: true } },
      },
    });
    return rows.map((r) => ({
      id: r.id,
      title: r.title,
      model: r.model,
      updatedAt: r.updatedAt,
      messages: r._count.messages,
    }));
  }

  /** Новый чат с выбранной моделью (или моделью по умолчанию). */
  async create(userId: string, model?: unknown) {
    const chosen = typeof model === 'string' && model.trim() ? model.trim() : DEFAULT_AI_MODEL;
    return this.prisma.aiChat.create({
      data: { userId, model: chosen },
      select: { id: true, title: true, model: true, updatedAt: true },
    });
  }

  /** Чат владельца; чужой или несуществующий — 404. */
  async owned(userId: string, chatId: string) {
    const chat = await this.prisma.aiChat.findFirst({ where: { id: chatId, userId } });
    if (!chat) throw notFound('чат не найден');
    return chat;
  }

  /**
   * Правка чата: тема и/или модель.
   *
   * Типы проверяются руками: `ValidationPipe` в проекте не зарегистрирован (см. app.module),
   * а тело приходит из клиента — строка вместо объекта здесь уронила бы Prisma.
   */
  async patch(userId: string, chatId: string, body: Record<string, unknown>) {
    await this.owned(userId, chatId);
    const data: { title?: string; model?: string } = {};
    if (body.title !== undefined) {
      if (typeof body.title !== 'string') throw badRequest('title must be a string');
      const title = body.title.trim();
      if (!title) throw badRequest('title must not be empty');
      data.title = title.slice(0, 200);
    }
    if (body.model !== undefined) {
      if (typeof body.model !== 'string' || !body.model.trim()) throw badRequest('model must be a string');
      data.model = body.model.trim();
    }
    if (Object.keys(data).length === 0) throw badRequest('nothing to update');
    return this.prisma.aiChat.update({
      where: { id: chatId },
      data,
      select: { id: true, title: true, model: true, updatedAt: true },
    });
  }

  /** Удаление чата вместе с сообщениями (каскад в схеме). */
  async remove(userId: string, chatId: string): Promise<void> {
    await this.owned(userId, chatId);
    await this.prisma.aiChat.delete({ where: { id: chatId } });
  }

  /** Сообщения чата в порядке отправки — то, что показывает открытый чат. */
  async messages(userId: string, chatId: string) {
    await this.owned(userId, chatId);
    return this.prisma.aiMessage.findMany({
      where: { chatId },
      orderBy: { createdAt: 'asc' },
      select: {
        id: true,
        role: true,
        content: true,
        reasoning: true,
        promptTokens: true,
        completionTokens: true,
        createdAt: true,
      },
    });
  }

  /**
   * Контекст, который уходит провайдеру: последние сообщения чата.
   *
   * Окно ограничено не из-за размера контекста модели (у `grok-4.6` он 500k токенов), а
   * из-за цены: за отправленную историю платят каждый раз заново, и разговор на сотни
   * сообщений стоил бы дороже самого ответа. Старые сообщения остаются в БД и видны на
   * экране — в запрос они просто не попадают.
   */
  async context(chatId: string): Promise<{ role: ChatRole; content: string }[]> {
    const newestFirst = await this.prisma.aiMessage.findMany({
      where: { chatId },
      orderBy: { createdAt: 'desc' },
      take: CONTEXT_MESSAGES,
      select: { role: true, content: true },
    });
    const picked: { role: ChatRole; content: string }[] = [];
    let chars = 0;
    // идём от свежих к старым и останавливаемся, когда набрался потолок по символам: обрезать
    // надо самое старое, а не самое нужное
    for (const row of newestFirst) {
      chars += row.content.length;
      if (chars > CONTEXT_CHARS && picked.length > 0) break;
      picked.push({ role: this.asRole(row.role), content: row.content });
    }
    // в запрос сообщения уходят в хронологическом порядке
    return picked.reverse();
  }

  /**
   * Роль из БД. Колонка строковая (значения пишет только этот сервис), но тип приводим
   * явно: неизвестное значение из ручной правки БД должно попасть в контекст как роль
   * пользователя, а не уронить запрос к провайдеру.
   */
  private asRole(value: string): ChatRole {
    return value === 'assistant' || value === 'system' ? value : 'user';
  }

  /** Дописывает сообщение и поднимает чат в списке (по `updatedAt` он и сортируется). */
  async append(params: {
    chatId: string;
    role: 'user' | 'assistant';
    content: string;
    reasoning?: string;
    promptTokens?: number | null;
    completionTokens?: number | null;
  }) {
    const created = await this.prisma.aiMessage.create({
      data: {
        chatId: params.chatId,
        role: params.role,
        content: params.content,
        reasoning: params.reasoning ?? '',
        promptTokens: params.promptTokens ?? null,
        completionTokens: params.completionTokens ?? null,
      },
      select: { id: true, role: true, content: true, reasoning: true, createdAt: true },
    });
    await this.prisma.aiChat.update({
      where: { id: params.chatId },
      data: { updatedAt: new Date() },
    });
    return created;
  }

  /**
   * Называет чат по первому вопросу.
   *
   * Своей темы у модели не спрашивают: лишний запрос к платной ручке ради строки в списке.
   * Берём первую строку вопроса и обрезаем по границе слова, чтобы тема влезала в список.
   */
  async retitleFromQuestion(chatId: string, question: string): Promise<string> {
    const firstLine = question.split('\n').find((l) => l.trim()) ?? question;
    const flat = firstLine.trim().replace(/\s+/g, ' ');
    let title = flat.slice(0, 60);
    if (flat.length > 60) {
      // обрезаем по границе слова, но не в самом начале строки: иначе от темы осталось бы
      // одно слово, если первый пробел встретился слишком рано
      const cut = title.lastIndexOf(' ');
      title = `${cut > 20 ? title.slice(0, cut) : title}…`;
    }
    const chat = await this.prisma.aiChat.update({
      where: { id: chatId },
      data: { title: title || 'Новый чат' },
      select: { title: true },
    });
    return chat.title;
  }
}
