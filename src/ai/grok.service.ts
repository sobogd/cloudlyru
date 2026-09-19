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

/**
 * Разобранная строка потока: порция ответа ([delta]) и признак того, что поток на ней
 * закончился ([terminal]).
 *
 * Терминальное событие приносит расход и стоимость, поэтому просто отбросить его нельзя:
 * без пометки поток выглядел бы оборванным, и в лог на каждый ответ шло бы предупреждение.
 */
type ParsedFrame =
  | { delta?: GrokDelta; terminal: boolean }
  | 'failed'
  | null;

/** Порция ответа модели. */
export interface GrokDelta {
  /** Кусок текста ответа. */
  text?: string;
  /** Кусок «размышлений» reasoning-модели. */
  reasoning?: string;
  /**
   * Модель пошла искать в интернете (`true`) или закончила искать (`false`).
   *
   * Отдельным событием, а не молчанием: с поиском ответ идёт десятками секунд, и человек
   * должен видеть, что происходит, а не решать, что чат завис.
   */
  searching?: boolean;
  /** Расход на ответ: приходит один раз, в завершающем событии потока. */
  usage?: { promptTokens: number; completionTokens: number; searches: number; costUsd: number };
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
 * Почему `responses`, а не `chat/completions`: поиск в интернете (серверный инструмент
 * `web_search`) существует только здесь. Старый способ включить поиск в `chat/completions`
 * (`search_parameters`, он же Live Search) провайдер отключил — на живой запрос он отвечает
 * `410 Live search is deprecated`, из-за чего модель без инструментов честно говорила, что
 * свежих данных у неё нет (её знания заканчиваются 1 февраля 2026). `chat/completions` при
 * этом официально legacy, так что переезд нужен был в любом случае.
 *
 * Историю по-прежнему храним сами (`store: false`): переписка лежит в нашей БД, у провайдера
 * ей делать нечего. Расход и точная стоимость ответа приходят в завершающем событии потока.
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
    const url = `${this.baseUrl}/responses`;
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
          // В Responses API история называется `input`; роли те же (system/user/assistant)
          input: params.messages,
          stream: true,
          // Историю храним сами, у провайдера переписке делать нечего: с `store: true` ответы
          // лежат у него 30 дней, и это ещё одна копия личной переписки на чужой стороне.
          store: false,
          // Поиск в интернете. Инструмент включён всегда, а искать или нет — решает модель по
          // вопросу (`auto`-поведение у инструментов: она вызывает его, только когда данных
          // не хватает). Один вызов поиска стоит $0.005, поэтому в лог пишем их число.
          tools: [{ type: 'web_search' }],
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
    // Идёт ли поиск прямо сейчас. Следим за переходами сами: провайдер присылает «начал» и
    // «закончил» на каждый вызов, а вызовов за один ответ бывает несколько — без склейки
    // подпись «Ищу в интернете…» мигала бы на экране по три раза за ответ.
    let searching = false;
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
          if (parsed === 'failed') {
            // провайдер сам сообщил, что запрос не удался: причину уже залогировали в parseFrame
            return;
          }
          if (!parsed) continue;

          const delta = parsed.delta;
          if (delta) {
            if (delta.searching === true) {
              // сообщаем только о начале поиска; «закончил искать» само по себе не показываем —
              // модель может тут же пойти искать второй раз
              if (!searching) {
                searching = true;
                yield { searching: true };
              }
            } else if (delta.searching === false) {
              // переход «поиск закончен» на экран не отдаём: его снимает первый же текст
            } else {
              if (delta.usage) usage = delta.usage;
              // пошёл текст — значит поиск позади, снимаем подпись
              if (delta.text && searching) {
                searching = false;
                yield { searching: false };
              }
              yield delta;
            }
          }

