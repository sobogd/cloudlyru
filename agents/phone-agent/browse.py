#!/usr/bin/env python3
"""browse.py — что именно делает агент в браузере телефона: ищет и читает.

Три действия, и все три — «как человек»:

  `search_on(phone, site, query)` — открыть сайт, ввести запрос в ЕГО поисковую строку и
  нажать его кнопку поиска. Так работает и Google, и Амазон, и Reddit: человек не набирает
  «site:amazon.es средство от запаха» в чужом поисковике, он идёт в магазин и ищет там.
  Прежний чат так не умел: слово «амазоне» уходило в Google обычным текстом, и на вопрос
  «поищи на амазоне» сервер читал статью про попугая амазона (живой случай из логов).

  `read_page(phone, url)` — открыть страницу и вернуть её текст. Для Reddit есть отдельный
  путь: обычная страница отдаёт «Prove your humanity» (проверка на бота), а тот же адрес с
  `.json` отдаёт всю переписку данными — и это работает там, где разметку не отдают.

  `dismiss_consent(phone)` — закрыть баннер про cookies. Без него на amazon.es нет ни
  поисковой строки, ни товаров: страница сначала спрашивает согласие.

Профили сайтов держат селекторы. Они и есть самое хрупкое место: сайты меняют разметку, и
когда Амазон это сделает, поправить придётся одну строку здесь, а не логику агента.
"""

from __future__ import annotations

import json
import os
import re
import urllib.parse
import urllib.request

# Сколько результатов отдавать агенту с одной выдачи. Больше ему не нужно: он всё равно
# открывает одну-две страницы, а лишние строки только занимают его контекст.
MAX_RESULTS = 8

# Слова, которыми сайты подписывают кнопку согласия на cookies. Проверяются и по тексту,
# и по `aria-label`: на amazon.es кнопка — это `input[type=submit]` с пустым текстом и
# подписью «Accept» в атрибуте, поэтому по одному тексту её не найти.
CONSENT_WORDS = (
    "accept", "aceptar", "принять", "согласен", "согласиться", "agree", "akzeptieren",
    "accetta", "tout accepter", "alle akzeptieren", "i agree", "got it", "понятно",
    "accept all", "aceptar todo", "принять все",
)

