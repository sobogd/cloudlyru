import {
  Body,
  Controller,
  Delete,
  Get,
  HttpStatus,
  Logger,
  Param,
  Patch,
  Post,
  Put,
  Req,
  Res,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { randomUUID } from 'node:crypto';
import { ChatsService, COMPACT_AFTER_CHARS, DEFAULT_AI_MODEL } from './chats.service';
import { LlmDelta, LlmError, LlmMessage, LlmService } from './llm.service';
import { SearchService } from './search.service';
import {
  COMPACT_HEADER,
  COMPACT_PROMPT,
  needsSearch,
  searchBlock,
  systemPrompt,
} from './prompts';
import { ApiError, badRequest } from '../common/errors';
import { AiSettingsService } from './ai-settings.service';
import { CurrentUser, RateLimit, RequestUser } from '../common/decorators';

/** Потолок длины вопроса: у модели контекст в сотни тысяч токенов, но префилл на маке — время. */
const MAX_QUESTION_CHARS = 8_000;

/**
 * Раздел «Чат»: модели, чаты, сообщения и поток ответа.
 *
 * Отвечает локальная модель на домашнем маке (LM Studio), но запросы всё равно делает сервер:
 * так история чатов живёт в БД и доступна с любого устройства, причины отказов попадают в лог
 * (`pm2 logs`), а на телефоне не нужно ни адреса туннеля, ни ключа. Мак соединён с VPS
 * reverse-SSH туннелем, поэтому для сервера это обычный `http://127.0.0.1:18812`.
 *
 * Плата за бесплатность — доступность: мак может спать или потерять сеть, и тогда раздел честно
 * отвечает «локальная модель недоступна», а не притворяется, что модель думает.
 */
@Controller('ai')
export class AiController {
  private readonly logger = new Logger(AiController.name);

  constructor(
    private readonly llm: LlmService,
    private readonly search: SearchService,
    private readonly chats: ChatsService,
    private readonly settings: AiSettingsService,
  ) {}

  /**
   * Модели, загруженные в LM Studio, и признак «раздел вообще может работать».
   *
   * Недоступный мак — это не ошибка запроса, а состояние: отдаём пустой список и
   * `configured: false`, чтобы клиент показал «локальная модель недоступна» вместо «не удалось
   * получить список». Иначе человек видел бы сбой сети там, где на самом деле спит его мак.
   */
  @Get('models')
  async models() {
    try {
      const models = await this.llm.listModels();
      return { configured: true, models };
    } catch (e) {
      this.logger.warn(`список моделей не получен — ${e instanceof Error ? e.message : e}`);
      return { configured: false, models: [] };
    }
  }

  /** Память владельца: текст, который подмешивается в системную часть каждого запроса. */
  @Get('settings')
  async getSettings(@CurrentUser() user: RequestUser) {
    return { memory: await this.settings.memory(user.id) };
  }

  /**
   * Запись памяти владельца.
   *
   * Тип проверяется руками (в проекте нет `ValidationPipe`): объект вместо строки уронил бы
   * Prisma, а причина была бы не видна ни в логе, ни в интерфейсе.
   */
  @Put('settings')
  async putSettings(
    @Body() body: Record<string, unknown> = {},
    @CurrentUser() user: RequestUser,
  ) {
    if (body.memory !== undefined && typeof body.memory !== 'string') {
      throw badRequest('memory must be a string');
    }
    const memory = await this.settings.saveMemory(user.id, typeof body.memory === 'string' ? body.memory : '');
    this.logger.log(`память обновлена: ${memory.length} симв.`);
    return { memory };
  }

  /** Список чатов владельца — темы, свежие сверху. */
  @Get('chats')
  listChats(@CurrentUser() user: RequestUser) {
    return this.chats.list(user.id).then((chats) => ({ chats }));
  }

  /** Новый чат; модель можно не указывать — подставится модель по умолчанию. */
  @Post('chats')
  async createChat(@Body() body: Record<string, unknown> = {}, @CurrentUser() user: RequestUser) {
    const chat = await this.chats.create(user.id, body.model);
    this.logger.log(`чат создан: ${chat.id} (модель ${chat.model})`);
    return chat;
  }

  /** Правка темы и модели чата. */
  @Patch('chats/:id')
  patchChat(
    @Param('id') id: string,
    @Body() body: Record<string, unknown> = {},
    @CurrentUser() user: RequestUser,
  ) {
    return this.chats.patch(user.id, id, body);
  }

  /** Удаление чата вместе с его сообщениями. */
  @Delete('chats/:id')
  async removeChat(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    await this.chats.remove(user.id, id);
    return { ok: true };
  }

  /** Сообщения чата в порядке отправки — история при открытии чата. */
  @Get('chats/:id/messages')
  async messages(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    const messages = await this.chats.messages(user.id, id);
    return { messages };
  }

  /**
   * Отправка вопроса: ответ уходит потоком SSE, переписка сохраняется в БД.
   *
   * Лимит 20 запросов в минуту на IP: модель локальная и бесплатная, но она одна и считает на
   * одном маке — «случайный» цикл на клиенте займёт её целиком, и владелец будет ждать ответа
   * минутами. Поток отдаём сами (`@Res`), потому что Nest не умеет отдавать незакрытый ответ:
   * события пишутся по мере генерации, соединение живёт до конца ответа.
   *
   * Коды до начала потока (адрес модели не задан, пустой вопрос, чужой чат) уходят обычной
   * ошибкой API — их ловит глобальный фильтр. Всё, что случилось внутри потока, приходит
   * событием `error`: заголовки уже отправлены, и подменить ответ на JSON нельзя.
   */
  @Post('chats/:id/messages')
  @RateLimit(20, 60_000)
  async send(
    @Param('id') id: string,
    @Body() body: Record<string, unknown> = {},
    @CurrentUser() user: RequestUser,
    @Req() req: Request,
    @Res() res: Response,
  ): Promise<void> {
    const question = typeof body.text === 'string' ? body.text.trim() : '';
    // Поиск: клиент может настоять на своём (`search: true/false`), иначе решаем по тексту
    // вопроса. Поиск бесплатный, но не мгновенный (несколько секунд до выдачи), поэтому «на
    // всякий случай» его не подключаем.
    const wantSearch = typeof body.search === 'boolean' ? body.search : needsSearch(question);
    if (!question) throw badRequest('текст сообщения пуст', 'empty_message');
    if (question.length > MAX_QUESTION_CHARS) {
      throw badRequest(`сообщение длиннее ${MAX_QUESTION_CHARS} символов`, 'message_too_long');
    }
    if (!this.llm.configured) {
      throw new ApiError(
        HttpStatus.SERVICE_UNAVAILABLE,
        'на сервере не задан адрес локальной модели (LLM_BASE_URL)',
        'ai_not_configured',
      );
    }

    // владелец проверяется до сохранения вопроса: чужой чат не должен обрастать сообщениями
    const chat = await this.chats.owned(user.id, id);
    // модель для запроса: у старых чатов в БД записан идентификатор xAI, которого на маке нет
    const model = await this.llm.resolveModel(chat.model);
    // память читаем на каждый запрос, а не кэшируем: она меняется в настройках, и запрос после
    // правки должен уходить уже с новым текстом
    const memory = await this.settings.memory(user.id);
    const history = await this.requestHistory(chat.id, memory);
    await this.chats.append({ chatId: chat.id, role: 'user', content: question });
    // тема берётся из первого вопроса: у нового чата в истории только системная часть
    const titled = history.messages.length <= 1 && chat.title === 'Новый чат';
    const title = titled ? await this.chats.retitleFromQuestion(chat.id, question) : null;

    res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
    res.setHeader('Cache-Control', 'no-cache, no-transform');
    res.setHeader('Connection', 'keep-alive');
    // без этого nginx копит ответ в буфере и поток превращается в «ответ приходит целиком в конце»
    res.setHeader('X-Accel-Buffering', 'no');
    res.flushHeaders?.();

    if (title) this.event(res, 'title', { title });

    // Поиск идёт до генерации и занимает секунды: без события экран не понимал бы, что
    // происходит, и выглядел бы зависшим. Статус снимаем сразу после поиска, а не по первому
    // слову ответа: между ними может пройти десяток секунд префилла.
    let searched = 0;
    let userContent = question;
    if (wantSearch) {
      this.event(res, 'status', { searching: true });
      const outcome = await this.search.search(question);
      this.event(res, 'status', { searching: false });
      if (outcome.results.length) {
        searched = 1;
        userContent = `${searchBlock(outcome.results)}\n\nВопрос: ${question}`;
      }
    }

    this.logger.log(
      `чат ${chat.id}: вопрос ${question.length} симв., истории ${history.messages.length - 1} ` +
        `сообщений${history.compacted ? ' (разговор сжат)' : ''}, модель ${model}, ` +
        `память ${memory.length} симв., поиск ${wantSearch ? (searched ? 'с результатами' : 'без результатов') : 'выключен'}`,
    );

    // Разрыв со стороны клиента (уход с экрана, «Стоп», потеря сети) должен гасить и запрос к
    // модели: иначе мак продолжит считать ответ, которого уже никто не увидит.
    const abort = new AbortController();
    let closed = false;
    req.on('close', () => {
      closed = true;
      abort.abort();
    });

    let answer = '';
    let reasoning = '';
    // расход приходит одним событием в конце; тип берём у сервиса, чтобы поля не разъезжались
    let usage: LlmDelta['usage'];
    try {
      for await (const delta of this.llm.streamChat({
        model,
        messages: [...history.messages, { role: 'user', content: userContent }],
        signal: abort.signal,
      })) {
        if (delta.usage) {
          // поисков у локальной модели не бывает — их делает сервер, поэтому число подставляем
          // здесь: сервис модели об этом ничего не знает
          usage = { ...delta.usage, searches: searched };
        }
        if (delta.reasoning) {
          reasoning += delta.reasoning;
          this.event(res, 'reasoning', { text: delta.reasoning });
        }
        if (delta.text) {
          answer += delta.text;
          this.event(res, 'delta', { text: delta.text });
        }
      }

      // Пустой ответ не сохраняем: пузырь без текста на экране ничего не объясняет, а причину
      // показывает сообщение об ошибке.
      const saved = answer
        ? await this.chats.append({
            chatId: chat.id,
            role: 'assistant',
            content: answer,
            reasoning,
            promptTokens: usage?.promptTokens,
            completionTokens: usage?.completionTokens,
            // стоимость сохраняем вместе с ответом: у локальной модели это всегда ноль, но поле
            // остаётся — по нему старые ответы xAI продолжают считаться в расходе по чату
            costUsd: usage?.costUsd,
          })
        : null;
      this.logger.log(
        `чат ${chat.id}: ответ ${answer.length} симв., размышления ${reasoning.length} симв.` +
          (usage
            ? `, токенов ${usage.promptTokens}→${usage.completionTokens}, поисков ${usage.searches}`
            : ''),
      );
      this.event(res, 'done', {
        messageId: saved?.id ?? null,
        usage: usage ?? null,
        interrupted: closed,
      });
      this.compactIfNeeded(chat.id, model);
    } catch (e) {
      await this.fail(res, chat.id, e, answer, reasoning, usage, closed);
    } finally {
      if (!res.writableEnded) res.end();
    }
  }

  /**
   * Собирает историю запроса: системная часть плюс то, что не уместилось в компакцию.
   *
   * Пока разговор не сжимали — это окно последних сообщений ([ChatsService.context]). После
   * сжатия история живёт внутри выжимки, и в запрос уходят только сообщения, созданные позже
   * границы (`compactedUpToAt`). Системную часть отправляем и в этом случае: она короткая и по
   * ней модель понимает, как отвечать.
   *
   * Выжимка идёт отдельным сообщением сразу за системным, а не вклеивается в него: так модель
   * видит, что это пересказ прежнего разговора, а не правило поведения.
   */
  private async requestHistory(
    chatId: string,
    memory: string,
  ): Promise<{ messages: LlmMessage[]; compacted: boolean }> {
    const system: LlmMessage = { role: 'system', content: systemPrompt(memory) };
    const compaction = await this.chats.compaction(chatId);
    if (!compaction) {
      return { messages: [system, ...(await this.chats.context(chatId))], compacted: false };
    }
    return {
      compacted: true,
      messages: [
        system,
        { role: 'system', content: `${COMPACT_HEADER}\n${compaction.blob}` },
        ...(await this.chats.messagesAfter(chatId, compaction.upToAt)),
      ],
    };
  }

  /**
   * Сжимает разговор в фоне, если он перерос порог.
   *
   * В фоне — потому что это отдельная генерация на маке (десятки секунд его времени), а ответ
   * человеку из-за неё ждать не должен. Ошибку только логируем: без сжатия разговор просто
   * продолжит отвечать медленнее, а не сломается.
   */
  private compactIfNeeded(chatId: string, model: string): void {
    void (async () => {
      try {
        const history = await this.chats.fullHistory(chatId);
        const chars = history.reduce((sum, m) => sum + m.content.length, 0);
        if (chars < COMPACT_AFTER_CHARS) return;
        // В компакцию уходят только реплики разговора: системная подсказка (и память) в
        // выжимке не нужны — они и так уходят в каждый запрос заново, а лишнее системное
        // сообщение перед инструкцией сбивает модель с задачи (см. `LlmService.compact`).
        const blob = await this.llm.compact({
          model,
          prompt: COMPACT_PROMPT,
          messages: history,
        });
        if (!blob) return;
        const upTo = await this.chats.lastMessageAt(chatId);
        if (!upTo) return;
        // Идентификатор блока больше не приходит от провайдера: выжимку пишем мы сами, и он
        // нужен только чтобы в логах было видно, какая именно выжимка лежит в чате.
        await this.chats.saveCompaction(chatId, randomUUID(), blob, upTo);
        this.logger.log(`чат ${chatId}: история ${chars} симв. сжата в выжимку ${blob.length} симв.`);
      } catch (e) {
        this.logger.warn(`чат ${chatId}: компакция не удалась — ${e instanceof Error ? e.message : e}`);
      }
    })();
  }

  /**
   * Завершает поток ошибкой: сохраняет то, что уже пришло, и объясняет причину.
   *
   * Обрыв по инициативе клиента ошибкой не считается — это «Стоп» или уход с экрана: ответ
   * сохраняется как есть, а событие уходит только если соединение ещё живо.
   */
  private async fail(
    res: Response,
    chatId: string,
    e: unknown,
    answer: string,
    reasoning: string,
    usage: LlmDelta['usage'],
    closed: boolean,
  ): Promise<void> {
    const aborted = closed || (e instanceof Error && e.name === 'AbortError');
    if (aborted) {
      if (answer) {
        await this.chats.append({
          chatId,
          role: 'assistant',
          content: answer,
          reasoning,
          promptTokens: usage?.promptTokens,
          completionTokens: usage?.completionTokens,
          costUsd: usage?.costUsd,
        });
      }
      this.logger.log(`чат ${chatId}: поток прерван клиентом, сохранено ${answer.length} симв.`);
      return;
    }

    // В логе — причина от сервера модели целиком: по ней и разбирают, почему раздел не работает
    // (упал туннель, мак уснул, модель не загружена, контекст не влез).
    const message = e instanceof LlmError ? e.message : 'не удалось получить ответ';
    const details = e instanceof LlmError ? e.details : e instanceof Error ? e.message : String(e);
    this.logger.error(`чат ${chatId}: ${message}${details ? ` — ${details.slice(0, 500)}` : ''}`);

    if (answer) {
      await this.chats.append({
        chatId,
        role: 'assistant',
        content: answer,
        reasoning,
        promptTokens: usage?.promptTokens,
        completionTokens: usage?.completionTokens,
        costUsd: usage?.costUsd,
      });
    }
    this.event(res, 'error', { message, partial: answer.length > 0 });
  }

  /** Пишет одно событие SSE; после закрытия соединения молча ничего не делает. */
  private event(res: Response, type: string, payload: Record<string, unknown>): void {
    if (res.writableEnded || res.destroyed) return;
    res.write(`data: ${JSON.stringify({ type, ...payload })}\n\n`);
  }
}
