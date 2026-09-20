import { Injectable, Logger } from '@nestjs/common';
import { env } from '../config/env';
import { LlmMessage, LlmService, LlmTool, LlmToolCall } from './llm.service';
import { PhoneError, PhoneService } from './phone.service';

/** Источник ответа: страница, которую агент открыл, с её текстом и номером для ссылок. */
export interface AgentSource {
  position: number;
  title: string;
  url: string;
  snippet: string;
  read: boolean;
  chars: number;
  /** Текст страницы — уходит модели в контекст, в БД не сохраняется (мегабайты на ответ). */
  text: string;
}

/** Что агент сообщает наружу по ходу работы: экран показывает это вместо молчащего спиннера. */
export interface AgentEvents {
  /** Что происходит прямо сейчас: «ищу на reddit.com: …», «читаю источник 2». */
  status(text: string): void;
  /** Список источников на текущий момент (приложение сразу делает из них ссылки). */
  sources(list: AgentSource[]): void;
  /** Кусок финального ответа. */
  delta(text: string): void;
}

/** Итог прогона: ответ, источники и расход. */
export interface AgentOutcome {
  answer: string;
  reasoning: string;
  sources: AgentSource[];
  promptTokens?: number;
  completionTokens?: number;
  /** Сколько шагов (обращений к телефону) понадобилось. */
  steps: number;
}

