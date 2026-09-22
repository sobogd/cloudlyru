import { Injectable, Logger } from '@nestjs/common';
import { env } from '../config/env';

/** Сообщение запроса в том виде, в каком его понимает OpenAI-совместимый движок. */
export interface LlmMessage {
  role: 'system' | 'user';
  content: string;
}

/** Причина отказа движка, от которой зависит, что показать человеку. */
export type LlmErrorCode = 'unavailable' | 'timeout' | 'http';

/** Ошибка обращения к локальной модели. Контроллер сам решает, каким HTTP-кодом её отдать. */
export class LlmError extends Error {
  constructor(
    message: string,
    readonly code: LlmErrorCode,
  ) {
    super(message);
    this.name = 'LlmError';
  }
}

/**
 * Клиент локальной модели на маке: один полный ответ по стандартному OpenAI-совместимому
 * протоколу (`POST /v1/chat/completions`).
 *
 * Говорим только этим протоколом и не знаем, что именно отвечает — сегодня это llama.cpp,
 * завтра LM Studio или Ollama: переезд сводится к смене `LLM_BASE_URL`, а не к правке кода.
 * Потока здесь нет намеренно: перевод письма показывается целиком, поэтому клиенту не нужны
 * ни SSE, ни промежуточные состояния — только готовый текст или причина отказа.
 */
@Injectable()
export class LlmService {
  private readonly logger = new Logger(LlmService.name);

  /** Задан ли адрес модели: пусто — перевод отвечает отказом, а не ходит в никуда. */
  get configured(): boolean {
    return env.LLM_BASE_URL.trim().length > 0;
  }

  /**
   * Один полный ответ модели без потока. Возвращает текст ответа без крайних пробелов.
   *
   * Бросает [LlmError] на любую неудачу, чтобы вызывающий код не видел сырой TypeError от fetch:
   * у сетевого обрыва, таймаута и отказа движка разные коды, и человеку про них говорят разное.
   */
  async chat(params: {
    messages: LlmMessage[];
    maxTokens: number;
    temperature?: number;
  }): Promise<string> {
    if (!this.configured) {
      throw new LlmError('на сервере не задан адрес локальной модели (LLM_BASE_URL)', 'unavailable');
    }

    const url = `${this.baseUrl()}/v1/chat/completions`;
    let res: Response;
    try {
      res = await fetch(url, {
        method: 'POST',
        headers: this.headers(),
        body: JSON.stringify(this.body(params)),
        // Свой потолок времени: перевод не должен висеть вечно, если движок перестал отвечать.
        signal: AbortSignal.timeout(this.timeoutMs()),
      });
    } catch (err) {
      throw this.networkError(err);
    }
    if (!res.ok) throw await this.httpError(res);

    const data = (await res.json()) as { choices?: { message?: { content?: string } }[] };
    const text = data.choices?.[0]?.message?.content;
    return typeof text === 'string' ? text.trim() : '';
  }

  /** Тело запроса: модель, сообщения, потолок ответа и выключатель размышлений. */
  private body(params: { messages: LlmMessage[]; maxTokens: number; temperature?: number }): Record<string, unknown> {
    const body: Record<string, unknown> = {
      model: env.LLM_MODEL.trim(),
      messages: params.messages,
      stream: false,
      // Температура ниже единицы: перевод — не генератор идей, и «творчество» тут выглядит как
      // переписанные по-своему имена и ссылки.
      temperature: params.temperature ?? 0.2,
      max_tokens: params.maxTokens,
    };
    const reasoning = env.LLM_REASONING.trim();
    if (reasoning) body.reasoning_effort = reasoning;
    const kwargs = this.templateKwargs();
    if (kwargs) body.chat_template_kwargs = kwargs;
    return body;
  }

  /**
   * `LLM_TEMPLATE_KWARGS` разобранный в объект, или `null`.
   *
   * Битое значение логируем и игнорируем: опечатка в окружении не должна ронять перевод целиком,
   * а незнакомое поле движок просто проигнорирует.
   */
  private templateKwargs(): Record<string, unknown> | null {
    const raw = env.LLM_TEMPLATE_KWARGS.trim();
    if (!raw) return null;
    try {
      const parsed = JSON.parse(raw) as unknown;
      return parsed && typeof parsed === 'object' ? (parsed as Record<string, unknown>) : null;
    } catch {
      this.logger.warn('LLM_TEMPLATE_KWARGS не разбирается как JSON — отправляю запрос без него');
      return null;
    }
  }

  /** Адрес движка без хвостового слэша, чтобы пути не склеивались в `//`. */
  private baseUrl(): string {
    return env.LLM_BASE_URL.trim().replace(/\/+$/, '');
  }

  /** Заголовки запроса: ключ отправляем только если он задан (обычно движок его не требует). */
  private headers(): Record<string, string> {
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    const key = env.LLM_API_KEY.trim();
    if (key) headers.Authorization = `Bearer ${key}`;
    return headers;
  }

  /** Потолок одного ответа из окружения, мс. */
  private timeoutMs(): number {
    return env.LLM_TIMEOUT_MS;
  }

  /** Отказ движка с текстом его же объяснения: у llama.cpp в теле бывает и «context length
   *  exceeded», и «model not found», и по этому тексту в логе видно причину. */
  private async httpError(res: Response): Promise<LlmError> {
    let detail = '';
    try {
      detail = (await res.text()).slice(0, 300);
    } catch {
      /* тело уже прочитано — останется один код */
    }
    this.logger.error(`локальная модель: HTTP ${res.status} — ${detail || 'без тела'}`);
    return new LlmError(`модель ответила ошибкой ${res.status}`, 'http');
  }

  /** Сетевой сбой: таймаут и недоступный движок — это разные коды. */
  private networkError(err: unknown): LlmError {
    if (err instanceof LlmError) return err;
    if (err instanceof Error && (err.name === 'TimeoutError' || err.name === 'AbortError')) {
      return new LlmError('модель не ответила за отведённое время', 'timeout');
    }
    const reason = err instanceof Error ? err.message : String(err);
    this.logger.warn(`локальная модель недоступна по адресу ${this.baseUrl()}: ${reason}`);
    return new LlmError('локальная модель недоступна (мак спит или туннель отключён)', 'unavailable');
  }
}
