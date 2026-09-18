import { Injectable, Logger } from '@nestjs/common';
import { env } from '../config/env';

/** Роль сообщения в том виде, в каком её понимает API провайдера. */
export type GrokRole = 'system' | 'user' | 'assistant';

/** Сообщение, уходящее провайдеру в теле запроса. */
export interface GrokMessage {
  role: GrokRole;
  content: string;
}

/** Модель, доступная ключу сервера. */
export interface GrokModel {
  id: string;
  /** Размер контекста в токенах, если провайдер его сообщил. */
  contextLength: number | null;
  /** Цена входа за 1 млн токенов в долларах. */
  inputPricePerMillion: number | null;
  /** Цена выхода за 1 млн токенов в долларах. */
  outputPricePerMillion: number | null;
}

/** Порция ответа модели. */
export interface GrokDelta {
  /** Кусок текста ответа. */
  text?: string;
  /** Кусок «размышлений» reasoning-модели. */
  reasoning?: string;
  /** Расход токенов на текущий момент (провайдер присылает его в каждом чанке). */
  usage?: { promptTokens: number; completionTokens: number };
}

/**
 * Ошибка обращения к xAI с причиной, пригодной для показа человеку.
 *
 * Отдельный тип, а не HttpException: сервис не знает, в каком виде ошибка уйдёт наружу —
 * до начала потока это HTTP-ответ, внутри потока — событие SSE. Решение принимает контроллер.
 */
export class GrokError extends Error {
  constructor(
    message: string,
    /** HTTP-код ответа xAI, если он был. */
    readonly status?: number,
    /** Ответ провайдера целиком — уходит в лог, но не клиенту. */
    readonly details?: string,
  ) {
    super(message);
    this.name = 'GrokError';
  }
}

/**
 * Клиент xAI (Grok): список моделей и ответ потоком.
 *
 * Ключ берётся из окружения сервера (`GROK_API_KEY`) и никогда не уходит клиенту. Все запросы
 * и ошибки логируются: раздел «Чат» разбирают по логам pm2, а не по сообщению на экране —
 * у провайдера причин отказа много (ключ, квота, недоступная модель, лимит), и по ответу
 * «не работает» без лога не отличить одну от другой.
 *
 * Почему `chat/completions`, хотя у xAI он помечен legacy: это документированный
 * OpenAI-совместимый SSE, которого достаточно для чата. `/v1/responses` тянет за собой
 * хранение истории на стороне провайдера — это отдельное решение, его принимают, когда
 * понадобятся инструменты и веб-поиск.
 */
@Injectable()
export class GrokService {
  private readonly logger = new Logger(GrokService.name);

  /** База API xAI; версия в пути — часть контракта, а не украшение. */
  private readonly baseUrl = 'https://api.x.ai/v1';

  /** Кэш списка моделей: набор зависит от ключа и меняется редко, а ходить за ним на каждый
   *  показ вкладки незачем. Неудача не кэшируется — иначе раздел «Чат» остался бы без моделей
   *  до перезапуска процесса после короткого сбоя сети. */
  private modelsCache: { at: number; models: GrokModel[] } | null = null;

  /** Сколько живёт кэш моделей, мс. */
  private readonly modelsTtlMs = 10 * 60 * 1000;

  /** Задан ли ключ xAI на сервере. */
  get configured(): boolean {
    return env.GROK_API_KEY.trim().length > 0;
  }

  /**
   * Список моделей, доступных ключу сервера.
   *
   * Два запроса, потому что одного мало: `/language-models` отдаёт именно чат-модели (в нём
   * нет генераторов картинок и видео, которые чат не обслуживают) вместе с ценами, но без
   * размера контекста; контекст лежит в `/models`. Неудача второго запроса список не отменяет:
   * контекст — справка в подписи, терять из-за него сами модели нельзя.
   */
  async listModels(): Promise<GrokModel[]> {
    if (!this.configured) return [];
    const cached = this.modelsCache;
    if (cached && Date.now() - cached.at < this.modelsTtlMs) return cached.models;

    const models = await this.fetchLanguageModels();
    const contexts = await this.fetchContextLengths();
    const withContext = models.map((m) => ({ ...m, contextLength: contexts.get(m.id) ?? null }));

    this.logger.log(`xAI: моделей доступно ${withContext.length} (${withContext.map((m) => m.id).join(', ')})`);
    this.modelsCache = { at: Date.now(), models: withContext };
    return withContext;
  }

