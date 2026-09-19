import { Injectable, Logger } from '@nestjs/common';
import { env } from '../config/env';

/**
 * Потолок длины ответа в токенах.
 *
 * Здесь это не про деньги (локальная модель бесплатна), а про время: на маке генерация идёт
 * около 20 токенов в секунду, то есть две тысячи токенов — это почти две минуты ожидания.
 * Обычные ответы в наших чатах укладывались в 1900 токенов, но потолок держим: модель без
 * него уходит в «простыню», и человек всё это время ждёт у экрана.
 */
const MAX_OUTPUT_TOKENS = 2000;

/** Сколько живёт кэш списка моделей, мс: набор меняется, только когда владелец трогает LM Studio. */
const MODELS_TTL_MS = 10 * 60 * 1000;

/** Роль сообщения в том виде, в каком её понимает API локального сервера. */
export type LlmRole = 'system' | 'user' | 'assistant';

/** Сообщение, уходящее модели в теле запроса. */
export interface LlmMessage {
  role: LlmRole;
  content: string;
}

/** Модель, загруженная в LM Studio (или лежащая на диске и готовая к загрузке). */
export interface LlmModel {
  id: string;
  /** Размер контекста в токенах, если сервер его сообщил. */
  contextLength: number | null;
  /** `loaded` — модель уже в памяти; `not-loaded` — её загрузит первый запрос. */
  state: string | null;
  /** Квантование (`4bit` и подобное) — справка для человека в списке выбора. */
  quantization: string | null;
}

/** Порция ответа модели. */
export interface LlmDelta {
  /** Кусок текста ответа. */
  text?: string;
  /** Кусок «размышлений» — у Gemma 4 они выключены настройкой, но парсер их знает. */
  reasoning?: string;
  /** Расход на ответ: приходит один раз, в завершающем событии потока. */
  usage?: {
    promptTokens: number;
    completionTokens: number;
    /**
     * Сколько входных токенов взято из кэша префикса. Локальный сервер этого не сообщает,
     * поэтому всегда 0 — поле оставлено ради лога: по нему видно, что кэш не при чём.
     */
    cachedTokens: number;
    /**
     * Сколько раз модель сходила в интернет. Считает не модель (поиск делает сервер сам,
     * см. search.service.ts), а вызывающий код: сюда значение приходит уже готовым.
     */
    searches: number;
    /** Стоимость ответа в долларах: у локальной модели всегда 0. */
    costUsd: number;
  };
}

/**
 * Ошибка обращения к локальной модели с причиной, пригодной для показа человеку.
 *
 * Отдельный тип, а не HttpException: сервис не знает, в каком виде ошибка уйдёт наружу —
 * до начала потока это HTTP-ответ, внутри потока — событие SSE. Решение принимает контроллер.
 */
export class LlmError extends Error {
  constructor(
    message: string,
    /** HTTP-код ответа LM Studio, если он был. */
    readonly status?: number,
    /** Ответ сервера целиком — уходит в лог, но не клиенту. */
    readonly details?: string,
  ) {
    super(message);
    this.name = 'LlmError';
  }
}

/**
 * Клиент локальной модели на маке (LM Studio, OpenAI-совместимый `/v1/chat/completions`).
 *
 * Почему `chat/completions`, а не `/v1/responses`: Responses API есть и у LM Studio, но
 * chat/completions понимают все локальные серверы (Ollama, llama.cpp — тоже), и переезд на
 * другой сервер тогда сводится к смене `LLM_BASE_URL`. Формат потока здесь классический:
 * строки `data: {...}`, в конце `data: [DONE]`, расход — отдельным чанком (за это отвечает
 * `stream_options.include_usage`).
 *
 * Сервер на маке один, а моделей в нём несколько, поэтому модель приходит в каждом запросе
 * (`model` в теле), а не берётся из настроек сервиса. Значение по умолчанию — `LLM_MODEL`.
 */
@Injectable()
export class LlmService {
  private readonly logger = new Logger(LlmService.name);

