import { Injectable, Logger } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { notFound } from '../common/errors';
import { LlmMessage, LlmRole, LlmService } from './llm.service';
import { COMPACT_AFTER_CHARS, COMPACT_HEADER, COMPACT_PROMPT } from './prompts';

/** Сколько последних сообщений вообще попадает в запрос: остальное живёт в выжимке. */
const MAX_HISTORY_MESSAGES = 20;

/** Сколько символов первого вопроса становится темой чата. */
const TITLE_CHARS = 60;

/** Чат в списке: без сообщений — их подтягивает экран чата. */
export interface ChatSummary {
  id: string;
  title: string;
  model: string;
  updatedAt: Date;
  messages: number;
}

/** Источник ответа в том виде, в каком он уходит приложению. */
export interface SourceView {
  position: number;
  title: string;
  url: string;
  read: boolean;
  chars: number;
}

/** Сообщение чата для экрана: вопрос человека или ответ модели вместе с его источниками. */
export interface MessageView {
  id: string;
  role: string;
  content: string;
  reasoning: string;
  searchQuery: string | null;
  promptTokens: number | null;
  completionTokens: number | null;
  createdAt: Date;
  sources: SourceView[];
}

/**
 * Хранилище раздела «Чат»: чаты, сообщения, источники, память владельца и сборка контекста.
 *
 * Отдельный сервис, а не работа с Prisma прямо из контроллера: у раздела два неочевидных
 * правила — история перед отправкой сжимается, а источники ответа сохраняются вместе с ним, —
 * и оба обязаны быть в одном месте, иначе они разъедутся между ручками.
 */
@Injectable()
export class ChatsService {
  private readonly logger = new Logger(ChatsService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly llm: LlmService,
  ) {}

  /** Список чатов владельца, свежие сверху. */
  async list(userId: string): Promise<ChatSummary[]> {
    const chats = await this.prisma.chat.findMany({
      where: { userId },
      orderBy: { updatedAt: 'desc' },
      include: { _count: { select: { messages: true } } },
    });
    return chats.map((chat) => ({
      id: chat.id,
      title: chat.title,
      model: chat.model,
      updatedAt: chat.updatedAt,
      messages: chat._count.messages,
    }));
  }

  /** Создаёт пустой чат: тема появится из первого вопроса. */
  async create(userId: string): Promise<ChatSummary> {
    const chat = await this.prisma.chat.create({
      data: { userId, model: this.llm.defaultModel },
    });
    return {
      id: chat.id,
      title: chat.title,
      model: chat.model,
      updatedAt: chat.updatedAt,
      messages: 0,
    };
  }

  /** Переименование чата вручную — на случай, когда выведенная из вопроса тема не подошла. */
  async rename(userId: string, chatId: string, title: string): Promise<ChatSummary> {
    await this.owned(userId, chatId);
    const chat = await this.prisma.chat.update({
      where: { id: chatId },
      data: { title: title.trim().slice(0, TITLE_CHARS) || 'Новый чат' },
      include: { _count: { select: { messages: true } } },
    });
    return {
      id: chat.id,
      title: chat.title,
      model: chat.model,
      updatedAt: chat.updatedAt,
      messages: chat._count.messages,
    };
  }

  /** Удаление чата вместе с сообщениями и источниками (каскадом в схеме). */
  async remove(userId: string, chatId: string): Promise<void> {
    await this.owned(userId, chatId);
    await this.prisma.chat.delete({ where: { id: chatId } });
  }

  /**
   * Чат владельца или 404.
   *
   * Проверка владельца обязательна и делается здесь, а не в контроллере: идентификатор чата
   * приходит от клиента, и без неё чужой чат читался бы по угаданному uuid.
   */
  async owned(userId: string, chatId: string) {
    const chat = await this.prisma.chat.findFirst({ where: { id: chatId, userId } });
    if (!chat) throw notFound('чат не найден');
    return chat;
  }

