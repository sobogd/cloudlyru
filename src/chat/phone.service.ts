import { Injectable, Logger } from '@nestjs/common';
import { env } from '../config/env';

/** Результат поиска на сайте: адрес выдачи и найденные ссылки. */
export interface PhoneSearchResult {
  site: string;
  url: string;
  /** Запрос, который написал агент. */
  query: string;
  /** Запрос, который реально ушёл в строку сайта (у amazon.es — уже по-испански). */
  searchQuery: string;
  results: Array<{ title: string; url: string; snippet: string }>;
}

/** Прочитанная страница. */
export interface PhonePage {
  url: string;
  title: string;
  text: string;
  chars: number;
  /** Сайт отдал проверку на бота вместо текста. */
  blocked: boolean;
  /** `reddit-json` — текст получен через `.json`, потому что разметку сайт не отдал. */
  via?: string;
}

/** Ошибка сервиса телефона: текст пригоден и для лога, и для модели (она его прочитает). */
export class PhoneError extends Error {}

/** Потолки ожидания: телефон медленнее сервера, но и не бесконечен. */
const SEARCH_TIMEOUT_MS = 120_000;
const PAGE_TIMEOUT_MS = 90_000;
const HEALTH_TIMEOUT_MS = 20_000;

/**
 * Клиент сервиса на телефоне (`agents/phone-agent` на маке, порт 18816 через туннель).
 *
 * Почему телефон: только он даёт то, чего не даёт ни сервер, ни браузер на маке —
 *  1) поиск **внутри сайта** через его собственную поисковую строку (Амазон, Reddit),
 *     а не google-запрос со словом «амазон» в тексте;
 *  2) сессии и домашний адрес: там, где мак получает «Prove your humanity», телефон с
 *     настоящим Chrome отдаёт страницу.
 *
 * Сервис не думает: он выполняет три действия и возвращает результат. Которое из них
 * вызвать, решает модель в цикле агента.
 */
@Injectable()
export class PhoneService {
  private readonly logger = new Logger(PhoneService.name);

  /** Настроен ли агент: без адреса поиск идёт своими знаниями, и это видно в логе. */
  get configured(): boolean {
    return env.AGENT_URL.trim().length > 0;
  }

  /** Доступен ли телефон прямо сейчас (подключён ли он к маку). */
  async available(): Promise<{ ok: boolean; reason?: string }> {
    if (!this.configured) return { ok: false, reason: 'агент на телефоне не настроен' };
    try {
      const health = await this.call<{ phone?: string; phone_error?: string; busy?: boolean }>(
        '/health',
        undefined,
        HEALTH_TIMEOUT_MS,
        'GET',
      );
      if (health.phone !== 'ok') {
        return { ok: false, reason: health.phone_error || 'телефон не подключён к маку' };
      }
      if (health.busy) return { ok: false, reason: 'телефон занят другим прогоном' };
      return { ok: true };
    } catch (e) {
      return { ok: false, reason: e instanceof Error ? e.message : 'сервис агента недоступен' };
    }
  }

  /** Поиск в Google в браузере телефона. */
  search(query: string): Promise<PhoneSearchResult> {
    return this.call<PhoneSearchResult>('/search', { query, site: 'google.com' }, SEARCH_TIMEOUT_MS);
  }

  /**
   * Поиск внутри названного сайта через его собственную строку.
   *
   * Запрос переводится на язык сайта на стороне сервиса (`SITE_LANGS`): у amazon.es каталог
   * испанский, и русский запрос там находит случайные товары. В ответе видно и исходный
   * запрос, и тот, что ушёл в строку, — это возвращается модели, чтобы она понимала, что
   * именно искала.
   */
  siteSearch(site: string, query: string): Promise<PhoneSearchResult> {
    return this.call<PhoneSearchResult>('/search', { site, query }, SEARCH_TIMEOUT_MS);
  }

  /** Открыть страницу и получить её текст. */
  open(url: string, maxChars = 4000): Promise<PhonePage> {
    return this.call<PhonePage>('/open', { url, max: maxChars }, PAGE_TIMEOUT_MS);
  }

  /**
   * Обращается к сервису и переводит сбои в [PhoneError] с понятным текстом.
   *
   * Текст ошибки уходит модели как результат инструмента: она по нему решает, что делать
   * дальше (сменить запрос, взять другой сайт, ответить своими знаниями), поэтому формулировки
   * здесь важнее, чем в обычном клиенте.
   */
  private async call<T>(
    path: string,
    body: Record<string, unknown> | undefined,
    timeoutMs: number,
    method: 'GET' | 'POST' = 'POST',
  ): Promise<T> {
    const base = env.AGENT_URL.trim().replace(/\/+$/, '');
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await fetch(`${base}${path}`, {
        method,
        headers: { 'Content-Type': 'application/json' },
        body: body ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      });
      const payload = (await res.json()) as T & { error?: string | null };
      if (!res.ok) throw new PhoneError(payload.error || `сервис агента ответил ${res.status}`);
      if (payload.error) throw new PhoneError(payload.error);
      return payload;
    } catch (e) {
      if (e instanceof PhoneError) throw e;
      if (controller.signal.aborted) {
        throw new PhoneError(`телефон не ответил за ${Math.round(timeoutMs / 1000)} с`);
      }
      this.logger.warn(`агент недоступен: ${e instanceof Error ? e.message : e}`);
      throw new PhoneError('телефон недоступен (не подключён к маку или сервис не поднят)');
    } finally {
      clearTimeout(timer);
    }
  }
}