  /** Кэш списка моделей: ходить за ним на каждый показ вкладки незачем, а Mac не любит лишние запросы. */
  private modelsCache: { at: number; models: LlmModel[] } | null = null;

  /** Задан ли адрес модели: пусто — раздел «Чат» отвечает «не настроен». */
  get configured(): boolean {
    return env.LLM_BASE_URL.trim().length > 0;
  }

  /** Идентификатор модели по умолчанию для новых чатов. */
  get defaultModel(): string {
    return env.LLM_MODEL.trim();
  }

  /**
   * Список моделей локального сервера.
   *
   * Берём `GET /api/v0/models`, а не OpenAI-совместимый `/v1/models`: только первый отдаёт
   * размер контекста, квантование и признак «модель уже в памяти» — то есть ровно то, чем
   * список моделей полезен человеку. Эмбеддинги из списка выкидываем: чат ими не отвечает,
   * а глазами их в выборе модели видеть незачем.
   */
  async listModels(): Promise<LlmModel[]> {
    const cached = this.modelsCache;
    if (cached && Date.now() - cached.at < MODELS_TTL_MS) return cached.models;

    const data = await this.getJson('/api/v0/models');
    const list = (data as { data?: unknown }).data;
    if (!Array.isArray(list)) {
      throw new LlmError('LM Studio вернул список моделей в незнакомом виде', undefined, JSON.stringify(data).slice(0, 300));
    }
    const models: LlmModel[] = [];
    for (const item of list) {
      if (typeof item !== 'object' || item === null) continue;
      const m = item as Record<string, unknown>;
      const id = typeof m.id === 'string' ? m.id : '';
      if (!id) continue;
      // `type` у LM Studio: llm | vlm | embeddings. Всё, кроме эмбеддингов, годится для чата —
      // картинки и звук сюда пока не передаются, но vlm отвечает текстом не хуже llm.
      if (m.type === 'embeddings') continue;
      models.push({
        id,
        contextLength: typeof m.max_context_length === 'number' ? m.max_context_length : null,
        state: typeof m.state === 'string' ? m.state : null,
        quantization: typeof m.quantization === 'string' ? m.quantization : null,
      });
    }
    if (!models.length) throw new LlmError('в LM Studio нет ни одной чат-модели');

    this.logger.log(
      `локальная модель: доступно ${models.length} (${models.map((m) => `${m.id}${m.state === 'loaded' ? ' [в памяти]' : ''}`).join(', ')})`,
    );
    this.modelsCache = { at: Date.now(), models };
    return models;
  }

  /**
   * Выбирает модель для запроса: указанную, если сервер её знает, иначе модель по умолчанию.
   *
   * Нужно из-за истории: в БД у чатов, созданных до перехода на локальную модель, записаны
   * идентификаторы xAI (`grok-*`), которых на маке нет. Отвечать на такой чат ошибкой «модель
   * не найдена» неправильно — человек ничего не делал, это мы поменяли провайдера, поэтому
   * старый чат молча продолжается на модели по умолчанию (в лог уходит предупреждение).
   */
  async resolveModel(requested: string): Promise<string> {
    const fallback = this.defaultModel;
    try {
      const models = await this.listModels();
      const known = models.some((m) => m.id === requested);
      if (known) return requested;
      this.logger.warn(
        `модель «${requested}» на локальном сервере не найдена — отвечаю моделью «${fallback}»`,
      );
      return fallback;
    } catch {
      // Список не пришёл — не повод отказывать: пусть запрос уйдёт с тем, что просили, а
      // настоящую причину покажет ошибка самого запроса.
      return requested || fallback;
    }
  }