# Профили сайтов: где у сайта поисковая строка, чем он отправляет запрос и как выглядит
# его выдача. `field` — селекторы по очереди, первый найденный и используется.
SITES = {
    "google.com": {
        "url": "https://www.google.com/",
        "field": ("textarea[name=q]", "input[name=q]"),
        "submit": ("input[name=btnK]", "button[type=submit]"),
        "results": """
        (() => {
          const out = [];
          const seen = new Set();
          for (const a of document.querySelectorAll('#search a[href^="http"], #rso a[href^="http"]')) {
            const t = (a.innerText || '').trim();
            const h = a.href;
            if (t.length < 15 || h.includes('google.') || seen.has(h)) continue;
            seen.add(h);
            out.push({title: t.slice(0, 120), url: h, snippet: ''});
            if (out.length >= %d) break;
          }
          return out;
        })()
        """,
    },
    "amazon.es": {
        "url": "https://www.amazon.es/",
        "field": ("#nav-search-keywords", "#twotabsearchtextbox", "input[name=field-keywords]",
                  "input[name=k]", "input[type=search]"),
        "submit": ("#nav-search-submit-button", "form input[type=submit]", "form button[type=submit]"),
        "results": """
        (() => {
          // Разбор идёт ОТ ССЫЛОК на товар, а не от карточек. Раскладок у Amazon несколько,
          // и какая достанется — зависит от запроса: на испанский запрос карточки лежат в
          // `[data-component-type="s-search-result"]`, на русский (редкий для этого домена)
          // их там нет вовсе, а ссылки на `/dp/` есть. Пока разбор начинался с карточек,
          // русский запрос давал ноль товаров при непустой выдаче — проверено на живых
          // страницах. Ссылка есть всегда: без неё карточка бессмысленна.
          const out = [];
          const seen = new Set();
          for (const a of document.querySelectorAll('a[href*="/dp/"]')) {
            const asin = (a.href.match(/\\/dp\\/([A-Z0-9]{10})/) || [])[1];
            if (!asin || seen.has(asin)) continue;
            // Цену и описание берём у ближайшей карточки: у самой ссылки только заголовок.
            const card = a.closest('[data-asin]:not([data-asin=""])')
                      || a.closest('div.s-result-item')
                      || a.parentElement;
            const lines = (card ? card.innerText : a.innerText || '')
              .split('\\n').map(s => s.trim()).filter(Boolean);
            const title = (a.innerText || lines[0] || '').trim();
            const price = lines.find(s => /€|EUR/.test(s)) || '';
            // Служебные ссылки («условия», «похожие») отсеиваем по отсутствию и цены, и текста.
            if (title.length < 12 && !price) continue;
            seen.add(asin);
            out.push({
              title: title.slice(0, 120) || lines[0].slice(0, 120),
              url: 'https://www.amazon.es/dp/' + asin,
              snippet: [price, lines.slice(1, 3).join(' ')].filter(Boolean).join(' · ').slice(0, 200),
            });
            if (out.length >= %d) break;
          }
          return out;
        })()
        """,
    },
    "reddit.com": {
        "url": "https://www.reddit.com/",
        # На главной Reddit поля ввода нет вовсе — в разметке только скрытый input, а поиск
        # открывается кнопкой «Search Reddit». Это выяснилось на живом прогоне: агент получил
        # «на reddit.com не нашлась поисковая строка» и не смог ничего найти. Поэтому у сайта
        # есть шаг `reveal` — сначала нажать кнопку, потом искать поле.
        "reveal": ("search reddit", "search", "поиск"),
        "field": ("input[name=q]", "#search-input", "input[type=search]", "input[name=query]"),
        "submit": ("button[type=submit]", "#search-submit", "button[aria-label*=earch]"),
        "results": """
        (() => {
          const out = [];
          const seen = new Set();
          for (const a of document.querySelectorAll('a[href*="/comments/"]')) {
            const t = (a.innerText || '').trim();
            if (t.length < 12 || seen.has(a.href)) continue;
            seen.add(a.href);
            out.push({title: t.slice(0, 120), url: a.href.split('?')[0], snippet: ''});
            if (out.length >= %d) break;
          }
          return out;
        })()
        """,
    },
}

# Общий случай для сайта, которого нет в профилях: ищем поле по типовым признакам.
GENERIC_FIELD = ("input[type=search]", "input[name=q]", "input[name=s]", "input[name=k]",
                 "input[name=query]", "input[aria-label*=earch]", "input[placeholder*=earch]",
                 "input[placeholder*=оиск]", "input[placeholder*=uscar]")

# Язык, на котором сайт ищет по-настоящему. Амазон — не «поисковик», а магазин: он ищет
# по своему каталогу, и каталог у amazon.es испанский. Запрос по-русски там находит
# случайные товары (проверено: 18 ссылок и ни одного совпадения), а по-испански —
# конкретные средства с ценами. Поэтому запрос переводится на язык сайта ДО ввода в строку.
SITE_LANGS = {
    "amazon.es": "es",
    "amazon.de": "de",
    "amazon.fr": "fr",
    "amazon.it": "it",
    "amazon.co.uk": "en",
    "amazon.com": "en",
    "reddit.com": "en",
    "google.com": "en",
    "google.es": "es",
}

# Как называть язык в просьбе к модели (перевод идёт через локальную модель на маке).
LANG_NAMES = {
    "es": "Spanish",
    "en": "English",
    "de": "German",
    "fr": "French",
    "it": "Italian",
    "ru": "Russian",
}