          if (parsed.terminal) {
            this.logger.log(
              `xAI ${params.model}: ответ готов за ${Date.now() - started} мс, ` +
                `токенов ${usage ? `${usage.promptTokens}→${usage.completionTokens}` : 'неизвестно'}` +
                (usage ? `, поисков ${usage.searches}, стоимость $${usage.costUsd.toFixed(4)}` : ''),
            );
            return;
          }
        }
      }
      // поток кончился без завершающего события: так бывает при обрыве на стороне провайдера
      this.logger.warn(
        `xAI ${params.model}: поток закончился без завершающего события за ${Date.now() - started} мс`,
      );
    } finally {
      // отпускаем соединение и при нормальном конце, и при отмене
      await reader.cancel().catch(() => undefined);
    }
  }

  /**
   * Разбирает одну строку SSE Responses API.
   *
   * Возвращает порцию ответа, `'done'` на завершающем событии, `'failed'` на отказе провайдера
   * или `null`, если разбирать нечего. Битый JSON не считается ошибкой потока: одна
   * неразобранная порция — потеря нескольких символов, тогда как исключение здесь оборвало бы
   * всю генерацию.
   *
   * Имена событий отличаются от `chat/completions`: текст приходит `response.output_text.delta`,
   * «размышления» — `response.reasoning_summary_text.delta` (у Responses это краткое изложение
   * хода мысли), расход и стоимость — одним событием `response.completed`, поиск виден по
   * `response.web_search_call.*`. Набор проверен на живом API: перечисленные события приходят
   * с включённым `web_search`, и завершающего `data: [DONE]` здесь нет вовсе.
   */
  private parseFrame(rawLine: string): ParsedFrame {
    const line = rawLine.trim();
    if (!line.startsWith('data:')) return null;
    const payload = line.slice('data:'.length).trim();
    if (!payload) return null;
    // завершающая строка осталась от прежнего формата — принимаем и её, чтобы смена
    // провайдером вида потока не превращалась в «поток без конца»
    if (payload === '[DONE]') return { terminal: true };

    let decoded: unknown;
    try {
      decoded = JSON.parse(payload);
    } catch {
      return null;
    }
    if (typeof decoded !== 'object' || decoded === null) return null;
    const frame = decoded as Record<string, unknown>;
    const type = typeof frame.type === 'string' ? frame.type : '';

    switch (type) {
      case 'response.output_text.delta':
        return typeof frame.delta === 'string' && frame.delta
          ? { delta: { text: frame.delta }, terminal: false }
          : null;
      case 'response.reasoning_summary_text.delta':
        return typeof frame.delta === 'string' && frame.delta
          ? { delta: { reasoning: frame.delta }, terminal: false }
          : null;
      case 'response.web_search_call.in_progress':
      case 'response.web_search_call.searching':
        return { delta: { searching: true }, terminal: false };
      case 'response.web_search_call.completed':
        return { delta: { searching: false }, terminal: false };
      case 'response.completed': {
        const response = frame.response as Record<string, unknown> | undefined;
        const usage = response?.usage as Record<string, unknown> | undefined;
        const ticks = typeof usage?.cost_in_usd_ticks === 'number' ? usage.cost_in_usd_ticks : 0;
        // завершающее событие: расход отдаём наверх и говорим, что поток на этом закончился
        return {
          delta: {
            usage: {
              promptTokens: typeof usage?.input_tokens === 'number' ? usage.input_tokens : 0,
              completionTokens: typeof usage?.output_tokens === 'number' ? usage.output_tokens : 0,
              searches:
                typeof usage?.num_server_side_tools_used === 'number'
                  ? usage.num_server_side_tools_used
                  : 0,
              // «тик» у xAI — стомиллионная доллара (10 000 000 000 тиков в долларе)
              costUsd: ticks / 1e10,
            },
          },
          terminal: true,
        };
      }
      case 'response.failed':
      case 'response.incomplete': {
        const response = frame.response as Record<string, unknown> | undefined;
        const error = response?.error as Record<string, unknown> | undefined;
        const message =
          typeof error?.message === 'string' ? error.message : 'xAI не смог выполнить запрос';
        this.logger.error(`xAI: ${type} — ${message}`);
        return 'failed';
      }
      case 'error': {
        // ошибки внутри потока xAI присылает этим событием; текст нужен и в лог, и клиенту
        const message = typeof frame.message === 'string' ? frame.message : JSON.stringify(frame);
        this.logger.error(`xAI: ошибка в потоке — ${message.slice(0, 500)}`);
        return 'failed';
      }
      default:
        // остальные события (создание ответа, добавление частей, done-события) для чата
        // смысла не несут: текст, размышления и расход приходят перечисленными выше
        return null;
    }
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