  /** Сообщения чата вместе с источниками ответов — в порядке появления. */
  async messages(userId: string, chatId: string): Promise<MessageView[]> {
    await this.owned(userId, chatId);
    const messages = await this.prisma.chatMessage.findMany({
      where: { chatId },
      orderBy: { createdAt: 'asc' },
      include: { sources: { orderBy: { position: 'asc' } } },
    });
    return messages.map((message) => ({
      id: message.id,
      role: message.role,
      content: message.content,
      reasoning: message.reasoning,
      searchQuery: message.searchQuery,
      promptTokens: message.promptTokens,
      completionTokens: message.completionTokens,
      createdAt: message.createdAt,
      sources: message.sources.map((source) => ({
        position: source.position,
        title: source.title,
        url: source.url,
        read: source.read,
        chars: source.chars,
      })),
    }));
  }

  /**
   * Записывает вопрос человека.
   *
   * Заодно выводит тему чата из первого вопроса (как это делают приложения ChatGPT и Gemini) и
   * обновляет время чата — по нему список чатов сортируется, а `@updatedAt` сам по себе при
   * добавлении сообщения не срабатывает.
   */
  async addUserMessage(chatId: string, content: string): Promise<void> {
    const isFirst = (await this.prisma.chatMessage.count({ where: { chatId } })) === 0;
    await this.prisma.chatMessage.create({ data: { chatId, role: 'user', content } });
    await this.prisma.chat.update({
      where: { id: chatId },
      data: {
        updatedAt: new Date(),
        ...(isFirst ? { title: this.titleFrom(content) } : {}),
      },
    });
  }

  /**
   * Записывает ответ модели и его источники одним действием.
   *
   * Источники сохраняются всегда, даже когда ответ пришёл из знаний модели: пустой список — это
   * тоже факт («поиска не было»), и по нему на экране видно, откуда взялся ответ.
   */
  async addAssistantMessage(
    chatId: string,
    data: {
      content: string;
      reasoning: string;
      searchQuery: string | null;
      promptTokens?: number;
      completionTokens?: number;
      sources: Array<{
        position: number;
        title: string;
        url: string;
        snippet: string;
        read: boolean;
        chars: number;
      }>;
    },
  ): Promise<{ id: string; createdAt: Date }> {
    const message = await this.prisma.chatMessage.create({
      data: {
        chatId,
        role: 'assistant',
        content: data.content,
        reasoning: data.reasoning,
        searchQuery: data.searchQuery,
        promptTokens: data.promptTokens ?? null,
        completionTokens: data.completionTokens ?? null,
      },
    });
    if (data.sources.length) {
      await this.prisma.chatSource.createMany({
        data: data.sources.map((source) => ({ ...source, messageId: message.id })),
      });
    }
    await this.prisma.chat.update({ where: { id: chatId }, data: { updatedAt: new Date() } });
    return { id: message.id, createdAt: message.createdAt };
  }