# Локальная модель для перевода запроса: тот же llama-server на маке.
LLM_URL = os.environ.get("PHONE_AGENT_LLM_URL", "http://127.0.0.1:1234/v1")
LLM_MODEL = os.environ.get("PHONE_AGENT_LLM_MODEL", "qwen/qwen3.5-9b")

# Признак того, что страница — проверка на бота, а не статья.
BOT_WALL = ("prove your humanity", "are you a robot", "verify you are human",
            "unusual traffic", "подтвердите, что вы не робот")


class BrowseError(Exception):
    """Действие в браузере не удалось; текст — короткая причина для агента и для лога."""


def translate_query(query: str, lang: str) -> str:
    """Переводит поисковый запрос на язык сайта; при любой неудаче возвращает исходный.

    Спрашиваем локальную модель на маке короткой английской инструкцией и просим только
    запрос — без пояснений. Модель возвращает запрос как есть, если он уже на нужном языке,
    поэтому вызывать это можно не проверяя язык заранее.

    Отказ перевода не должен ломать поиск: лучше искать на исходном языке, чем не искать
    вовсе, поэтому все ошибки здесь гасятся.
    """
    name = LANG_NAMES.get(lang)
    if not name or not query.strip():
        return query
    body = {
        "model": LLM_MODEL,
        "messages": [{
            "role": "user",
            "content": f"Translate this product search query into {name}. "
                       f"Reply with the translated query only, no quotes, no explanation:\n{query}",
        }],
        "max_tokens": 64,
        "temperature": 0,
    }
    req = urllib.request.Request(f"{LLM_URL}/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.load(r)
        text = (data["choices"][0]["message"].get("content") or "").strip().strip('"')
        return text or query
    except Exception:
        return query


def site_of(url_or_name: str) -> str:
    """Приводит «амазон», «amazon.es» или адрес к ключу профиля; неизвестное — как есть.

    Агент называет сайт по-разному (модель может написать «amazon», «amazon.es»,
    «www.amazon.es»), а профиль один. Разбираем это здесь, чтобы у агента не было выбора
    «правильного написания» — на нём и спотыкаются модели.
    """
    value = (url_or_name or "").strip().lower()
    if not value:
        raise BrowseError("не указан сайт")
    if "//" in value:
        value = urllib.parse.urlparse(value).netloc
    value = value.split("/")[0].removeprefix("www.")
    for key in SITES:
        if value == key or value.startswith(key.split(".")[0]):
            return key
    return value


def site_url(site: str) -> str:
    """Адрес сайта: из профиля, а иначе собранный из имени домена."""
    key = site_of(site)
    if key in SITES:
        return SITES[key]["url"]
    return f"https://{key}/"


def dismiss_consent(phone) -> list[str]:
    """Закрывает баннер про cookies, если он есть. Возвращает подписи нажатых кнопок.

    Без этого шага на amazon.es не видно ни поисковой строки, ни товаров: страница сначала
    требует согласия. Нажимаем настоящим тапом по координатам (`tap_selector`), потому что
    часть баннеров игнорирует программный `element.click()`.
    """
    clicked = phone.eval_js("""
    (() => {
      const words = %s;
      const norm = el => ((el.innerText || '') + ' ' + (el.value || '') + ' ' +
                          (el.getAttribute('aria-label') || '')).trim().toLowerCase();
      const out = [];
      for (const el of document.querySelectorAll('button, input[type=submit], [role=button], a')) {
        const t = norm(el);
        if (!t) continue;
        if (!words.some(w => t.startsWith(w) || t.includes(w))) continue;
        const r = el.getBoundingClientRect();
        if (!r.width && !r.height) continue;
        el.id = el.id || 'agent-consent-%d'.replace('%%d', out.length);
        out.push({id: el.id, label: t.slice(0, 30)});
      }
      return out;
    })()
    """ % (json.dumps(list(CONSENT_WORDS)), 0)) or []
    pressed = []
    for item in clicked[:3]:
        if phone.tap_selector("#" + item["id"]):
            pressed.append(item["label"])
    return pressed


def reveal_search(phone, words: tuple[str, ...]) -> str | None:
    """Нажимает кнопку, которая раскрывает поиск, и возвращает её подпись.

    Нужно там, где поисковой строки на странице сразу нет (Reddit): сайт показывает кнопку
    «Search Reddit», а поле появляется после нажатия. Нажимаем настоящим тапом по координатам —
    так же, как это сделал бы человек: часть таких кнопок игнорирует программный `click()`.
    """
    found = phone.eval_js("""
    (() => {
      const words = %s;
      for (const el of document.querySelectorAll('button, [role=button], a, [role=link]')) {
        const t = ((el.innerText || '') + ' ' + (el.getAttribute('aria-label') || '')).trim().toLowerCase();
        if (!t) continue;
        const r = el.getBoundingClientRect();
        if (!r.width && !r.height) continue;
        if (!words.some(w => t === w || t.startsWith(w) || t.includes(w))) continue;
        el.id = 'agent-reveal';
        return t.slice(0, 40);
      }
      return null;
    })()
    """ % json.dumps(list(words)))
    if not found:
        return None
    return found if phone.tap_selector("#agent-reveal") else None


def focus_field(phone, selectors: tuple[str, ...]) -> str | None:
    """Находит поисковое поле, ставит в него курсор и возвращает, чем оно оказалось.

    Ищем и в обычном дереве, и внутри shadow DOM: у Reddit поисковая строка — `textarea[name=q]`
    внутри `<faceplate-search-input>`, и обычный `document.querySelector` её не находит вовсе
    (на живом прогоне это и дало «на reddit.com не нашлась поисковая строка»). Курсор ставим
    здесь же: после этого текст вводится через CDP в сфокусированное поле, независимо от того,
    где оно лежит в дереве.
    """
    return phone.eval_js("""
    (() => {
      const sels = %s;
      const deep = (sel) => {
        const walk = (root, depth) => {
          if (depth > 6) return null;
          for (const el of root.querySelectorAll('*')) {
            if (el.shadowRoot) {
              const hit = el.shadowRoot.querySelector(sel);
              if (hit) return hit;
              const nested = walk(el.shadowRoot, depth + 1);
              if (nested) return nested;
            }
          }
          return null;
        };
        return document.querySelector(sel) || walk(document, 0);
      };
      for (const sel of sels) {
        const el = deep(sel);
        if (!el || (!el.offsetWidth && !el.offsetHeight)) continue;
        el.focus();
        return sel;
      }
      return null;
    })()
    """ % json.dumps(list(selectors)))


def search_on(phone, site: str, query: str, limit: int = MAX_RESULTS,
              lang: str | None = None, translate: bool = True) -> dict:
    """Ищет [query] на сайте [site]: открывает его, вводит запрос в его строку, читает выдачу.

    Запрос переводится на язык сайта (`SITE_LANGS`): у amazon.es каталог испанский, и русский
    запрос там находит случайные товары. В ответе видно и исходный запрос, и тот, что реально
    ушёл в строку, — иначе непонятно, почему выдача такая.

    Если поисковой строки на сайте нет, это отдельная ошибка с внятным текстом: агент по ней
    поймёт, что на этом сайте так искать нельзя, и выберет другой путь (например, обычный поиск).
    """
    key = site_of(site)
    search_query = query
    if translate:
        target_lang = lang or SITE_LANGS.get(key)
        if target_lang:
            search_query = translate_query(query, target_lang)
    phone.open(site_url(key))
    dismiss_consent(phone)

    profile = SITES.get(key, {})
    field = focus_field(phone, tuple(profile.get("field", ())) or GENERIC_FIELD)
    if not field:
        # Поля нет сразу — возможно, поиск раскрывается кнопкой (Reddit).
        revealed = reveal_search(phone, tuple(profile.get("reveal", ())) or ("search", "поиск", "buscar"))
        if revealed:
            phone.settle(2.5)
            field = focus_field(phone, tuple(profile.get("field", ())) or GENERIC_FIELD)
    if not field:
        # Последняя попытка: перезагрузить корень сайта (страница могла уехать на статью)
        # и поискать поле общими признаками.
        phone.open(site_url(key))
        dismiss_consent(phone)
        field = focus_field(phone, GENERIC_FIELD)
    if not field:
        raise BrowseError(f"на {key} не нашлась поисковая строка")

    # Ввод. Поле уже в фокусе — его поставил `focus_field` (и только он умеет попадать в shadow
    # DOM). `Input.insertText` пишет юникод как есть, в отличие от `adb shell input text`,
    # который молча теряет кириллицу — на этом спотыкался прежний агент.
    phone.type_text(search_query)

    submitted = False
    submit_selectors = tuple(profile.get("submit", ())) or ("form input[type=submit]", "form button[type=submit]")
    if phone.tap_deep(submit_selectors):
        submitted = True
    if not submitted:
        # Часть сайтов (и все, где поле в shadow DOM) отправляют форму по Enter.
        phone.press_enter()
    phone.settle(5.0)

    extractor = profile.get("results")
    if extractor:
        results = phone.eval_js(extractor % limit) or []
    else:
        results = _generic_results(phone, limit)
    return {
        "site": key,
        "url": phone.url(),
        "query": query,
        "search_query": search_query,
        "results": results[:limit],
    }


def _generic_results(phone, limit: int) -> list[dict]:
    """Выдача сайта, для которого нет профиля: все осмысленные ссылки страницы."""
    return phone.eval_js("""
    (() => {
      const out = [];
      const seen = new Set();
      const host = location.host;
      for (const a of document.querySelectorAll('a[href^="http"]')) {
        const t = (a.innerText || '').trim();
        if (t.length < 15 || seen.has(a.href)) continue;
        if (new URL(a.href).host !== host) continue;
        seen.add(a.href);
        out.push({title: t.slice(0, 120), url: a.href.split('?')[0], snippet: ''});
        if (out.length >= %d) break;
      }
      return out;
    })()
    """ % limit) or []


def read_page(phone, url: str, max_chars: int = 4000) -> dict:
    """Открывает страницу и возвращает её текст.

    Для Reddit отдельный путь: разметку он не отдаёт (проверка на бота), а тот же адрес с
    `.json` отдаёт всю переписку данными — проверено на живом прогоне (59 тысяч символов
    против 238 символов заглушки).
    """
    phone.open(url)
    text = phone.text(limit=max_chars)
    title = phone.title()

    if any(mark in text.lower() for mark in BOT_WALL) and "reddit.com" in url:
        data = _reddit_json(phone, url)
        if data:
            return data
    return {
        "url": phone.url() or url,
        "title": title,
        "text": text,
        "chars": len(text),
        "blocked": any(mark in text.lower() for mark in BOT_WALL),
    }


def _reddit_json(phone, url: str) -> dict | None:
    """Читает ветку Reddit через `.json`: заголовок, текст поста и верхние комментарии."""
    clean = url.split("?")[0].rstrip("/")
    phone.open(clean + "/.json")
    raw = phone.text(limit=400_000)
    try:
        data = json.loads(raw)
    except Exception:
        return None
    out: list[str] = []
    try:
        post = data[0]["data"]["children"][0]["data"]
        out.append(f"{post.get('title', '')}\n{post.get('selftext', '')}".strip())
        for child in data[1]["data"]["children"][:15]:
            body = (child.get("data") or {}).get("body")
            if body:
                out.append(body.strip())
    except Exception:
        return None
    text = re.sub(r"\n{3,}", "\n\n", "\n\n".join(out)).strip()
    if not text:
        return None
    return {
        "url": clean,
        "title": out[0].split("\n")[0][:200],
        "text": text[:4000],
        "chars": len(text),
        "blocked": False,
        "via": "reddit-json",
    }
