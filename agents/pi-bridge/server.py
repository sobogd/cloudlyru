#!/usr/bin/env python3
"""server.py — мост между приложением CloudlyRu и харнессом pi на маке.

Зачем отдельный сервис. Харнесс pi (`pi --mode rpc`) разговаривает JSON-строками по
stdio и умеет ровно то, что нужно разделу «Проекты» в приложении: держит сессию с
рабочей папкой проекта, стримит текст ответа, вызовы инструментов и их вывод, умеет
`abort`, `compact`, смену модели. Но stdio — это не сеть: телефон до него не дотянется.
Поэтому здесь тонкий адаптер: HTTP+SSE наружу, JSON-строки внутрь.

Границы ответственности:
  * сервис НЕ думает и НЕ хранит историю: вся история — файлы сессий pi
    (`~/.pi/agent/sessions/`), модель и инструменты — тоже pi;
  * сервис только перекладывает протокол, ведёт пул процессов (один процесс pi на
    сессию) и решает, кто имеет право спрашивать.

Ручки (все требуют `Authorization: Bearer <токен>`, кроме `/health`):
  GET    /health                      — жив ли сервис, есть ли pi, что с процессами;
  GET    /projects                    — проекты из allowlist-корней (папки с .git);
  GET    /sessions?path=<папка>       — сессии проекта (файлы pi), свежие сверху;
  POST   /sessions                    — открыть сессию: поднять процесс pi в этой папке;
  GET    /sessions/<id>               — состояние сессии (модель, контекст, занятость);
  GET    /sessions/<id>/messages      — переписка в нормализованном виде;
  POST   /sessions/<id>/prompt        — отправить сообщение, ответ потоком SSE;
  POST   /sessions/<id>/abort         — остановить генерацию;
  POST   /sessions/<id>/compact       — сжать контекст;
  POST   /sessions/<id>/model         — сменить модель;
  POST   /sessions/<id>/ui            — ответ на диалог расширения (по умолчанию не нужен);
  DELETE /sessions/<id>               — закрыть процесс (файл сессии остаётся).

Настройки лежат в `~/.pi-bridge.json` и создаются при первом запуске: порт, токен,
allowlist корней, модель. Токен нигде не печатается — его берут из файла.

Автоответы. Подтверждений у pi в RPC-режиме нет как понятия: диалоги приходят от
расширений событием `extension_ui_request`, и без ответа агент ждёт вечно. Выбранная
политика раздела — «разрешать всё без вопросов», поэтому сервис отвечает сам:
`confirm` → да, `select` → первый вариант, `input` → отмена (текст придумать нельзя).
Каждый автоответ пишется в лог: иначе по журналу нельзя было бы понять, что агент
сделал без человека.
"""

import hmac
import json
import os
import queue
import secrets
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# Порт по умолчанию. Наружу его не открывает ничто: на маке к нему ходит только
# cloudflared, который и держит туннель до Cloudflare (см. README рядом).
PORT = int(os.environ.get("PI_BRIDGE_PORT", "18820"))
HOST = os.environ.get("PI_BRIDGE_HOST", "127.0.0.1")

# Файл настроек: рядом с сессиями pi, но отдельно от них — это настройки моста, а не харнесса.
CONFIG_PATH = Path(os.environ.get("PI_BRIDGE_CONFIG", str(Path.home() / ".pi-bridge.json")))

# Где pi держит сессии: одна папка на рабочую директорию, внутри — JSONL-файлы.
PI_SESSIONS = Path.home() / ".pi" / "agent" / "sessions"
# Каталог моделей pi: из него берём провайдера и модель по умолчанию, чтобы не хардкодить.
PI_MODELS = Path.home() / ".pi" / "agent" / "models.json"

# Потолки и таймауты. Все — про предсказуемость: без них зависший pi держал бы поток
# приложения открытым бесконечно, а ответ без единого события выглядел бы как работа.
COMMAND_TIMEOUT = 60.0     # ожидание ответа на команду (get_state, prompt-подтверждение)
IDLE_STOP_SECONDS = 1800.0  # простой, после которого процесс pi закрывается
MAX_MESSAGE_CHARS = 20_000  # потолок сообщения, чтобы одним запросом не забить контекст
# События pi, которые уходят приложению. Остальные (message_start, turn_start и прочая
# служебная механика) наружу не нужны: экран строится по дельтим и вызовам инструментов.
FORWARDED_EVENTS = {
    "message_update",
    "tool_execution_start",
    "tool_execution_update",
    "tool_execution_end",
    "agent_start",
    "agent_end",
    "agent_settled",
    "turn_end",
    "queue_update",
    "compaction_start",
    "compaction_end",
    "auto_retry_start",
    "auto_retry_end",
    "extension_error",
}

log_lock = threading.Lock()


def log(message):
    """Пишет строку в stderr с временем: launchd складывает его в файл лога.

    Почему stderr, а не файл: stdout в этом процессе свободен (в отличие от pi, у которого
    там протокол), а перенаправление делает launchd — сервису незачем знать путь к логу.
    """
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with log_lock:
        sys.stderr.write("[%s] %s\n" % (stamp, message))
        sys.stderr.flush()