  /**
   * Собирает историю для запроса к модели, сжимая длинный разговор в выжимку.
   *
   * Зачем сжатие: каждый ответ пересылает историю заново, а префилл на домашнем маке идёт
   * медленно — на длинном разговоре человек минуту ждал бы первого слова. Поэтому при
   * превышении [COMPACT_AFTER_CHARS] старшая половина окна пересказывается моделью, выжимка
   * ложится в чат, а в запрос уходят выжимка плюс свежие сообщения.
   *
   * Отказ сжатия ответ не срывает: если модель недоступна, история уходит как есть — лучше
   * медленный ответ, чем никакого.
   */
  async contextFor(
    chat: { id: string; summary: string | null; summarizedUpToAt: Date | null },
    model: string,
    signal: AbortSignal,
  ): Promise<{ messages: LlmMessage[]; compacted: boolean }> {
    const rows = await this.prisma.chatMessage.findMany({
      where: {
        chatId: chat.id,
        ...(chat.summarizedUpToAt ? { createdAt: { gt: chat.summarizedUpToAt } } : {}),
      },
      orderBy: { createdAt: 'asc' },
    });
    const window = rows.slice(-MAX_HISTORY_MESSAGES);
    const chars = window.reduce((sum, message) => sum + message.content.length, 0);

    if (chars > COMPACT_AFTER_CHARS && window.length >= 6) {
      const half = Math.floor(window.length / 2);
      const older = window.slice(0, half);
      const compacted = await this.compact(chat, older, model, signal);
      if (compacted) {
        return {
          messages: [
            { role: 'system', content: `${COMPACT_HEADER}\n${compacted}` },
            ...this.toLlm(window.slice(half)),
          ],
          compacted: true,
        };
      }
    }

    const messages = this.toLlm(window);
    if (chat.summary) {
      // Выжимка уже есть, но окно ещё короткое: пересказ всё равно идёт первым сообщением.
      messages.unshift({ role: 'system', content: `${COMPACT_HEADER}\n${chat.summary}` });
    }
    return { messages, compacted: Boolean(chat.summary) };
  }

  /** Пересказывает старшие сообщения и запоминает выжимку в чате. Возвращает её текст. */
  private async compact(
    chat: { id: string; summary: string | null },
    older: Array<{ role: string; content: string; createdAt: Date }>,
    model: string,
    signal: AbortSignal,
  ): Promise<string | null> {
    const dialog = older.map((message) => `${message.role === 'user' ? 'Человек' : 'Помощник'}: ${message.content}`);
    const parts: string[] = [];
    if (chat.summary) {
      // Прежняя выжимка идёт первой: иначе новый пересказ потерял бы всё, что было сжато раньше.
      parts.push(`Прежняя выжимка:\n${chat.summary}`);
    }
    parts.push(dialog.join('\n\n'));
    parts.push(COMPACT_PROMPT);
    try {
      const summary = await this.llm.complete({ model, messages: [{ role: 'user', content: parts.join('\n\n') }], signal });
      if (!summary) return null;
      await this.prisma.chat.update({
        where: { id: chat.id },
        data: {
          summary,
          // Граница сжатия — время последнего пересказанного сообщения: всё, что позже, уходит
          // в запрос как есть.
          summarizedUpToAt: older[older.length - 1].createdAt,
        },
      });
      this.logger.log(`чат ${chat.id}: история сжата до ${summary.length} симв.`);
      return summary;
    } catch (e) {
      this.logger.warn(`чат ${chat.id}: сжать историю не удалось — ${e instanceof Error ? e.message : e}`);
      return null;
    }
  }

  /** Переводит строки БД в сообщения запроса: роли совпадают, переводить нечего. */
  private toLlm(rows: Array<{ role: string; content: string }>): LlmMessage[] {
    return rows.map((row) => ({ role: row.role as LlmRole, content: row.content }));
  }

  /** Тема чата из первого вопроса: обрезка по границе слова, чтобы не рвать фразу. */
  private titleFrom(question: string): string {
    const flat = question.replace(/\s+/g, ' ').trim();
    if (flat.length <= TITLE_CHARS) return flat || 'Новый чат';
    const cut = flat.slice(0, TITLE_CHARS);
    const space = cut.lastIndexOf(' ');
    return (space > TITLE_CHARS * 0.6 ? cut.slice(0, space) : cut).trim();
  }

  /** Память владельца: текст, который подмешивается в системную часть каждого запроса. */
  async memory(userId: string): Promise<string> {
    const settings = await this.prisma.chatSettings.findUnique({ where: { userId } });
    return settings?.memory ?? '';
  }

  /** Запись памяти владельца (upsert: строки может ещё не быть). */
  async saveMemory(userId: string, memory: string): Promise<string> {
    const value = memory.slice(0, 8_000);
    const settings = await this.prisma.chatSettings.upsert({
      where: { userId },
      create: { userId, memory: value },
      update: { memory: value },
    });
    return settings.memory;
  }
}
