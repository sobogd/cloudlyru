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
import { ChatsService, COMPACT_AFTER_CHARS } from './chats.service';
import { GrokDelta, GrokError, GrokMessage, GrokService } from './grok.service';
import { ApiError, badRequest } from '../common/errors';
import { AiSettingsService } from './ai-settings.service';
import { needsSearch, systemPrompt } from './prompts';
import { CurrentUser, RateLimit, RequestUser } from '../common/decorators';

/** Потолок длины вопроса: у модели контекст в сотни тысяч токенов, но платят за каждый. */
const MAX_QUESTION_CHARS = 8_000;

/**
 * Раздел «Чат»: модели, чаты, сообщения и поток ответа.
 *
 * Провайдера ИИ здесь представляет сервер, а не приложение: ключ xAI лежит в окружении сервера
 * (`GROK_API_KEY`) и на клиент не уходит, каждый запрос и ответ провайдера попадает в лог
 * (`pm2 logs`), а переписка хранится в БД и доступна с любого устройства. Первый заход был
 * сделан наоборот — ключ вшивался в сборку приложения, — и разобрать «не работает» было нечем:
 * ни причины отказа, ни истории, ни возможности что-то поправить без новой сборки.
 */
@Controller('ai')
export class AiController {
  private readonly logger = new Logger(AiController.name);

  constructor(
    private readonly grok: GrokService,
    private readonly chats: ChatsService,
    private readonly settings: AiSettingsService,
  ) {}