def load_config():
    """Читает настройки, создавая файл с токеном при первом запуске.

    Токен генерируется здесь и только здесь: он нужен, чтобы туннель не превращался в
    «любой, кто угадал адрес, получает шелл на маке». Печатать его в лог нельзя — лог
    читают глазами и он попадает в переписку; владелец берёт токен из файла сам.
    """
    if CONFIG_PATH.exists():
        try:
            cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            if isinstance(cfg, dict):
                return cfg
            log("настройки %s — не объект, беру значения по умолчанию" % CONFIG_PATH)
        except (OSError, ValueError) as e:
            log("не смог прочитать %s (%s), беру значения по умолчанию" % (CONFIG_PATH, e))

    cfg = {
        "port": PORT,
        "host": HOST,
        # Корни, внутри которых разрешено выбирать проекты. Именно allowlist, а не «вся
        # файловая система»: раздел даёт агенту право писать файлы и запускать команды, и
        # граница тут — единственное, что отделяет рабочие репозитории от остального дома.
        "roots": [str(Path.home() / "work")],
        "depth": 2,          # на сколько уровней вглубь искать папки с .git
        "pi": "pi",          # бинарь харнесса (PATH launchd задан в plist)
        "provider": "",      # пусто — взять первого провайдера из models.json pi
        "model": "",         # пусто — взять первую модель этого провайдера
        "token": secrets.token_hex(24),
    }
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding="utf-8")
    os.chmod(CONFIG_PATH, 0o600)
    log("создал %s — токен и корни внутри файла, откройте его и впишите в приложение" % CONFIG_PATH)
    return cfg


CONFIG = load_config()