  /**
   * Ответ модели потоком.
   *
   * Отдаёт порции по мере генерации; [signal] рвёт запрос к xAI, когда клиент закрыл
   * соединение — иначе генерация продолжалась бы до конца, а токены списывались бы за ответ,
   * которого уже никто не увидит.
   */
  async *streamChat(params: {
    model: string;
    messages: GrokMessage[];
    signal: AbortSignal;
  }): AsyncGenerator<GrokDelta> {
    if (!this.configured) {
      throw new GrokError('на сервере не задан ключ xAI (GROK_API_KEY)');
    }
    const started = Date.now();
    const url = `${this.baseUrl}/chat/completions`;
    let res: Response;
    try {
      res = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${env.GROK_API_KEY.trim()}`,
        },
        body: JSON.stringify({
          model: params.model,
          messages: params.messages,
          stream: true,
        }),
        signal: params.signal,
      });
    } catch (e) {
      // сюда попадает и обрыв сети, и отмена по сигналу
      const reason = e instanceof Error ? e.message : String(e);
      this.logger.warn(`xAI ${params.model}: запрос не ушёл — ${reason}`);
      throw new GrokError('нет связи с xAI', undefined, reason);
    }

    if (!res.ok) {
      // Тело читаем целиком: в нём причина отказа («model not found», «insufficient credits»),
      // и без него в логе остаётся один код. Ключ в теле не приходит, поэтому логировать его
      // безопасно.
      const details = await res.text().catch(() => '');
      this.logger.error(
        `xAI ${params.model}: HTTP ${res.status} — ${details.slice(0, 500) || 'без тела'}`,
      );
      throw new GrokError(this.hintFor(res.status, details), res.status, details);
    }

    const body = res.body;
    if (!body) {
      this.logger.error(`xAI ${params.model}: ответ без тела`);
      throw new GrokError('xAI закрыл соединение, не прислав ответ');
    }

    // Поток SSE читаем вручную, но с буфером: сетевой чанк не обязан совпадать со строкой и
    // может разрезать JSON посередине. Без буфера ответ рвётся на длинных сообщениях — это
    // ровно та ошибка, из-за которой разбор потока переписывают «на удачу».
    const reader = body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    let usage: GrokDelta['usage'];
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        // последний кусок строки может быть неполным — оставляем его до следующего чтения
        buffer = lines.pop() ?? '';
        for (const line of lines) {
          const delta = this.parseFrame(line);
          if (delta === 'done') {
            this.logger.log(
              `xAI ${params.model}: ответ готов за ${Date.now() - started} мс, ` +
                `токенов ${usage ? `${usage.promptTokens}→${usage.completionTokens}` : 'неизвестно'}`,
            );
            return;
          }
          if (!delta) continue;
          if (delta.usage) usage = delta.usage;
          yield delta;
        }
      }
      // поток кончился без [DONE]: так бывает при обрыве на стороне провайдера
      this.logger.warn(
        `xAI ${params.model}: поток закончился без [DONE] за ${Date.now() - started} мс`,
      );
    } finally {
      // отпускаем соединение и при нормальном конце, и при отмене
      await reader.cancel().catch(() => undefined);
    }
  }

  /**
   * Разбирает одну строку SSE.
   *
   * Возвращает порцию ответа, строку `'done'` на признаке конца или `null`, если разбирать
   * нечего. Битый JSON не считается ошибкой потока: одна неразобранная порция — потеря
   * нескольких символов, тогда как исключение здесь оборвало бы всю генерацию.
   */
  private parseFrame(rawLine: string): GrokDelta | 'done' | null {
    const line = rawLine.trim();
    if (!line.startsWith('data:')) return null;
    const payload = line.slice('data:'.length).trim();
    if (!payload) return null;
    if (payload === '[DONE]') return 'done';

    let decoded: unknown;
    try {
      decoded = JSON.parse(payload);
    } catch {
      return null;
    }
    if (typeof decoded !== 'object' || decoded === null) return null;
    const frame = decoded as Record<string, unknown>;

    const out: GrokDelta = {};
    const choices = frame.choices;
    if (Array.isArray(choices) && choices.length > 0) {
      const first = choices[0] as Record<string, unknown> | undefined;
      const delta = first?.delta as Record<string, unknown> | undefined;
      if (delta) {
        if (typeof delta.content === 'string' && delta.content) out.text = delta.content;
        // «размышления» reasoning-модели приходят тем же потоком, но отдельным полем
        if (typeof delta.reasoning_content === 'string' && delta.reasoning_content) {
          out.reasoning = delta.reasoning_content;
        }
      }
    }
    const usage = frame.usage as Record<string, unknown> | undefined;
    if (usage) {
      out.usage = {
        promptTokens: typeof usage.prompt_tokens === 'number' ? usage.prompt_tokens : 0,
        completionTokens: typeof usage.completion_tokens === 'number' ? usage.completion_tokens : 0,
      };
    }
    return out.text || out.reasoning || out.usage ? out : null;
  }

  /** Чат-модели ключа с ценами — из `GET /v1/language-models`. */
  private async fetchLanguageModels(): Promise<GrokModel[]> {
    const data = await this.getJson('/language-models');
    const models = (data as { models?: unknown }).models;
    if (!Array.isArray(models)) {
      throw new GrokError('xAI вернул список моделей в незнакомом виде', undefined, JSON.stringify(data).slice(0, 300));
    }
    return models
      .filter((m): m is Record<string, unknown> => typeof m === 'object' && m !== null)
      .map((m) => ({
        id: typeof m.id === 'string' ? m.id : '',
        contextLength: null,
        inputPricePerMillion: this.usdPerMillion(m.prompt_text_token_price),
        outputPricePerMillion: this.usdPerMillion(m.completion_text_token_price),
      }))
      .filter((m) => m.id.length > 0);
  }

  /** Размеры контекста по идентификаторам моделей — из `GET /v1/models`. */
  private async fetchContextLengths(): Promise<Map<string, number>> {
    try {
      const data = await this.getJson('/models');
      const list = (data as { data?: unknown }).data;
      const out = new Map<string, number>();
      if (!Array.isArray(list)) return out;
      for (const item of list) {
        if (typeof item !== 'object' || item === null) continue;
        const m = item as Record<string, unknown>;
        if (typeof m.id === 'string' && typeof m.context_length === 'number' && m.context_length > 0) {
          out.set(m.id, m.context_length);
        }
      }
      return out;
    } catch (e) {
      // контекст — только справка в интерфейсе, из-за него не отказываем в списке моделей
      this.logger.warn(`xAI: размеры контекста не получены — ${e instanceof Error ? e.message : e}`);
      return new Map();
    }
  }

  /** GET к xAI с ключом сервера и разбором ответа в JSON. */
  private async getJson(path: string): Promise<unknown> {
    const url = `${this.baseUrl}${path}`;
    let res: Response;
    try {
      res = await fetch(url, {
        headers: { Authorization: `Bearer ${env.GROK_API_KEY.trim()}` },
        signal: AbortSignal.timeout(20_000),
      });
    } catch (e) {
      const reason = e instanceof Error ? e.message : String(e);
      this.logger.warn(`xAI ${path}: запрос не ушёл — ${reason}`);
      throw new GrokError('нет связи с xAI', undefined, reason);
    }
    if (!res.ok) {
      const details = await res.text().catch(() => '');
      this.logger.warn(`xAI ${path}: HTTP ${res.status} — ${details.slice(0, 300) || 'без тела'}`);
      throw new GrokError(this.hintFor(res.status, details), res.status, details);
    }
    return res.json();
  }

  /**
   * Цена xAI в долларах за 1 млн токенов или `null`, если цена не пришла.
   *
   * Провайдер отдаёт цены в центах за 100 млн токенов (`20000` — это $200 за 100 млн, то есть
   * $2 за 1M), поэтому делим на 10 000. Без пересчёта в интерфейсе были бы цены, отличающиеся
   * от настоящих в сто раз.
   */
  private usdPerMillion(cents: unknown): number | null {
    return typeof cents === 'number' && cents > 0 ? cents / 10000 : null;
  }

  /** Причина отказа xAI, переведённая в то, что человеку есть с чем делать. */
  private hintFor(status: number, details: string): string {
    if (status === 401 || status === 403) return 'xAI не принял ключ сервера — проверьте GROK_API_KEY';
    if (status === 429) return 'xAI отклонил запрос: исчерпан лимит или квота';
    if (status === 400) return `xAI отклонил запрос: ${details.slice(0, 200) || 'неверные параметры'}`;
    if (status === 404) return 'xAI не знает такую модель — выберите модель заново';
    return `xAI ответил ошибкой ${status}`;
  }
}
