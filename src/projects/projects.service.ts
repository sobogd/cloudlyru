import { Injectable, Logger } from '@nestjs/common';
import { env } from '../config/env';

/**
 * Ошибка обращения к мосту pi.
 *
 * Несёт код моста (или 0, если ответа не было) и готовый текст: причина приходит от моста, а
 * сетевые сбои формулируются здесь — контроллер только переводит это в HTTP-ответ.
 */
export class ProjectsError extends Error {
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
 * 20 с, а не 60: если мост не ответил за это время, он уже не ответит — а приложение всё это
 * время ждёт списка, открытого разговора или состояния сессии. Медленные ручки (сжатие
 * контекста, распознавание речи, запуск процесса) задают свой таймаут явно.
 */
const REQUEST_TIMEOUT_MS = 20_000;

/**
 * Потолок ожидания распознавания речи.
 *
 * whisper-server считает запись на маке целиком и на длинной диктовке может уйти за минуту;
 * таймаут нужен только чтобы зависший запрос не держал соединение вечно, а не как бюджет.
 */
const STT_TIMEOUT_MS = 120_000;

/**
 * Клиент моста до харнесса pi на домашнем маке (`agents/pi-bridge/`).
 *
 * Сервер ходит к мосту через reverse-SSH туннель, на
 * `http://127.0.0.1:18820` — порт открыт только на loopback самого VPS, наружу не смотрит
 * никто, и ни TLS, ни ключей на этом плече нет. Клиент приложения видит только ручки
 * `/projects/*` и ни адресов туннеля, ни токенов не знает.
 *
 * Сервис ничего не решает: он перекладывает запросы и отдаёт поток ответа агента как есть.
 * Проекты, сессии, инструменты и история живут на маке, у pi.
 */
@Injectable()
export class ProjectsService {
  private readonly logger = new Logger(ProjectsService.name);

  /** Настроен ли мост: пустой адрес означает, что раздел работать не может. */
  get configured(): boolean {
    return env.PI_BRIDGE_URL.trim().length > 0;
  }

  /** Адрес моста без хвостовых слэшей, чтобы пути склеивались одним способом. */
  private base(): string {
    return env.PI_BRIDGE_URL.trim().replace(/\/+$/, '');
  }

  /** Настроено ли распознавание речи: без адреса ручка голосового ввода не работает. */
  get sttConfigured(): boolean {
    return env.STT_URL.trim().length > 0;
  }

  /** Адрес whisper-сервера без хвостовых слэшей, чтобы путь `/inference` склеивался верно. */
  private sttBase(): string {
    return env.STT_URL.trim().replace(/\/+$/, '');
  }

  /**
   * Обычный запрос к мосту с разбором JSON.
   *
   * Таймаут свой у каждой ручки и задаётся вызывающим: сжатие контекста — это отдельный вызов
   * модели и десятки секунд, а список проектов, который не ответил за минуту, уже не ответит.
   * Отмена приходит снаружи ([signal]): по ней запрос гасится и тогда, когда человек ушёл.
   */
  async call<T>(
    method: 'GET' | 'POST' | 'DELETE',
    path: string,
    options: { body?: unknown; signal?: AbortSignal; timeoutMs?: number } = {},
  ): Promise<T> {
    const res = await this.send(method, path, options);
    const text = await res.text();
    if (!text) return {} as T;
    try {
      return JSON.parse(text) as T;
    } catch {
      throw new ProjectsError(502, `мост ответил не JSON: ${text.slice(0, 200)}`);
    }
  }

  /**
   * Поток событий ответа агента: отдаём тело ответа моста как есть, без разбора.
   *
   * Мост уже говорит на SSE (`data: {...}`), и переупаковывать его в сервере незачем: так
   * поток доходит до приложения как есть. Проверка кода
   * ответа делается здесь, до того как клиенту уйдут заголовки потока.
   */
  async stream(
    path: string,
    body: unknown,
    options: { signal?: AbortSignal; method?: 'GET' | 'POST' } = {},
  ): Promise<ReadableStream<Uint8Array>> {
    const { method = 'POST', ...rest } = options;
    const res = await this.send(method, path, { ...rest, body });
    if (!res.body) throw new ProjectsError(502, 'мост закрыл соединение, не прислав ответ');
    return res.body as ReadableStream<Uint8Array>;
  }

