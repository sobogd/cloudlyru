"""server.py — HTTP-ручка агента для раздела «Чат» CloudlyRu.

Живёт на маке и торчит только на 127.0.0.1:18816; наружу его отдаёт reverse-SSH туннель мака
(`jevel.ai/agents/run-dsh-tunnel.sh`), откуда его дёргает прод-сервер (`src/ai/agent.service.ts`).
Такое расположение не выбиралось: телефон подключён по USB к маку, и агент может работать
только там, где он лежит. Наружу порт не смотрит, поэтому ни TLS, ни своей авторизации здесь
нет — до него дотягивается только сам сервер CloudlyRu.

Ручки:
  POST /run     {"task": "...", "max_steps": 25} — прогнать задачу на телефоне
  GET  /health  — состояние: adb, устройство, занятость, счётчики

Ответ /run:
  {"answer": "текст", "steps": 7, "seconds": 94, "stopped": null}
  Ошибка приходит с непустым "error" и человеческим "message": no_device (503), busy (409),
  empty_task / too_long (400), agent_failed (500). Код причины прод разбирает, текст показывает
  человеку — поэтому причина и формулировка живут здесь, рядом с тем, что их вызвало.

Чего здесь намеренно нет: текста задачи в логах. Логи мака не место для вопросов владельца, а
для разбора хватает длины задачи, числа шагов и причины остановки.
"""

from __future__ import annotations

import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import android
from agent import DEFAULT_MAX_STEPS, LLM_MODEL, Agent

HOST = "127.0.0.1"
PORT = int(os.environ.get("AGENT_PORT", "18816"))

# Потолок длины задачи: в чате вопрос ограничен 8000 символами, но агенту такое не нужно — он
# всё равно выполнит одно действие за шаг, а длинная задача только размывает инструкцию.
MAX_TASK_CHARS = 4000

# Потолок шагов на прогон, который можно попросить с сервера. Агент ходит по экрану телефона, и
# каждый шаг — это запрос к модели и несколько секунд ожидания; сорок шагов это уже минуты.
MAX_STEPS_LIMIT = 40


class AgentRunError(Exception):
    """Отказ агента с машиночитаемым кодом, текстом для человека и HTTP-статусом."""

    def __init__(self, code: str, message: str, status: int) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status = status


class Runner:
    """Один прогон за раз на одном телефоне: очередь, счётчики, отказ «занято».

    Почему без очереди: прогон занимает минуты, а телефон один. Накопленная очередь означала бы,
    что человек ждёт не только свой прогон, но и все предыдущие, и не понимает, чего именно
    ждёт. Отказ «занято» честнее: видно, что устройство работает на кого-то другого.
    """

    def __init__(self) -> None:
        # Блокировка, а не флаг: между проверкой и началом прогона не должно быть щели, иначе
        # два одновременных запроса оба решат, что телефон свободен.
        self._lock = threading.Lock()
        self._runs = 0
        self._last_seconds = 0
        self._last_steps = 0

    @property
    def busy(self) -> bool:
        """Занят ли телефон прямо сейчас (для `/health`)."""
        return self._lock.locked()

    def stats(self) -> dict:
        """Счётчики для `/health`: сколько прогонов и чем закончился последний."""
        return {
            "runs": self._runs,
            "last_seconds": self._last_seconds,
            "last_steps": self._last_steps,
        }

    def run(self, task: str, max_steps: int) -> dict:
        """Выполнить задачу на телефоне и вернуть ответ агента.

        Поднимает AgentRunError, если телефон занят, не подключён или прогон сорвался. Устройство
        проверяется до захвата блокировки: без телефона работать нечем, и занимать на это телефон
        (а точнее, отказывать «занято» следующему запросу) незачем.
        """
        serial, problem = android.device_state()
        if serial is None:
            raise AgentRunError("no_device", problem, 503)

        if not self._lock.acquire(blocking=False):
            raise AgentRunError(
                "busy",
                "телефон занят другой задачей — дождись её окончания",
                409,
            )
        try:
            started = time.time()
            result = Agent(
                serial=serial,
                max_steps=max_steps,
                # Ход прогона видно в логе мака, но без содержимого экрана: иначе в логах оседал
                # бы текст чужих страниц и переписки.
                progress=lambda message: print(f"  {message}", flush=True),
            ).run(task)
            self._runs += 1
            self._last_seconds = int(time.time() - started)
            self._last_steps = result.steps
            return {
                "answer": result.answer,
                "steps": result.steps,
                "seconds": self._last_seconds,
                "stopped": result.stop_reason or None,
            }
        except RuntimeError as error:
            # Сбой adb или модели: и телефон могли выдернуть, и LM Studio мог не ответить.
            # Причина уходит в лог целиком — это единственное место, где её видно.
            raise AgentRunError("agent_failed", str(error)[:300], 500) from error
        finally:
            self._lock.release()


