import {
  Body,
  Controller,
  Delete,
  Get,
  Logger,
  Param,
  Patch,
  Post,
  Put,
  Req,
  Res,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { ChatsService } from './chats.service';
import { LlmService } from './llm.service';
import { WebSearchService, type ChatSource } from './websearch.service';
import { needsSearch, searchFailedBlock, sourcesBlock, systemPrompt } from './prompts';
import { badRequest } from '../common/errors';
import { CurrentUser, RateLimit, RequestUser } from '../common/decorators';

/** Потолок длины вопроса: контекст модели это выдержит, а вот префилл на маке — время. */
const MAX_QUESTION_CHARS = 8_000;

/**
 * Раздел «Чат»: модели, чаты, сообщения и поток ответа.
 *
 * Модель и поиск работают на домашнем маке, но запросы делает сервер: история чатов живёт в БД и
 * доступна с любого устройства, причины отказов видны в логе, а в сборке приложения нет ни
 * адресов туннеля, ни ключей. От мака сервер отделён reverse-SSH туннелем, поэтому для него это
 * обычные `http://127.0.0.1:18812` (модель) и `http://127.0.0.1:18814` (поиск).
 *
 * Плата за бесплатность — доступность: мак может спать или потерять сеть, и тогда раздел честно
 * говорит «локальная модель недоступна», а не притворяется, что модель думает.
 *
 * Порядок работы над вопросом: решить, нужен ли поиск → найти и прочитать источники → сохранить
 * вопрос и собрать историю → стримить ответ → сохранить ответ вместе с источниками. Источники
 * сохраняются до генерации не случайно: ссылки нужны и в тексте ответа (`[1]`), и в БД, чтобы их
 * можно было открыть через неделю.
 */
@Controller('chat')
export class ChatController {
  private readonly logger = new Logger(ChatController.name);

  constructor(
    private readonly chats: ChatsService,
    private readonly llm: LlmService,
    private readonly search: WebSearchService,
  ) {}

  /**
   * Модели сервера модели и признак «раздел вообще может работать».
   *
   * Недоступный мак — это не ошибка запроса, а состояние: отдаём пустой список и
   * `configured: false`, чтобы клиент показал «локальная модель недоступна» вместо «не удалось
   * получить список». Иначе человек видел бы сбой сети там, где на самом деле спит его мак.
   */
  @Get('models')
  async models() {
    try {
      return { configured: true, models: await this.llm.listModels() };
    } catch (e) {
      this.logger.warn(`список моделей не получен — ${e instanceof Error ? e.message : e}`);
      return { configured: false, models: [] };
    }
  }

  /** Память владельца: текст, который подмешивается в системную часть каждого запроса. */
  @Get('settings')
  async getSettings(@CurrentUser() user: RequestUser) {
    return { memory: await this.chats.memory(user.id) };
  }

  /**
   * Запись памяти владельца.
   *
   * Тип проверяется руками (в проекте нет `ValidationPipe`): объект вместо строки уронил бы
   * Prisma, а причина была бы не видна ни в логе, ни в интерфейсе.
   */
  @Put('settings')
  async putSettings(@Body() body: Record<string, unknown> = {}, @CurrentUser() user: RequestUser) {
    if (body.memory !== undefined && typeof body.memory !== 'string') {
      throw badRequest('memory must be a string');
    }
    const memory = await this.chats.saveMemory(user.id, typeof body.memory === 'string' ? body.memory : '');
    this.logger.log(`память обновлена: ${memory.length} симв.`);
    return { memory };
  }

  /** Список чатов владельца — свежие сверху. */
  @Get('chats')
  async listChats(@CurrentUser() user: RequestUser) {
    return { chats: await this.chats.list(user.id) };
  }

  /** Новый чат. Тема появится из первого вопроса. */
  @Post('chats')
  @RateLimit(30, 60_000)
  async createChat(@CurrentUser() user: RequestUser) {
    return { chat: await this.chats.create(user.id) };
  }

  /** Переименование чата. */
  @Patch('chats/:id')
  async renameChat(
    @Param('id') id: string,
    @Body() body: Record<string, unknown> = {},
    @CurrentUser() user: RequestUser,
  ) {
    if (typeof body.title !== 'string') throw badRequest('title must be a string');
    return { chat: await this.chats.rename(user.id, id, body.title) };
  }

  /** Удаление чата со всей перепиской. */
  @Delete('chats/:id')
  async deleteChat(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    await this.chats.remove(user.id, id);
    return { ok: true };
  }

  /** Переписка чата вместе с источниками ответов. */
  @Get('chats/:id/messages')
  async listMessages(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return { messages: await this.chats.messages(user.id, id) };
  }

  /**
   * Вопрос к модели: ответ приходит потоком событий SSE.
   *
   * Тело: `{ text, search? }`. `search` — переключатель в интерфейсе: `true` ищет всегда, `false`
   * никогда, отсутствие — решает сервер по тексту вопроса (`needsSearch`). Ошибиться в сторону
   * «не поискать» дешевле: поиск с чтением страниц стоит человеку секунд ожидания.
   *
   * События: `title` (тема чата появилась из первого вопроса), `status` (идёт поиск, идёт чтение
   * страниц), `sources` (готовые источники с номерами), `delta` и `reasoning` (куски ответа),
   * `done` (идентификатор сохранённого ответа и расход), `error` (причина и признак `partial`).
   */
  @Post('chats/:id/messages')
  @RateLimit(20, 60_000)
  async sendMessage(
    @Param('id') id: string,
    @Body() body: Record<string, unknown> = {},
    @CurrentUser() user: RequestUser,
    @Req() req: Request,
    @Res() res: Response,
  ) {
    const text = typeof body.text === 'string' ? body.text.trim() : '';
    if (!text) throw badRequest('text must not be empty');
    if (text.length > MAX_QUESTION_CHARS) {
      throw badRequest(`вопрос длиннее ${MAX_QUESTION_CHARS} символов`);
    }
    const chat = await this.chats.owned(user.id, id);
    const model = await this.llm.resolveModel(chat.model);
    const wantSearch =
      typeof body.search === 'boolean' ? body.search : this.search.configured && needsSearch(text);

    res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
    res.setHeader('Cache-Control', 'no-cache, no-transform');
    res.setHeader('Connection', 'keep-alive');
    // без этого nginx копит ответ в буфере и поток превращается в «ответ приходит целиком в конце»
    res.setHeader('X-Accel-Buffering', 'no');
    res.flushHeaders?.();

    // Разрыв со стороны клиента (уход с экрана, «Стоп», потеря сети) должен гасить и работу
    // сервера: иначе мак продолжит считать ответ, которого уже никто не увидит, и будет занят
    // этим до конца генерации — поток у него один.
    const abort = new AbortController();
    req.on('close', () => abort.abort());

    let sources: ChatSource[] = [];
    let note: string | null = null;
    if (wantSearch) {
      this.event(res, 'status', { searching: true });
      const found = await this.search.research(text, abort.signal);
      this.event(res, 'status', { searching: false });
      sources = found.sources;
      note = found.note;
      if (sources.length) {
        // Источники уходят на экран до генерации: человек видит, откуда будет ответ, и может
        // открыть ссылку, пока модель ещё печатает.
        this.event(res, 'sources', { sources: sources.map(({ position, title, url, read }) => ({ position, title, url, read })) });
      }
    }

    // Вопрос записывается после поиска: если поиск упал по отмене, в истории не останется
    // вопроса без ответа.
    await this.chats.addUserMessage(chat.id, text);
    const saved = await this.chats.owned(user.id, chat.id);
    if (saved.title !== chat.title) this.event(res, 'title', { title: saved.title });

    const memory = await this.chats.memory(user.id);
    const { messages: history, compacted } = await this.chats.contextFor(saved, model, abort.signal);

    // Последнее сообщение истории — только что записанный вопрос; данные поиска подмешиваются
    // именно в него, чтобы они оказались ближе к концу запроса: середину длинного контекста
    // модели используют заметно хуже.
    const question =
      sources.length > 0
        ? `${sourcesBlock(sources, note)}\n\nВопрос: ${text}`
        : note
          ? `${searchFailedBlock(note)}\n\nВопрос: ${text}`
          : text;
    const payload = this.withQuestion(history, question);

    this.logger.log(
      `чат ${chat.id}: вопрос ${text.length} симв., истории ${payload.length} сообщений` +
        `${compacted ? ' (сжат)' : ''}, модель ${model}, память ${memory.length} симв., ` +
        `поиск ${wantSearch ? `${sources.length} источников` : 'выключен'}`,
    );

    let answer = '';
    let reasoning = '';
    let promptTokens: number | undefined;
    let completionTokens: number | undefined;
    try {
      for await (const delta of this.llm.streamChat({
        model,
        messages: [{ role: 'system', content: systemPrompt(memory) }, ...payload],
        signal: abort.signal,
      })) {
        if (delta.reasoning) {
          reasoning += delta.reasoning;
          this.event(res, 'reasoning', { text: delta.reasoning });
        }
        if (delta.text) {
          answer += delta.text;
          this.event(res, 'delta', { text: delta.text });
        }
        if (delta.usage) {
          promptTokens = delta.usage.promptTokens;
          completionTokens = delta.usage.completionTokens;
        }
      }
    } catch (e) {
      const message = e instanceof Error ? e.message : 'модель не ответила';
      this.logger.error(`чат ${chat.id}: ответ не получен — ${message}`);
      // Уже сказанное сохраняем: человек видел этот текст на экране, и терять его при
      // перезагрузке раздела незачем.
      if (answer.trim()) {
        await this.saveAnswer(chat.id, { answer, reasoning, text, sources, promptTokens, completionTokens });
      }
      this.event(res, 'error', { message, partial: answer.length > 0 });
      if (!res.writableEnded) res.end();
      return;
    }

    if (!answer.trim()) {
      this.logger.warn(`чат ${chat.id}: модель вернула пустой ответ`);
      this.event(res, 'error', { message: 'модель вернула пустой ответ', partial: false });
      if (!res.writableEnded) res.end();
      return;
    }

    const savedMessage = await this.saveAnswer(chat.id, {
      answer,
      reasoning,
      text,
      sources,
      promptTokens,
      completionTokens,
    });
    this.event(res, 'done', {
      messageId: savedMessage.id,
      createdAt: savedMessage.createdAt,
      promptTokens: promptTokens ?? null,
      completionTokens: completionTokens ?? null,
      sources: sources.map(({ position, title, url, read }) => ({ position, title, url, read })),
    });
    if (!res.writableEnded) res.end();
  }

  /** Сохраняет ответ модели вместе с источниками — общий путь для полного и оборванного ответа. */
  private async saveAnswer(
    chatId: string,
    data: {
      answer: string;
      reasoning: string;
      text: string;
      sources: ChatSource[];
      promptTokens?: number;
      completionTokens?: number;
    },
  ) {
    return this.chats.addAssistantMessage(chatId, {
      content: data.answer,
      reasoning: data.reasoning,
      searchQuery: data.sources.length ? data.text.slice(0, 200) : null,
      promptTokens: data.promptTokens,
      completionTokens: data.completionTokens,
      sources: data.sources.map(({ position, title, url, snippet, read, chars }) => ({
        position,
        title,
        url,
        snippet,
        read,
        chars,
      })),
    });
  }

  /**
   * Заменяет последнее сообщение истории на вопрос с данными поиска.
   *
   * История приходит из БД уже вместе с только что записанным вопросом, а подмешивать источники
   * в него нужно на стороне запроса: в БД лежит чистый вопрос человека, а не служебная обвязка
   * с адресами и текстом страниц.
   */
  private withQuestion(
    history: Array<{ role: 'system' | 'user' | 'assistant'; content: string }>,
    question: string,
  ): Array<{ role: 'system' | 'user' | 'assistant'; content: string }> {
    if (!history.length) return [{ role: 'user', content: question }];
    return [...history.slice(0, -1), { ...history[history.length - 1], content: question }];
  }

  /** Пишет событие в поток SSE; после закрытия ответа молча ничего не делает. */
  private event(res: Response, type: string, payload: Record<string, unknown>): void {
    if (res.writableEnded || res.destroyed) return;
    res.write(`data: ${JSON.stringify({ type, ...payload })}\n\n`);
  }
}
