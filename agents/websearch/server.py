#!/usr/bin/env python3
"""server.py — HTTP-ручки поиска и чтения страниц для сервера CloudlyRu.

Зачем отдельный сервис на маке. Модель и браузер живут на домашнем маке, а сервер
приложения — на VPS. Сервер приходит сюда через reverse-SSH туннель (на VPS открыт
только loopback-порт), поэтому этот сервис слушает 127.0.0.1 и не знает ни о TLS, ни
об авторизации: его клиент — единственный процесс на том же туннеле.

Ручки:
  GET /health                                  — жив ли сервис и что с браузером;
  GET /search?q=<запрос>&n=<сколько>           — выдача поисковика;
  GET /page?url=<адрес>&max=<символов>         — основной текст страницы.

Формат ответа всегда один и тот же JSON с полем `error`: null — получилось, строка —
короткая причина. Коды ответа при этом честные (400 на кривой запрос, 502 если не
смогли сходить в интернет), чтобы клиент мог отличить свою ошибку от чужой.

Кэш. Один и тот же запрос приходит дважды чаще, чем кажется: человек переспрашивает,
модель повторяет поиск, сервер перечитывает страницу после перезапуска. Держим
короткий кэш в памяти — поиск на 10 минут, страницы на 30: свежесть для новостей
сохраняется, а повторный поход в браузер (2-4 секунды) не оплачивается.
"""

import json
import os
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from browser import BrowserError, BrowserWorker

# Порт по умолчанию — тот же, что проброшен туннелем (VPS 127.0.0.1:18814 -> мак 18814).
# Менять его нужно вместе с agents/run-dsh-tunnel.sh, иначе сервер приложения перестанет
# видеть поиск.
PORT = int(os.environ.get("WEBSEARCH_PORT", "18814"))
HOST = os.environ.get("WEBSEARCH_HOST", "127.0.0.1")

# Границы запросов: защита от того, что клиент попросит 50 результатов или 5 МБ текста
# и займёт единственный браузер на минуты.
MAX_RESULTS = 10
DEFAULT_RESULTS = 5
MAX_PAGE_CHARS = 30_000
DEFAULT_PAGE_CHARS = 8_000

SEARCH_TTL = 600.0
PAGE_TTL = 1800.0
CACHE_LIMIT = 120

worker = BrowserWorker()


class Cache:
    """Кэш ответов с временем жизни и потолком по числу записей.

    Потолок нужен не ради памяти под строки (её мало), а ради предсказуемости: без него
    словарь рос бы вместе с числом уникальных запросов за всё время работы сервиса.
    Вытесняется самая старая запись — при таком объёме разница между LRU и «первым
    пришедшим» не стоит кода.
    """

    def __init__(self, limit=CACHE_LIMIT):
        self._limit = limit
        self._items = {}
        self._lock = threading.Lock()

    def get(self, key):
        """Возвращает значение, если оно есть и не протухло, иначе None."""
        with self._lock:
            item = self._items.get(key)
            if not item:
                return None
            value, expires = item
            if expires < time.time():
                self._items.pop(key, None)
                return None
            return value

    def put(self, key, value, ttl):
        """Кладёт значение на [ttl] секунд, вытесняя самую старую запись при переполнении."""
        with self._lock:
            if len(self._items) >= self._limit:
                oldest = min(self._items, key=lambda k: self._items[k][1])
                self._items.pop(oldest, None)
            self._items[key] = (value, time.time() + ttl)

    def size(self):
        """Число живых записей — уходит в /health."""
        with self._lock:
            return len(self._items)


search_cache = Cache()
page_cache = Cache()


class _Answered(Exception):
    """Внутренний сигнал: ответ клиенту уже отправлен, обрабатывать нечего."""


