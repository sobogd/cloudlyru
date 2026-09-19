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
  Req,
  Res,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { ChatsService } from './chats.service';
import { GrokDelta, GrokError, GrokService } from './grok.service';
import { ApiError, badRequest } from '../common/errors';
import { styleList, systemPrompt } from './prompts';
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

  /**
   * Стили ответа: идентификатор, подпись и короткое пояснение.
   *
   * Подписи живут на сервере вместе с подсказками (src/ai/prompts.ts): приложение показывает
   * ровно те стили, которые сервер умеет применить, и не хранит их список у себя.
   */
  @Get('styles')
  styles() {
    return { styles: styleList() };
  }

  /** Список чатов владельца — темы, свежие сверху. */
  @Get('chats')
  listChats(@CurrentUser() user: RequestUser) {
    return this.chats.list(user.id).then((chats) => ({ chats }));
  }

  /** Новый чат; модель и стиль можно не указывать — подставятся значения по умолчанию. */
  @Post('chats')
  async createChat(@Body() body: Record<string, unknown> = {}, @CurrentUser() user: RequestUser) {
    const chat = await this.chats.create(user.id, body.model, body.style);
    this.logger.log(`чат создан: ${chat.id} (модель ${chat.model}, стиль ${chat.style})`);
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
    const context = await this.chats.context(chat.id);
    await this.chats.append({ chatId: chat.id, role: 'user', content: question });
    // тема берётся из первого вопроса: у нового чата она ещё пустая
    const titled = context.length === 0 && chat.title === 'Новый чат';
    const title = titled ? await this.chats.retitleFromQuestion(chat.id, question) : null;

    this.logger.log(
      `чат ${chat.id}: вопрос ${question.length} симв., истории ${context.length} сообщений, ` +
        `модель ${chat.model}, стиль ${chat.style}`,
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
        messages: [
          { role: 'system', content: systemPrompt(chat.style) },
          ...context,
          { role: 'user', content: question },
        ],
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
    } catch (e) {
      await this.fail(res, chat.id, e, answer, reasoning, usage, closed);
    } finally {
      if (!res.writableEnded) res.end();
    }
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