  /**
   * Модели, доступные ключу сервера, и признак «ключ вообще задан».
   *
   * Признак нужен клиенту, чтобы отличить «на сервере нет ключа» (это чинится секретом
   * репозитория, в приложении делать нечего) от «список не пришёл» (это сеть).
   */
  @Get('models')
  async models() {
    const models = await this.grok.listModels();
    return { configured: this.grok.configured, models };
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
   * Лимит 20 запросов в минуту на IP: каждый запрос — платный вызов провайдера, и «случайный»
   * цикл на клиенте стоит денег, а не времени. Поток отдаём сами (`@Res`), потому что Nest не
   * умеет отдавать незакрытый ответ: события пишутся по мере генерации, соединение живёт
   * до конца ответа.
   *
   * Коды до начала потока (нет ключа, пустой вопрос, чужой чат) уходят обычной ошибкой API —
   * их ловит глобальный фильтр. Всё, что случилось внутри потока, приходит событием `error`:
   * заголовки уже отправлены, и подменить ответ на JSON нельзя.
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
    // вопроса. Инструмент стоит $0.005 за вызов плюс десятки тысяч входных токенов на
    // прочитанные страницы, поэтому «на всякий случай» его не подключаем.
    const search = typeof body.search === 'boolean' ? body.search : needsSearch(question);
    if (!question) throw badRequest('текст сообщения пуст', 'empty_message');
    if (question.length > MAX_QUESTION_CHARS) {
      throw badRequest(`сообщение длиннее ${MAX_QUESTION_CHARS} символов`, 'message_too_long');
    }
    if (!this.grok.configured) {
      throw new ApiError(
        HttpStatus.SERVICE_UNAVAILABLE,
        'на сервере не задан ключ xAI (GROK_API_KEY)',
        'ai_not_configured',
      );
    }

    // владелец проверяется до сохранения вопроса: чужой чат не должен обрастать сообщениями
    const chat = await this.chats.owned(user.id, id);
    // память читаем на каждый запрос, а не кэшируем: она меняется в настройках, и запрос после
    // правки должен уходить уже с новым текстом
    const memory = await this.settings.memory(user.id);
    const history = await this.requestHistory(chat.id, memory, search);
    await this.chats.append({ chatId: chat.id, role: 'user', content: question });
    // тема берётся из первого вопроса: у нового чата в истории только системная часть
    const titled = history.messages.length <= 1 && chat.title === 'Новый чат';
    const title = titled ? await this.chats.retitleFromQuestion(chat.id, question) : null;

    this.logger.log(
      `чат ${chat.id}: вопрос ${question.length} симв., истории ${history.messages.length - 1} ` +
        `сообщений${history.compacted ? ' (разговор сжат)' : ''}, модель ${chat.model}, ` +
        `память ${memory.length} симв., поиск ${search ? 'включён' : 'выключен'}`,
    );

    res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
    res.setHeader('Cache-Control', 'no-cache, no-transform');
    res.setHeader('Connection', 'keep-alive');
    // без этого nginx копит ответ в буфере и поток превращается в «ответ приходит целиком в конце»
    res.setHeader('X-Accel-Buffering', 'no');
    res.flushHeaders?.();

    if (title) this.event(res, 'title', { title });

    // Разрыв со стороны клиента (уход с экрана, «Стоп», потеря сети) должен гасить и запрос
    // к xAI: иначе генерация идёт до конца, а токены списываются за ответ, которого никто
    // не увидит.
    const abort = new AbortController();
    let closed = false;
    req.on('close', () => {
      closed = true;
      abort.abort();
    });

    let answer = '';
    let reasoning = '';
    // расход приходит одним событием в конце; тип берём у сервиса, чтобы поля не разъезжались
    let usage: GrokDelta['usage'];
    try {
      for await (const delta of this.grok.streamChat({
        model: chat.model,
        messages: [...history.messages, { role: 'user', content: question }],
        search,
        // ключ кэша промпта: у xAI кэш живёт на конкретном сервере, и один ключ на разговор
        // удерживает запросы на одной машине — иначе вход каждый раз оплачивается полностью
        cacheKey: chat.id,
        signal: abort.signal,
      })) {
        if (delta.usage) usage = delta.usage;
        // поиск в интернете виден отдельным событием: с ним ответ идёт десятками секунд, и
        // экран должен показывать, что модель ищет, а не «зависла»
        if (delta.searching !== undefined) this.event(res, 'status', { searching: delta.searching });
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
            // стоимость сохраняем вместе с ответом: по ней считается расход по чату
            costUsd: usage?.costUsd,
          })
        : null;
      this.logger.log(
        `чат ${chat.id}: ответ ${answer.length} симв., размышления ${reasoning.length} симв.` +
          (usage
            ? `, токенов ${usage.promptTokens}→${usage.completionTokens}, ` +
              `поисков ${usage.searches}, стоимость $${usage.costUsd.toFixed(4)}`
            : ''),
      );
      this.event(res, 'done', {
        messageId: saved?.id ?? null,
        usage: usage ?? null,
        interrupted: closed,
      });
      this.compactIfNeeded(chat.id, chat.model, memory, search);
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
   * сжатия история живёт внутри непрозрачного блока, и в запрос уходят только сообщения,
   * созданные позже границы (`compactedUpToAt`). Системную часть отправляем и в этом случае:
   * она короткая, кэшируется, а память владельца может меняться — иначе правка памяти не
   * действовала бы на сжатые разговоры.
   */
  private async requestHistory(
    chatId: string,
    memory: string,
    search: boolean,
  ): Promise<{ messages: GrokMessage[]; compacted: boolean }> {
    const system: GrokMessage = { role: 'system', content: systemPrompt(memory, search) };
    const compaction = await this.chats.compaction(chatId);
    if (!compaction) {
      return { messages: [system, ...(await this.chats.context(chatId))], compacted: false };
    }
    return {
      compacted: true,
      messages: [
      // Блок передаём ровно в том виде, в каком его вернул провайдер: разбирать или собирать
      // заново нельзя, он имеет смысл только целиком. Тип сообщения здесь не роль, а запись
      // сжатия, поэтому в общий тип GrokMessage он не входит — отсюда приведение.
      {
        type: 'compaction',
        id: compaction.id,
        encrypted_content: compaction.blob,
      } as unknown as GrokMessage,
        system,
        ...(await this.chats.messagesAfter(chatId, compaction.upToAt)),
      ],
    };
  }

  /**
   * Сжимает разговор в фоне, если он перерос порог.
   *
   * В фоне — потому что вызов компакции сам стоит токенов и времени, а ответ человеку из-за него
   * ждать не должен. Ошибку только логируем: без сжатия разговор просто продолжит дорожать,
   * а не сломается.
   */
  private compactIfNeeded(chatId: string, model: string, memory: string, search: boolean): void {
    void (async () => {
      try {
        const history = await this.chats.fullHistory(chatId);
        const chars = history.reduce((sum, m) => sum + m.content.length, 0);
        if (chars < COMPACT_AFTER_CHARS) return;
        const result = await this.grok.compact({
          model,
          messages: [
            { role: 'system', content: systemPrompt(memory, search) },
            ...history,
          ],
        });
        if (!result) return;
        const upTo = await this.chats.lastMessageAt(chatId);
        if (!upTo) return;
        await this.chats.saveCompaction(chatId, result.id, result.blob, upTo);
        this.logger.log(`чат ${chatId}: история ${chars} симв. сжата в блок ${result.id}`);
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
    usage: GrokDelta['usage'],
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

    // В логе — причина от провайдера целиком: по ней и разбирают, почему раздел не работает.
    const message = e instanceof GrokError ? e.message : 'не удалось получить ответ';
    const details = e instanceof GrokError ? e.details : e instanceof Error ? e.message : String(e);
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