/** Инструмент в понимании модели: имя, назначение и схема аргументов. */
const TOOLS: LlmTool[] = [
  {
    type: 'function',
    function: {
      name: 'web_search',
      description:
        "Search the web with Google in the phone's browser. Returns result titles and urls. " +
        'Use it when the user did not name a specific site.',
      parameters: {
        type: 'object',
        properties: { query: { type: 'string', description: 'Search query, any language.' } },
        required: ['query'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'site_search',
      description:
        "Open the named site in the phone's browser and search inside it using the site's own " +
        'search box (amazon.es, reddit.com, ozon.ru). Use it whenever the user names a site, or ' +
        'when a specific site is obviously the right place: opinions and real experience live on ' +
        'reddit.com, product prices live in the shop the user is in (amazon.es for Spain). ' +
        "The query is translated into the site's language automatically.",
      parameters: {
        type: 'object',
        properties: {
          site: { type: 'string', description: 'Domain or site name, e.g. reddit.com or amazon.es.' },
          query: { type: 'string', description: 'What to search for on that site.' },
        },
        required: ['site', 'query'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'open_page',
      description:
        "Open a url in the phone's browser and return its readable text. Every opened page " +
        'becomes a numbered SOURCE that you can cite in the answer.',
      parameters: {
        type: 'object',
        properties: { url: { type: 'string', description: 'Full http(s) url.' } },
        required: ['url'],
      },
    },
  },
];

/** Сколько результатов поиска уходит модели. Больше — только шум в контексте. */
const RESULTS_IN_CONTEXT = 8;

/**
 * Агент раздела «Чат»: модель сама решает, что искать и где.
 *
 * Почему так, а не «правилом по словам вопроса», как было раньше. Прежний чат решал, нужен ли
 * поиск, по списку русских слов, а сам поиск всегда шёл в Google текстом вопроса. Из-за этого
 * просьба «поищи на амазоне» превращалась в google-запрос со словом «амазоне» — и сервер
 * читал статью про попугая амазона (живой случай из логов). Здесь решение принимает модель
 * инструментами: `site_search` открывает названный сайт и ищет в ЕГО строке, `web_search` —
 * обычный поиск, `open_page` — чтение конкретной страницы.
 *
 * Цикл намеренно не одношаговый: она обязана собрать данные из разных источников, а если
 * выдача пустая или мимо — переписать запрос и попробовать снова. Потолок шагов задан
 * настройкой (`AGENT_MAX_STEPS`), потому что каждое обращение к телефону стоит секунд.
 */
@Injectable()
export class AgentService {
  private readonly logger = new Logger(AgentService.name);

  constructor(
    private readonly llm: LlmService,
    private readonly phone: PhoneService,
  ) {}

  /** Есть ли чем работать: без сервиса телефона агент отвечает своими знаниями. */
  get configured(): boolean {
    return this.phone.configured;
  }

  /**
   * Системная часть запроса. Английский — намеренно: инструкции модели и внутренние шаги идут
   * на нём, а человеку ответ приходит по-русски (последнее правило).
   */
  private systemPrompt(memory: string, maxSteps: number): string {
    const rules = [
      'You are the research agent behind the Cloudly chat app. You decide what to do: search the ' +
        'web, search inside a named site, or open a page. Do not ask the user what to do.',
      'Use site_search whenever the user names a site ("on Reddit", "on Amazon") or when one site ' +
        'is obviously the right place: opinions and real experience live on reddit.com, prices and ' +
        'products live in the shop (amazon.es for Spain). Use web_search when no site is named.',
      'Gather evidence from at least two different sources before answering, and read the pages ' +
        'themselves (open_page) instead of judging by titles.',
      'If a search returns nothing, looks irrelevant, or a page is blocked, rewrite the query and ' +
        'try again — different wording, another query, another site — before you give up.',
      `You may call tools at most ${maxSteps} times for one question. Answer as soon as you have enough.`,
      'Every page you open with open_page comes back as a numbered SOURCE. Cite the numbers in ' +
        'square brackets right after the claim they support, like [1] or [2].',
      'Never invent facts, prices, dates or urls: use only what the tool results say. If the tools ' +
        'gave you nothing, say so in one line and answer from your own knowledge, marking it as such.',
      'Write the final answer in Russian, short: 5-7 sentences or a short list. No preamble.',
    ];
    const parts = [rules.join('\n')];
    if (memory.trim()) {
      parts.push(`What the owner asked you to remember about himself and his preferred style:\n${memory.trim()}`);
    }
    return parts.join('\n\n');
  }

  /**
   * Прогоняет вопрос через цикл инструментов и возвращает ответ.
   *
   * События отдаются по ходу: `status` — что делает сейчас (на экране вместо молчащего
   * спиннера), `sources` — найденные источники, `delta` — куски финального ответа.
   */
  async run(params: {
    model: string;
    memory: string;
    history: LlmMessage[];
    question: string;
    signal: AbortSignal;
    events: AgentEvents;
  }): Promise<AgentOutcome> {
    const maxSteps = env.AGENT_MAX_STEPS;
    const messages: LlmMessage[] = [
      { role: 'system', content: this.systemPrompt(params.memory, maxSteps) },
      ...params.history,
      { role: 'user', content: params.question },
    ];

    const sources: AgentSource[] = [];
    let answer = '';
    let reasoning = '';
    let promptTokens: number | undefined;
    let completionTokens: number | undefined;
    let steps = 0;

    // Заранее выясняем, доступен ли телефон: если нет — не тратим шаг модели на попытку,
    // а сразу говорим ей, что интернета не будет.
    const available = await this.phone.available();
    if (!available.ok) {
      this.logger.warn(`агент недоступен: ${available.reason}`);
      params.events.status(`Интернет недоступен: ${available.reason}`);
      messages.push({
        role: 'system',
        content: `Tools are unavailable right now (${available.reason}). Answer the user in Russian ` +
          'from your own knowledge and say in the first line that you could not reach the internet.',
      });
    }

    for (let step = 1; step <= maxSteps; step++) {
      const turn = await this.turn({
        model: params.model,
        messages,
        tools: available.ok ? TOOLS : undefined,
        signal: params.signal,
        events: params.events,
      });
      steps = step;
      answer = turn.text;
      reasoning += turn.reasoning;
      promptTokens = turn.usage?.promptTokens ?? promptTokens;
      completionTokens = turn.usage?.completionTokens ?? completionTokens;

      if (!turn.toolCalls.length) {
        // Модель ответила текстом — это и есть финальный ответ, он уже ушёл на экран потоком.
        return { answer, reasoning, sources, promptTokens, completionTokens, steps };
      }

      // Форма вызова здесь — та, что ждёт сервер модели (OpenAI-стиль с `type: function`):
      // плоскую llama.cpp отвергает с «Missing tool call type».
      messages.push({
        role: 'assistant',
        content: turn.text,
        tool_calls: turn.toolCalls.map((call) => ({
          id: call.id,
          type: 'function' as const,
          function: { name: call.name, arguments: call.arguments },
        })),
      });
      for (const call of turn.toolCalls) {
        const result = await this.execute(call, sources, params.events);
        messages.push({ role: 'tool', tool_call_id: call.id, content: result });
      }
    }

    // Шаги кончились: просим ответить тем, что уже собрано. Без этого прогон оборвался бы
    // молча, а человек ждал бы ответ, которого не будет.
    params.events.status('Собираю ответ из найденного…');
    messages.push({
      role: 'system',
      content: 'You have reached the tool limit. Answer now in Russian using what you already have, ' +
        'and mention in one line if something important could not be checked.',
    });
    const finalTurn = await this.turn({
      model: params.model,
      messages,
      signal: params.signal,
      events: params.events,
    });
    return {
      answer: finalTurn.text,
      reasoning: reasoning + finalTurn.reasoning,
      sources,
      promptTokens: finalTurn.usage?.promptTokens ?? promptTokens,
      completionTokens: finalTurn.usage?.completionTokens ?? completionTokens,
      steps,
    };
  }

  /**
   * Один шаг модели: поток ответа с накоплением вызовов инструментов.
   *
   * Кусок текста сразу уходит на экран: у финального шага это и есть ответ, а у шагов с
   * инструментами текста обычно нет вовсе (модель просто просит вызвать инструмент).
   */
  private async turn(params: {
    model: string;
    messages: LlmMessage[];
    tools?: LlmTool[];
    signal: AbortSignal;
    events: AgentEvents;
  }): Promise<{
    text: string;
    reasoning: string;
    toolCalls: LlmToolCall[];
    usage?: { promptTokens?: number; completionTokens?: number };
  }> {
    let text = '';
    let reasoning = '';
    let toolCalls: LlmToolCall[] = [];
    let usage: { promptTokens?: number; completionTokens?: number } | undefined;
    for await (const delta of this.llm.streamChat({
      model: params.model,
      messages: params.messages,
      tools: params.tools,
      signal: params.signal,
    })) {
      if (delta.text) {
        text += delta.text;
        params.events.delta(delta.text);
      }
      if (delta.reasoning) reasoning += delta.reasoning;
      if (delta.usage) usage = delta.usage;
      if (delta.toolCalls) toolCalls = delta.toolCalls;
    }
    return { text, reasoning, toolCalls, usage };
  }

  /**
   * Выполняет вызов инструмента и возвращает его результат текстом для модели.
   *
   * Читаемые страницы становятся источниками с номерами: номер уходит и модели (в тексте
   * результата), и на экран (`sources`), поэтому `[1]` в ответе превращается в ссылку.
   * Ошибка инструмента — это тоже результат: модель прочитает причину и решит, что делать
   * (переписать запрос, взять другой сайт или ответить своими знаниями).
   */
  private async execute(call: LlmToolCall, sources: AgentSource[], events: AgentEvents): Promise<string> {
    const args = this.parseArgs(call);
    try {
      if (call.name === 'web_search') {
        const query = String(args.query ?? '').trim();
        if (!query) return this.errorResult('query is required');
        events.status(`Ищу в Google: ${query}`);
        const found = await this.phone.search(query);
        return this.searchResult(found);
      }

      if (call.name === 'site_search') {
        const site = String(args.site ?? '').trim();
        const query = String(args.query ?? '').trim();
        if (!site || !query) return this.errorResult('site and query are required');
        events.status(`Ищу на ${site}: ${query}`);
        const found = await this.phone.siteSearch(site, query);
        return this.searchResult(found);
      }

      if (call.name === 'open_page') {
        const url = String(args.url ?? '').trim();
        if (!url.startsWith('http')) return this.errorResult('url must start with http');
        events.status(`Читаю страницу: ${this.shortUrl(url)}`);
        const page = await this.phone.open(url);
        const source: AgentSource = {
          position: sources.length + 1,
          title: page.title || this.shortUrl(page.url || url),
          url: page.url || url,
          snippet: page.text.slice(0, 200),
          read: !page.blocked,
          chars: page.chars,
          text: page.text,
        };
        sources.push(source);
        events.sources(sources);
        events.status(`Читаю страницу: ${source.title.slice(0, 40)}`);
        if (page.blocked) {
          return `SOURCE ${source.position} | ${source.url} | the site showed a bot check instead of ` +
            'the content, so this source has no usable text. Try another source.';
        }
        return `SOURCE ${source.position} | ${source.title} | ${source.url}\n${page.text}`;
      }

      return this.errorResult(`unknown tool: ${call.name}`);
    } catch (e) {
      const reason = e instanceof PhoneError ? e.message : e instanceof Error ? e.message : 'tool failed';
      this.logger.warn(`инструмент ${call.name} не отработал: ${reason}`);
      return this.errorResult(reason);
    }
  }

  /** Результат поиска в виде, удобном модели: список ссылок без разметки. */
  private searchResult(found: {
    site: string;
    url: string;
    searchQuery?: string;
    results: Array<{ title: string; url: string; snippet: string }>;
  }): string {
    const results = found.results.slice(0, RESULTS_IN_CONTEXT);
    if (!results.length) {
      return JSON.stringify({
        site: found.site,
        search_query: found.searchQuery ?? '',
        results: [],
        note: 'The site returned no results for this query. Rewrite the query or try another site.',
      });
    }
    return JSON.stringify({
      site: found.site,
      search_query: found.searchQuery ?? '',
      page_url: found.url,
      results,
      note: 'These are links only. Open the ones that look relevant with open_page before you answer.',
    });
  }

  /** Ошибка инструмента как результат: модель должна увидеть причину, а не пустоту. */
  private errorResult(reason: string): string {
    return JSON.stringify({ error: reason });
  }

  /** Аргументы вызова: модель присылает JSON строкой, и он может быть битым. */
  private parseArgs(call: LlmToolCall): Record<string, unknown> {
    try {
      const parsed = JSON.parse(call.arguments || '{}');
      return parsed && typeof parsed === 'object' ? (parsed as Record<string, unknown>) : {};
    } catch {
      this.logger.warn(`аргументы ${call.name} не разобраны: ${call.arguments?.slice(0, 120)}`);
      return {};
    }
  }

  /** Короткий вид адреса для подписи на экране. */
  private shortUrl(url: string): string {
    try {
      return new URL(url).host;
    } catch {
      return url.slice(0, 40);
    }
  }
}