def default_model():
    """Провайдер и модель по умолчанию: из настроек моста, иначе из моделей pi.

    Порядок именно такой, потому что models.json — файл харнесса: его правит человек для
    терминала, и мост не должен его переписывать. Здесь он только читается, а перевод
    раздела на другую модель делается настройкой моста.
    """
    provider = str(CONFIG.get("provider") or "").strip()
    model = str(CONFIG.get("model") or "").strip()
    if provider and model:
        return provider, model

    try:
        data = json.loads(PI_MODELS.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        log("не смог прочитать модели pi (%s) — модель выберет сам pi" % e)
        return provider, model

    providers = data.get("providers") if isinstance(data, dict) else None
    if not isinstance(providers, dict):
        return provider, model
    for name, body in providers.items():
        if not isinstance(body, dict):
            continue
        models = body.get("models")
        if not isinstance(models, list) or not models or not isinstance(models[0], dict):
            continue
        return provider or str(name), model or str(models[0].get("id") or "")
    return provider, model


def sessions_dir_for(cwd):
    """Папка сессий pi для рабочей директории проекта.

    Схема имени задана харнессом (`docs/session-format.md`): ведущий разделитель убирается,
    а `/`, `\\` и `:` заменяются на `-`; результат обёрнут в двойные дефисы. Повторяем её
    дословно — иначе список сессий проекта окажется пустым.
    """
    encoded = str(cwd).lstrip(os.sep).replace("/", "-").replace("\\", "-").replace(":", "-")
    return PI_SESSIONS / ("--%s--" % encoded)


def content_text(content):
    """Склеивает текстовые блоки сообщения pi в одну строку.

    Содержимое у pi бывает и строкой, и списком блоков (`text`, `thinking`, `toolCall`,
    картинки). Текстом для экрана считается только `text`: размышления показываются
    отдельно, а вызовы инструментов разбираются по-своему.
    """
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(str(block.get("text") or ""))
    return "".join(parts)


def thinking_text(content):
    """Склеивает блоки «размышлений» сообщения pi."""
    if not isinstance(content, list):
        return ""
    return "".join(
        str(b.get("thinking") or "")
        for b in content
        if isinstance(b, dict) and b.get("type") == "thinking"
    )


def normalize_messages(messages):
    """Приводит переписку pi к плоскому списку строк для экрана.

    У pi история — дерево записей, где вызов инструмента и его результат лежат в разных
    сообщениях. Экрану нужно другое: последовательность «вопрос — ответ — что агент
    сделал». Поэтому результат инструмента не становится отдельной строкой, а
    подклеивается к своему вызову по `toolCallId` — так в приложении вызов и его вывод
    показываются одной карточкой.
    """
    items = []
    by_call = {}
    for message in messages:
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        if role == "user":
            text = content_text(message.get("content"))
            if text.strip():
                items.append({"kind": "user", "text": text})
        elif role == "assistant":
            tools = []
            content = message.get("content")
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "toolCall":
                        call = {
                            "id": str(block.get("id") or ""),
                            "name": str(block.get("name") or ""),
                            "args": block.get("arguments") if isinstance(block.get("arguments"), dict) else {},
                            "output": "",
                            "isError": False,
                        }
                        tools.append(call)
                        by_call[call["id"]] = call
            text = content_text(content)
            thinking = thinking_text(content)
            # Пустой ответ без вызовов — это сообщение с одним лишь текстом ошибки провайдера;
            # показываем его, иначе прогон выглядел бы как «агент молча ничего не сделал».
            error = message.get("errorMessage")
            if text.strip() or thinking or tools or error:
                items.append({
                    "kind": "assistant",
                    "text": text,
                    "reasoning": thinking,
                    "tools": tools,
                    "error": str(error) if error else "",
                })
        elif role == "toolResult":
            call = by_call.get(str(message.get("toolCallId") or ""))
            if call is not None:
                call["output"] = content_text(message.get("content"))
                call["isError"] = bool(message.get("isError"))
        elif role == "bashExecution":
            items.append({
                "kind": "bash",
                "command": str(message.get("command") or ""),
                "output": str(message.get("output") or ""),
                "exitCode": message.get("exitCode"),
            })
        # system и прочие роли на экран не попадают: это внутренняя механика харнесса
    return items


def session_files(path):
    """Файлы сессий проекта, свежие сверху."""
    folder = sessions_dir_for(path)
    if not folder.is_dir():
        return []
    files = [p for p in folder.glob("*.jsonl") if p.is_file()]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return files


def read_session_meta(file):
    """Читает из файла сессии то, что нужно строке списка: id, время, имя, число сообщений.

    Файл разбирается построчно до конца: имя сессии pi хранит отдельной записью, которая
    может стоять в любом месте, а счётчик сообщений иначе не собрать. Строки, которые не
    разбираются (обрывок последней записи — pi пишет построчно и может не успеть), просто
    пропускаются: список важнее строгости одной строки.

    Имя и заголовок — разные вещи: `name` ставит человек (или сам pi) записью `session_info`,
    `title` — первые слова первого вопроса. Для строки списка годится любое, поэтому наружу
    уходит `name`, а если его нет — `title`.
    """
    meta = {
        "id": file.stem.split("_")[-1],
        "cwd": "",
        "startedAt": None,
        "name": "",
        "title": "",
        "messages": 0,
    }
    try:
        with file.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(entry, dict):
                    continue
                kind = entry.get("type")
                if kind == "session":
                    meta["id"] = str(entry.get("id") or meta["id"])
                    meta["cwd"] = str(entry.get("cwd") or "")
                    meta["startedAt"] = entry.get("timestamp")
                elif kind == "session_info":
                    # побеждает последняя такая запись: пустое имя означает «имя снято»
                    name = entry.get("name")
                    meta["name"] = name.strip() if isinstance(name, str) else ""
                elif kind == "message":
                    message = entry.get("message")
                    if isinstance(message, dict) and message.get("role") in ("user", "assistant"):
                        meta["messages"] += 1
                        if not meta["title"] and message.get("role") == "user":
                            text = content_text(message.get("content")).strip().replace("\n", " ")
                            if text:
                                meta["title"] = text[:80]
    except OSError as e:
        log("не смог прочитать сессию %s: %s" % (file, e))
    if not meta["name"]:
        meta["name"] = meta["title"]
    if not meta["startedAt"]:
        meta["startedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(file.stat().st_mtime))
    meta["updatedAt"] = time.strftime(
        "%Y-%m-%dT%H:%M:%SZ", time.gmtime(file.stat().st_mtime)
    )
    return meta


def list_projects():
    """Проекты: корни из allowlist плюс папки с `.git` внутри них.

    Выбор проекта — это выбор рабочей папки, поэтому список строится из файловой системы,
    а не из базы: у pi уже есть сессии по каждой папке, и «проект со шляпкой истории»
    виден по наличию папки сессий. Папки без `.git` и без сессий в список не попадают:
    иначе он превратился бы в браузер файловой системы.
    """
    depth = int(CONFIG.get("depth") or 2)
    roots = [Path(str(r)).expanduser() for r in (CONFIG.get("roots") or [])]
    seen = set()
    projects = []

    def add(path):
        """Добавляет папку в список, если она ещё не добавлена и существует."""
        key = str(path)
        if key in seen or not path.is_dir():
            return
        seen.add(key)
        files = session_files(path)
        last = None
        if files:
            last = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(files[0].stat().st_mtime))
        projects.append({
            "path": key,
            "name": path.name,
            "root": str(next((r for r in roots if str(path).startswith(str(r))), path.parent)),
            "sessions": len(files),
            "lastUsed": last,
        })

    for root in roots:
        if not root.is_dir():
            continue
        add(root)
        for level in range(1, depth + 1):
            pattern = "/".join(["*"] * level)
            try:
                candidates = sorted(root.glob(pattern))
            except OSError as e:
                log("не смог обойти %s: %s" % (root, e))
                break
            for path in candidates:
                if not path.is_dir() or path.name.startswith("."):
                    continue
                if (path / ".git").exists() or sessions_dir_for(path).is_dir():
                    add(path)
    # сначала проекты с историей и свежие, потом остальные по имени
    projects.sort(key=lambda p: (p["lastUsed"] is None, p["name"].lower()))
    projects.sort(key=lambda p: p["lastUsed"] or "", reverse=True)
    return projects


def allowed_path(path):
    """Проверяет, что папка лежит внутри allowlist-корня.

    Проверка идёт по разобранному пути (`resolve`), а не по строке: иначе `~/work/../.ssh`
    прошло бы как «начинается с ~/work». Это не песочница (её у pi нет), а граница выбора:
    агент работает в папке проекта, но случайно выбрать домашний каталог нельзя.
    """
    try:
        resolved = Path(path).expanduser().resolve()
    except (OSError, RuntimeError):
        return None
    for root in CONFIG.get("roots") or []:
        try:
            base = Path(str(root)).expanduser().resolve()
        except (OSError, RuntimeError):
            continue
        if resolved == base or base in resolved.parents:
            return resolved
    return None


class PiError(Exception):
    """Ошибка работы с харнессом: текст пригоден и для лога, и для показа в приложении."""


class PiSession:
    """Один процесс pi в режиме RPC, привязанный к рабочей папке проекта.

    Почему процесс на сессию, а не один на всех: `pi --mode rpc` — это одна сессия с
    одним cwd, и переключать папку в живом процессе нельзя. Пул держит процессы открытыми,
    чтобы продолжение разговора не ждало старта pi (несколько секунд) и не теряло прогрев
    промпта в llama.cpp.
    """

    def __init__(self, cwd, session_id=None):
        """Поднимает процесс pi в папке [cwd], при необходимости продолжая сессию [session_id]."""
        self.cwd = str(cwd)
        self.id = session_id or ""
        self.proc = None
        self.reader = None
        self.lock = threading.Lock()
        self.pending = {}          # id команды -> очередь ответа
        self.subscribers = []      # очереди SSE-потоков, слушающих эту сессию
        self.busy = False          # идёт генерация: второй запрос в ту же сессию не пускаем
        self.touched = time.time()  # время последнего обращения (для остановки по простою)
        self.state = {}            # последнее get_state: модель, контекст, число сообщений
        self.stderr_tail = []      # хвост stderr pi — попадает в текст ошибки, если процесс умер
        self._start(session_id)

    def _start(self, session_id):
        """Собирает команду запуска pi и заводит потоки чтения stdout и stderr."""
        provider, model = default_model()
        cmd = [str(CONFIG.get("pi") or "pi"), "--mode", "rpc"]
        if session_id:
            # --session-id продолжает существующую сессию или создаёт её с этим id: так
            # приложение может вернуться к разговору, который уже лежит в файлах pi.
            cmd += ["--session-id", session_id]
        if provider:
            cmd += ["--provider", provider]
        if model:
            cmd += ["--model", model]
        # Расширения и скиллы проекта подхватываем: у pi это защищено вопросом о доверии,
        # а в RPC-режиме вопроса не бывает — без --approve ресурсы проекта молча не грузятся.
        cmd.append("--approve")

        log("запускаю pi в %s: %s" % (self.cwd, " ".join(cmd)))
        try:
            self.proc = subprocess.Popen(
                cmd,
                cwd=self.cwd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,  # построчно: протокол pi — это JSON-строки
            )
        except OSError as e:
            raise PiError("не удалось запустить pi (%s): %s" % (CONFIG.get("pi"), e))

        self.reader = threading.Thread(target=self._read_stdout, daemon=True)
        self.reader.start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

        # Сессия узнаёт свой id только у pi: при запуске без --session-id его генерирует он.
        state = self.command("get_state", timeout=COMMAND_TIMEOUT)
        self.id = str(state.get("sessionId") or self.id or "")
        self.state = state

    def _read_stdout(self):
        """Читает протокол pi: ответы на команды разводит по ожидающим, события — подписчикам."""
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except ValueError:
                log("не разобрал строку pi: %s" % line[:200])
                continue
            if not isinstance(message, dict):
                continue

            kind = message.get("type")
            if kind == "response":
                pending = self.pending.pop(str(message.get("id")), None)
                if pending is not None:
                    pending.put(message)
                continue
            if kind == "extension_ui_request":
                self._answer_ui(message)
                continue
            if kind in FORWARDED_EVENTS:
                self._publish(message)

        # процесс закончился — будим всех, кто ждал ответа или события
        self._fail_waiters("процесс pi завершился")

    def _read_stderr(self):
        """Держит хвост stderr pi: по нему понятно, почему процесс умер."""
        for line in self.proc.stderr:
            line = line.rstrip()
            if not line:
                continue
            self.stderr_tail.append(line)
            del self.stderr_tail[:-20]
            log("pi: %s" % line[:300])

    def _answer_ui(self, message):
        """Отвечает на диалог расширения по политике «разрешать всё без вопросов».

        Диалог без ответа блокирует агента навсегда, а спрашивать человека в этом разделе
        решено не спрашивать (см. заголовок файла). Поэтому: подтверждение — да, выбор —
        первый вариант, ввод текста — отмена (придумать текст за человека нельзя). Каждый
        автоответ уходит подписчикам событием `ui`, чтобы он был виден в переписке.
        """
        request_id = str(message.get("id") or "")
        method = str(message.get("method") or "")
        title = str(message.get("title") or message.get("message") or "")
        response = {"type": "extension_ui_response", "id": request_id}
        shown = ""
        if method == "confirm":
            response["confirmed"] = True
            shown = "подтверждено автоматически"
        elif method == "select":
            options = message.get("options")
            if isinstance(options, list) and options:
                response["value"] = options[0]
                shown = "выбрано автоматически: %s" % options[0]
            else:
                response["cancelled"] = True
                shown = "отменено автоматически: вариантов нет"
        elif method in ("input", "editor"):
            response["cancelled"] = True
            shown = "отменено автоматически: ввод текста без человека"
        else:
            return  # notify/setStatus и прочее ответа не ждут
        log("автоответ на диалог расширения (%s): %s — %s" % (method, shown, title[:120]))
        self._write(response)
        self._publish({"type": "ui", "method": method, "title": title, "auto": shown})

    def _publish(self, event):
        """Рассылает событие pi всем открытым потокам SSE этой сессии."""
        for q in list(self.subscribers):
            q.put(event)

    def _fail_waiters(self, reason):
        """Будит всех ожидающих после смерти процесса, чтобы запросы не висели вечно."""
        for key, q in list(self.pending.items()):
            q.put({"type": "response", "id": key, "success": False, "error": reason})
        self.pending.clear()
        for q in list(self.subscribers):
            q.put({"type": "fatal", "message": reason})

    def _write(self, payload):
        """Отправляет одну команду pi; сбой записи означает смерть процесса."""
        self.touched = time.time()
        try:
            self.proc.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
            self.proc.stdin.flush()
        except (OSError, ValueError) as e:
            raise PiError("процесс pi не принимает команды: %s" % e)

    def command(self, kind, timeout=COMMAND_TIMEOUT, **fields):
        """Отправляет команду и ждёт её ответ; возвращает `data` ответа.

        Идентификатор ставит сам мост: по нему ответ сопоставляется с запросом, потому что
        события pi и ответы на команды идут в одном потоке stdout.
        """
        if self.proc is None or self.proc.poll() is not None:
            detail = self.stderr_tail[-1] if self.stderr_tail else "без вывода"
            raise PiError("процесс pi не работает (%s)" % detail)
        request_id = uuid.uuid4().hex
        answer = queue.Queue(maxsize=1)
        self.pending[request_id] = answer
        self._write(dict({"id": request_id, "type": kind}, **fields))
        try:
            response = answer.get(timeout=timeout)
        except queue.Empty:
            self.pending.pop(request_id, None)
            raise PiError("pi не ответил на %s за %.0f с" % (kind, timeout))
        if not response.get("success"):
            raise PiError(str(response.get("error") or "pi отклонил команду %s" % kind))
        data = response.get("data")
        return data if isinstance(data, dict) else {}

    def messages(self):
        """Переписка сессии в нормализованном виде."""
        data = self.command("get_messages")
        messages = data.get("messages")
        return normalize_messages(messages if isinstance(messages, list) else [])

    def refresh_state(self):
        """Обновляет снимок состояния: модель, контекст, число сообщений."""
        try:
            self.state = self.command("get_state")
            stats = self.command("get_session_stats")
        except PiError as e:
            log("не смог обновить состояние сессии %s: %s" % (self.id, e))
            return self.state
        context = stats.get("contextUsage") if isinstance(stats, dict) else None
        return {
            **self.state,
            "tokens": (stats or {}).get("tokens"),
            "contextUsage": context if isinstance(context, dict) else None,
        }

    def stop(self):
        """Закрывает процесс pi: приложению сессия больше не нужна."""
        proc = self.proc
        if proc is None:
            return
        self.proc = None
        try:
            proc.stdin.close()
        except (OSError, ValueError, AttributeError):
            pass
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        log("закрыл процесс pi сессии %s" % self.id)

    def alive(self):
        """Жив ли процесс."""
        return self.proc is not None and self.proc.poll() is None


class Pool:
    """Пул процессов pi: по одному на сессию, с остановкой по простою."""

    def __init__(self):
        self.lock = threading.Lock()
        self.sessions = {}
        self.reaper = threading.Thread(target=self._reap, daemon=True)
        self.reaper.start()

    def open(self, cwd, session_id=None):
        """Отдаёт сессию в папке [cwd], поднимая процесс, если его ещё нет.

        Занятая сессия не переоткрывается: два клиента в одной сессии — это два писателя в
        один JSONL-файл pi, и разговор бы разъехался. Проверка «занято» живёт в ручке prompt,
        здесь же важно не потерять уже поднятый процесс.
        """
        with self.lock:
            if session_id and session_id in self.sessions:
                session = self.sessions[session_id]
                if not session.alive():
                    session._start(session_id)
                session.touched = time.time()
                return session

            session = PiSession(cwd, session_id)
            if not session.id:
                session.stop()
                raise PiError("pi не сообщил идентификатор сессии")
            # если такой процесс уже был под другим ключом — закрываем дубль
            existing = self.sessions.get(session.id)
            if existing is not None and existing is not session:
                session.stop()
                existing.touched = time.time()
                return existing
            self.sessions[session.id] = session
            return session

    def find(self, session_id):
        """Находит живую сессию по id или бросает понятную ошибку."""
        with self.lock:
            session = self.sessions.get(session_id)
        if session is None:
            raise PiError("сессия не открыта: сначала откройте её в приложении")
        if not session.alive():
            session._start(session.id)
        return session

    def list(self):
        """Снимок пула для /health."""
        with self.lock:
            return [
                {"id": s.id, "cwd": s.cwd, "busy": s.busy, "idle": round(time.time() - s.touched)}
                for s in self.sessions.values()
            ]

    def take_all(self):
        """Забирает все сессии из пула и очищает его: нужен при остановке сервиса."""
        with self.lock:
            sessions = list(self.sessions.values())
            self.sessions.clear()
            return sessions

    def _reap(self):
        """Останавливает процессы, к которым давно не обращались.

        Без этого на маке копились бы процессы pi (каждый — с контекстом модели в памяти),
        а память здесь дороже пары секунд на запуск.
        """
        while True:
            time.sleep(60)
            now = time.time()
            with self.lock:
                stale = [
                    s for s in self.sessions.values()
                    if not s.busy and now - s.touched > IDLE_STOP_SECONDS
                ]
                for session in stale:
                    self.sessions.pop(session.id, None)
            for session in stale:
                session.stop()


POOL = Pool()


class Handler(BaseHTTPRequestHandler):
    """Разбор ручек, авторизация и ответы. Логика — в пуле и сессиях."""

    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        """Логи запросов пишем своим форматом: умалчивать о них нельзя, шуметь — тоже."""
        log("%s %s" % (self.address_string(), fmt % args))

    # --- служебное ---

    def _authorized(self):
        """Проверяет токен моста.

        Токен обязателен даже за Cloudflare Access: Access закрывает вход, но он один, а
        токен даёт вторую границу и отдельный отзыв (потерянный телефон отключается сменой
        токена, не трогая туннель).
        """
        expected = str(CONFIG.get("token") or "")
        if not expected:
            return True
        header = self.headers.get("Authorization") or ""
        provided = header[len("Bearer "):].strip() if header.startswith("Bearer ") else ""
        return hmac.compare_digest(provided, expected)

    def _json(self, status, payload):
        """Отправляет JSON-ответ с честным кодом."""
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        """Читает тело запроса как JSON-объект (пустое тело — пустой объект)."""
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise PiError("тело запроса — не JSON")
        return data if isinstance(data, dict) else {}

    def _route(self):
        """Путь запроса без хвостового слэша и разобранные параметры строки."""
        parsed = urllib.parse.urlparse(self.path)
        return parsed.path.rstrip("/") or "/", urllib.parse.parse_qs(parsed.query)

    def _guard(self, fn):
        """Общая обёртка ручек: авторизация, разбор ошибок, логирование сбоев."""
        if not self._authorized():
            self._json(401, {"error": "неверный токен моста"})
            return
        try:
            fn()
        except PiError as e:
            self._json(400, {"error": str(e)})
        except BrokenPipeError:
            pass  # приложение ушло с экрана — это нормальный конец потока
        except Exception as e:  # noqa: BLE001 — сервис не должен падать от одной ручки
            log("ошибка в ручке %s: %r" % (self.path, e))
            self._json(500, {"error": "внутренняя ошибка моста: %s" % e})

    # --- ручки ---

    def do_GET(self):  # noqa: N802 — имя диктует BaseHTTPRequestHandler
        """Читающие ручки: состояние, проекты, сессии, переписка."""
        path, params = self._route()

        def run():
            if path == "/health":
                self._json(200, self._health())
            elif path == "/projects":
                self._json(200, {"projects": list_projects()})
            elif path == "/sessions":
                self._list_sessions(params)
            elif path.startswith("/sessions/"):
                parts = path.split("/")
                session = POOL.find(parts[2])
                if len(parts) == 4 and parts[3] == "messages":
                    self._json(200, {"session": self._session_brief(session),
                                     "items": session.messages()})
                elif len(parts) == 3:
                    session.refresh_state()
                    self._json(200, {"session": self._session_brief(session)})
                else:
                    self._json(404, {"error": "неизвестная ручка: %s" % path})
            else:
                self._json(404, {"error": "неизвестная ручка: %s" % path})

        self._guard(run)

    def do_POST(self):  # noqa: N802
        """Пишущие ручки: открыть сессию, спросить, остановить, сжать, сменить модель."""
        path, _ = self._route()

        def run():
            body = self._body()
            if path == "/sessions":
                self._open_session(body)
                return
            parts = path.split("/")
            if len(parts) >= 4 and parts[1] == "sessions":
                session = POOL.find(parts[2])
                action = parts[3]
                if action == "prompt":
                    self._prompt(session, body)
                elif action == "abort":
                    session.command("abort")
                    self._json(200, {"ok": True})
                elif action == "compact":
                    instructions = body.get("instructions")
                    data = session.command(
                        "compact",
                        timeout=900.0,  # сжатие — это отдельный вызов модели, он не быстрый
                        **({"customInstructions": instructions} if isinstance(instructions, str) and instructions else {}),
                    )
                    self._json(200, {"summary": data.get("summary") or ""})
                elif action == "model":
                    provider = str(body.get("provider") or "").strip()
                    model = str(body.get("modelId") or "").strip()
                    if not provider or not model:
                        raise PiError("нужны provider и modelId")
                    session.command("set_model", provider=provider, modelId=model)
                    self._json(200, {"session": session.refresh_state()})
                elif action == "ui":
                    self._json(200, self._manual_ui(session, body))
                else:
                    self._json(404, {"error": "неизвестная ручка: %s" % path})
                return
            self._json(404, {"error": "неизвестная ручка: %s" % path})

        self._guard(run)

    def do_DELETE(self):  # noqa: N802
        """Закрывает сессию: процесс pi гасится, файл истории остаётся на диске."""
        path, _ = self._route()

        def run():
            parts = path.split("/")
            if len(parts) == 3 and parts[1] == "sessions":
                session = POOL.find(parts[2])
                with POOL.lock:
                    POOL.sessions.pop(session.id, None)
                session.stop()
                self._json(200, {"ok": True})
            else:
                self._json(404, {"error": "неизвестная ручка: %s" % path})

        self._guard(run)

    # --- что делают ручки ---

    def _health(self):
        """Сводка для приложения: работает ли мост, виден ли pi, что в пуле."""
        version = ""
        try:
            out = subprocess.run(
                [str(CONFIG.get("pi") or "pi"), "--version"],
                capture_output=True, text=True, timeout=10,
            )
            version = (out.stdout or out.stderr or "").strip().splitlines()[0] if (out.stdout or out.stderr or "").strip() else ""
        except (OSError, subprocess.SubprocessError) as e:
            log("pi --version не ответил: %s" % e)
        provider, model = default_model()
        return {
            "ok": True,
            "pi": version,
            "provider": provider,
            "model": model,
            "roots": CONFIG.get("roots") or [],
            "sessions": POOL.list(),
        }

    def _list_sessions(self, params):
        """Сессии проекта из файлов pi: работает и когда процесс pi не поднят."""
        raw = (params.get("path") or [""])[0]
        path = allowed_path(raw) if raw else None
        if path is None:
            raise PiError("папка вне разрешённых корней: %s" % raw)
        meta = [read_session_meta(f) for f in session_files(path)]
        self._json(200, {"path": str(path), "sessions": meta})

    def _open_session(self, body):
        """Открывает сессию в выбранной папке (или продолжает существующую по id)."""
        raw = str(body.get("path") or "").strip()
        path = allowed_path(raw) if raw else None
        if path is None:
            raise PiError("папка вне разрешённых корней: %s" % raw)
        session_id = str(body.get("sessionId") or "").strip() or None
        session = POOL.open(path, session_id)
        self._json(200, {"session": self._session_brief(session)})

    def _session_brief(self, session):
        """Короткое описание сессии для списков и заголовка экрана.

        Расход контекста берётся из того же снимка состояния: приложению он нужен, чтобы
        показать, сколько окна модели уже занято, — и это единственное место, откуда он
        приходит (у pi он живёт в `get_session_stats`).
        """
        state = session.state if isinstance(session.state, dict) else {}
        model = state.get("model") if isinstance(state.get("model"), dict) else {}
        context = state.get("contextUsage") if isinstance(state.get("contextUsage"), dict) else {}
        return {
            "id": session.id,
            "path": session.cwd,
            "name": str(state.get("sessionName") or ""),
            "model": str(model.get("id") or ""),
            "provider": str(model.get("provider") or ""),
            "thinkingLevel": str(state.get("thinkingLevel") or ""),
            "busy": session.busy,
            "messages": int(state.get("messageCount") or 0),
            "contextTokens": context.get("tokens"),
            "contextWindow": context.get("contextWindow") or model.get("contextWindow"),
        }

    def _settled_brief(self, session):
        """Описание сессии после прогона: с обновлённым расходом контекста.

        Отдельно от [_session_brief], потому что снимок состояния в самой сессии
        обновляется только по запросу: без перезапроса в ответе ушли бы числа с момента
        открытия, то есть «0 сообщений» после полноценного разговора.
        """
        try:
            session.state = session.refresh_state()
        except PiError as e:
            log("не смог обновить состояние сессии %s: %s" % (session.id, e))
        return self._session_brief(session)

    def _manual_ui(self, session, body):
        """Ответ человека на диалог расширения (нужен, только если политику поменяют)."""
        request_id = str(body.get("requestId") or "").strip()
        if not request_id:
            raise PiError("нужен requestId")
        response = {"type": "extension_ui_response", "id": request_id}
        if "confirmed" in body:
            response["confirmed"] = bool(body["confirmed"])
        elif "value" in body:
            response["value"] = body["value"]
        else:
            response["cancelled"] = True
        session._write(response)
        return {"ok": True}

    def _prompt(self, session, body):
        """Отправляет сообщение агенту и стримит события ответа в SSE.

        Занятость проверяется до подписки: два одновременных потока в одну сессию — это
        либо две ветки ответа в одном контексте, либо каша. Приложение на «занято» покажет
        отказ, а не подвесит второй запрос.
        """
        text = str(body.get("text") or "").strip()
        if not text:
            raise PiError("пустое сообщение")
        if len(text) > MAX_MESSAGE_CHARS:
            raise PiError("сообщение длиннее %d символов" % MAX_MESSAGE_CHARS)
        if session.busy:
            self._json(409, {"error": "сессия занята: дождитесь конца ответа или нажмите «Стоп»"})
            return

        events = queue.Queue()
        session.subscribers.append(events)
        session.busy = True
        session.touched = time.time()

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache, no-transform")
        # без этого промежуточный прокси (в том числе Cloudflare) копит поток и отдаёт его целиком
        self.send_header("X-Accel-Buffering", "no")
        # длина потока заранее неизвестна, поэтому тело заканчивается закрытием соединения
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        aborted = False
        try:
            # подписка стоит ДО отправки prompt: события первого шага иначе можно потерять
            try:
                session.command("prompt", message=text)
            except PiError as e:
                # Заголовки потока уже отправлены, поэтому ответить кодом нельзя — отказ
                # уходит событием. Так приходит, например, отказ pi принять второй вопрос в
                # занятую сессию, если её занял кто-то помимо моста.
                self._event({"type": "error", "message": str(e)})
                return
            self._event({"type": "accepted"})
            while True:
                try:
                    event = events.get(timeout=1.0)
                except queue.Empty:
                    # пустой такт — проверка, жив ли ещё клиент и не оборвался ли процесс
                    if not session.alive():
                        self._event({"type": "error", "message": "процесс pi завершился"})
                        break
                    continue
                kind = event.get("type")
                if kind == "message_update":
                    self._message_update(event)
                elif kind == "tool_execution_start":
                    self._event({
                        "type": "tool_start",
                        "id": str(event.get("toolCallId") or ""),
                        "name": str(event.get("toolName") or ""),
                        "args": event.get("args") if isinstance(event.get("args"), dict) else {},
                    })
                elif kind == "tool_execution_update":
                    self._event({
                        "type": "tool_update",
                        "id": str(event.get("toolCallId") or ""),
                        "text": self._partial_text(event),
                    })
                elif kind == "tool_execution_end":
                    result = event.get("result") if isinstance(event.get("result"), dict) else {}
                    self._event({
                        "type": "tool_end",
                        "id": str(event.get("toolCallId") or ""),
                        "name": str(event.get("toolName") or ""),
                        "text": content_text(result.get("content")),
                        "isError": bool(event.get("isError")),
                    })
                elif kind == "compaction_start":
                    self._event({"type": "status", "step": "сжимаю контекст"})
                elif kind == "compaction_end":
                    self._event({"type": "compacted"})
                elif kind == "agent_settled":
                    # полностью устоявшийся прогон: ни ретраев, ни очереди продолжений.
                    # Занятость снимаем ДО события: иначе в нём ушло бы `busy: true`, и
                    # приложение решило бы, что сессия всё ещё работает.
                    session.busy = False
                    session.touched = time.time()
                    self._event({"type": "done", "session": self._settled_brief(session)})
                    break
                elif kind == "fatal":
                    self._event({"type": "error", "message": str(event.get("message") or "сбой pi")})
                    break
                elif kind in ("auto_retry_start", "auto_retry_end", "extension_error", "queue_update"):
                    self._event({**event, "type": kind})
        except (BrokenPipeError, ConnectionResetError):
            # клиент ушёл (уход с экрана, кнопка «Стоп», потеря сети): гасим и работу агента,
            # иначе мак продолжит считать ответ, которого никто не ждёт
            aborted = True
        finally:
            if aborted and session.alive():
                try:
                    session.command("abort", timeout=30.0)
                except PiError as e:
                    log("не смог прервать сессию %s: %s" % (session.id, e))
            session.busy = False
            session.touched = time.time()
            if events in session.subscribers:
                session.subscribers.remove(events)
            try:
                self._event({"type": "closed"})
            except (BrokenPipeError, ConnectionResetError, ValueError):
                pass

    def _partial_text(self, event):
        """Вытаскивает накопленный текст из события прогресса инструмента."""
        partial = event.get("partialResult")
        if isinstance(partial, dict):
            return content_text(partial.get("content"))
        return ""

    def _message_update(self, event):
        """Превращает дельту сообщения pi в события экрана: текст, размышления, вызов."""
        delta = event.get("assistantMessageEvent")
        if not isinstance(delta, dict):
            return
        kind = delta.get("type")
        if kind == "text_delta":
            self._event({"type": "delta", "text": str(delta.get("delta") or "")})
        elif kind == "thinking_delta":
            self._event({"type": "reasoning", "text": str(delta.get("delta") or "")})
        elif kind == "toolcall_start":
            self._event({
                "type": "tool_call",
                "id": str(delta.get("id") or ""),
                "name": str(delta.get("toolName") or ""),
            })
        usage = event.get("usage")
        if isinstance(usage, dict):
            self._event({
                "type": "usage",
                "input": usage.get("input"),
                "output": usage.get("output"),
                "totalTokens": usage.get("totalTokens"),
            })

    def _event(self, payload):
        """Пишет одно событие в поток SSE."""
        self.wfile.write(("data: %s\n\n" % json.dumps(payload, ensure_ascii=False)).encode("utf-8"))
        self.wfile.flush()


def main():
    """Поднимает сервис: один поток на запрос, потому что сессий бывает больше одной."""
    host = str(CONFIG.get("host") or HOST)
    port = int(CONFIG.get("port") or PORT)
    server = ThreadingHTTPServer((host, port), Handler)
    log("мост pi слушает %s:%d, корни: %s" % (host, port, ", ".join(CONFIG.get("roots") or [])))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        # остановка сервиса гасит и процессы pi: иначе они остались бы висеть сиротами,
        # а launchd, перезапустив мост, поднял бы рядом вторые такие же
        for session in POOL.take_all():
            session.stop()
        server.server_close()


if __name__ == "__main__":
    main()
