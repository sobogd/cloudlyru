import { Injectable, Logger } from '@nestjs/common';
import { env } from '../config/env';

/** Результат поисковой выдачи — то, что отдаёт браузер на маке. */
export interface SearchHit {
  title: string;
  url: string;
  snippet: string;
}

/** Прочитанная страница. */
export interface PageRead {
  url: string;
  title: string;
  text: string;
  chars: number;
  /** Страница оказалась заглушкой (согласие на cookies, paywall, «включите JavaScript»). */
  short: boolean;
}

/**
 * Источник ответа: то, что уходит модели в промпт и сохраняется в БД.
 *
 * `text` пуст, если страницу прочитать не удалось — тогда у модели остаётся только `snippet`
 * из выдачи, и это честно помечено `read: false`.
 */
export interface ChatSource {
  position: number;
  title: string;
  url: string;
  snippet: string;
  text: string;
  read: boolean;
  chars: number;
}

/** Итог сбора данных по вопросу: источники и замечание для промпта, если что-то не вышло. */
export interface ResearchResult {
  query: string;
  sources: ChatSource[];
  /** Готовая фраза для промпта: «поиск ничего не нашёл», «страницы не открылись» или null. */
  note: string | null;
}

/** Ошибка сервиса поиска: текст пригоден для лога, наружу уходит как замечание в промпт. */
export class WebSearchError extends Error {}

/** Сколько результатов просить у поисковика. Больше — не лучше: читаем всё равно единицы. */
const SEARCH_LIMIT = 8;

/**
 * Сколько страниц читать целиком.
 *
 * Три. Больше — не точнее, а медленнее: обработка промпта на этом маке идёт ~200 токенов в
 * секунду (замер llama-server), то есть каждая тысяча токенов источников стоит пять секунд
 * ожидания перед первым словом. Четыре страницы по 6000 символов давали 21-27 секунд prefill
 * и ответы по 60-75 секунд, а выигрыш в точности был незаметен: конкретика попадалась и в трёх.
 */
const MAX_PAGES = 3;

/** Сколько символов страницы уходит модели. Хвост статьи для ответа на вопрос обычно не нужен. */
const PAGE_CHARS = 4_000;

/** Потолок числа источников в ответе: длиннее список ссылок человек всё равно не читает. */
const MAX_SOURCES = 5;

/** Потолки ожидания на одну ручку. Молчащий поисковик — повод ответить без свежих данных. */
const SEARCH_TIMEOUT_MS = 25_000;
const PAGE_TIMEOUT_MS = 20_000;

/**
 * Клиент сервиса поиска и чтения страниц на домашнем маке (`agents/websearch/`).
 *
 * Сейчас в решении о поиске НЕ участвует: раздел «Чат» работает через агента на телефоне
 * (`agent.service.ts`), который ищет внутри сайтов и читает страницы сам. Файл оставлен как
 * запасной путь и для ручных проверок сервиса (`/search`, `/page` на маке) — если агент
 * отключён или сломан, сюда можно вернуться одной правкой в контроллере.
 *
 * Поиск живёт на маке не по выбору: там настоящий Chrome с обычным отпечатком и домашний IP —
 * именно это отличает живую выдачу от капчи, которую получает HTTP-клиент с серверного адреса.
 * На VPS сервис виден через reverse-SSH туннель как `http://127.0.0.1:18814`.
 *
 * Главное отличие от прежнего поиска: страницы читаются целиком. Раньше модель получала пять
 * выдержек по 400 символов и отвечала по огрызкам — отсюда и «отвечает неточно» на вопросах о
 * фактах, хотя контекст модели был занят на проценты.
 */
@Injectable()
export class WebSearchService {
  private readonly logger = new Logger(WebSearchService.name);

  /** Настроен ли поиск: без адреса раздел работает, но отвечает без свежих данных. */
  get configured(): boolean {
    return env.WEBSEARCH_URL.trim().length > 0;
  }

  /**
   * Собирает данные по вопросу: ищет, читает верхние страницы, нумерует источники.
   *
   * Порядок источников — порядок выдачи поисковика: читаются первые страницы в этом же порядке,
   * и нумерация в ответе модели (`[1]`, `[2]`) соответствует и тексту промпта, и списку ссылок
   * на экране. Хосты не повторяются: три страницы одного сайта — это один источник, а не три.
   */
  async research(query: string, signal: AbortSignal): Promise<ResearchResult> {
    if (!this.configured) return { query, sources: [], note: null };

    let hits: SearchHit[];
    try {
      hits = await this.search(query, signal);
    } catch (e) {
      const reason = e instanceof WebSearchError ? e.message : 'поиск не ответил';
      this.logger.warn(`поиск «${query}» не удался — ${reason}`);
      return { query, sources: [], note: `Поиск в интернете не удался (${reason}).` };
    }
    if (!hits.length) {
      this.logger.warn(`поиск «${query}» не дал результатов`);
      return { query, sources: [], note: 'Поиск в интернете не дал результатов.' };
    }

    const sources: ChatSource[] = [];
    const hosts = new Set<string>();
    let pagesRead = 0;
    let pageFailures = 0;

    for (const hit of hits) {
      if (sources.length >= MAX_SOURCES) break;
      const host = this.host(hit.url);
      if (!host || hosts.has(host)) continue;
      hosts.add(host);

      let page: PageRead | null = null;
      if (pagesRead < MAX_PAGES) {
        try {
          page = await this.readPage(hit.url, signal);
        } catch (e) {
          pageFailures += 1;
          // Отдельная страница — не повод бросать поиск: остальные ссылки ещё могут ответить.
          this.logger.warn(`страница ${hit.url} не прочитана — ${e instanceof Error ? e.message : e}`);
        }
        if (page && page.short) {
          // Текст есть, но это заглушка или paywall: модели он не поможет, а место займёт.
          this.logger.log(`страница ${hit.url} — заглушка (${page.chars} симв.), беру выдержку`);
          page = null;
        }
        if (page) pagesRead += 1;
      }

      sources.push({
        position: sources.length + 1,
        title: (page?.title || hit.title || host).slice(0, 200),
        url: hit.url,
        snippet: hit.snippet,
        text: page?.text ?? '',
        read: page !== null,
        chars: page?.chars ?? 0,
      });
    }

    const note = this.noteFor(sources, pagesRead, pageFailures);
    this.logger.log(
      `поиск «${query}»: источников ${sources.length}, прочитано страниц ${pagesRead}` +
        (note ? ` (${note})` : ''),
    );
    return { query, sources, note };
  }

