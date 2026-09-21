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

Ручки (все отдаёт наружу сервер приложения, `src/projects` с префиксом `/projects/*`):
  GET    /health                      — жив ли сервис, есть ли pi, что с процессами;
  GET    /projects                    — проекты из allowlist-корней (папки с .git);
  GET    /sessions?path=<папка>       — сессии проекта (файлы pi), свежие сверху;
  GET    /models                      — модели, доступные pi (локальные и по API);
  GET    /providers                   — провайдеры и признак «ключ задан» (самих ключей нет);
  POST   /providers                   — создать или изменить своего провайдера (models.json);
  POST   /providers/probe             — проверить адрес и ключ, получить список моделей;
  POST   /providers/key               — задать или убрать ключ встроенного провайдера (auth.json);
  DELETE /providers/<key>             — удалить своего провайдера;
  POST   /sessions                    — открыть сессию: поднять процесс pi в этой папке;
  GET    /sessions/<id>               — состояние сессии (модель, контекст, занятость);
  GET    /sessions/<id>/messages      — переписка в нормализованном виде;
  POST   /sessions/<id>/prompt        — отправить сообщение, ответ потоком SSE;
  POST   /sessions/<id>/abort         — остановить генерацию;
  POST   /sessions/<id>/compact       — сжать контекст;
  POST   /sessions/<id>/model         — сменить модель;
  POST   /sessions/<id>/close         — закрыть процесс (файл сессии остаётся);
  POST   /sessions/<id>/ui            — ответ на диалог расширения (по умолчанию не нужен);
  DELETE /sessions/<id>               — удалить сессию: процесс гасится, файл стирается.

Кто сюда ходит: только сервер приложения, и только через reverse-SSH туннель мака — порт
18820 слушает loopback на обоих концах (см. jevel.ai/agents/run-dsh-tunnel.sh), ровно как
порт поиска 18814 у раздела «Чат». Поэтому авторизации здесь нет: снаружи порт не виден
никому, а доступ к разделу закрыт сессией приложения. Поле `token` в настройках существует
на случай, если мост когда-нибудь выставят наружу, и по умолчанию пустое.

Настройки лежат в `~/.pi-bridge.json` и создаются при первом запуске: порт, allowlist
корней, модель, токен.

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
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# Порт по умолчанию. Наружу его не открывает ничто: порт слушает loopback, а на VPS его
# видит только сервер приложения — через reverse-SSH туннель мака (18820, см. README рядом).
PORT = int(os.environ.get("PI_BRIDGE_PORT", "18820"))
HOST = os.environ.get("PI_BRIDGE_HOST", "127.0.0.1")

# Файл настроек: рядом с сессиями pi, но отдельно от них — это настройки моста, а не харнесса.
CONFIG_PATH = Path(os.environ.get("PI_BRIDGE_CONFIG", str(Path.home() / ".pi-bridge.json")))

# Где pi держит сессии: одна папка на рабочую директорию, внутри — JSONL-файлы.
PI_SESSIONS = Path.home() / ".pi" / "agent" / "sessions"
# Каталог моделей pi: из него берём провайдера и модель по умолчанию, чтобы не хардкодить.
PI_MODELS = Path.home() / ".pi" / "agent" / "models.json"
# Файл ключей pi для встроенных провайдеров (anthropic, openai, deepseek, …). Формат задан pi:
# `{"<провайдер>": {"type": "api_key", "key": "…"}}`, права 600 — файл создаёт и читает сам pi,
# поэтому при правке мы сохраняем и структуру, и права.
PI_AUTH = Path.home() / ".pi" / "agent" / "auth.json"

# Встроенные провайдеры pi, для которых приложению разрешено класть ключ в auth.json. Список
# нужен только для подсказки в интерфейсе: pi знает их сам и подхватит ключ из файла, поэтому
# значение здесь — просто идентификатор и человеческое название.
BUILTIN_PROVIDERS = [
    {"key": "anthropic", "name": "Anthropic (Claude)"},
    {"key": "openai", "name": "OpenAI"},
    {"key": "google", "name": "Google (Gemini)"},
    {"key": "deepseek", "name": "DeepSeek"},
    {"key": "xai", "name": "xAI (Grok)"},
    {"key": "mistral", "name": "Mistral"},
    {"key": "groq", "name": "Groq"},
    {"key": "openrouter", "name": "OpenRouter"},
    {"key": "cerebras", "name": "Cerebras"},
    {"key": "together", "name": "Together AI"},
    {"key": "nvidia", "name": "NVIDIA NIM"},
    {"key": "xiaomi", "name": "Xiaomi (MiMo)"},
]

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

# Кэш списка моделей: pi отвечает таблицей, а вызывается она при каждом открытии выбора
# модели. Минута — потому что список меняется только правкой настроек pi.
_models_cache = None
models_lock = threading.Lock()


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
    """Приводит переписку pi к списку элементов для экрана.

    У pi история — дерево записей: ответ агента, результат инструмента и следующий ответ лежат
    отдельными сообщениями. Экрану нужно другое — «вопрос и всё, что агент по нему сделал»,
    поэтому:

    * несколько ответов подряд (модель ответила, получила результаты инструментов, ответила
      снова) склеиваются в один элемент: в приложении это один ответ на один вопрос, и живой
      поток выглядит так же — значит открытая заново сессия обязана выглядеть одинаково;
    * внутри ответа блоки идут в том порядке, в каком их выдала модель: текст, вызов
      инструмента, снова текст. Без этого новый текст после команды оказывался бы над её
      карточкой, и разговор читался бы не в том порядке, в каком он шёл;
    * результат инструмента не становится отдельной строкой, а подклеивается к своему вызову
      по `toolCallId` — вызов и его вывод показываются одной карточкой. Ссылки на карточки в
      `blocks` идут по идентификатору, поэтому вывод не дублируется в ответе.

    Поля `text`, `reasoning` и `tools` остаются рядом с `blocks` для совместимости: сборка
    приложения, которая ещё не знает про блоки, покажет ответ как раньше — текстом и списком
    карточек под ним.
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
            blocks = []
            calls = []
            content = message.get("content")
            if isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    kind = block.get("type")
                    if kind == "text":
                        text = str(block.get("text") or "")
                        if text:
                            blocks.append({"type": "text", "text": text})
                    elif kind == "thinking":
                        thinking = str(block.get("thinking") or "")
                        if thinking:
                            blocks.append({"type": "reasoning", "text": thinking})
                    elif kind == "toolCall":
                        call = {
                            "id": str(block.get("id") or ""),
                            "name": str(block.get("name") or ""),
                            "args": block.get("arguments") if isinstance(block.get("arguments"), dict) else {},
                            "output": "",
                            "isError": False,
                        }
                        calls.append(call)
                        by_call[call["id"]] = call
                        blocks.append({"type": "tool", "id": call["id"]})
            elif isinstance(content, str) and content.strip():
                blocks.append({"type": "text", "text": content})

            # Пустой ответ без вызовов — это сообщение с одним лишь текстом ошибки провайдера;
            # показываем его, иначе прогон выглядел бы как «агент молча ничего не сделал».
            error = message.get("errorMessage")
            if not blocks and not error:
                continue
            if items and items[-1].get("kind") == "assistant":
                # продолжаем тот же ответ: модель ответила ещё раз в рамках одного вопроса
                items[-1]["blocks"].extend(blocks)
                items[-1]["tools"].extend(calls)
                if error:
                    items[-1]["error"] = str(error)
            else:
                items.append({
                    "kind": "assistant",
                    "blocks": blocks,
                    "tools": calls,
                    "text": "",
                    "reasoning": "",
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

    for item in items:
        if item.get("kind") != "assistant":
            continue
        # Сводные строки собираем из блоков в том же порядке: старые сборки приложения читают
        # именно их, и по ним же экран решает, пустой ли это ответ.
        item["text"] = "".join(b["text"] for b in item["blocks"] if b["type"] == "text")
        item["reasoning"] = "".join(b["text"] for b in item["blocks"] if b["type"] == "reasoning")
    return items


# Харнессы, которые умеет мост. Имя идёт в идентификатор сессии: `pi--<id>`, `claude--<id>`.
# Так два хранилища истории (у pi и у Claude Code они свои) не путаются, а приложение видит
# идентификатор как одну непрозрачную строку и не думает о том, чей это разговор.
HARNESS_PI = "pi"
HARNESS_CLAUDE = "claude"
HARNESS_NAMES = {HARNESS_PI: "pi", HARNESS_CLAUDE: "Claude Code"}

# Модели Claude Code задаются псевдонимами: так их понимает и он сам, и они не устаревают с
# выходом новых версий. Окно контекста у них одно и то же (длинные варианты — отдельные модели).
CLAUDE_MODELS = [
    {"id": "default", "name": "Как настроено в Claude Code", "contextWindow": 200_000},
    {"id": "opus", "name": "Opus — самый сильный", "contextWindow": 200_000},
    {"id": "sonnet", "name": "Sonnet — баланс", "contextWindow": 200_000},
    {"id": "haiku", "name": "Haiku — самый быстрый", "contextWindow": 200_000},
]


def session_key(harness, session_id):
    """Идентификатор сессии наружу: `харнесс--id` (или просто id, если харнесс не задан).

    Разделитель — двойной дефис, а не слэш: идентификатор ходит в пути ручек, и со слэшем
    пришлось бы разбирать URL-кодирование на обеих сторонах.
    """
    if not session_id:
        return ""
    if not harness:
        return str(session_id)
    return "%s--%s" % (harness, session_id)


def split_key(key):
    """Разбирает идентификатор сессии на харнесс и его собственный id.

    Идентификатор без имени харнесса считается сессией pi: так продолжает работать сборка
    приложения, которая про второй харнесс ещё не знает.
    """
    text = str(key or "")
    for harness in (HARNESS_PI, HARNESS_CLAUDE):
        prefix = harness + "--"
        if text.startswith(prefix):
            return harness, text[len(prefix):]
    return HARNESS_PI, text


def claude_profile():
    """Профиль Claude Code, из которого он залогинен на этом маке.

    У Claude Code профилей может быть несколько, и различаются они переменной
    `CLAUDE_CONFIG_DIR`: в одном человек работает, другой остаётся пустым — и тогда он отвечает
    «Not logged in», хотя в терминале всё работает. Мост запускает Claude Code от себя (в
    окружении launchd, где переменных оболочки нет), поэтому профиль задаётся настройкой моста
    `claude_config_dir`, а если она пуста — берётся из окружения самого моста.
    """
    value = str(CONFIG.get("claude_config_dir") or "").strip() or str(os.environ.get("CLAUDE_CONFIG_DIR") or "").strip()
    if value:
        return str(Path(value).expanduser())
    return ""


def claude_projects_dir():
    """Где Claude Code держит проекты: внутри профиля, из которого он залогинен.

    Профиль задаётся `CLAUDE_CONFIG_DIR` и заменяет собой `~/.claude` целиком, вместе с
    каталогом `projects`. Искать сессии в `~/.claude` при другом профиле бессмысленно: там их
    просто нет, и список разговоров выглядел бы пустым при живых файлах на диске.
    """
    return Path(claude_profile() or (Path.home() / ".claude")) / "projects"


def claude_sessions_dir(cwd):
    """Папка сессий Claude Code для рабочей директории проекта.

    Схема имени задана им самим: путь с заменёнными на дефис разделителями. Повторяем её
    дословно — иначе список сессий проекта окажется пустым.
    """
    encoded = str(cwd).lstrip(os.sep).replace("/", "-").replace("\\", "-").replace(":", "-")
    return claude_projects_dir() / ("-" + encoded)


def find_session_file(harness, session_id):
    """Файл сессии по идентификатору, если он есть на диске; иначе `None`.

    Ищем по имени файла, а не по папке проекта: удалить или показать разговор нужно и тогда,
    когда сессия не открыта, а идентификатор в имени уникален. У pi файл называется
    `<время>_<id>.jsonl`, у Claude Code — просто `<id>.jsonl`.
    """
    if not session_id:
        return None
    if harness == HARNESS_CLAUDE:
        found = sorted(claude_projects_dir().glob("*/%s.jsonl" % session_id))
    else:
        found = sorted(PI_SESSIONS.glob("*/**%s.jsonl" % session_id))
    return found[0] if found else None


def claude_result_text(content):
    """Текст результата инструмента Claude Code: он бывает строкой и списком блоков."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(str(block.get("text") or ""))
        elif isinstance(block, str):
            parts.append(block)
    return "".join(parts)


