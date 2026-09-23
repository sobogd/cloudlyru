import { Injectable, Logger } from '@nestjs/common';
import { env } from '../config/env';

/**
 * Ошибка обращения к панели домашнего мака.
 *
 * Несёт код панели (или 0, если ответа не было) и готовый текст: причина приходит от панели,
 * а сетевые сбои формулируются здесь — контроллер только переводит это в HTTP-ответ.
 */
export class MacError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

/**
 * Потолок ожидания обычной ручки.
 *
 * 20 с: если панель не ответила за это время, она уже не ответит — а приложение всё это время
 * ждёт карточку статуса. Медленные ручки (терминал, env, github) задают свой таймаут явно.
 */
const REQUEST_TIMEOUT_MS = 20_000;

/**
 * Клиент панели управления домашним маком (`mac-status-server.py`).
 *
 * Сервер ходит к панели через reverse-SSH туннель на `http://127.0.0.1:18810` — порт открыт
 * только на loopback самого VPS, наружу не смотрит никто, ни TLS, ни ключей на этом плече нет.
 * Клиент приложения видит только ручки `/mac/*` и ни адреса туннеля, ни порта не знает.
 *
 * Сервис ничего не решает: он перекладывает запросы к панели и переводит сбои в [MacError].
 */
@Injectable()
export class MacService {
  private readonly logger = new Logger(MacService.name);

  /** Настроена ли панель: пустой адрес означает, что раздел работать не может. */
  get configured(): boolean {
    return env.MAC_STATUS_URL.trim().length > 0;
  }

  /** Адрес панели без хвостовых слэшей, чтобы пути склеивались одним способом. */
  private base(): string {
    return env.MAC_STATUS_URL.trim().replace(/\/+$/, '');
  }

  /**
   * Запрос к панели с разбором JSON.
   *
   * Отдельно разведены отказ панели (у него свой код и своя причина) и «панель недоступна» —
   * последнее означает, что мак спит или туннель отключился, и повторять бессмысленно.
   */
  async call<T>(
    method: 'GET' | 'POST',
    path: string,
    options: { body?: unknown; timeoutMs?: number } = {},
  ): Promise<T> {
    if (!this.configured) {
      throw new MacError(503, 'мак недоступен: раздел не настроен');
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? REQUEST_TIMEOUT_MS);
    try {
      const headers: Record<string, string> = {};
      if (options.body !== undefined) headers['Content-Type'] = 'application/json';
      // Сервис-токен панели: без него панель отвечает 401 на /api/* (если он у неё заведён).
      const token = env.MAC_SERVICE_TOKEN.trim();
      if (token) headers['X-Mac-Token'] = token;

      const res = await fetch(`${this.base()}${path}`, {
        method,
        signal: controller.signal,
        headers: Object.keys(headers).length ? headers : undefined,
        body: options.body === undefined ? undefined : JSON.stringify(options.body),
      });
      const text = await res.text();
      if (!res.ok) {
        throw new MacError(res.status, text.slice(0, 200) || `панель ответила ${res.status}`);
      }
      if (!text) return {} as T;
      try {
        return JSON.parse(text) as T;
      } catch {
        throw new MacError(502, `панель ответила не JSON: ${text.slice(0, 200)}`);
      }
    } catch (e) {
      if (e instanceof MacError) throw e;
      if (controller.signal.aborted) {
        throw new MacError(504, 'панель мака не ответила за 20 с');
      }
      this.logger.warn(`панель мака недоступна: ${String(e)}`);
      throw new MacError(502, 'панель мака недоступна: мак спит или туннель отключился');
    } finally {
      clearTimeout(timer);
    }
  }
}