class Handler(BaseHTTPRequestHandler):
    """Обработчик ручек: разбор параметров, кэш, вызов браузера, JSON-ответ."""

    protocol_version = "HTTP/1.1"

    def do_GET(self):  # noqa: N802 — имя диктует BaseHTTPRequestHandler
        """Разводит запрос по ручкам и гасит исключения, чтобы сервис не падал."""
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        started = time.time()
        route = parsed.path.rstrip("/") or "/"
        try:
            if route == "/health":
                self._send(200, self._health())
            elif route == "/search":
                self._search(params)
            elif route == "/page":
                self._page(params)
            else:
                self._send(404, {"error": "неизвестная ручка: %s" % route})
        except _Answered:
            # Ответ уже отправлен внутри ручки (ошибку браузера превратили в 502) —
            # второй раз писать в тот же сокет нельзя.
            pass
        except Exception as e:
            # Сюда попадает всё неожиданное: причину видно в логе и в ответе, а сервис
            # продолжает работать.
            self._send(500, {"error": "%s: %s" % (type(e).__name__, e)})
        self._log(route, params, started)

    def _search(self, params):
        """Отдаёт выдачу поисковика: GET /search?q=&n="""
        query = (params.get("q") or [""])[0].strip()
        if not query:
            self._send(400, {"error": "не задан параметр q"})
            return
        limit = self._int_param(params, "n", DEFAULT_RESULTS, 1, MAX_RESULTS)
        key = "%s|%d" % (query, limit)
        cached = search_cache.get(key)
        if cached:
            self._send(200, {**cached, "cached": True})
            return
        engine, results = self._run(lambda: worker.search(query, limit), search_cache, key)
        payload = {"engine": engine, "results": results}
        search_cache.put(key, payload, SEARCH_TTL)
        self._send(200, {**payload, "cached": False})

    def _page(self, params):
        """Отдаёт текст страницы: GET /page?url=&max="""
        url = (params.get("url") or [""])[0].strip()
        if not url.startswith(("http://", "https://")):
            self._send(400, {"error": "параметр url должен начинаться с http:// или https://"})
            return
        max_chars = self._int_param(params, "max", DEFAULT_PAGE_CHARS, 500, MAX_PAGE_CHARS)
        key = "%s|%d" % (url, max_chars)
        cached = page_cache.get(key)
        if cached:
            self._send(200, {**cached, "cached": True})
            return
        page = self._run(lambda: worker.read_page(url, max_chars), page_cache, key)
        page_cache.put(key, page, PAGE_TTL)
        self._send(200, {**page, "cached": False})

    def _run(self, call, cache, key):
        """Вызывает браузер и превращает его ошибку в понятный клиенту ответ.

        Ошибка браузера — это 502: с нашей стороны всё в порядке, а сходить в интернет
        не получилось. Клиенту такое важно отличать от собственной ошибки в запросе.
        """
        try:
            return call()
        except BrowserError as e:
            self._send(502, {"error": str(e)})
            raise _Answered()

    def _health(self):
        """Состояние сервиса: поднят ли браузер и сколько помнит кэш."""
        return {
            "ok": True,
            "browser": worker.state,
            "cache": {"search": search_cache.size(), "page": page_cache.size()},
        }

    def _int_param(self, params, name, default, low, high):
        """Читает целочисленный параметр и зажимает его в границы [low, high]."""
        raw = (params.get(name) or [""])[0].strip()
        if not raw:
            return default
        try:
            value = int(raw)
        except ValueError:
            return default
        return max(low, min(high, value))

    def _send(self, status, payload):
        """Отдаёт JSON с честным кодом ответа; поле `error` есть всегда (null — успех)."""
        body = json.dumps({**payload, "error": payload.get("error")}, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _log(self, route, params, started):
        """Одна строка на запрос: ручка, ключевые параметры, миллисекунды.

        Пишем всегда, а не только ошибки: по этим строкам видно и кто отвечал (движок),
        и сколько ждал человек, — а лог дешевле, чем воспроизведение по памяти.
        """
        ms = int((time.time() - started) * 1000)
        key = (params.get("q") or params.get("url") or [""])[0][:60]
        print("%s %s %s %dms" % (time.strftime("%Y-%m-%d %H:%M:%S"), route, key, ms), flush=True)

    def log_message(self, fmt, *args):
        """Гасит встроенный лог BaseHTTPRequestHandler: свой формат уже написан выше."""
        return


def main():
    """Поднимает браузерный воркер и HTTP-сервер; работает до остановки процесса."""
    worker.start()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print("websearch слушает http://%s:%d (поиск и чтение страниц через Chrome)" % (HOST, PORT), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
