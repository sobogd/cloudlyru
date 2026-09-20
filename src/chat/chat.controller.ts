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
import { AgentEvents, AgentOutcome, AgentService, AgentSource } from './agent.service';
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
 * Как получается ответ: вопрос уходит агенту (`AgentService`), который сам решает инструментами,
 * что делать — искать в Google в браузере телефона, искать ВНУТРИ названного сайта через его
 * поисковую строку (amazon.es, reddit.com) или открывать конкретные страницы. Источники, которые
 * он прочитал, нумеруются и сохраняются вместе с ответом: `[1]` в тексте превращается в ссылку,
 * а открыть её можно и через неделю. Решения «искать или нет» по словам вопроса здесь больше
 * нет — раньше именно оно превращало просьбу «поищи на амазоне» в google-запрос с этим словом.
 */
@Controller('chat')
export class ChatController {
  private readonly logger = new Logger(ChatController.name);

  constructor(
    private readonly chats: ChatsService,
    private readonly llm: LlmService,
    private readonly agent: AgentService,
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

    res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
    res.setHeader('Cache-Control', 'no-cache, no-transform');
    res.setHeader('Connection', 'keep-alive');
    // без этого nginx копит ответ в буфере и поток превращается в «ответ приходит целиком в конце»
    res.setHeader('X-Accel-Buffering', 'no');
    res.flushHeaders?.();

    // Разрыв со стороны клиента (уход с экрана, «Стоп», потеря сети) гасит и работу агента:
    // иначе телефон продолжал бы ходить по сайтам, а мак — считать ответ, которого никто не ждёт.
    const abort = new AbortController();
    req.on('close', () => abort.abort());

    const memory = await this.chats.memory(user.id);
    // История берётся ДО записи вопроса: агент получает её отдельным сообщением, а сам вопрос
    // приходит последним — так он не дублируется в контексте.
    const { messages: history, compacted } = await this.chats.contextFor(chat, model, abort.signal);

    await this.chats.addUserMessage(chat.id, text);
    const saved = await this.chats.owned(user.id, chat.id);
    if (saved.title !== chat.title) this.event(res, 'title', { title: saved.title });

    this.logger.log(
      `чат ${chat.id}: вопрос ${text.length} симв., истории ${history.length} сообщений` +
        `${compacted ? ' (сжат)' : ''}, модель ${model}, память ${memory.length} симв., агент ${this.agent.configured ? 'включён' : 'не настроен'}`,
    );

    // Источники и статус копятся здесь: статус показывается вместо молчащего спиннера (агент
    // ходит по сайтам десятками секунд), источники сразу уходят на экран списком ссылок.
    const events: AgentEvents = {
      status: (step) => this.event(res, 'status', { searching: true, step }),
      sources: (list) =>
        this.event(res, 'sources', {
          sources: list.map(({ position, title, url, read }) => ({ position, title, url, read })),
        }),
      delta: (chunk) => this.event(res, 'delta', { text: chunk }),
    };

    let outcome: AgentOutcome;
    try {
      outcome = await this.agent.run({
        model,
        memory,
        history,
        question: text,
        signal: abort.signal,
        events,
      });
    } catch (e) {
      const message = e instanceof Error ? e.message : 'агент не смог ответить';
      this.logger.error(`чат ${chat.id}: прогон агента сорвался — ${message}`);
      this.event(res, 'error', { message, partial: false });
      if (!res.writableEnded) res.end();
      return;
    }

    if (!outcome.answer.trim()) {
      this.logger.warn(`чат ${chat.id}: агент вернул пустой ответ`);
      this.event(res, 'error', { message: 'модель вернула пустой ответ', partial: false });
      if (!res.writableEnded) res.end();
      return;
    }

    const savedMessage = await this.saveAnswer(chat.id, text, outcome);
    this.logger.log(
      `чат ${chat.id}: ответ ${outcome.answer.length} симв., шагов ${outcome.steps}, ` +
        `источников ${outcome.sources.length}`,
    );
    this.event(res, 'done', {
      messageId: savedMessage.id,
      createdAt: savedMessage.createdAt,
      promptTokens: outcome.promptTokens ?? null,
      completionTokens: outcome.completionTokens ?? null,
      sources: outcome.sources.map(({ position, title, url, read }) => ({ position, title, url, read })),
    });
    if (!res.writableEnded) res.end();
  }

  /**
   * Сохраняет ответ агента вместе с источниками.
   *
   * Источники ложатся в БД отдельными строками (`chat_sources`): ссылку нужно открыть и через
   * неделю, когда модель уже ничего не помнит, а разбирать адреса регуляркой из текста ответа —
   * тот ещё способ. Полный текст страниц в БД не пишется: это мегабайты на каждый ответ.
   */
  private async saveAnswer(chatId: string, question: string, outcome: AgentOutcome) {
    return this.chats.addAssistantMessage(chatId, {
      content: outcome.answer,
      reasoning: outcome.reasoning,
      // Поисковый запрос сохраняем первым, если он есть: по нему через неделю видно, что искали.
      searchQuery: question.slice(0, 200),
      promptTokens: outcome.promptTokens,
      completionTokens: outcome.completionTokens,
      sources: outcome.sources.map((source: AgentSource) => ({
        position: source.position,
        title: source.title,
        url: source.url,
        snippet: source.snippet,
        read: source.read,
        chars: source.chars,
      })),
    });
  }

  /** Пишет событие в поток SSE; после закрытия ответа молча ничего не делает. */
  private event(res: Response, type: string, payload: Record<string, unknown>): void {
    if (res.writableEnded || res.destroyed) return;
    res.write(`data: ${JSON.stringify({ type, ...payload })}\n\n`);
  }
}
