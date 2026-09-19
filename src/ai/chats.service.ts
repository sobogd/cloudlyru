import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { badRequest, notFound } from '../common/errors';
import { env } from '../config/env';

/**
 * Роль сообщения в том виде, в каком её понимает API модели: эти же имена лежат в колонке
 * `ai_messages.role`, поэтому контекст запроса собирается без перевода ролей.
 */
export type ChatRole = 'system' | 'user' | 'assistant';

/**
 * Модель, которой отвечает новый чат, пока владелец не выбрал другую.
 *
 * Значение берётся из окружения (`LLM_MODEL`), а не вписано строкой: идентификатор модели —
 * это то, что отдаёт LM Studio в `GET /api/v0/models`, и он меняется вместе с квантом или
 * каталогом модели на маке. Держать его в коде значило бы править и пересобирать сервер при
 * каждой смене файла модели на домашней машине.
 */
export const DEFAULT_AI_MODEL = env.LLM_MODEL.trim();

/** Чат в списке: без сообщений — их подтягивает экран чата. */
export interface ChatSummary {
  id: string;
  title: string;
  model: string;
  updatedAt: Date;
  messages: number;
}

/**
 * Окно истории, отправляемой модели, когда компакции ещё нет.
 *
 * Считано по скорости мака, а не по размеру контекста модели. У Gemma 4 контекст 128k токенов,
 * но префилл на M1 Pro идёт около 300 токенов в секунду (замер), а в русском тексте примерно
 * три символа на токен — то есть 24 000 символов это ~8000 токенов и ~27 секунд до первого
 * слова, если кэш префикса пуст. Прежние шестьдесят тысяч символов давали больше минуты на
 * каждый первый ответ в разговоре — за это время человек уходит с экрана.
 *
 * Сообщений двадцать: при среднем сообщении в сотню символов потолок по символам наступает
 * раньше, а этот лимит страхует от разговора из длинных «простыней».
 */
const CONTEXT_MESSAGES = 20;
const CONTEXT_CHARS = 24_000;

/**
 * Порог, после которого разговор сжимается (символы истории).
 *
 * Вдвое ниже окна контекста: компакция — это отдельная генерация на маке, и запускать её в тот
 * момент, когда история уже не влезает в окно, значит гарантированно получить несколько
 * медленных ответов до сжатия. Двенадцать тысяч символов — примерно четыре тысячи токенов
 * префилла, то есть около пятнадцати секунд, и сжатие окупается уже на втором ответе после него.
 */
export const COMPACT_AFTER_CHARS = 12_000;

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

  /**
   * Сохранённая выжимка разговора или `null`, если разговор ещё не сжимали.
   *
   * Выжимку пишет та же локальная модель (см. `LlmService.compact`) и уходит она в следующий
   * запрос обычным сообщением — разбирать её не нужно, дополнять тоже: она заменяет историю
   * целиком. Идентификатор блока остаётся ради логов и ради того, чтобы отличать «сжали один
   * раз» от «сжали заново».
   */
  async compaction(chatId: string): Promise<{ id: string; blob: string; upToAt: Date } | null> {
    const row = await this.prisma.aiChat.findUnique({
      where: { id: chatId },
      select: { compactionId: true, compactionBlob: true, compactedUpToAt: true },
    });
    if (!row?.compactionId || !row.compactionBlob || !row.compactedUpToAt) return null;
    return { id: row.compactionId, blob: row.compactionBlob, upToAt: row.compactedUpToAt };
  }

  /** Запоминает результат компакции: выжимку и границу, до которой сообщения внутри неё. */
  async saveCompaction(chatId: string, id: string, blob: string, upToAt: Date): Promise<void> {
    await this.prisma.aiChat.update({
      where: { id: chatId },
      data: { compactionId: id, compactionBlob: blob, compactedUpToAt: upToAt },
    });
  }

  /**
   * Сообщения, созданные позже указанного момента, — «хвост» после компакции.
   *
   * Окно здесь не ограничиваем: истории в хвосте ровно столько, сколько накопилось после
   * последнего сжатия, и она всё равно меньше порога, по которому сжатие запускается.
   */
  async messagesAfter(chatId: string, after: Date): Promise<{ role: ChatRole; content: string }[]> {
    const rows = await this.prisma.aiMessage.findMany({
      where: { chatId, createdAt: { gt: after } },
      orderBy: { createdAt: 'asc' },
      select: { role: true, content: true },
    });
    return rows.map((r) => ({ role: this.asRole(r.role), content: r.content }));
  }

  /**
   * Вся переписка чата вместе с системной частью — то, что уходит в компакцию.
   *
   * В компакцию отдаём разговор целиком, а не окно: смысл в том, чтобы сжать как раз то, что
   * иначе пересылалось бы в каждом следующем запросе.
   */
  async fullHistory(chatId: string): Promise<{ role: ChatRole; content: string }[]> {
    const rows = await this.prisma.aiMessage.findMany({
      where: { chatId },
      orderBy: { createdAt: 'asc' },
      select: { role: true, content: true },
    });
    return rows.map((r) => ({ role: this.asRole(r.role), content: r.content }));
  }

  /** Время последнего сообщения чата — граница компакции. */
  async lastMessageAt(chatId: string): Promise<Date | null> {
    const row = await this.prisma.aiMessage.findFirst({
      where: { chatId },
      orderBy: { createdAt: 'desc' },
      select: { createdAt: true },
    });
    return row?.createdAt ?? null;
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
        costUsd: true,
        createdAt: true,
      },
    });
  }

  /**
   * Контекст, который уходит модели: последние сообщения чата.
   *
   * Окно ограничено не размером контекста модели (у Gemma 4 это 128k токенов), а временем:
   * префилл на маке идёт около 300 токенов в секунду, и за отправленную историю платят именно
   * ожиданием. Старые сообщения остаются в БД и видны на экране — в запрос они просто не
   * попадают.
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
    costUsd?: number | null;
  }) {
    const created = await this.prisma.aiMessage.create({
      data: {
        chatId: params.chatId,
        role: params.role,
        content: params.content,
        reasoning: params.reasoning ?? '',
        promptTokens: params.promptTokens ?? null,
        completionTokens: params.completionTokens ?? null,
        costUsd: params.costUsd ?? null,
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
