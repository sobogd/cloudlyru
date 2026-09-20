import { Injectable, Logger } from '@nestjs/common';
import { env } from '../config/env';

/**
 * Роль сообщения в запросе к модели. Те же имена, что понимает OpenAI-совместимый API, —
 * переводить их при сборке контекста не приходится.
 */
export type LlmRole = 'system' | 'user' | 'assistant';

/** Сообщение запроса к модели. */
export interface LlmMessage {
  role: LlmRole;
  content: string;
}

/** Расход токенов, как его посчитал сервер модели. */
export interface LlmUsage {
  promptTokens?: number;
  completionTokens?: number;
}

/**
 * Кусок ответа модели в потоке.
 *
 * `text` — то, что видит человек; `reasoning` — «размышления» reasoning-модели: на экране они
 * идут отдельным блоком и в контекст следующего запроса не попадают. Оба поля необязательны, и
 * за один кусок может прийти любое из них.
 */
export interface LlmDelta {
  text?: string;
  reasoning?: string;
  usage?: LlmUsage;
}

/** Ошибка обращения к модели: текст пригоден для показа человеку. */
export class LlmError extends Error {}

/** Модель, как её видит приложение: идентификатор и есть всё, что отдаёт стандартная ручка. */
export interface LlmModel {
  id: string;
}

/** Как долго держим список моделей: перезагрузка модели на маке не повод бить в него каждый раз. */
const MODELS_TTL_MS = 30_000;

/** Потолок ожидания коротких ответов (список моделей, сжатие истории). Генерация не ограничена. */
const SHORT_TIMEOUT_MS = 15_000;

/** Потолок ответа при сжатии истории: выжимка длиннее просто не нужна. */
const COMPACT_MAX_TOKENS = 400;

/**
 * Клиент модели на домашнем маке.
 *
 * Говорит только на стандартном OpenAI-совместимом протоколе (`GET /v1/models`,
 * `POST /v1/chat/completions`) и намеренно не знает, что именно стоит на том конце — LM Studio,
 * llama.cpp или Ollama. Прежний раздел читал список моделей из ручки LM Studio `/api/v0/models`,
 * и это привязывало сервер к приложению с графическим интерфейсом; здесь такой ручки нет.
 *
 * Цена независимости: у `/v1/models` нет ни признака «загружена в память», ни типа модели
 * (чат или эмбеддинги), поэтому список приходит простым перечнем идентификаторов. Для раздела
 * этого достаточно: чат с исчезнувшей моделью всё равно молча отвечает моделью по умолчанию.
 */
@Injectable()
export class LlmService {
  private readonly logger = new Logger(LlmService.name);

  /** Кэш списка моделей: он неизменен минутами, а запрашивается на каждое открытие раздела. */
  private modelsCache: { at: number; models: LlmModel[] } | null = null;

  /** Настроен ли раздел: без адреса модели он честно отвечает «локальная модель недоступна». */
  get configured(): boolean {
    return env.LLM_BASE_URL.trim().length > 0;
  }

  /** Модель по умолчанию для новых чатов (`LLM_MODEL`). */
  get defaultModel(): string {
    return env.LLM_MODEL.trim();
  }

  /** Адрес сервера модели без хвостового слэша: так его можно склеивать с путями ручек. */
  private baseUrl(): string {
    return env.LLM_BASE_URL.trim().replace(/\/+$/, '');
  }

  /** Заголовки запроса. Ключ нужен только если сервер модели его требует, обычно пусто. */
  private headers(): Record<string, string> {
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    const key = env.LLM_API_KEY.trim();
    if (key) headers.Authorization = `Bearer ${key}`;
    return headers;
  }

  /**
   * Список моделей, доступных на сервере модели.
   *
   * Кэшируется на [MODELS_TTL_MS]: ручка дёргается при открытии чата, а мак на каждый запрос
   * отвечает списком файлов моделей с диска.
   */
  async listModels(): Promise<LlmModel[]> {
    if (!this.configured) throw new LlmError('на сервере не задан адрес модели (LLM_BASE_URL)');
    const cached = this.modelsCache;
    if (cached && Date.now() - cached.at < MODELS_TTL_MS) return cached.models;

    const data = await this.getJson<{ data?: Array<{ id?: string }> }>('/v1/models');
    const models: LlmModel[] = (data.data ?? [])
      .map((m) => ({ id: String(m.id ?? '').trim() }))
      .filter((m) => m.id.length > 0);
    if (!models.length) throw new LlmError('сервер модели не отдал ни одной модели');

    this.logger.log(`модели: ${models.map((m) => m.id).join(', ')}`);
    this.modelsCache = { at: Date.now(), models };
    return models;
  }

