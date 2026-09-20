#!/usr/bin/env python3
"""browser.py — поиск в интернете и чтение страниц настоящим браузером на маке.

Зачем браузер, а не HTTP-клиент. Сырой POST в DuckDuckGo отдаёт нормальную выдачу
ровно до первой пачки запросов, а потом приходит страница-аномалия (HTTP 202) на все
запросы подряд — с того же IP, где настоящий браузер в тот же момент получает обычную
выдачу. Режут не адрес, а отпечаток клиента: отсутствие JS, cookies и истории сеанса.
Для чтения страниц причина та же: половина сайтов отдаёт ботам заглушку или 403, а
браузеру с домашнего IP — текст.

Что здесь есть:
  - `search(query, limit)` — выдача одного из движков (перебираются по очереди);
  - `read_page(url, max_chars)` — основной текст страницы, очищенный от разметки.

Потоки. Синхронный API Playwright привязан к создавшему его потоку, поэтому браузер
живёт в отдельном потоке-воркере, а вызывающие кладут задания в очередь и ждут ответа.
Очередь и есть вся синхронизация: браузер один, задания выполняются по одному.

Память. Головной Chrome — это 200-400 МБ на маке, где уже живёт модель на 6 ГБ, а
поиски случаются по нескольку раз в день. Поэтому браузер закрывается после простоя
(IDLE_CLOSE_SECONDS) и поднимается заново на следующем задании: пара секунд на запуск
дешевле, чем постоянно занятая память.
"""

import base64
import queue
import threading
import time
import urllib.parse

# Сколько ждать ответа движка или страницы. Не ответивший за это время движок считается
# неудачным, и перебирается следующий: лучше выдача второго по качеству, чем минута
# ожидания на экране телефона.
PAGE_TIMEOUT_MS = 25_000

# Пауза после загрузки документа: выдача и текст дорисовываются скриптами, и без неё
# разбор увидит полупустую страницу.
SEARCH_SETTLE_MS = 2_500
PAGE_SETTLE_MS = 1_500

# Простой, после которого браузер закрывается и освобождает память.
IDLE_CLOSE_SECONDS = 600.0

# Страница короче этого числа символов считается не прочитанной: так выглядят заглушки
# «включите JavaScript», согласие на cookies и paywall. Сервер по этому признаку берёт
# следующий источник, вместо того чтобы отвечать модели пустотой.
MIN_PAGE_CHARS = 400

# Отпечаток обычного Chrome на этом маке: подставляем явно, чтобы браузер не выглядел
# «серверным» — на этом и держится весь смысл затеи.
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36"
)

# Движки в порядке предпочтения. `unwrap_bing` — потому что Bing отдаёт ссылки через
# свою ручку /ck/a с настоящим адресом внутри base64-параметра `u`.
ENGINES = (
    {
        "name": "duckduckgo",
        "url": "https://duckduckgo.com/?q={query}&ia=web",
        "titles": 'a[data-testid="result-title-a"]',
        "snippets": '[data-result="snippet"]',
    },
    {
        "name": "startpage",
        "url": "https://www.startpage.com/sp/search?query={query}",
        "titles": "a.result-link",
        "snippets": ".description",
    },
    {
        "name": "bing",
        "url": "https://www.bing.com/search?q={query}",
        "titles": "li.b_algo h2 a",
        "snippets": ".b_lineclamp2",
        "unwrap": True,
    },
)

# Ссылки самих поисковиков (настройки, реклама, «похожие запросы») в ответе модели
# бесполезны, а место в подсказке занимают.
ENGINE_HOSTS = ("bing.com", "startpage.com", "duckduckgo.com")

# Что вырезать из страницы перед выдачей текста. Навигация, меню и подвалы не несут
# фактов, зато съедают контекст модели; скрипты и стили — тем более.
PAGE_EXTRACT_JS = """
() => {
  const drop = ['script', 'style', 'noscript', 'template', 'svg', 'canvas', 'iframe',
                'nav', 'header', 'footer', 'aside', 'form', 'button', 'select'];
  const root = document.querySelector('article')
    || document.querySelector('main')
    || document.querySelector('[role="main"]')
    || document.body;
  if (!root) return { title: document.title || '', lang: '', text: '' };
  const copy = root.cloneNode(true);
  for (const tag of drop) {
    for (const node of copy.querySelectorAll(tag)) node.remove();
  }
  const text = (copy.innerText || copy.textContent || '')
    .replace(/[ \\t\\u00a0]+/g, ' ')
    .replace(/\\n{3,}/g, '\\n\\n')
    .trim();
  return {
    title: (document.title || '').trim(),
    lang: document.documentElement.getAttribute('lang') || '',
    text,
  };
}
"""


