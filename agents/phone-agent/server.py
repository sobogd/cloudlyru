#!/usr/bin/env python3
"""server.py — HTTP-ручки телефона для агента в чате CloudlyRu.

Сервис живёт на маке и даёт серверу приложения три действия в браузере телефона:

  POST /search       {"query": "...", "site": "google.com"}   — поиск на сайте через его строку
  POST /open         {"url": "..."}                            — открыть страницу и прочитать текст
  GET  /health                                                 — телефон, Chrome, занятость

Почему на маке, а не на сервере: телефон подключён к маку по USB, и управлять им можно
только отсюда. Сервер приложения видит сервис через reverse-SSH туннель по loopback-порту,
поэтому ни TLS, ни авторизация тут не нужны — снаружи порт не смотрит.

Занятость. Телефон один, а Chrome в нём — один браузер: два одновременных прогона дрались бы
за вкладку и сбивали друг другу ввод. Поэтому задания выполняются по одному (замок), а второй
запрос честно получает `busy`, а не тихо портит чужой прогон.
"""

import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from browse import BrowseError, read_page, search_on
from phone import Phone, PhoneError

# Порт по умолчанию — тот же, что проброшен туннелем (VPS 127.0.0.1:18816 -> мак 18816).
# Менять его нужно вместе с jevel.ai/agents/run-dsh-tunnel.sh.
PORT = int(os.environ.get("PHONE_AGENT_PORT", "18816"))
HOST = os.environ.get("PHONE_AGENT_HOST", "127.0.0.1")

# Потолки запросов: телефон медленнее сервера, и очень длинный запрос означает, что агент
# сошёл с ума, а не то, что человеку нужен именно такой поиск.
MAX_QUERY_CHARS = 300
MAX_URL_CHARS = 2000

# Один телефон — один прогон. Замок не даёт двум вопросам одновременно дёргать браузер.
_run_lock = threading.Lock()
_stats = {"runs": 0, "last_ms": 0, "last_error": None, "last_at": None}


class Handler(BaseHTTPRequestHandler):
    """Ручки сервиса: поиск на сайте, чтение страницы, состояние."""

    protocol_version = "HTTP/1.1"

    def do_GET(self):  # noqa: N802 — имя диктует BaseHTTPRequestHandler
        """Только /health: остальное — POST, потому что тело несёт параметры запроса."""
        started = time.time()
        if self.path.rstrip("/") in ("", "/health"):
            body = {"ok": True, "busy": _run_lock.locked(), **_stats}
            try:
                with Phone() as phone:
                    body["device"] = phone.device()
                body["phone"] = "ok"
            except (PhoneError, BrowseError) as e:
                # Телефон не подключён — это состояние, а не ошибка сервиса: он работает,
                # а вот агент сейчас ничего сделать не сможет.
                body["phone"] = "нет телефона"
                body["phone_error"] = str(e)
            self._send(200, body)
        else:
            self._send(404, {"error": "неизвестная ручка: %s" % self.path})
        self._log("GET " + self.path, started)

    def do_POST(self):  # noqa: N802
        """POST /search и POST /open."""
        started = time.time()
        route = self.path.split("?", 1)[0].rstrip("/")
        try:
            payload = self._body()
            if route == "/search":
                self._search(payload)
            elif route == "/open":
                self._open(payload)
            else:
                self._send(404, {"error": "неизвестная ручка: %s" % route})
        except _Answered:
            pass
        except Exception as e:  # noqa: BLE001 — сервис обязан отвечать, а не падать
            self._send(500, {"error": "%s: %s" % (type(e).__name__, e)})
        self._log("POST " + route, started)

    def _search(self, payload: dict):
        """Поиск на сайте через его собственную поисковую строку."""
        query = str(payload.get("query") or "").strip()
        site = str(payload.get("site") or "google.com").strip()
        if not query:
            self._send(400, {"error": "не задан query"})
            return
        if len(query) > MAX_QUERY_CHARS:
            self._send(400, {"error": f"query длиннее {MAX_QUERY_CHARS} символов"})
            return
        if not _run_lock.acquire(blocking=False):
            self._send(409, {"error": "телефон занят другим прогоном"})
            return
        try:
            with Phone() as phone:
                result = search_on(phone, site, query)
            result["error"] = None
            self._send(200, result)
            _stats["runs"] += 1
            _stats["last_error"] = None
        except (PhoneError, BrowseError) as e:
            _stats["last_error"] = str(e)
            self._send(502, {"error": str(e)})
        finally:
            _run_lock.release()

    def _open(self, payload: dict):
        """Открыть страницу и вернуть её текст."""
        url = str(payload.get("url") or "").strip()
        max_chars = int(payload.get("max") or 4000)
        if not url.startswith(("http://", "https://")):
            self._send(400, {"error": "параметр url должен начинаться с http:// или https://"})
            return
        if len(url) > MAX_URL_CHARS:
            self._send(400, {"error": "url слишком длинный"})
            return
        if not _run_lock.acquire(blocking=False):
            self._send(409, {"error": "телефон занят другим прогоном"})
            return
        try:
            with Phone() as phone:
                result = read_page(phone, url, max_chars=max(500, min(20_000, max_chars)))
            result["error"] = None
            self._send(200, result)
            _stats["runs"] += 1
            _stats["last_error"] = None
        except (PhoneError, BrowseError) as e:
            _stats["last_error"] = str(e)
            self._send(502, {"error": str(e)})
        finally:
            _run_lock.release()

    def _body(self) -> dict:
        """Читает тело запроса как JSON; пустое тело — пустой словарь."""
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except Exception as e:
            raise BrowseError(f"тело запроса не разобрано как JSON: {e}") from e
        if not isinstance(parsed, dict):
            raise BrowseError("тело запроса должно быть объектом JSON")
        return parsed

    def _send(self, status: int, payload: dict):
        """Отдаёт JSON с честным кодом; поле `error` есть всегда (null — получилось)."""
        body = json.dumps({**payload, "error": payload.get("error")}, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _log(self, route: str, started: float):
        """Одна строка на запрос: ручка, миллисекунды, причина отказа если была."""
        ms = int((time.time() - started) * 1000)
        _stats["last_ms"] = ms
        _stats["last_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
        tail = f" ошибка: {_stats['last_error']}" if _stats["last_error"] else ""
        print(f"{_stats['last_at']} {route} {ms}ms{tail}", flush=True)

    def log_message(self, fmt, *args):
        """Гасит встроенный лог: свой формат уже написан выше."""
        return


class _Answered(Exception):
    """Ответ уже отправлен внутри ручки — второй раз писать в сокет нельзя."""


def main():
    """Поднимает HTTP-сервер; телефон и Chrome проверяются на каждом запросе, а не при старте."""
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"phone-agent слушает http://{HOST}:{PORT} (поиск и чтение через Chrome на телефоне)",
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