  /**
   * Распознаёт записанную речь локальным whisper.cpp на маке.
   *
   * Запись уходит на `/inference` полем `file` (multipart) — так её ждёт whisper-server.
   * Формат не важен: сервер запущен с `--convert` и сам приводит вход через ffmpeg, поэтому
   * приложение записывает то, что умеет платформа. Наружу отдаём только текст: метки времени
   * и вероятности экрану не нужны. Отказ (туннель отключился, модель не поднялась) — тот же
   * [ProjectsError], что и у моста, и по коду 502 приложение понимает «повторять бессмысленно».
   */
  async transcribe(audio: Buffer, mime: string): Promise<string> {
    if (!this.sttConfigured) {
      throw new ProjectsError(503, 'голосовой ввод не настроен: распознавание речи недоступно');
    }

    const form = new FormData();
    form.append(
      'file',
      new Blob([new Uint8Array(audio)], { type: mime || 'application/octet-stream' }),
      'voice',
    );
    // `json` — самый простой ответ whisper-server (`{text}`). Язык отправляем всегда, и при
    // пустой настройке это `auto`: у whisper-server дефолт — `en`, поэтому запрос без поля
    // модель читает как «переведи на английский» и возвращает русскую речь английским
    // пересказом. Явное `auto` и есть автоопределение (см. STT_LANGUAGE).
    form.append('response_format', 'json');
    form.append('language', env.STT_LANGUAGE.trim() || 'auto');

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), STT_TIMEOUT_MS);
    try {
      const res = await fetch(`${this.sttBase()}/inference`, {
        method: 'POST',
        body: form,
        signal: controller.signal,
      });
      if (!res.ok) {
        const text = await res.text().catch(() => '');
        throw new ProjectsError(
          502,
          `распознавание речи ответило ${res.status}${text ? `: ${text.slice(0, 200)}` : ''}`,
        );
      }
      const raw = (await res.json().catch(() => ({}))) as { text?: unknown };
      return typeof raw.text === 'string' ? raw.text.trim() : '';
    } catch (e) {
      if (e instanceof ProjectsError) throw e;
      if (controller.signal.aborted) {
        throw new ProjectsError(504, 'распознавание речи не ответило за 120 с');
      }
      this.logger.warn(`распознавание речи недоступно: ${String(e)}`);
      throw new ProjectsError(
        502,
        'распознавание речи недоступно: whisper на маке не отвечает',
      );
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * Отправляет запрос и переводит сбой в [ProjectsError].
   *
   * Отдельно разведены три случая, которые раньше сливались в один текст: отказ моста (у него
   * свой код и своя причина), отмена человеком и «мост недоступен» — последнее означает, что
   * мак спит или туннель отключился, и повторять запрос бессмысленно.
   */
  private async send(
    method: 'GET' | 'POST' | 'DELETE',
    path: string,
    options: { body?: unknown; signal?: AbortSignal; timeoutMs?: number } = {},
  ): Promise<Response> {
    if (!this.configured) {
      throw new ProjectsError(503, 'мост до харнесса не настроен: раздел «Проекты» недоступен');
    }

    const controller = new AbortController();
    const onAbort = () => controller.abort();
    options.signal?.addEventListener('abort', onAbort, { once: true });
    const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? REQUEST_TIMEOUT_MS);

    try {
      const res = await fetch(`${this.base()}${path}`, {
        method,
        signal: controller.signal,
        headers: options.body === undefined ? undefined : { 'Content-Type': 'application/json' },
        body: options.body === undefined ? undefined : JSON.stringify(options.body),
      });

      if (!res.ok) {
        // мост отвечает `{error: "..."}` с понятным текстом — отдаём его как есть
        const text = await res.text();
        let message = `мост ответил ${res.status}`;
        try {
          const parsed = JSON.parse(text) as { error?: unknown };
          if (typeof parsed.error === 'string' && parsed.error) message = parsed.error;
        } catch {
          if (text) message = text.slice(0, 200);
        }
        throw new ProjectsError(res.status, message);
      }
      return res;
    } catch (e) {
      if (e instanceof ProjectsError) throw e;
      if (options.signal?.aborted) throw new ProjectsError(499, 'запрос отменён');
      if (controller.signal.aborted) {
        throw new ProjectsError(
          504,
          `мост не ответил за ${Math.round((options.timeoutMs ?? REQUEST_TIMEOUT_MS) / 1000)} с`,
        );
      }
      this.logger.warn(`мост pi недоступен: ${String(e)}`);
      throw new ProjectsError(
        502,
        'мост недоступен: мак спит, выключен или туннель отключился',
      );
    } finally {
      clearTimeout(timer);
      options.signal?.removeEventListener('abort', onAbort);
    }
  }
}