  /**
   * Выбирает модель для запроса: запрошенную, если сервер её знает, иначе модель по умолчанию.
   *
   * Нужно из-за истории: в чатах, созданных раньше, записаны идентификаторы прежних моделей,
   * которых на маке больше нет. Отвечать на такой чат ошибкой «модель не найдена» неправильно —
   * человек ничего не делал, это мы поменяли модель, поэтому старый чат молча продолжается на
   * модели по умолчанию (в лог уходит предупреждение).
   */
  async resolveModel(requested: string): Promise<string> {
    const fallback = this.defaultModel;
    try {
      const models = await this.listModels();
      if (models.some((m) => m.id === requested)) return requested;
      this.logger.warn(`модель «${requested}» не найдена — отвечаю моделью «${fallback}»`);
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
   * Отдаёт куски по мере генерации; [signal] рвёт запрос, когда клиент закрыл соединение —
   * иначе мак продолжал бы считать ответ, которого уже никто не увидит, и держал бы на этом
   * свой единственный поток генерации.
   */
  async *streamChat(params: {
    model: string;
    messages: LlmMessage[];
    signal: AbortSignal;
  }): AsyncGenerator<LlmDelta> {
    if (!this.configured) {
      throw new LlmError('на сервере не задан адрес модели (LLM_BASE_URL)');
    }
    const body: Record<string, unknown> = {
      model: params.model,
      messages: params.messages,
      stream: true,
    };
    // `reasoning_effort` — не из стандарта OpenAI (его понимал LM Studio, который на маке больше
    // не стоит; llama.cpp это поле игнорирует, а «размышления» выключает флагом шаблона). Без `none` модель
    // тратит на размышления весь ответ и текста не отдаёт вовсе, поэтому значение по умолчанию
    // именно `none`. Сервер, который параметра не знает, просто его проигнорирует.
    const reasoning = env.LLM_REASONING.trim();
    if (reasoning) body.reasoning_effort = reasoning;
    this.applyTemplateKwargs(body);

    let res: Response;
    try {
      res = await fetch(`${this.baseUrl()}/v1/chat/completions`, {
        method: 'POST',
        headers: this.headers(),
        body: JSON.stringify(body),
        signal: params.signal,
      });
    } catch (e) {
      throw this.wrap(e);
    }
    if (!res.ok || !res.body) {
      throw new LlmError(`модель ответила ${res.status}: ${(await res.text()).slice(0, 300)}`);
    }

    // Разбор потока SSE вручную: строки приходят кусками, поэтому хвост неполной строки
    // переносится в следующую итерацию, а не выбрасывается.
    const decoder = new TextDecoder();
    let buffer = '';
    for await (const chunk of res.body as unknown as AsyncIterable<Uint8Array>) {
      buffer += decoder.decode(chunk, { stream: true });
      let index: number;
      while ((index = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (!line.startsWith('data:')) continue;
        const payload = line.slice(5).trim();
        if (!payload || payload === '[DONE]') continue;
        const delta = this.parseDelta(payload);
        if (delta) yield delta;
      }
    }
  }

  /**
   * Один ответ модели целиком, без потока. Нужен там, где человек ответа не видит: сжатие
   * истории в выжимку.
   */
  async complete(params: { model: string; messages: LlmMessage[]; signal?: AbortSignal }): Promise<string> {
    if (!this.configured) {
      throw new LlmError('на сервере не задан адрес модели (LLM_BASE_URL)');
    }
    const body: Record<string, unknown> = {
      model: params.model,
      messages: params.messages,
      stream: false,
      max_tokens: COMPACT_MAX_TOKENS,
    };
    const reasoning = env.LLM_REASONING.trim();
    if (reasoning) body.reasoning_effort = reasoning;
    this.applyTemplateKwargs(body);

    const data = await this.postJson<{ choices?: Array<{ message?: { content?: string } }> }>(
      '/v1/chat/completions',
      body,
      params.signal,
    );
    return (data.choices?.[0]?.message?.content ?? '').trim();
  }

  /**
   * Дополнительные поля тела запроса из `LLM_TEMPLATE_KWARGS` (JSON-объект строкой).
   *
   * Зачем отдельная настройка: «размышления» выключаются у разных серверов по-разному —
   * LM Studio понимал `reasoning_effort`, а llama.cpp (на нём считает мак) ждёт
   * `chat_template_kwargs`. Держать это в коде значило бы пересобирать сервер при смене
   * сервера модели; строка в окружении позволяет переехать одной настройкой.
   *
   * Битая строка не срывает запрос: пишем в лог и отправляем без этих полей — иначе
   * опечатка в настройке выключила бы раздел целиком.
   */
  private applyTemplateKwargs(body: Record<string, unknown>): void {
    const raw = env.LLM_TEMPLATE_KWARGS.trim();
    if (!raw) return;
    try {
      const parsed = JSON.parse(raw) as Record<string, unknown>;
      body.chat_template_kwargs = parsed;
    } catch {
      this.logger.warn('LLM_TEMPLATE_KWARGS не разобран как JSON — отправляю запрос без него');
    }
  }

  /**
   * Достаёт из строки SSE кусок ответа и расход токенов.
   *
   * Имена полей у разных серверов расходятся: `reasoning_content` (LM Studio, DeepSeek, Qwen;
   * против `reasoning`, поэтому принимаем оба — иначе после смены сервера размышления просто
   * исчезли бы с экрана, а причина была бы не видна.
   */
  private parseDelta(payload: string): LlmDelta | null {
    let parsed: {
      choices?: Array<{ delta?: { content?: string; reasoning_content?: string; reasoning?: string } }>;
      usage?: { prompt_tokens?: number; completion_tokens?: number };
    };
    try {
      parsed = JSON.parse(payload);
    } catch {
      return null;
    }
    const delta = parsed.choices?.[0]?.delta ?? {};
    const out: LlmDelta = {};
    if (typeof delta.content === 'string' && delta.content) out.text = delta.content;
    const reasoning = delta.reasoning_content ?? delta.reasoning;
    if (typeof reasoning === 'string' && reasoning) out.reasoning = reasoning;
    if (parsed.usage) {
      out.usage = {
        promptTokens: parsed.usage.prompt_tokens,
        completionTokens: parsed.usage.completion_tokens,
      };
    }
    return out.text || out.reasoning || out.usage ? out : null;
  }

  /** GET на сервер модели с потолком ожидания и понятной ошибкой. */
  private async getJson<T>(path: string): Promise<T> {
    try {
      const res = await fetch(`${this.baseUrl()}${path}`, {
        headers: this.headers(),
        signal: AbortSignal.timeout(SHORT_TIMEOUT_MS),
      });
      if (!res.ok) throw new LlmError(`модель ответила ${res.status} на ${path}`);
      return (await res.json()) as T;
    } catch (e) {
      throw this.wrap(e);
    }
  }

  /** POST на сервер модели: поток не нужен, ответ читается целиком. */
  private async postJson<T>(path: string, body: unknown, signal?: AbortSignal): Promise<T> {
    try {
      const res = await fetch(`${this.baseUrl()}${path}`, {
        method: 'POST',
        headers: this.headers(),
        body: JSON.stringify(body),
        signal: signal ?? AbortSignal.timeout(SHORT_TIMEOUT_MS * 4),
      });
      if (!res.ok) throw new LlmError(`модель ответила ${res.status}: ${(await res.text()).slice(0, 300)}`);
      return (await res.json()) as T;
    } catch (e) {
      throw this.wrap(e);
    }
  }

  /**
   * Приводит сетевые ошибки к одному типу с понятным текстом.
   *
   * Обрыв соединения — самый частый отказ: мак спит, туннель переподключается, модель выгружена.
   * Человеку важно прочитать «локальная модель недоступна», а не `TypeError: fetch failed`.
   */
  private wrap(e: unknown): LlmError {
    if (e instanceof LlmError) return e;
    if (e instanceof Error && e.name === 'TimeoutError') {
      return new LlmError('локальная модель не ответила вовремя');
    }
    if (e instanceof Error && (e.name === 'AbortError' || e.name === 'TimeoutError')) {
      return new LlmError('запрос к модели прерван');
    }
    return new LlmError('локальная модель недоступна (мак спит или туннель отключился)');
  }
}