def claude_context_window(model):
    """Окно контекста модели Claude Code по псевдониму; неизвестная — стандартные 200k."""
    for entry in CLAUDE_MODELS:
        if entry["id"] == model:
            return entry["contextWindow"]
    return 200_000


def claude_model_label(model):
    """Человеческое название модели Claude Code по псевдониму."""
    for entry in CLAUDE_MODELS:
        if entry["id"] == model:
            return entry["name"]
    return model


def read_claude_meta(file):
    """Читает из файла сессии Claude Code то, что нужно строке списка.

    Файл читается целиком одним куском, но разбирается только начало: у Claude Code история
    измеряется десятками мегабайт, и разбор каждой строки в JSON на список из двадцати сессий
    занял бы секунды. Счётчики берутся подсчётом подстрок — этого достаточно для строки списка,
    а точную переписку разбирает `messages()` уже у открытой сессии.
    """
    meta = {
        "id": file.stem,
        "cwd": "",
        "startedAt": None,
        "name": "",
        "title": "",
        "messages": 0,
        "provider": HARNESS_CLAUDE,
        "model": "",
        "userMessages": 0,
        "assistantMessages": 0,
        "toolCalls": 0,
    }
    try:
        data = file.read_bytes()
    except OSError as e:
        log("не смог прочитать сессию %s: %s" % (file, e))
        return meta

    meta["userMessages"] = data.count(b'"type":"user"')
    meta["assistantMessages"] = data.count(b'"type":"assistant"')
    meta["toolCalls"] = data.count(b'"type":"tool_use"')
    meta["messages"] = meta["userMessages"] + meta["assistantMessages"]

    for line in data[:400_000].decode("utf-8", "replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict) or entry.get("isSidechain") is True:
            continue
        if not meta["startedAt"] and entry.get("timestamp"):
            meta["startedAt"] = entry["timestamp"]
        if not meta["cwd"] and entry.get("cwd"):
            meta["cwd"] = str(entry["cwd"])
        message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
        if entry.get("type") == "user" and not meta["title"]:
            content = message.get("content")
            text = content if isinstance(content, str) else content_text(content)
            text = str(text or "").strip().replace("\n", " ")
            if text and not text.startswith("<"):
                # служебные вставки самого Claude Code начинаются с разметки — их в заголовок не берём
                meta["title"] = text[:80]
        elif entry.get("type") == "assistant" and not meta["model"]:
            meta["model"] = str(message.get("model") or "")

    if not meta["name"]:
        meta["name"] = meta["title"]
    if not meta["startedAt"]:
        meta["startedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(file.stat().st_mtime))
    meta["updatedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(file.stat().st_mtime))
    return meta


def normalize_claude_messages(entries):
    """Переписка Claude Code в том же виде, что и у pi: элементы с блоками по порядку.

    У Claude Code история — плоский список записей: вопрос, ответ, результат инструмента
    отдельной записью. Приводим её к той же форме, что и у pi (элемент на вопрос, блоки по
    порядку, результат подклеен к своему вызову), иначе один и тот же разговор выглядел бы в
    приложении по-разному в зависимости от харнесса.
    """
    items = []
    by_call = {}
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("isSidechain") is True:
            continue
        kind = entry.get("type")
        message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
        content = message.get("content")

        if kind == "user":
            blocks = []
            calls = []
            text = ""
            if isinstance(content, str):
                text = content
            elif isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") == "text":
                        text += str(block.get("text") or "")
                    elif block.get("type") == "tool_result":
                        call = by_call.get(str(block.get("tool_use_id") or ""))
                        if call is not None:
                            call["output"] = claude_result_text(block.get("content"))
                            call["isError"] = bool(block.get("is_error"))
            if text.strip() and not text.lstrip().startswith("<"):
                items.append({"kind": "user", "text": text})
            continue

        if kind != "assistant":
            continue

        blocks = []
        calls = []
        if isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                block_type = block.get("type")
                if block_type == "text" and str(block.get("text") or "").strip():
                    blocks.append({"type": "text", "text": str(block["text"])})
                elif block_type == "thinking" and str(block.get("thinking") or "").strip():
                    blocks.append({"type": "reasoning", "text": str(block["thinking"])})
                elif block_type == "tool_use":
                    call = {
                        "id": str(block.get("id") or ""),
                        "name": str(block.get("name") or "").lower(),
                        "args": block.get("input") if isinstance(block.get("input"), dict) else {},
                        "output": "",
                        "isError": False,
                    }
                    calls.append(call)
                    by_call[call["id"]] = call
                    blocks.append({"type": "tool", "id": call["id"]})
        if not blocks:
            continue
        if items and items[-1].get("kind") == "assistant":
            items[-1]["blocks"].extend(blocks)
            items[-1]["tools"].extend(calls)
        else:
            items.append({
                "kind": "assistant",
                "blocks": blocks,
                "tools": calls,
                "text": "",
                "reasoning": "",
                "error": "",
            })

    for item in items:
        if item.get("kind") != "assistant":
            continue
        item["text"] = "".join(b["text"] for b in item["blocks"] if b["type"] == "text")
        item["reasoning"] = "".join(b["text"] for b in item["blocks"] if b["type"] == "reasoning")
    return items


def harness_status():
    """Что из харнессов стоит на этом маке: имя, версия и путь к бинарю.

    Приложение показывает этот список при создании сессии: предлагать Claude Code там, где его
    нет, значило бы обещать то, чего не будет.
    """
    result = []
    for harness, binary in ((HARNESS_PI, CONFIG.get("pi") or "pi"),
                            (HARNESS_CLAUDE, CONFIG.get("claude") or "claude")):
        path = shutil.which(str(binary)) or ""
        version = ""
        if path:
            try:
                out = subprocess.run([str(binary), "--version"], capture_output=True, text=True, timeout=15)
                version = (out.stdout or out.stderr or "").strip().splitlines()[0] if (out.stdout or out.stderr or "").strip() else ""
            except (OSError, subprocess.SubprocessError) as e:
                log("%s --version не ответил: %s" % (harness, e))
        result.append({
            "harness": harness,
            "name": HARNESS_NAMES.get(harness, harness),
            "available": bool(path),
            "version": version,
        })
    return result


def claude_session_files(path):
    """Файлы сессий Claude Code в папке проекта, свежие сверху."""
    folder = claude_sessions_dir(path)
    if not folder.is_dir():
        return []
    files = [p for p in folder.glob("*.jsonl") if p.is_file()]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return files


def session_files(path):
    """Файлы сессий pi в папке проекта, свежие сверху."""
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
        "provider": "",
        "model": "",
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
                elif kind == "model_change":
                    # модель, которой считался разговор: в списке сессий по ней видно, какая
                    # это была сессия — локальная или по API. Первая запись побеждает: она
                    # пишется при открытии, а дальше модель могла меняться по ходу.
                    if not meta["model"]:
                        meta["provider"] = str(entry.get("provider") or "")
                        meta["model"] = str(entry.get("modelId") or "")
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
    """Проекты: папки, в которых есть чем работать, — плюс найденные по историям агентов.

    «Проект» здесь — это рабочая папка агента, поэтому признаков три: свой `.git`, история pi
    или история Claude Code. Последний появился вместе со вторым харнессом, и без него из
    списка пропадали папки, где работали только им: например контейнер с репозиториями, у
    которого своего `.git` нет (`~/work/tangem` — 246 разговоров Claude Code и ни одного pi).

    Кроме обхода корней на заданную глубину список дополняется папками из самих историй: у каждой
    сессии записан её рабочий каталог, и по нему проект находится на любой глубине — там, где
    обход по `depth` до него не дошёл бы.
    """
    depth = int(CONFIG.get("depth") or 2)
    roots = [Path(str(r)).expanduser() for r in (CONFIG.get("roots") or [])]
    seen = set()
    projects = []

    def inside_roots(path):
        """Лежит ли папка внутри разрешённого корня (иначе её показывать нельзя)."""
        try:
            resolved = Path(path).expanduser().resolve()
        except (OSError, RuntimeError):
            return None
        for root in roots:
            try:
                base = root.resolve()
            except (OSError, RuntimeError):
                continue
            if resolved == base or base in resolved.parents:
                return resolved
        return None

    def add(path):
        """Добавляет папку в список, если она ещё не добавлена и существует.

        Сессии считаются обоих харнессов: по ним видно, что в папке действительно работали, а
        время последней берётся самое свежее — по нему список и сортируется.
        """
        resolved = inside_roots(path)
        if resolved is None or not resolved.is_dir() or str(resolved) in seen:
            return
        seen.add(str(resolved))
        files = session_files(resolved) + claude_session_files(resolved)
        last = None
        if files:
            newest = max(f.stat().st_mtime for f in files)
            last = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(newest))
        projects.append({
            "path": str(resolved),
            "name": resolved.name,
            "root": str(next((r for r in roots if str(resolved).startswith(str(r))), resolved.parent)),
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
                if (path / ".git").exists() or sessions_dir_for(path).is_dir() or claude_sessions_dir(path).is_dir():
                    add(path)

    # Папки из историй агентов: у сессии записан её рабочий каталог, поэтому проект находится
    # и на глубине больше `depth`, и там, где нет ни `.git`, ни обхода по шаблону.
    for folder, reader in (
        (PI_SESSIONS, read_session_meta),
        (claude_projects_dir(), read_claude_meta),
    ):
        if not folder.is_dir():
            continue
        try:
            directories = sorted(folder.iterdir())
        except OSError as e:
            log("не смог обойти истории %s: %s" % (folder, e))
            continue
        for directory in directories:
            if not directory.is_dir():
                continue
            try:
                files = sorted(directory.glob("*.jsonl"), key=lambda f: f.stat().st_mtime, reverse=True)
            except OSError:
                continue
            if not files:
                continue
            cwd = str(reader(files[0]).get("cwd") or "")
            if cwd:
                add(cwd)

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


def session_file(session):
    """Файл сессии живого процесса: путь из снимка состояния, иначе поиск по идентификатору.

    Искать приходится потому, что у только что открытой сессии файл может появиться позже
    первого вопроса, а удалять и показывать время старта нужно и до него. Харнесс берётся из
    самой сессии: у pi и Claude Code свои хранилища истории.
    """
    if session.file_cache:
        return session.file_cache
    state_file = session.state.get("sessionFile") if isinstance(session.state, dict) else None
    if isinstance(state_file, str) and state_file and Path(state_file).exists():
        session.file_cache = Path(state_file)
    elif session.id:
        found = find_session_file(session.harness, session.id)
        if found:
            session.file_cache = found
    if session.file_cache and session.start_meta is None:
        reader = read_claude_meta if session.harness == HARNESS_CLAUDE else read_session_meta
        session.start_meta = reader(session.file_cache)
    return session.file_cache


def session_mtime(file):
    """Время последнего изменения файла сессии в ISO — «когда в ней последний раз что-то было»."""
    if not file:
        return None
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(file.stat().st_mtime))
    except OSError:
        return None


def is_local_model(model):
    """Считает ли модель этот мак, а не удалённый сервер по API.

    Признак по адресу провайдера: у локальной модели это loopback (llama.cpp на 1234), у
    удалённой — внешний адрес. Нужен экрану, чтобы подписать сессию словами: «локальная» или
    «по API», и не путать, где именно считаются токены.
    """
    if not isinstance(model, dict):
        return False
    base = str(model.get("baseUrl") or "")
    provider = str(model.get("provider") or "")
    if not base:
        return provider == "local"
    try:
        host = urllib.parse.urlparse(base).hostname or ""
    except ValueError:
        return False
    return host in ("127.0.0.1", "localhost", "::1", "0.0.0.0")


def list_models(harness=HARNESS_PI):
    """Список моделей харнесса для выбора в приложении.

    У pi он собирается из его собственного каталога (см. ниже), у Claude Code — фиксированный:
    модели задаются псевдонимами (`opus`, `sonnet`, `haiku`), и придумывать им список из
    документации значило бы показывать то, чего в этой версии может уже не быть.
    """
    if harness == HARNESS_CLAUDE:
        return [
            {
                "provider": HARNESS_CLAUDE,
                "id": entry["id"],
                "name": entry["name"],
                "contextWindow": entry["contextWindow"],
                "maxTokens": None,
                "thinking": True,
                "baseUrl": "",
                "local": False,
                # ключи Claude Code — его собственные (подписка или ANTHROPIC_API_KEY на маке):
                # приложение их не знает и не показывает
                "hasKey": True,
            }
            for entry in CLAUDE_MODELS
        ]
    return list_pi_models()


def list_pi_models():
    """Список моделей, доступных pi на этом маке, для выбора в приложении.

    Источник — сам pi (`pi --list-models`): он знает и локальные провайдеры из `models.json`,
    и встроенный каталог с ключами из `auth.json` или переменных окружения. Разбирать его
    файлы вместо этого значило бы гадать, что pi считает доступным. Подписи и признак «есть
    ключ» добавляются из `models.json`, если провайдер там описан: у встроенных провайдеров
    ключ живёт не в этом файле.

    Кэш на минуту: список меняется только правкой настроек pi, а вызывается он при каждом
    открытии выбора модели.
    """
    global _models_cache
    with models_lock:
        if _models_cache and time.time() - _models_cache[0] < 60:
            return _models_cache[1]

    rows = []
    try:
        out = subprocess.run(
            [str(CONFIG.get("pi") or "pi"), "--list-models"],
            capture_output=True, text=True, timeout=30,
        )
        for line in (out.stdout or "").splitlines()[1:]:
            parts = re.split(r"\s{2,}", line.strip())
            if len(parts) < 2:
                continue
            rows.append({
                "provider": parts[0],
                "id": parts[1],
                "contextWindow": parse_size(parts[2]) if len(parts) > 2 else None,
                "maxTokens": parse_size(parts[3]) if len(parts) > 3 else None,
                "thinking": (parts[4].lower() in ("yes", "да")) if len(parts) > 4 else False,
            })
    except (OSError, subprocess.SubprocessError) as e:
        log("pi --list-models не ответил: %s" % e)

    described = describe_providers()
    models = []
    for row in rows:
        info = described.get(row["provider"], {})
        by_id = info.get("models", {}).get(row["id"], {})
        base = by_id.get("baseUrl") or info.get("baseUrl") or ""
        models.append({
            **row,
            "name": by_id.get("name") or row["id"],
            # точные значения из models.json важнее округлённых из таблицы pi («32.8K»)
            "contextWindow": by_id.get("contextWindow") or row["contextWindow"],
            "maxTokens": by_id.get("maxTokens") or row["maxTokens"],
            "baseUrl": base,
            "local": is_local_model({"baseUrl": base, "provider": row["provider"]}),
            # у встроенных провайдеров ключ лежит не в models.json, и pi их уже перечислил —
            # значит считаем, что он настроен; «нужен ключ» показываем только для своих
            # провайдеров без apiKey
            "hasKey": by_id.get("hasKey", info.get("hasKey", True)),
        })

    if not models:
        # pi не ответил — отдаём хотя бы то, что описано в models.json, чтобы выбор не пустовал
        for provider, info in described.items():
            for model_id, by_id in (info.get("models") or {}).items():
                models.append({
                    "provider": provider,
                    "id": model_id,
                    "name": by_id.get("name") or model_id,
                    "contextWindow": by_id.get("contextWindow"),
                    "maxTokens": by_id.get("maxTokens"),
                    "thinking": bool(by_id.get("reasoning")),
                    "baseUrl": by_id.get("baseUrl") or info.get("baseUrl") or "",
                    "local": is_local_model({"baseUrl": by_id.get("baseUrl") or info.get("baseUrl"), "provider": provider}),
                    "hasKey": by_id.get("hasKey", info.get("hasKey", True)),
                })

    with models_lock:
        _models_cache = (time.time(), models)
    return models


def describe_providers():
    """Провайдеры и модели из `~/.pi/agent/models.json` — с признаком «ключ задан», без ключей.

    Ключ наружу не отдаётся никогда: приложению нужно только знать, готов ли провайдер, чтобы
    не предлагать модель, которая всё равно не ответит.
    """
    try:
        data = json.loads(PI_MODELS.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    providers = data.get("providers") if isinstance(data, dict) else None
    if not isinstance(providers, dict):
        return {}
    result = {}
    for name, body in providers.items():
        if not isinstance(body, dict):
            continue
        models = {}
        for model in body.get("models") or []:
            if not isinstance(model, dict) or not model.get("id"):
                continue
            models[str(model["id"])] = {
                "name": model.get("name"),
                "baseUrl": model.get("baseUrl") or body.get("baseUrl"),
                "contextWindow": model.get("contextWindow"),
                "maxTokens": model.get("maxTokens"),
                "reasoning": bool(model.get("reasoning")),
                "hasKey": bool(str(body.get("apiKey") or "").strip()),
            }
        result[str(name)] = {
            "name": body.get("name"),
            "baseUrl": body.get("baseUrl"),
            "hasKey": bool(str(body.get("apiKey") or "").strip()),
            "models": models,
        }
    return result


def parse_size(raw):
    """Разбирает «32.8K» из таблицы pi в число токенов; непонятное значение — None."""
    text = str(raw or "").strip().upper()
    match = re.match(r"^([0-9.]+)\s*([KMG]?)$", text)
    if not match:
        return None
    value = float(match.group(1))
    for suffix, factor in (("K", 1_000), ("M", 1_000_000), ("G", 1_000_000_000)):
        if match.group(2) == suffix:
            value *= factor
    return int(value)


def purge_session(key):
    """Удаляет файл сессии с диска: разговор исчезает совсем, а не только из приложения.

    Харнесс берётся из идентификатора, потому что хранилищ два. Возвращаем число удалённых
    файлов — приложение по нему понимает, было ли что удалять.
    """
    harness, session_id = split_key(key)
    file = find_session_file(harness, session_id)
    if file is None:
        return 0
    try:
        file.unlink()
        log("удалил файл сессии %s (%s)" % (file, harness))
    except OSError as e:
        raise PiError("не смог удалить файл сессии %s: %s" % (file, e))
    return 1


def read_json_file(path):
    """Читает JSON-файл настроек pi; отсутствие файла и мусор — пустой объект.

    Настройки pi правятся и руками, и им самим, поэтому битый или недописанный файл не должен
    ронять мост: интерфейс покажет провайдеров без этого файла, а не откажет целиком.
    """
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def write_json_file(path, data, mode=0o600):
    """Пишет JSON атомарно, сохраняя копию прежнего файла и права доступа.

    Атомарно — потому что в этом файле лежат ключи: обрыв записи (или падение моста в этот
    момент) не должен оставить pi без настроек или с обрезанным ключом. Копия `.bak` нужна,
    чтобы правку из интерфейса можно было откатить руками; права 600 — чтобы ключи не стали
    читаемыми для других пользователей мака.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        try:
            backup = path.with_suffix(path.suffix + ".bak")
            backup.write_bytes(path.read_bytes())
            os.chmod(backup, mode)
        except OSError as e:
            log("не смог сохранить копию %s: %s" % (path, e))
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.chmod(tmp, mode)
    tmp.replace(path)


def provider_list():
    """Провайдеры для интерфейса: свои из models.json и встроенные с признаком «ключ задан».

    Ключ не отдаётся наружу ни целиком, ни хвостом: приложению достаточно знать, задан ли он и
    какой длины (по длине видно, вставился ли ключ полностью). Встроенные провайдеры идут
    отдельным списком — у них ключ лежит не в models.json, а в auth.json, и моделей в интерфейсе
    наперёд нет: они появляются у pi после того, как ключ задан.
    """
    models = read_json_file(PI_MODELS)
    providers = models.get("providers") if isinstance(models.get("providers"), dict) else {}
    auth = read_json_file(PI_AUTH)

    result = []
    for key, body in providers.items():
        if not isinstance(body, dict):
            continue
        api_key = str(body.get("apiKey") or "")
        base_url = str(body.get("baseUrl") or "")
        result.append({
            "key": str(key),
            "name": str(body.get("name") or key),
            "baseUrl": base_url,
            "api": str(body.get("api") or "openai-completions"),
            "custom": True,
            "hasKey": bool(api_key.strip()),
            "keyLength": len(api_key.strip()),
            "local": is_local_model({"baseUrl": base_url, "provider": str(key)}),
            "models": [
                {
                    "id": str(m.get("id")),
                    "name": str(m.get("name") or m.get("id")),
                    "contextWindow": m.get("contextWindow"),
                    "maxTokens": m.get("maxTokens"),
                    "thinking": bool(m.get("reasoning")),
                }
                for m in (body.get("models") or [])
                if isinstance(m, dict) and m.get("id")
            ],
        })

    for entry in BUILTIN_PROVIDERS:
        credential = auth.get(entry["key"])
        key_value = ""
        if isinstance(credential, dict):
            key_value = str(credential.get("key") or "")
        result.append({
            "key": entry["key"],
            "name": entry["name"],
            "baseUrl": "",
            "api": "",
            "custom": False,
            "hasKey": bool(key_value.strip()),
            "keyLength": len(key_value.strip()),
            "local": False,
            "models": [],
        })
    return result


def provider_probe(base_url, api_key):
    """Проверяет провайдера: спрашивает у него список моделей тем же ключом.

    Одна проверка отвечает сразу на два вопроса человека: «ключ рабочий?» и «какие модели мне
    доступны?» — поэтому интерфейс по этой ручке и подтягивает список моделей вместо того,
    чтобы просить вписать их руками. Обращаемся к стандартной ручке OpenAI-совместимых
    провайдеров `/models`; у кого её нет — покажем ошибку провайдера как есть.
    """
    base = str(base_url or "").strip().rstrip("/")
    if not base:
        raise PiError("нужен адрес провайдера")
    if not base.startswith("http://") and not base.startswith("https://"):
        raise PiError("адрес должен начинаться с http:// или https://")
    request = urllib.request.Request(base + "/models", headers={
        "Authorization": "Bearer %s" % api_key,
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.loads(response.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        raise PiError("провайдер ответил %s: %s" % (e.code, e.read()[:200].decode("utf-8", "replace")))
    except (urllib.error.URLError, ValueError, OSError) as e:
        raise PiError("провайдер недоступен: %s" % e)

    data = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(data, list):
        # некоторые провайдеры отвечают просто списком
        data = payload if isinstance(payload, list) else []
    models = []
    for item in data:
        if isinstance(item, dict) and item.get("id"):
            models.append({"id": str(item["id"]), "name": str(item.get("name") or item["id"])})
        elif isinstance(item, str):
            models.append({"id": item, "name": item})
    return models


def save_provider(body):
    """Создаёт или обновляет своего провайдера в models.json.

    Пустой `apiKey` при обновлении означает «оставить прежний ключ»: интерфейс не показывает
    сохранённый ключ, поэтому человек правит название и адрес, не вводя ключ заново. Пустой
    `apiKey` при создании — провайдер без ключа (бывает у локальных серверов).
    """
    key = str(body.get("key") or "").strip()
    if not key:
        raise PiError("нужен идентификатор провайдера (латиницей, без пробелов)")
    if not re.match(r"^[a-zA-Z0-9._-]+$", key):
        raise PiError("идентификатор провайдера: только латиница, цифры, точка, дефис и подчёркивание")
    base_url = str(body.get("baseUrl") or "").strip()
    if not base_url.startswith("http://") and not base_url.startswith("https://"):
        raise PiError("адрес провайдера должен начинаться с http:// или https://")

    models = read_json_file(PI_MODELS)
    providers = models.get("providers")
    if not isinstance(providers, dict):
        providers = {}
        models["providers"] = providers
    existing = providers.get(key) if isinstance(providers.get(key), dict) else {}

    api_key = str(body.get("apiKey") or "").strip()
    if not api_key:
        api_key = str(existing.get("apiKey") or "")

    new_models = []
    for item in body.get("models") or []:
        if not isinstance(item, dict) or not item.get("id"):
            continue
        entry = {
            "id": str(item["id"]),
            "name": str(item.get("name") or item["id"]),
            "reasoning": bool(item.get("thinking")),
            "input": ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
        }
        if item.get("contextWindow"):
            entry["contextWindow"] = int(item["contextWindow"])
        if item.get("maxTokens"):
            entry["maxTokens"] = int(item["maxTokens"])
        new_models.append(entry)
    if not new_models:
        raise PiError("нужна хотя бы одна модель: без неё pi не сможет выбрать, чем отвечать")

    providers[key] = {
        "name": str(body.get("name") or existing.get("name") or key),
        "baseUrl": base_url,
        "apiKey": api_key,
        "api": str(body.get("api") or existing.get("api") or "openai-completions"),
        "models": new_models,
    }
    write_json_file(PI_MODELS, models)
    invalidate_models_cache()
    log("сохранил провайдера %s (%s, моделей %d)" % (key, base_url, len(new_models)))
    return provider_list()


def delete_provider(key):
    """Удаляет своего провайдера из models.json.

    Не даём удалить провайдера, которым мост отвечает по умолчанию: на него смотрит вся работа
    на этом маке, когда модель не выбрана, и снести его одной кнопкой из телефона было бы
    неприятным сюрпризом. Проверяем именно текущий провайдер по умолчанию, а не «любой на
    loopback»: свой сервер на localhost — обычное дело, и запрет на него был бы непонятен.
    Встроенные провайдеры живут не здесь — у них убирается ключ (`/providers/key`), а не запись.
    """
    models = read_json_file(PI_MODELS)
    providers = models.get("providers") if isinstance(models.get("providers"), dict) else {}
    body = providers.get(key) if isinstance(providers.get(key), dict) else None
    if body is None:
        raise PiError("провайдер не найден: %s" % key)
    if key == (default_model()[0] or ""):
        raise PiError(
            "это провайдер по умолчанию: на нём работает мак, когда модель не выбрана — "
            "сначала назначьте другого провайдера в ~/.pi-bridge.json"
        )
    providers.pop(key)
    write_json_file(PI_MODELS, models)
    invalidate_models_cache()
    log("удалил провайдера %s" % key)
    return provider_list()


def save_provider_key(provider, api_key):
    """Кладёт или убирает ключ встроенного провайдера в auth.json.

    Пустой ключ означает «убрать»: так человек отключает провайдера, не трогая ни файлы pi, ни
    свои ключи на бумаге. Формат файла задан pi (`{"<провайдер>": {"type": "api_key", "key": …}}`),
    поэтому остальные записи сохраняются как есть.
    """
    name = str(provider or "").strip()
    if not name:
        raise PiError("нужен провайдер")
    auth = read_json_file(PI_AUTH)
    value = str(api_key or "").strip()
    if value:
        auth[name] = {"type": "api_key", "key": value}
        log("сохранил ключ провайдера %s (длина %d)" % (name, len(value)))
    else:
        auth.pop(name, None)
        log("убрал ключ провайдера %s" % name)
    write_json_file(PI_AUTH, auth)
    invalidate_models_cache()
    return provider_list()


def invalidate_models_cache():
    """Сбрасывает кэш списка моделей: после правки провайдеров он показывает устаревшее."""
    global _models_cache
    with models_lock:
        _models_cache = None


class PiError(Exception):
    """Ошибка работы с харнессом: текст пригоден и для лога, и для показа в приложении."""


class AgentSession:
    """Общая часть сессии любого харнесса: один процесс, одна папка проекта, один разговор.

    Харнессы (pi и Claude Code) говорят на разных протоколах, но всё остальное у них совпадает:
    пул процессов, подписчики потока, признак «занята», остановка по простою, отправка команды
    строкой JSON в stdin. Это и живёт здесь, а наследник добавляет своё: как запустить процесс,
    как отправить сообщение, как прервать работу, как прочитать переписку и снимок состояния.
    """

    #: Имя харнесса: уходит в идентификатор сессии (`pi--<id>`, `claude--<id>`), потому что
    #: хранилищ истории два и по имени видно, к какому относится разговор.
    harness = ""

    def __init__(self, cwd, model=None):
        """Заводит общие поля сессии; процесс поднимает наследник."""
        self.cwd = str(cwd)
        self.id = ""                # идентификатор сессии внутри харнесса
        self.model = model or ""    # выбранная модель (у pi — `провайдер/модель`)
        self.proc = None
        self.reader = None
        self.lock = threading.Lock()
        self.pending = {}           # id команды -> очередь ответа (у pi; у Claude не нужен)
        self.subscribers = []       # очереди SSE-потоков, слушающих эту сессию
        self.busy = False           # идёт генерация: второй запрос в ту же сессию не пускаем
        self.touched = time.time()  # время последнего обращения (для остановки по простою)
        self.state = {}             # снимок состояния в общем для обоих виде (см. _session_brief)
        self.start_meta = None      # заголовок файла сессии (время старта) — читается один раз
        self.file_cache = None      # путь к файлу сессии: ищем один раз по идентификатору
        self.stderr_tail = []       # хвост stderr процесса — попадает в текст ошибки
        self.counters = {"userMessages": 0, "assistantMessages": 0, "toolCalls": 0}
        self.partial_seen = False   # пришли ли частичные куски текущего ответа (у Claude)

    @property
    def key(self):
        """Идентификатор сессии наружу: с именем харнесса, потому что хранилищ два."""
        return session_key(self.harness, self.id)

    def subscribe(self):
        """Подписывает поток SSE на события сессии и отдаёт очередь этих событий.

        Подписка ставится ДО отправки сообщения: события первого шага иначе можно потерять.
        """
        events = queue.Queue()
        self.subscribers.append(events)
        return events

    def unsubscribe(self, events):
        """Снимает подписку: клиент ушёл или ответ закончился."""
        if events in self.subscribers:
            self.subscribers.remove(events)

    def _publish(self, event):
        """Рассылает событие всем открытым потокам SSE этой сессии."""
        for q in list(self.subscribers):
            q.put(event)

    def _write(self, payload):
        """Отправляет одну команду процессу; сбой записи означает смерть процесса."""
        self.touched = time.time()
        try:
            self.proc.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
            self.proc.stdin.flush()
        except (OSError, ValueError) as e:
            raise PiError("процесс %s не принимает команды: %s" % (self.harness, e))

    def stop(self):
        """Закрывает процесс: приложению сессия больше не нужна."""
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
        log("закрыл процесс %s сессии %s" % (self.harness, self.id))

    def _fail_waiters(self, reason):
        """Будит всех ожидающих после смерти процесса, чтобы запросы не висели вечно."""
        for key, q in list(self.pending.items()):
            q.put({"type": "response", "id": key, "success": False, "error": reason})
        self.pending.clear()
        for q in list(self.subscribers):
            q.put({"type": "fatal", "message": reason})

    def alive(self):
        """Жив ли процесс."""
        return self.proc is not None and self.proc.poll() is None

    def _restart(self):
        """Поднимает процесс заново, продолжая ту же сессию (он мог умереть или быть погашен).

        Продолжение идёт по идентификатору сессии: у pi это `--session-id`, у Claude Code —
        `--resume`, и оба берут историю из своего файла, так что разговор не теряется.
        """
        self._start(self.id)

    def prompt(self, text):
        """Отправляет сообщение агенту; реализует наследник (у каждого свой протокол)."""
        raise NotImplementedError

    def abort(self):
        """Прерывает работу агента; реализует наследник."""
        raise NotImplementedError

    def refresh_state(self):
        """Обновляет снимок состояния; реализует наследник."""
        raise NotImplementedError

    def messages(self):
        """Переписка в нормализованном виде; реализует наследник."""
        raise NotImplementedError


class PiSession(AgentSession):
    """Один процесс pi в режиме RPC, привязанный к рабочей папке проекта.

    Почему процесс на сессию, а не один на всех: `pi --mode rpc` — это одна сессия с
    одним cwd, и переключать папку в живом процессе нельзя. Пул держит процессы открытыми,
    чтобы продолжение разговора не ждало старта pi (несколько секунд) и не теряло прогрев
    промпта в llama.cpp.
    """

    harness = "pi"

    def __init__(self, cwd, session_id=None, provider=None, model=None):
        """Поднимает процесс pi в папке [cwd], при необходимости продолжая сессию [session_id].

        [provider] и [model] — выбор модели для этой сессии. Приложению он нужен, потому что
        моделей может быть несколько (локальная и удалённая по API), и выбор делается в момент
        открытия сессии; пустые значения означают «модель по умолчанию из настроек моста».
        """
        super().__init__(cwd, model=model)
        self.id = session_id or ""
        self.provider = provider or ""
        self._start(session_id)

    def _start(self, session_id):
        """Собирает команду запуска pi и заводит потоки чтения stdout и stderr."""
        provider, model = default_model()
        provider = self.provider or provider
        model = self.model or model
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

    def prompt(self, text):
        """Отправляет сообщение агенту: у pi это команда RPC, ответ на неё приходит сразу."""
        self.command("prompt", message=text)

    def abort(self):
        """Прерывает работу агента: pi подтверждает отмену и ждёт, пока сессия станет свободной."""
        self.command("abort")

    def set_model(self, provider, model):
        """Меняет модель у открытой сессии: разговор продолжается, меняется считающий."""
        self.command("set_model", provider=provider, modelId=model)

    def messages(self):
        """Переписка сессии в нормализованном виде."""
        data = self.command("get_messages")
        messages = data.get("messages")
        return normalize_messages(messages if isinstance(messages, list) else [])

    def refresh_state(self):
        """Обновляет снимок состояния: модель, контекст, расход, счётчики.

        Два запроса, а не один, потому что у pi они про разное: `get_state` — что за модель и
        сколько сообщений, `get_session_stats` — расход токенов и заполнение контекста. Экран
        показывает и то, и другое, а обновляется снимок только по запросу: сам pi чисел не
        пушит, и без этого в шапке сессии висели бы значения с момента открытия.
        """
        try:
            self.state = self.command("get_state")
            stats = self.command("get_session_stats")
        except PiError as e:
            log("не смог обновить состояние сессии %s: %s" % (self.id, e))
            return self.state
        stats = stats if isinstance(stats, dict) else {}
        context = stats.get("contextUsage")
        self.state = {
            **self.state,
            "tokens": stats.get("tokens") if isinstance(stats.get("tokens"), dict) else None,
            "contextUsage": context if isinstance(context, dict) else None,
            "cost": stats.get("cost"),
            "userMessages": stats.get("userMessages"),
            "assistantMessages": stats.get("assistantMessages"),
            "toolCalls": stats.get("toolCalls"),
            "totalMessages": stats.get("totalMessages"),
        }
        return self.state



class ClaudeSession(AgentSession):
    """Один процесс Claude Code в потоковом режиме, привязанный к рабочей папке проекта.

    Claude Code — второй харнесс в этом разделе, и говорит он не JSON-RPC, как pi, а потоком
    событий со своим набором полей (`system/init`, `assistant`, `user`, `result`). Протокол
    задаёт флагами: `--input-format stream-json` (сообщения строками JSON в stdin) и
    `--output-format stream-json` (события строками JSON в stdout). Один процесс живёт столько
    же, сколько разговор: продолжение не поднимает его заново и не теряет прогрев промпта.

    Разрешения: подтверждать в headless-режиме некому, поэтому сессия запускается с
    `--permission-mode bypassPermissions` — тем же «разрешать всё», что и у pi. Какой режим
    использовать, решает настройка моста (`claude_permission_mode`), но по умолчанию он такой
    же, иначе часть работы агент молча не смог бы выполнить.

    Учётные данные Claude Code — его собственные (подписка или ключ в `ANTHROPIC_API_KEY`) и
    живут на этом маке. Если он не залогинен, ответом придёт строка «Not logged in · Please run
    /login» — мост покажет её как обычный ответ, а не сломает раздел.
    """

    harness = "claude"

    def __init__(self, cwd, session_id=None, model=None):
        """Поднимает процесс Claude Code в папке [cwd], продолжая сессию [session_id].

        Идентификатор новой сессии задаём сами (`--session-id`): свой Claude Code сообщает
        только вместе с первым ответом, а он нужен сразу — иначе приложение не смогло бы ни
        запомнить разговор, ни показать его в списке сессий. Продолжение идёт через `--resume`
        с тем же идентификатором.
        """
        super().__init__(cwd, model=model)
        self.id = session_id or str(uuid.uuid4())
        self.last_usage = {}   # расход последнего хода: из него считается занятое окно
        self._start(session_id)

    def _start(self, session_id):
        """Собирает команду запуска Claude Code и заводит потоки чтения."""
        cmd = [
            str(CONFIG.get("claude") or "claude"),
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            # без частичных кусков текст приходит целиком в конце ответа: на экране это выглядело
            # бы как «молчит минуту, потом вывалил всё»
            "--include-partial-messages",
            "--verbose",
            "--permission-mode", str(CONFIG.get("claude_permission_mode") or "bypassPermissions"),
        ]
        if session_id:
            cmd += ["--resume", session_id]
        else:
            cmd += ["--session-id", self.id]
        model = self.model.split("/", 1)[1] if "/" in self.model else self.model
        if model and model != "default":
            cmd += ["--model", model]

        env = dict(os.environ)
        profile = claude_profile()
        if profile:
            # Профилей у Claude Code может быть несколько (`CLAUDE_CONFIG_DIR`), и залогинен
            # обычно один: без нужного профиля он отвечает «Not logged in», хотя в терминале
            # у человека всё работает. Берём профиль из настроек моста, а если там пусто — из
            # окружения самого моста.
            env["CLAUDE_CONFIG_DIR"] = profile

        log("запускаю claude в %s (профиль %s): %s" % (self.cwd, profile or "по умолчанию", " ".join(cmd)))
        try:
            self.proc = subprocess.Popen(
                cmd,
                cwd=self.cwd,
                env=env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,  # построчно: протокол Claude Code — тоже JSON-строки
            )
        except OSError as e:
            raise PiError("не удалось запустить claude (%s): %s" % (CONFIG.get("claude"), e))

        self.reader = threading.Thread(target=self._read_stdout, daemon=True)
        self.reader.start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

        # Служебные события Claude Code присылает не сразу, а вместе с первым ответом, поэтому
        # запуск проверяем коротким ожиданием: если процесс умер (не тот профиль, сломан
        # конфиг), об этом лучше сказать сразу, чем показывать пустую сессию.
        time.sleep(0.6)
        if not self.alive():
            detail = self.stderr_tail[-1] if self.stderr_tail else "без вывода"
            raise PiError("Claude Code не запустился: %s" % detail)

    def _read_stdout(self):
        """Читает поток событий Claude Code и раздаёт их подписчикам.

        Разбирать здесь нечего: перевод событий харнесса в события экрана делает
        `translate_claude_event`, потому что тому же переводу нужен доступ к снимку состояния
        сессии (расход токенов, модель, счётчики).
        """
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                log("не разобрал строку claude: %s" % line[:200])
                continue
            if not isinstance(event, dict):
                continue
            # Идентификатор сессии и модель — это состояние сессии, а не то, что показывается
            # на экране, поэтому забираем их себе, если харнесс прислал своё: при `--resume`
            # он может вернуть другой идентификатор, и продолжать разговор нужно уже по нему.
            session_id = str(event.get("session_id") or "")
            if session_id:
                self.id = session_id
                self.file_cache = None  # файл сессии мог смениться вместе с идентификатором
            model = str(event.get("model") or "")
            if model and (not self.model or self.model == "default"):
                self.model = model
            self._publish(event)

        # процесс закончился — будим всех, кто ждал событий
        self._fail_waiters("процесс claude завершился")

    def _read_stderr(self):
        """Держит хвост stderr: по нему понятно, почему процесс умер."""
        for line in self.proc.stderr:
            line = line.rstrip()
            if not line:
                continue
            self.stderr_tail.append(line)
            del self.stderr_tail[:-20]
            log("claude: %s" % line[:300])

    def prompt(self, text):
        """Отправляет сообщение в том виде, в каком его ждёт потоковый режим Claude Code."""
        self.counters["userMessages"] += 1
        self._write({
            "type": "user",
            "message": {"role": "user", "content": [{"type": "text", "text": text}]},
        })

    def abort(self):
        """Прерывает работу: у Claude Code для этого отдельный кадр управления."""
        self._write({"type": "control_request", "request": {"subtype": "interrupt"}})

    def set_model(self, provider, model):
        """Меняет модель: у Claude Code она задаётся при запуске, поэтому процесс перезапускается.

        Разговор при этом не теряется: новый процесс поднимается с `--resume` и продолжает ту же
        сессию из её файла. Другого способа у него нет — модель в живом процессе не меняется.
        """
        self.model = model
        self.stop()
        self._start(self.id)

    def refresh_state(self):
        """Собирает снимок состояния в том же виде, что у pi: экран общий для обоих.

        Часть чисел у Claude Code приходится считать самим: он не отдаёт «занято токенов в
        окне» одним полем, зато присылает расход последнего хода — из него занятое окно и
        получается (вход + прочитанное из кэша + записанное в кэш). Поэтому процент здесь
        оценка, и наружу это уходит флагом `contextEstimated`: приложение помечает такое число
        знаком «≈», а не выдаёт за точное, как у pi.
        """
        usage = self.last_usage if isinstance(self.last_usage, dict) else {}
        used = sum(int(usage.get(k) or 0) for k in (
            "input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens",
        ))
        model = self.model.split("/", 1)[1] if "/" in self.model else (self.model or CONFIG.get("claude_model") or "default")
        window = claude_context_window(model)
        tokens = self.state.get("tokens") if isinstance(self.state.get("tokens"), dict) else {}
        file = session_file(self)
        meta = self.start_meta or {}
        self.state = {
            **self.state,
            "model": {"id": model, "name": claude_model_label(model), "provider": "claude"},
            "thinkingLevel": "on",
            "messageCount": (self.counters["userMessages"] + self.counters["assistantMessages"]) or meta.get("messages") or 0,
            "tokens": tokens,
            "cost": self.state.get("cost") or 0,
            "userMessages": self.counters["userMessages"] or meta.get("userMessages") or 0,
            "assistantMessages": self.counters["assistantMessages"] or meta.get("assistantMessages") or 0,
            "toolCalls": self.counters["toolCalls"] or meta.get("toolCalls") or 0,
            "contextUsage": {
                "tokens": used,
                "contextWindow": window,
                "percent": round(used / window * 100, 1) if window else 0,
                "estimated": True,
            } if used else None,
            "sessionFile": str(file) if file else "",
        }
        return self.state

    def messages(self):
        """Переписка сессии из её файла: у Claude Code история лежит готовыми сообщениями."""
        file = session_file(self)
        if not file or not file.exists():
            return []
        entries = []
        with file.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if isinstance(entry, dict):
                    entries.append(entry)
        return normalize_claude_messages(entries)


def translate_pi_event(session, event):
    """Переводит событие pi в события экрана; второй элемент ответа — «прогон закончился».

    Перевод живёт здесь, а не в самой сессии, по одной причине: у обоих харнессов он разный, а
    ручка потока — одна. Так HTTP-слой не знает, с кем он говорит, и второй харнесс не требует
    второй ручки.
    """
    kind = event.get("type")
    out = []

    if kind == "message_update":
        delta = event.get("assistantMessageEvent")
        if isinstance(delta, dict):
            delta_kind = delta.get("type")
            if delta_kind == "text_delta" and delta.get("delta"):
                out.append({"type": "delta", "text": str(delta["delta"])})
            elif delta_kind == "thinking_delta" and delta.get("delta"):
                out.append({"type": "reasoning", "text": str(delta["delta"])})
            elif delta_kind == "toolcall_start":
                out.append({
                    "type": "tool_call",
                    "id": str(delta.get("id") or ""),
                    "name": str(delta.get("toolName") or ""),
                })
        usage = event.get("usage")
        if isinstance(usage, dict) and (usage.get("totalTokens") or usage.get("input")):
            out.append({
                "type": "usage",
                "input": usage.get("input"),
                "output": usage.get("output"),
                "totalTokens": usage.get("totalTokens"),
            })
        return out, False

    if kind == "tool_execution_start":
        out.append({
            "type": "tool_start",
            "id": str(event.get("toolCallId") or ""),
            "name": str(event.get("toolName") or ""),
            "args": event.get("args") if isinstance(event.get("args"), dict) else {},
        })
        return out, False

    if kind == "tool_execution_update":
        partial = event.get("partialResult")
        text = content_text(partial.get("content")) if isinstance(partial, dict) else ""
        out.append({"type": "tool_update", "id": str(event.get("toolCallId") or ""), "text": text})
        return out, False

    if kind == "tool_execution_end":
        result = event.get("result") if isinstance(event.get("result"), dict) else {}
        out.append({
            "type": "tool_end",
            "id": str(event.get("toolCallId") or ""),
            "name": str(event.get("toolName") or ""),
            "text": content_text(result.get("content")),
            "isError": bool(event.get("isError")),
        })
        return out, False

    if kind == "compaction_start":
        return [{"type": "status", "step": "сжимаю контекст"}], False

    if kind == "compaction_end":
        return [{"type": "compacted"}], False

    if kind == "agent_settled":
        # полностью устоявшийся прогон: ни ретраев, ни очереди продолжений
        session.busy = False
        session.touched = time.time()
        return out, True

    if kind == "fatal":
        return [{"type": "error", "message": str(event.get("message") or "сбой харнесса")}], True

    if kind in ("auto_retry_start", "auto_retry_end", "extension_error", "queue_update"):
        return [{**event, "type": kind}], False

    return out, False


def translate_claude_event(session, event):
    """Переводит событие Claude Code в события экрана; второй элемент — «ход закончился».

    События Claude Code богаче наших: он присылает и частичные куски текста, и целые сообщения,
    и служебные кадры. Наружу уходит только то, что видно на экране, а из служебного берётся
    важное: идентификатор сессии, модель, расход токенов и стоимость.

    Отдельная тонкость — частичные куски. С `--include-partial-messages` текст приходит дважды:
    кусками по мере генерации и целиком в готовом сообщении. Поэтому готовое сообщение отдаёт
    текст только тогда, когда частичных кусков не было: иначе в ответе всё напечаталось бы
    второй раз.
    """
    kind = event.get("type")
    subtype = event.get("subtype")
    out = []

    if kind == "system":
        if subtype == "init":
            # идентификатор и модель сессии забирает себе читатель потока (см. ClaudeSession);
            # на экран отсюда уходит только подпись «что происходит»
            out.append({"type": "status", "step": "готовлю ответ"})
        return out, False

    if kind == "stream_event":
        inner = event.get("event") if isinstance(event.get("event"), dict) else {}
        inner_kind = inner.get("type")
        if inner_kind == "content_block_start":
            block = inner.get("content_block") if isinstance(inner.get("content_block"), dict) else {}
            if block.get("type") == "tool_use":
                out.append({
                    "type": "tool_call",
                    "id": str(block.get("id") or ""),
                    "name": str(block.get("name") or "").lower(),
                })
        elif inner_kind == "content_block_delta":
            delta = inner.get("delta") if isinstance(inner.get("delta"), dict) else {}
            if delta.get("type") == "text_delta" and delta.get("text"):
                session.partial_seen = True
                out.append({"type": "delta", "text": str(delta["text"])})
            elif delta.get("type") == "thinking_delta" and delta.get("thinking"):
                session.partial_seen = True
                out.append({"type": "reasoning", "text": str(delta["thinking"])})
        return out, False

    if kind == "assistant":
        message = event.get("message") if isinstance(event.get("message"), dict) else {}
        content = message.get("content")
        if isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                block_kind = block.get("type")
                if block_kind == "tool_use":
                    out.append({
                        "type": "tool_start",
                        "id": str(block.get("id") or ""),
                        "name": str(block.get("name") or "").lower(),
                        "args": block.get("input") if isinstance(block.get("input"), dict) else {},
                    })
                    session.counters["toolCalls"] += 1
                elif block_kind == "text" and not session.partial_seen and str(block.get("text") or ""):
                    out.append({"type": "delta", "text": str(block["text"])})
                elif block_kind == "thinking" and not session.partial_seen and str(block.get("thinking") or ""):
                    out.append({"type": "reasoning", "text": str(block["thinking"])})
        usage = message.get("usage")
        if isinstance(usage, dict):
            session.last_usage = usage
        session.counters["assistantMessages"] += 1
        return out, False

    if kind == "user":
        message = event.get("message") if isinstance(event.get("message"), dict) else {}
        content = message.get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    out.append({
                        "type": "tool_end",
                        "id": str(block.get("tool_use_id") or ""),
                        "text": claude_result_text(block.get("content")),
                        "isError": bool(block.get("is_error")),
                    })
        return out, False

    if kind == "result":
        usage = event.get("usage") if isinstance(event.get("usage"), dict) else {}
        if usage:
            session.last_usage = usage
            tokens = session.state.get("tokens") if isinstance(session.state.get("tokens"), dict) else {}
            session.state["tokens"] = {
                "input": int(tokens.get("input") or 0) + int(usage.get("input_tokens") or 0),
                "output": int(tokens.get("output") or 0) + int(usage.get("output_tokens") or 0),
                "cacheRead": int(tokens.get("cacheRead") or 0) + int(usage.get("cache_read_input_tokens") or 0),
                "total": int(tokens.get("total") or 0) + sum(int(usage.get(k) or 0) for k in (
                    "input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens",
                )),
            }
        cost = event.get("total_cost_usd")
        if isinstance(cost, (int, float)):
            session.state["cost"] = float(session.state.get("cost") or 0) + float(cost)
        session.partial_seen = False
        session.busy = False
        session.touched = time.time()
        # Ход закончился ошибкой (например, «Not logged in» или отказ провайдера) — показываем
        # это ошибкой, а не пустым ответом: человеку нужно понять, что чинить.
        if event.get("is_error") or (subtype and subtype != "success"):
            return [{"type": "error", "message": str(event.get("result") or "Claude Code вернул ошибку")}], True
        return out, True

    return out, False


def translate(session, event):
    """Переводит событие харнесса в события экрана (см. переводы выше)."""
    if session.harness == HARNESS_CLAUDE:
        return translate_claude_event(session, event)
    return translate_pi_event(session, event)


class Pool:
    """Пул процессов харнессов: по одному на сессию, с остановкой по простою."""

    def __init__(self):
        self.lock = threading.Lock()
        self.sessions = {}
        self.reaper = threading.Thread(target=self._reap, daemon=True)
        self.reaper.start()

    def open(self, cwd, harness=HARNESS_PI, session_id=None, provider=None, model=None):
        """Отдаёт сессию в папке [cwd], поднимая процесс нужного харнесса, если его ещё нет.

        Занятая сессия не переоткрывается: два клиента в одной сессии — это два писателя в один
        файл истории, и разговор бы разъехался. Проверка «занято» живёт в ручке prompt, здесь же
        важно не потерять уже поднятый процесс.
        """
        key = session_key(harness, session_id) if session_id else ""
        with self.lock:
            if key and key in self.sessions:
                session = self.sessions[key]
                if not session.alive():
                    session._restart()
                session.touched = time.time()
                return session

            session = (ClaudeSession if harness == HARNESS_CLAUDE else PiSession)(
                cwd, session_id, model=model, **({"provider": provider} if harness != HARNESS_CLAUDE else {}),
            )
            if not session.id:
                detail = session.stderr_tail[-1] if session.stderr_tail else "без вывода"
                session.stop()
                raise PiError("%s не сообщил идентификатор сессии (%s)" % (harness, detail))
            # если такой процесс уже был под другим ключом — закрываем дубль
            existing = self.sessions.get(session.key)
            if existing is not None and existing is not session:
                session.stop()
                existing.touched = time.time()
                return existing
            self.sessions[session.key] = session
            return session

    def find(self, key):
        """Находит живую сессию по ключу (`харнесс--id`) или бросает понятную ошибку."""
        with self.lock:
            session = self.sessions.get(key)
        if session is None:
            raise PiError("сессия не открыта: сначала откройте её в приложении")
        if not session.alive():
            session._restart()
        return session

    def list(self):
        """Снимок пула для /health."""
        with self.lock:
            return [
                {
                    "id": s.key,
                    "harness": s.harness,
                    "cwd": s.cwd,
                    "busy": s.busy,
                    "idle": round(time.time() - s.touched),
                }
                for s in self.sessions.values()
            ]

    def take(self, session_id):
        """Забирает сессию из пула, если она там есть; иначе `None`.

        Нужно закрытию и удалению: сессия может быть уже закрыта (или приложение
        перезапускалось), и это не ошибка — тогда просто нечего останавливать.
        """
        with self.lock:
            return self.sessions.pop(session_id, None)

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
                    self.sessions.pop(session.key, None)
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
        """Проверяет токен моста, если он задан в настройках.

        По умолчанию токен пустой, и это правильно: мост виден только с loopback обоих
        концов туннеля, как поиск и телефон у раздела «Чат». Поле нужно на случай, если мост
        когда-нибудь выставят наружу — тогда он включается в `~/.pi-bridge.json`, и сервер
        приложения шлёт его из своего окружения.
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
            elif path == "/harnesses":
                self._json(200, {"harnesses": harness_status()})
            elif path == "/models":
                harness = str((params.get("harness") or [HARNESS_PI])[0]).strip().lower() or HARNESS_PI
                self._json(200, {"models": list_models(harness), "harness": harness})
            elif path == "/providers":
                self._json(200, {"providers": provider_list()})
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
            if path == "/providers":
                self._json(200, {"providers": save_provider(body)})
                return
            if path == "/providers/probe":
                # Ключ можно не присылать повторно: если провайдер уже сохранён, берём его ключ
                # с мака — человек правит адрес, не вводя ключ заново.
                api_key = str(body.get("apiKey") or "").strip()
                provider = str(body.get("provider") or "").strip()
                if not api_key and provider:
                    saved = read_json_file(PI_MODELS).get("providers") or {}
                    entry = saved.get(provider) if isinstance(saved.get(provider), dict) else {}
                    api_key = str(entry.get("apiKey") or "")
                models = provider_probe(body.get("baseUrl"), api_key)
                self._json(200, {"models": models})
                return
            if path == "/providers/key":
                self._json(200, {
                    "providers": save_provider_key(body.get("provider"), body.get("apiKey")),
                })
                return
            parts = path.split("/")
            if len(parts) >= 4 and parts[1] == "sessions":
                action = parts[3]
                # закрытие обрабатывается до поиска в пуле: закрыть уже закрытую сессию — не
                # ошибка, приложение зовёт эту ручку и при уходе с экрана, и явной кнопкой
                if action == "close":
                    self._close(parts[2])
                    return
                session = POOL.find(parts[2])
                if action == "prompt":
                    self._prompt(session, body)
                elif action == "abort":
                    session.abort()
                    self._json(200, {"ok": True})
                elif action == "compact":
                    if session.harness != HARNESS_PI:
                        raise PiError("сжатие контекста есть только у pi: Claude Code сжимает его сам")
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
                    session.set_model(provider, model)
                    # наружу отдаём описание сессии в том же виде, что и везде: приложение
                    # показывает им шапку и сведения, и сырое состояние харнесса тут не подходит
                    session.refresh_state()
                    self._json(200, {"session": self._session_brief(session)})
                elif action == "ui":
                    self._json(200, self._manual_ui(session, body))
                else:
                    self._json(404, {"error": "неизвестная ручка: %s" % path})
                return
            self._json(404, {"error": "неизвестная ручка: %s" % path})

        self._guard(run)

    def do_DELETE(self):  # noqa: N802
        """Удаляет сессию: процесс pi гасится, файл истории стирается с диска.

        Разрушительно и необратимо, поэтому в приложении это отдельное действие с
        подтверждением. Закрыть разговор (без потери истории) — ручка `POST /close`.
        """
        path, _ = self._route()

        def run():
            parts = path.split("/")
            if len(parts) == 3 and parts[1] == "providers":
                self._json(200, {"providers": delete_provider(parts[2])})
                return
            if len(parts) == 3 and parts[1] == "sessions":
                session = POOL.take(parts[2])
                if session is not None:
                    session.stop()
                # файл ищем всегда: удалить разговор можно и у закрытой сессии
                removed = purge_session(parts[2])
                self._json(200, {"ok": True, "deleted": removed})
            else:
                self._json(404, {"error": "неизвестная ручка: %s" % path})

        self._guard(run)

    # --- что делают ручки ---

    def _health(self):
        """Сводка для приложения: работает ли мост, какие харнессы стоят, что в пуле."""
        provider, model = default_model()
        harnesses = harness_status()
        pi_version = next((h["version"] for h in harnesses if h["harness"] == HARNESS_PI), "")
        return {
            "ok": True,
            # `pi` оставлен для сборок приложения, которые про харнессы ещё не знают
            "pi": pi_version,
            "harnesses": harnesses,
            "provider": provider,
            "model": model,
            "roots": CONFIG.get("roots") or [],
            "sessions": POOL.list(),
        }

    def _list_sessions(self, params):
        """Сессии проекта из файлов истории: работают и когда процессы не подняты.

        Харнесс задаёт вызывающий (`harness=pi|claude`), а без него отдаются оба списка с
        пометкой, чей это разговор: приложение показывает их вместе, различая по значку.
        """
        raw = (params.get("path") or [""])[0]
        path = allowed_path(raw) if raw else None
        if path is None:
            raise PiError("папка вне разрешённых корней: %s" % raw)
        asked = str((params.get("harness") or [""])[0]).strip()

        sessions = []
        if asked in ("", HARNESS_PI):
            for file in session_files(path):
                sessions.append({**read_session_meta(file), "harness": HARNESS_PI})
        if asked in ("", HARNESS_CLAUDE):
            for file in claude_session_files(path):
                sessions.append({**read_claude_meta(file), "harness": HARNESS_CLAUDE})
        # свежие сверху: два списка складываются в один по времени последнего обращения
        sessions.sort(key=lambda s: s.get("updatedAt") or "", reverse=True)
        for session in sessions:
            session["id"] = session_key(session["harness"], session["id"])
        self._json(200, {"path": str(path), "sessions": sessions})

    def _open_session(self, body):
        """Открывает сессию в выбранной папке (или продолжает существующую по id).

        Провайдер и модель можно задать здесь же: у pi моделей бывает несколько (локальная и
        удалённая по API), и для новой сессии выбор делается в момент открытия — потом его
        меняет ручка `model`, не перезапуская разговор.
        """
        raw = str(body.get("path") or "").strip()
        path = allowed_path(raw) if raw else None
        if path is None:
            raise PiError("папка вне разрешённых корней: %s" % raw)
        # Харнесс можно задать явно, а можно прийти вместе с идентификатором сессии
        # (`claude--<id>`): приложение открывает существующий разговор по строке из списка.
        raw_id = str(body.get("sessionId") or "").strip()
        harness = str(body.get("harness") or "").strip().lower()
        if not harness and raw_id:
            harness = split_key(raw_id)[0]
        if not harness:
            harness = HARNESS_PI
        if harness not in HARNESS_NAMES:
            raise PiError("неизвестный харнесс: %s" % harness)
        session_id = split_key(raw_id)[1] if raw_id else None
        provider = str(body.get("provider") or "").strip() or None
        model = str(body.get("model") or "").strip() or None
        session = POOL.open(path, harness, session_id, provider=provider, model=model)
        session.refresh_state()
        self._json(200, {"session": self._session_brief(session)})

    def _close(self, session_id):
        """Закрывает процесс pi, оставляя историю: освобождает память на маке.

        Отдельно от удаления: закрыть — это «я закончил разговор сейчас», после него сессия
        открывается снова из своего файла. Повторное закрытие не ошибка (сессия могла быть уже
        закрыта или приложение перезапускалось), поэтому отсутствие процесса в пуле — не отказ.
        """
        session = POOL.take(session_id)
        if session is not None:
            session.stop()
        self._json(200, {"ok": True, "closed": session is not None})

    def _session_brief(self, session):
        """Описание сессии для экрана: модель, контекст, расход, счётчики и время.

        Всё берётся из одного снимка состояния (`get_state` + `get_session_stats`), который
        обновляется перед отдачей: приложение показывает этими числами, сколько окна модели
        занято и не пора ли сжимать разговор, а по времени видно, как долго идёт работа.

        `local` — признак того, что модель считает на этом маке, а не по API: по нему
        приложение подписывает сессию, чтобы удалённая модель не выглядела как локальная.
        """
        state = session.state if isinstance(session.state, dict) else {}
        model = state.get("model") if isinstance(state.get("model"), dict) else {}
        context = state.get("contextUsage") if isinstance(state.get("contextUsage"), dict) else {}
        tokens = state.get("tokens") if isinstance(state.get("tokens"), dict) else {}
        file = session_file(session)
        meta = session.start_meta or {}
        context_estimated = bool(context.get("estimated")) if isinstance(context, dict) else False
        return {
            "id": session.key,
            "harness": session.harness,
            "harnessName": HARNESS_NAMES.get(session.harness, session.harness),
            "contextEstimated": context_estimated,
            "path": session.cwd,
            "name": str(state.get("sessionName") or ""),
            "model": str(model.get("id") or ""),
            "modelName": str(model.get("name") or ""),
            "provider": str(model.get("provider") or ""),
            "local": is_local_model(model),
            "thinkingLevel": str(state.get("thinkingLevel") or ""),
            "busy": session.busy,
            "messages": int(state.get("messageCount") or 0),
            "contextTokens": context.get("tokens"),
            "contextWindow": context.get("contextWindow") or model.get("contextWindow"),
            "contextPercent": round(float(context.get("percent") or 0), 1),
            "tokens": {
                "input": int(tokens.get("input") or 0),
                "output": int(tokens.get("output") or 0),
                "cacheRead": int(tokens.get("cacheRead") or 0),
                "total": int(tokens.get("total") or 0),
            },
            "cost": float(state.get("cost") or 0),
            "userMessages": int(state.get("userMessages") or 0),
            "assistantMessages": int(state.get("assistantMessages") or 0),
            "toolCalls": int(state.get("toolCalls") or 0),
            "startedAt": meta.get("startedAt"),
            "updatedAt": session_mtime(file),
            "sessionFile": str(file) if file else "",
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
        # без этого промежуточный nginx копит поток и отдаёт его целиком
        self.send_header("X-Accel-Buffering", "no")
        # длина потока заранее неизвестна, поэтому тело заканчивается закрытием соединения
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        aborted = False
        try:
            # подписка стоит ДО отправки сообщения: события первого шага иначе можно потерять
            try:
                session.prompt(text)
            except PiError as e:
                # Заголовки потока уже отправлены, поэтому ответить кодом нельзя — отказ
                # уходит событием. Так приходит, например, отказ харнесса принять второй вопрос
                # в занятую сессию, если её занял кто-то помимо моста.
                self._event({"type": "error", "message": str(e)})
                return
            self._event({"type": "accepted"})
            while True:
                try:
                    event = events.get(timeout=1.0)
                except queue.Empty:
                    # пустой такт — проверка, жив ли ещё клиент и не оборвался ли процесс
                    if not session.alive():
                        self._event({"type": "error", "message": "процесс %s завершился" % session.harness})
                        break
                    continue
                translated, done = translate(session, event)
                for ours in translated:
                    self._event(ours)
                if done:
                    # описание сессии собираем только теперь: расход и контекст обновляются
                    # ровно в конце прогона, и раньше этих чисел просто нет
                    self._event({"type": "done", "session": self._settled_brief(session)})
                    break
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