class BrowserError(Exception):
    """Задание не выполнено: текст — короткая причина для лога и для ответа клиенту."""


def unwrap_bing(href):
    """Достаёт настоящий адрес из редирект-обёртки Bing (`/ck/a?...&u=a1<base64>`).

    Возвращает исходную ссылку, если разобрать не удалось: лучше ссылка на Bing, чем
    никакой — по ней хотя бы видно, куда ведёт результат.
    """
    if "/ck/a" not in href:
        return href
    params = urllib.parse.parse_qs(urllib.parse.urlparse(href).query)
    raw = (params.get("u") or [""])[0]
    if not raw:
        return href
    # Префикс "a1" — служебный, дальше идёт base64url без выравнивания.
    body = raw[2:] if raw.startswith("a1") else raw
    padding = "=" * (-len(body) % 4)
    try:
        return base64.urlsafe_b64decode(body + padding).decode("utf-8", "replace")
    except Exception:
        return href


class BrowserWorker:
    """Очередь заданий к браузеру и сам браузер в отдельном потоке.

    Использование: `start()` один раз при запуске сервиса, дальше `search()` и
    `read_page()` из любого потока. Оба метода бросают BrowserError, если задание не
    выполнено; вызывающий решает, что делать (у нас — ответить без свежих данных).
    """

    def __init__(self, idle_close_seconds=IDLE_CLOSE_SECONDS):
        self._idle_close_seconds = idle_close_seconds
        self._jobs = queue.Queue()
        self._thread = None
        self._last_use = 0.0
        self._state = "idle"
        self._lock = threading.Lock()

    def start(self):
        """Поднимает поток-воркер; сам браузер запускается лениво, на первом задании."""
        if self._thread:
            return
        self._thread = threading.Thread(target=self._loop, name="browser-worker", daemon=True)
        self._thread.start()

    @property
    def state(self):
        """`idle` — браузер не поднят, `running` — поднят и держится до простоя."""
        with self._lock:
            return self._state

    def search(self, query, limit=5, timeout=90.0):
        """Ищет [query] и возвращает (имя движка, список результатов).

        Таймаут больше, чем таймаут одной страницы: движков три, и каждый имеет право
        не ответить. Ответ — список словарей с title, url, snippet.
        """
        return self._submit(("search", query, limit), timeout)

    def read_page(self, url, max_chars=8000, timeout=60.0):
        """Читает [url] и возвращает словарь с полем text (не длиннее [max_chars]).

        Кроме текста отдаёт заголовок, язык и признак `short`: текст короче
        MIN_PAGE_CHARS считается непрочитанным (заглушка, paywall, пустая страница).
        """
        return self._submit(("page", url, max_chars), timeout)

    def _submit(self, job, timeout):
        """Кладёт задание в очередь воркера и ждёт результат или ошибку."""
        if not self._thread:
            self.start()
        reply = queue.Queue(maxsize=1)
        self._jobs.put((job, reply))
        try:
            result = reply.get(timeout=timeout)
        except queue.Empty:
            raise BrowserError("браузер не ответил за %.0f с" % timeout)
        if isinstance(result, Exception):
            raise result
        return result

    def _loop(self):
        """Цикл воркера: ленивый запуск браузера, обработка заданий, закрытие по простою."""
        playwright = None
        browser = context = page = None
        try:
            while True:
                try:
                    job, reply = self._jobs.get(timeout=5.0)
                except queue.Empty:
                    # Простой: держать Chrome в памяти мака ради одного поиска в час незачем.
                    if browser and time.time() - self._last_use > self._idle_close_seconds:
                        self._close(page, context, browser)
                        browser = context = page = None
                        self._set_state("idle")
                    continue

                try:
                    if browser is None:
                        playwright, browser, context, page = self._launch(playwright)
                        self._set_state("running")
                    self._last_use = time.time()
                    kind = job[0]
                    if kind == "search":
                        reply.put(self._try_engines(page, job[1], job[2]))
                    elif kind == "page":
                        reply.put(self._read(page, job[1], job[2]))
                    else:
                        reply.put(BrowserError("неизвестное задание: %s" % kind))
                except Exception as e:
                    # Браузер мог умереть (обновление Chrome, падение) — закрываем и
                    # поднимаем заново на следующем задании, а не отдаём клиенту мёртвый.
                    self._close(page, context, browser)
                    browser = context = page = None
                    self._set_state("idle")
                    reply.put(e if isinstance(e, BrowserError) else BrowserError(str(e)))
        finally:
            self._close(page, context, browser)
            if playwright:
                try:
                    playwright.stop()
                except Exception:
                    pass

    def _set_state(self, state):
        """Запоминает состояние браузера для /health (под локом: читает другой поток)."""
        with self._lock:
            self._state = state

    def _launch(self, playwright):
        """Поднимает Playwright и Chrome.

        `channel="chrome"` — использовать уже установленный на маке Chrome, а не качать
        отдельный Chromium: экономит ~150 МБ диска и даёт настоящий браузер с обычным
        отпечатком. Контекст создаётся один на весь срок жизни браузера, поэтому cookies
        и история сеанса накапливаются от задания к заданию — именно это и отличает нас
        от HTTP-клиента, которого поисковики режут.
        """
        from playwright.sync_api import sync_playwright

        if playwright is None:
            playwright = sync_playwright().start()
        browser = playwright.chromium.launch(channel="chrome", headless=True)
        context = browser.new_context(
            user_agent=USER_AGENT,
            locale="ru-RU",
            timezone_id="Europe/Madrid",
            viewport={"width": 1440, "height": 900},
        )
        page = context.new_page()
        # Картинки и шрифты не нужны: разбору достаётся только текст, а каждая
        # загруженная картинка — это секунды на медленном канале.
        try:
            page.route(
                "**/*",
                lambda route: route.abort()
                if route.request.resource_type in ("image", "media", "font")
                else route.continue_(),
            )
        except Exception:
            pass
        return playwright, browser, context, page

    def _try_engines(self, page, query, limit):
        """Перебирает движки, пока один не отдаст результаты.

        Ошибка движка (таймаут, капча, пустая выдача) не считается ошибкой поиска: она
        только повод попробовать следующий. Итоговая причина собирается из всех попыток —
        по ней в логе видно, что именно случилось со всеми тремя.
        """
        reasons = []
        for engine in ENGINES:
            try:
                results = self._run_engine(page, engine, query, limit)
                if results:
                    return engine["name"], results
                reasons.append("%s: пусто" % engine["name"])
            except Exception as e:
                reasons.append("%s: %s" % (engine["name"], type(e).__name__))
        raise BrowserError("; ".join(reasons))

    def _run_engine(self, page, engine, query, limit):
        """Открывает страницу выдачи одного движка и вытаскивает из неё результаты."""
        url = engine["url"].format(query=urllib.parse.quote_plus(query))
        page.goto(url, wait_until="domcontentloaded", timeout=PAGE_TIMEOUT_MS)
        page.wait_for_timeout(SEARCH_SETTLE_MS)

        titles = page.query_selector_all(engine["titles"])
        # Сниппеты берём отдельным списком: у всех трёх движков они идут в том же
        # порядке, что и заголовки, но отдельными узлами, а не внутри ссылки.
        snippets = page.query_selector_all(engine["snippets"])
        snippet_texts = [(node.inner_text() or "").strip() for node in snippets]

        results = []
        seen = set()
        for index, node in enumerate(titles):
            href = node.get_attribute("href") or ""
            if engine.get("unwrap"):
                href = unwrap_bing(href)
            if not href.startswith("http"):
                continue
            host = urllib.parse.urlparse(href).netloc.lower()
            if not host or host.endswith(ENGINE_HOSTS):
                continue
            if href in seen:
                continue
            seen.add(href)
            snippet = snippet_texts[index] if index < len(snippet_texts) else ""
            results.append(
                {
                    "title": (node.inner_text() or "").strip(),
                    "url": href,
                    "snippet": " ".join(snippet.split())[:400],
                }
            )
            if len(results) >= limit:
                break
        return results

    def _read(self, page, url, max_chars):
        """Открывает страницу и возвращает её основной текст.

        Обрезка идёт по границе слова: модель, получившая половину слова в конце,
        додумывает его сама, и в ответе появляется то, чего на странице не было.
        """
        page.goto(url, wait_until="domcontentloaded", timeout=PAGE_TIMEOUT_MS)
        page.wait_for_timeout(PAGE_SETTLE_MS)
        data = page.evaluate(PAGE_EXTRACT_JS) or {}
        text = (data.get("text") or "").strip()
        final_url = page.url or url
        truncated = len(text) > max_chars
        if truncated:
            cut = text.rfind(" ", 0, max_chars)
            text = text[: cut if cut > max_chars * 0.8 else max_chars].rstrip()
        return {
            "url": final_url,
            "title": (data.get("title") or "").strip(),
            "lang": (data.get("lang") or "").strip(),
            "text": text,
            "chars": len(text),
            "truncated": truncated,
            "short": len(text) < MIN_PAGE_CHARS,
        }

    def _close(self, *closers):
        """Закрывает браузер, гася ошибки: он мог умереть сам, и это не повод падать."""
        for closer in closers:
            if closer is None:
                continue
            try:
                closer.close()
            except Exception:
                pass