  /**
   * Замечание для промпта о том, чего не хватило.
   *
   * Нужно, чтобы модель не выдумывала ответ по одному заголовку и не говорила «не знаю» молча:
   * человек должен видеть, что поиск был, но данные пришли неполные.
   */
  private noteFor(sources: ChatSource[], pagesRead: number, pageFailures: number): string | null {
    if (!sources.length) return 'Поиск в интернете не дал результатов.';
    if (pagesRead === 0 && pageFailures > 0) {
      return 'Страницы источников открыть не удалось (сайты не отдали текст) — ниже только выдержки из поисковой выдачи.';
    }
    if (pagesRead === 0) {
      return 'Ни одна страница не прочитана — ниже только выдержки из поисковой выдачи.';
    }
    return null;
  }

  /** Ищет через сервис на маке и возвращает выдачу без ссылок на сами поисковики. */
  private async search(query: string, signal: AbortSignal): Promise<SearchHit[]> {
    const data = await this.call<{ results?: SearchHit[]; error?: string | null }>(
      `/search?q=${encodeURIComponent(query)}&n=${SEARCH_LIMIT}`,
      signal,
      SEARCH_TIMEOUT_MS,
    );
    if (data.error) throw new WebSearchError(data.error);
    return (data.results ?? [])
      .map((r) => ({
        title: String(r.title ?? '').trim(),
        url: String(r.url ?? '').trim(),
        snippet: String(r.snippet ?? '').trim(),
      }))
      .filter((r) => r.url.startsWith('http'));
  }

  /** Читает страницу целиком через тот же браузер на маке. */
  private async readPage(url: string, signal: AbortSignal): Promise<PageRead> {
    const data = await this.call<{
      url?: string;
      title?: string;
      text?: string;
      chars?: number;
      short?: boolean;
      error?: string | null;
    }>(`/page?url=${encodeURIComponent(url)}&max=${PAGE_CHARS}`, signal, PAGE_TIMEOUT_MS);
    if (data.error) throw new WebSearchError(data.error);
    return {
      url: String(data.url ?? url),
      title: String(data.title ?? '').trim(),
      text: String(data.text ?? '').trim(),
      chars: Number(data.chars ?? 0),
      short: Boolean(data.short),
    };
  }

  /**
   * Обращается к сервису поиска с двумя потолками сразу: клиентским (человек закрыл экран) и
   * своим (поисковик молчит). Без второго запрос висел бы до таймаута соединения nginx.
   */
  private async call<T>(path: string, signal: AbortSignal, timeoutMs: number): Promise<T> {
    const base = env.WEBSEARCH_URL.trim().replace(/\/+$/, '');
    const controller = new AbortController();
    const onAbort = () => controller.abort();
    signal.addEventListener('abort', onAbort, { once: true });
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await fetch(`${base}${path}`, { signal: controller.signal });
      if (!res.ok) {
        const body = await res.text();
        throw new WebSearchError(`сервис поиска ответил ${res.status}: ${body.slice(0, 200)}`);
      }
      return (await res.json()) as T;
    } catch (e) {
      if (e instanceof WebSearchError) throw e;
      // Отмену по своему таймауту отделяем от отмены человеком и от обрыва связи: раньше все
      // три случая давали «мак спит или туннель отключился», и по этой фразе нельзя было
      // понять, что на самом деле страница просто не успела открыться за 20 секунд.
      if (signal.aborted) throw new WebSearchError('запрос отменён');
      if (controller.signal.aborted) {
        throw new WebSearchError(`сервис поиска не ответил за ${Math.round(timeoutMs / 1000)} с`);
      }
      throw new WebSearchError('сервис поиска недоступен (мак спит или туннель отключился)');
    } finally {
      clearTimeout(timer);
      signal.removeEventListener('abort', onAbort);
    }
  }

  /** Хост ссылки в нижнем регистре — ключ, по которому отсеиваются повторы сайтов. */
  private host(url: string): string {
    try {
      return new URL(url).host.toLowerCase();
    } catch {
      return '';
    }
  }
}