  /**
   * Ответ модели потоком.
   *
   * Отдаёт порции по мере генерации; [signal] рвёт запрос, когда клиент закрыл соединение —
   * иначе мак продолжал бы считать ответ, которого уже никто не увидит (и держал бы на этом
   * весь свой единственный поток генерации).
   */
  async *streamChat(params: {
    model: string;
    messages: LlmMessage[];
    signal: AbortSignal;
  }): AsyncGenerator<LlmDelta> {
    if (!this.configured) {
      throw new LlmError('на сервере не задан адрес локальной модели (LLM_BASE_URL)');
    }
    const started = Date.now();
    const url = `${this.baseUrl()}/v1/chat/completions`;
    let res: Response;
    try {
      res = await fetch(url, {
        method: 'POST',
        headers: this.headers(),
        body: JSON.stringify({
          model: params.model,
          messages: params.messages,
          stream: true,
          // Расход приходит последним чанком; без этого флага локальный сервер его не присылает,
          // и в интерфейсе не было бы ни токенов, ни понимания, сколько это стоило по времени.
          stream_options: { include_usage: true },
          max_tokens: MAX_OUTPUT_TOKENS,
          // Температура ниже единицы: чат — не генератор идей, а помощник, и «творчество»
          // здесь выглядит как выдуманные имена файлов и ссылки.
          temperature: 0.3,
          ...(env.LLM_REASONING.trim() ? { reasoning_effort: env.LLM_REASONING.trim() } : {}),
        }),
        signal: params.signal,
      });
    } catch (e) {
      // сюда попадает и обрыв сети, и отмена по сигналу
      const reason = e instanceof Error ? e.message : String(e);
      this.logger.warn(`локальная модель ${params.model}: запрос не ушёл — ${reason}`);
      throw new LlmError('нет связи с локальной моделью', undefined, reason);
    }

    if (!res.ok) {
      // Тело читаем целиком: в нём причина отказа («model not found», «context length exceeded»),
      // и без него в логе остаётся один код.
      const details = await res.text().catch(() => '');
      this.logger.error(
        `локальная модель ${params.model}: HTTP ${res.status} — ${details.slice(0, 500) || 'без тела'}`,
      );
      throw new LlmError(this.hintFor(res.status, details), res.status, details);
    }

    const body = res.body;
    if (!body) {
      this.logger.error(`локальная модель ${params.model}: ответ без тела`);
      throw new LlmError('LM Studio закрыл соединение, не прислав ответ');
    }

    // Поток SSE читаем вручную, но с буфером: сетевой чанк не обязан совпадать со строкой и
    // может разрезать JSON посередине. Буфер особенно нужен здесь, потому что между маком и
    // VPS лежит SSH-туннель, который режет поток на куски произвольного размера.
    const reader = body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    let usage: LlmDelta['usage'];
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        // последний кусок строки может быть неполным — оставляем его до следующего чтения
        buffer = lines.pop() ?? '';
        for (const line of lines) {
          const parsed = this.parseFrame(line);
          if (!parsed) continue;
          // Отказ внутри потока поднимаем исключением, а не тихим концом: контроллер поймает его
          // и объяснит причину человеку, а уже пришедший текст сохранит как частичный ответ.
          if (parsed.error) throw new LlmError(parsed.error, undefined, parsed.error);
          if (parsed.usage) usage = parsed.usage;
          // Чанк с расходом приходит пустым по тексту (choices пустой, один usage), поэтому
          // отдавать наверх нужно и его: иначе контроллер не увидит ни токенов, ни стоимости, и
          // в интерфейсе ответ останется без расхода вовсе.
          if (parsed.text || parsed.reasoning || parsed.usage || parsed.terminal) yield parsed;
          if (parsed.terminal) {
            this.logger.log(
              `локальная модель ${params.model}: ответ готов за ${Date.now() - started} мс, ` +
                `токенов ${usage ? `${usage.promptTokens}→${usage.completionTokens}` : 'неизвестно'}`,
            );
            return;
          }
        }
      }
      // поток кончился без завершающего события: так бывает при обрыве
      this.logger.warn(
        `локальная модель ${params.model}: поток закончился без [DONE] за ${Date.now() - started} мс`,
      );
    } finally {
      // отпускаем соединение и при нормальном конце, и при отмене
      await reader.cancel().catch(() => undefined);
    }
  }

  /**
   * Сжимает разговор в короткую текстовую выжимку (компакция контекста).
   *
   * Нужна потому, что каждый ответ пересылает предыдущую переписку заново, а на маке это
   * дорого не деньгами, а временем: префилл идёт около 300 токенов в секунду, и разговор на
   * восемь тысяч токенов — это полминуты ожидания перед первым словом каждого ответа.
   *
   * В отличие от прежнего провайдера, который возвращал непрозрачный зашифрованный блок,
   * здесь выжимка — обычный текст: его пишет та же локальная модель, и он же уходит в
   * следующий запрос. Разбирать или дополнять его не нужно, он заменяет историю целиком.
   *
   * Инструкция кладётся последней репликой человека, а не системным сообщением. Замер на живой
   * Gemma 4: с инструкцией в `system` модель отвечает одним токеном и пустым текстом, с той же
   * инструкцией после переписки — нормальной выжимкой на 115 токенов. Поэтому `prompt` тут
   * текст от лица человека, а не роль.
   *
   * Возвращает текст выжимки или `null`, если сжать не удалось: без компакции разговор
   * продолжит дорожать временем, но не сломается.
   */
  async compact(params: { model: string; messages: LlmMessage[]; prompt: string }): Promise<string | null> {
    if (!this.configured) return null;
    let res: Response;
    try {
      res = await fetch(`${this.baseUrl()}/v1/chat/completions`, {
        method: 'POST',
        headers: this.headers(),
        body: JSON.stringify({
          model: params.model,
          messages: [...params.messages, { role: 'user', content: params.prompt }],
          stream: false,
          max_tokens: 700,
          temperature: 0.2,
          ...(env.LLM_REASONING.trim() ? { reasoning_effort: env.LLM_REASONING.trim() } : {}),
        }),
        // Сжатие — самая долгая операция в разделе: на вход уходит вся переписка, поэтому
        // таймаут щедрый. Идёт она в фоне, человек её не ждёт.
        signal: AbortSignal.timeout(300_000),
      });
    } catch (e) {
      this.logger.warn(`компакция не отправлена — ${e instanceof Error ? e.message : e}`);
      return null;
    }
    if (!res.ok) {
      const details = await res.text().catch(() => '');
      this.logger.warn(`компакция отклонена HTTP ${res.status} — ${details.slice(0, 300)}`);
      return null;
    }
    const data = (await res.json().catch(() => null)) as Record<string, unknown> | null;
    const choices = data?.choices;
    const message = Array.isArray(choices)
      ? ((choices[0] as Record<string, unknown> | undefined)?.message as Record<string, unknown> | undefined)
      : undefined;
    const blob = typeof message?.content === 'string' ? message.content.trim() : '';
    if (!blob) {
      this.logger.warn('компакция вернула пустой ответ — выжимка не сохранена');
      return null;
    }
    const usage = data?.usage as Record<string, unknown> | undefined;
    this.logger.log(
      `разговор сжат в выжимку ${blob.length} симв. (токенов ${usage?.prompt_tokens ?? '?'}→${usage?.completion_tokens ?? '?'})`,
    );
    return blob;
  }

  /**
   * Разбирает одну строку SSE в порцию ответа, `null` — если разбирать нечего.
   *
   * Битый JSON не считается ошибкой потока: одна неразобранная порция — потеря нескольких
   * символов, тогда как исключение здесь оборвало бы всю генерацию. Чанки без текста (роль,
   * пустые дельты) пропускаем, а завершающий `data: [DONE]` — это терминальное событие:
   * после него генерации уже нет, и ждать ещё чего-то нельзя. Отдельный случай — объект с
   * `error`: он возвращается как есть, а исключение из него делает вызывающий код, потому что
   * решение «показать человеку или проглотить» принимает не разбор строки.
   */
  private parseFrame(rawLine: string): (LlmDelta & { terminal?: boolean; error?: string }) | null {
    const line = rawLine.trim();
    if (!line.startsWith('data:')) return null;
    const payload = line.slice('data:'.length).trim();
    if (!payload) return null;
    if (payload === '[DONE]') return { terminal: true };

    let decoded: unknown;
    try {
      decoded = JSON.parse(payload);
    } catch {
      return null;
    }
    if (typeof decoded !== 'object' || decoded === null) return null;
    const frame = decoded as Record<string, unknown>;

    // Ошибку внутри потока сервер присылает отдельным объектом: текст нужен и в лог, и клиенту.
    const error = frame.error as Record<string, unknown> | undefined;
    if (error) {
      const message = typeof error.message === 'string' ? error.message : JSON.stringify(error);
      this.logger.error(`локальная модель: ошибка в потоке — ${message.slice(0, 500)}`);
      return { error: message };
    }

    const usage = frame.usage as Record<string, unknown> | undefined;
    const choices = frame.choices;
    const delta = Array.isArray(choices)
      ? ((choices[0] as Record<string, unknown> | undefined)?.delta as Record<string, unknown> | undefined)
      : undefined;

    const out: LlmDelta & { terminal?: boolean; error?: string } = {};
    if (typeof delta?.content === 'string' && delta.content) out.text = delta.content;
    // Имя поля у LM Studio — `reasoning_content` (как у DeepSeek и Qwen); у других серверов
    // встречается `reasoning`, поэтому принимаем оба, чтобы смена сервера не гасила размышления.
    const reasoning = delta?.reasoning_content ?? delta?.reasoning;
    if (typeof reasoning === 'string' && reasoning) out.reasoning = reasoning;
    if (usage) {
      out.usage = {
        promptTokens: typeof usage.prompt_tokens === 'number' ? usage.prompt_tokens : 0,
        completionTokens: typeof usage.completion_tokens === 'number' ? usage.completion_tokens : 0,
        cachedTokens: 0,
        // Поиск делает сервер, а не модель: конкретное число подставляет контроллер.
        searches: 0,
        // Локальная модель не стоит денег — ноль здесь не «неизвестно», а точная правда.
        costUsd: 0,
      };
    }
    return Object.keys(out).length ? out : null;
  }

  /** База API локального сервера без хвостового слэша. */
  private baseUrl(): string {
    return env.LLM_BASE_URL.trim().replace(/\/+$/, '');
  }

  /** Заголовки запроса: ключ отправляем только если он задан (обычно LM Studio его не требует). */
  private headers(): Record<string, string> {
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    const key = env.LLM_API_KEY.trim();
    if (key) headers.Authorization = `Bearer ${key}`;
    return headers;
  }

  /** GET к локальному серверу с разбором ответа в JSON. */
  private async getJson(path: string): Promise<unknown> {
    const url = `${this.baseUrl()}${path}`;
    let res: Response;
    try {
      res = await fetch(url, { headers: this.headers(), signal: AbortSignal.timeout(20_000) });
    } catch (e) {
      const reason = e instanceof Error ? e.message : String(e);
      this.logger.warn(`локальная модель ${path}: запрос не ушёл — ${reason}`);
      throw new LlmError('нет связи с локальной моделью', undefined, reason);
    }
    if (!res.ok) {
      const details = await res.text().catch(() => '');
      this.logger.warn(`локальная модель ${path}: HTTP ${res.status} — ${details.slice(0, 300) || 'без тела'}`);
      throw new LlmError(this.hintFor(res.status, details), res.status, details);
    }
    return res.json();
  }

  /** Причина отказа локального сервера, переведённая в то, что человеку есть с чем делать. */
  private hintFor(status: number, details: string): string {
    if (status === 401 || status === 403) return 'LM Studio не принял ключ сервера — проверьте LLM_API_KEY';
    if (status === 404) return 'LM Studio не знает такую модель — выберите модель заново';
    if (status === 400) return `LM Studio отклонил запрос: ${details.slice(0, 200) || 'неверные параметры'}`;
    if (status === 503) return 'LM Studio занят другой генерацией — повторите вопрос';
    return `LM Studio ответил ошибкой ${status}`;
  }
}