RUNNER = Runner()


class Handler(BaseHTTPRequestHandler):
    """HTTP-ручка агента: разбор параметров, проверки, JSON-ответ."""

    server_version = "cloudlyru-android-agent/1"

    def do_GET(self):  # noqa: N802 — имя диктует BaseHTTPRequestHandler
        path = self.path.split("?", 1)[0]
        if path == "/health":
            serial, problem = android.device_state()
            payload = {
                "ok": True,
                "device": serial,
                "problem": problem or None,
                "model": LLM_MODEL,
                "busy": RUNNER.busy,
            }
            payload.update(RUNNER.stats())
            self._json(200, payload)
            return
        self._json(404, {"error": "not_found", "message": "такой ручки нет"})

    def do_POST(self):  # noqa: N802 — имя диктует BaseHTTPRequestHandler
        if self.path.split("?", 1)[0] != "/run":
            self._json(404, {"error": "not_found", "message": "такой ручки нет"})
            return
        try:
            body = self._read_json()
            task = str(body.get("task") or "").strip()
            if not task:
                raise AgentRunError("empty_task", "пустая задача", 400)
            if len(task) > MAX_TASK_CHARS:
                raise AgentRunError(
                    "too_long",
                    f"задача длиннее {MAX_TASK_CHARS} символов — агенту нужен короткий вопрос",
                    400,
                )
            try:
                max_steps = int(body.get("max_steps") or DEFAULT_MAX_STEPS)
            except (TypeError, ValueError):
                max_steps = DEFAULT_MAX_STEPS
            max_steps = max(1, min(max_steps, MAX_STEPS_LIMIT))

            print(
                "%s POST /run: задача %d симв., до %d шагов"
                % (time.strftime("%Y-%m-%d %H:%M:%S"), len(task), max_steps),
                flush=True,
            )
            payload = RUNNER.run(task, max_steps)
            self._json(200, payload)
        except AgentRunError as e:
            self._json(e.status, {"error": e.code, "message": e.message})
        except Exception as e:  # noqa: BLE001 — ручка не имеет права уронить сервис
            # Непредвиденное (разметка не разобралась, adb ответил странно) — в лог целиком, а
            # клиенту код и короткий текст: без этого сервис падал бы целиком на одном запросе.
            print("%s POST /run: непредвиденный сбой — %r" % (time.strftime("%Y-%m-%d %H:%M:%S"), e), flush=True)
            self._json(500, {"error": "internal", "message": str(e)[:300]})

    def _read_json(self) -> dict:
        """Прочитать тело запроса как JSON-объект (пустое тело — пустой объект)."""
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            data = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as error:
            raise AgentRunError("bad_json", f"тело запроса не разобралось: {error}", 400) from error
        return data if isinstance(data, dict) else {}

    def _json(self, status: int, payload: dict) -> None:
        """Отдаёт JSON и пишет в лог строку без текста задачи и без ответа агента."""
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        print(
            # Время обязательно: по логу разбирают, кто и когда стучался — а без отметок времени
            # один запрос через час и два подряд выглядят одинаково.
            "%s %s %s -> %d, шагов %s, секунд %s, ошибка %s"
            % (
                time.strftime("%Y-%m-%d %H:%M:%S"),
                self.command,
                self.path.split("?", 1)[0],
                status,
                payload.get("steps"),
                payload.get("seconds"),
                payload.get("error"),
            ),
            flush=True,
        )

    def log_message(self, fmt, *args):
        """Гасит стандартный лог: он печатает строку запроса целиком, то есть вопрос владельца.

        Свой лог пишет `_json`, и в нём есть только путь без параметров. Вопрос в логах мака не
        нужен: он уходит на телефон, а не в наши файлы.
        """
        return


def main() -> None:
    """Поднимает сервер.

    Потоки, а не один обработчик: прогон занимает минуты, и одиночный обработчик не отвечал бы
    даже на `/health`, пока агент работает на телефоне — а именно тогда состояние и спрашивают.
    """
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    serial, problem = android.device_state()
    print(
        "android-agent слушает http://%s:%d (модель %s, устройство %s)"
        % (HOST, PORT, LLM_MODEL, serial or f"нет: {problem}"),
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
