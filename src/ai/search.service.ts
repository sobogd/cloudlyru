import { Injectable, Logger } from '@nestjs/common';
import { env } from '../config/env';

/** Один результат поиска: заголовок, адрес и короткая выжимка страницы. */
export interface SearchResult {
  title: string;
  url: string;
  snippet: string;
}

/** Что вернул поиск: результаты и причина, по которой их нет. */
export interface SearchOutcome {
  results: SearchResult[];
  /**
   * Код причины, когда результатов нет (`ddg_blocked`, `ddg_cooldown`, `unavailable`…).
   * `null` — поиск отработал и что-то нашёл.
   */
  error: string | null;
}

/**
 * Поиск в интернете для модели.
 *
 * Сам поиск делает не сервер и не модель, а сервис на маке
 * (`jevel.ai/agents/search-server.py`, за туннелем на 127.0.0.1:18814), и внутри него —
 * настоящий браузер (Playwright поверх установленного Chrome). Причина в этом и состоит:
 * поисковики режут сырые HTTP-запросы по отпечатку клиента — капча прилетает запросу без JS
 * и cookies, тогда как браузер с того же адреса получает нормальную выдачу (проверено: curl
 * получал страницу-аномалию, Chrome в тот же момент — десять результатов). На сервере браузера
 * нет вовсе, на маке он уже стоит, а заодно запросы уходят с домашнего IP, а не с серверного.
 *
 * Модель поиском не управляет: инструмент (`web_search`) сюда не завезён, потому что Gemma 4
 * на четырёх миллиардах эффективных параметров ненадёжна в генерации корректных вызовов
 * функций, а «вызов → результат → второй запрос» на таком размере даёт больше отказов, чем
 * пользы. Вместо этого решение принимает `needsSearch()` по тексту вопроса, сервер ищет сам и
 * подмешивает результаты в подсказку — один ответ, один запрос к модели.
 *
 * Ошибка поиска никогда не срывает ответ: свежие данные — это улучшение, а не условие.
 */
@Injectable()
export class SearchService {
  private readonly logger = new Logger(SearchService.name);

  /** Сколько результатов просим: больше — длиннее подсказка и дольше префилл на маке. */
  private readonly limit = 5;

  /** Задан ли адрес поиска. Пусто — поиск выключен, модель отвечает по своим знаниям. */
  get configured(): boolean {
    return env.SEARCH_URL.trim().length > 0;
  }

  /**
   * Ищет [query].
   *
   * Таймаут 12 с — с запасом к тому, что сам сервис на маке ждёт поисковик не дольше 8 с:
   * разница уходит на SSH-туннель и на то, что мак может быть занят генерацией. Если поиск не
   * уложился, отвечаем «не нашёл» и продолжаем без него.
   */
  async search(query: string): Promise<SearchOutcome> {
    if (!this.configured) return { results: [], error: 'disabled' };
    const url = `${env.SEARCH_URL.trim().replace(/\/+$/, '')}/search?q=${encodeURIComponent(query)}&n=${this.limit}`;
    const started = Date.now();
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(12_000) });
      if (!res.ok) {
        // 429 — это наши собственные лимиты на маке (частые запросы, суточный потолок):
        // причина видна в логе, а человеку знать про них незачем.
        this.logger.warn(`поиск: HTTP ${res.status} за ${Date.now() - started} мс`);
        return { results: [], error: `search_http_${res.status}` };
      }
      const data = (await res.json().catch(() => null)) as Record<string, unknown> | null;
      const raw = data?.results;
      if (!Array.isArray(raw)) return { results: [], error: 'search_bad_reply' };

      const results: SearchResult[] = [];
      for (const item of raw) {
        if (typeof item !== 'object' || item === null) continue;
        const r = item as Record<string, unknown>;
        const url = typeof r.url === 'string' ? r.url : '';
        if (!url) continue;
        results.push({
          title: typeof r.title === 'string' ? r.title : '',
          url,
          snippet: typeof r.snippet === 'string' ? r.snippet : '',
        });
      }
      const error = typeof data?.error === 'string' ? data.error : null;
      if (!results.length) {
        // Причина приходит с мака как есть (капча, пауза после неё, пустая выдача) — в лог
        // её, человеку ничего: он просто получит ответ без свежих данных.
        this.logger.warn(`поиск: результатов нет (${error ?? 'без причины'}) за ${Date.now() - started} мс`);
      } else {
        this.logger.log(`поиск: ${results.length} результатов за ${Date.now() - started} мс`);
      }
      return { results, error };
    } catch (e) {
      // Таймаут, обрыв туннеля, мак спит — для ответа это одно и то же: данных нет.
      const reason = e instanceof Error ? e.message : String(e);
      this.logger.warn(`поиск: недоступен — ${reason}`);
      return { results: [], error: 'search_unavailable' };
    }
  }
}
