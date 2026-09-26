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
  GET    /sessions?path=<папка>       — сессии проекта (файлы pi), новые по дате создания
                                        сверху; без `path` —
                                        сессии всех проектов одним списком;
  GET    /models?harness=<pi|claude>   — модели харнесса и, у Claude Code, уровни усилия;
  GET    /providers                   — провайдеры и признак «ключ задан» (самих ключей нет);
  POST   /providers                   — создать или изменить своего провайдера (models.json);
  POST   /providers/probe             — проверить адрес и ключ, получить список моделей;
  POST   /providers/key               — задать или убрать ключ встроенного провайдера (auth.json);
  DELETE /providers/<key>             — удалить своего провайдера;
  POST   /sessions                    — открыть сессию: поднять процесс pi в этой папке;
  GET    /sessions/<id>               — состояние сессии (модель, контекст, занятость);
  GET    /sessions/<id>/messages      — переписка в нормализованном виде;
  GET    /sessions/<id>/events        — подключиться к уже идущему прогону (SSE);
  POST   /sessions/<id>/prompt        — отправить сообщение, ответ потоком SSE;
  POST   /sessions/<id>/queue         — дописать сообщение в занятую сессию (уйдёт по очереди);
  POST   /sessions/<id>/abort         — остановить генерацию;
  POST   /sessions/<id>/compact       — сжать контекст;
  POST   /sessions/<id>/model         — сменить модель;
  POST   /sessions/<id>/effort        — сменить уровень усилия (только Claude Code);
  POST   /sessions/<id>/name          — переименовать разговор (записью в его журнал; до
                                        первого сообщения имя ждёт журнала в памяти сессии);
  POST   /sessions/<id>/ui            — ответ на диалог расширения (по умолчанию не нужен);
  DELETE /sessions/<id>               — удалить сессию: процесс гасится, файл стирается.

Кто сюда ходит: только сервер приложения, и только через reverse-SSH туннель мака — порт
18820 слушает loopback на обоих концах (см. cloudlyru/agents/mac/run-tunnel.sh). Поэтому
авторизации здесь нет: снаружи порт не виден
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

# Память выбора модели и усилия по сессиям. На диске, а не только в пуле процессов, потому что
# процесс харнесса живёт до перезапуска моста или до остановки по простою, а выбор человека
# должен переживать и то, и другое: при подъёме процесса мост иначе брал бы модель по умолчанию
# из models.json — а там первым идёт `local`, и разговор молча съезжал на локальную модель.
SESSIONS_PATH = Path(os.environ.get(
    "PI_BRIDGE_SESSIONS", str(Path.home() / ".pi-bridge-sessions.json")
))

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
HEARTBEAT_SECONDS = 15      # как часто поток SSE шлёт `ping`, пока агент молчит
DELTA_FLUSH_SECONDS = 0.08  # за сколько склеивать куски текста в одно событие
EVENT_TICK = 0.05           # шаг ожидания событий: по нему же считаются пульс и склейка
SESSIONS_CACHE_SECONDS = 5.0  # короткий кэш списка разговоров (его спрашивают регулярно)
MAX_BODY_BYTES = 4 * 1024 * 1024  # потолок тела запроса: сообщение в 20k символов меньше на порядки
MAX_NAME_CHARS = 120        # потолок имени сессии: в списке оно всё равно режется одной строкой
# Наши собственные события в общем потоке с событиями харнесса: очередь, простой сессии и наши
# отказы (например, сообщение из очереди не удалось отдать агенту).
OWN_EVENTS = {"queued", "queued_started", "idle", "error"}

# События pi, которые уходят приложению. Остальные (message_start, turn_start и прочая
# служебная механика) наружу не нужны: экран строится по дельтим и вызовам инструментов.
# Завершение прогона у харнессов своё (`agent_settled` у pi, `result` у Claude Code), и его
# отмечает перевод события: по нему сессия снимает занятость (см. _dispatch).
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
        # Уровень усилия Claude Code для сессий, открываемых без выбора приложения: в файле
        # разговора он не хранится, и без этого возобновлённый процесс потерял бы выбор человека
        "claude_effort": "",
        "token": secrets.token_hex(24),
    }
    save_config(cfg)
    log("создал %s — токен и корни внутри файла, откройте его и впишите в приложение" % CONFIG_PATH)
    return cfg


def save_config(cfg):
    """Записывает настройки моста в тот же файл, что читает человек, и тем же режимом 600.

    Файл перезаписывается целиком из уже прочитанного `CONFIG`: так туда попадают только те
    поля, которые мост действительно помнит (сейчас — уровень усилия), а токен и корни не
    теряются.
    """
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding="utf-8")
    os.chmod(CONFIG_PATH, 0o600)


def remember_claude_effort(effort):
    """Запоминает уровень усилия Claude Code в настройках моста.

    Зачем: в файле разговора усилие не хранится, а процесс после простоя или перезапуска моста
    поднимается заново (`_reopen`) — без этой памяти выбор человека молча сменился бы на
    умолчание модели. Ошибка записи не должна ломать текущую сессию, поэтому её только логируем.
    """
    value = str(effort or "").strip()
    if str(CONFIG.get("claude_effort") or "") == value:
        return
    CONFIG["claude_effort"] = value
    try:
        save_config(CONFIG)
    except OSError as e:
        log("не смог сохранить уровень усилия в %s (%s)" % (CONFIG_PATH, e))


CONFIG = load_config()


# Выбор модели и усилия по сессиям: разговор продолжается тем же, чем его вели.
_sessions_lock = threading.Lock()


def session_choice(key):
    """Выбор модели и усилия для сессии [key] (`харнесс--id`); пустой словарь, если неизвестен.

    Ошибка чтения не должна мешать работать: без памяти мост откатится к модели из журнала
    сессии или к умолчанию — это хуже, но не отказ разговора целиком.
    """
    if not key:
        return {}
    with _sessions_lock:
        data = read_json_file(SESSIONS_PATH)
    entry = data.get(key)
    return entry if isinstance(entry, dict) else {}


def remember_session_choice(key, provider=None, model=None, effort=None):
    """Запоминает выбор модели и усилия для сессии [key] на диске.

    Пишем только то, что передали: `None` означает «про это ничего не сказали», и такое поле
    не затирается — иначе смена усилия у Claude Code стирала бы выбранную модель.
    Ошибку записи только логируем: потеря памяти хуже, но текущий разговор ломать нельзя.
    """
    if not key:
        return
    with _sessions_lock:
        data = read_json_file(SESSIONS_PATH)
        entry = data.get(key)
        # Чужая запись (например, дописанная руками) сохраняется: правим только известные поля
        entry = dict(entry) if isinstance(entry, dict) else {}
        if provider is not None:
            entry["provider"] = str(provider)
        if model is not None:
            entry["model"] = str(model)
        if effort is not None:
            entry["effort"] = str(effort)
        entry["at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        data[key] = entry
        try:
            write_json_file(SESSIONS_PATH, data)
        except OSError as e:
            log("не смог сохранить выбор модели для %s (%s): %s" % (key, SESSIONS_PATH, e))


def journal_model(harness, session_id, file=None):
    """Модель и провайдер из журнала сессии — второй источник после памяти моста.

    Нужен для разговоров, начатых не из приложения (в терминале): их выбора в памяти моста нет,
    а журнал знает, чем они считались. Читается только при подъёме процесса, так что цена —
    один разбор файла на старт, а не на каждый запрос.
    """
    if not session_id:
        return "", ""
    file = file or find_session_file(harness, session_id)
    if file is None:
        return "", ""
    reader = read_claude_meta if harness == HARNESS_CLAUDE else read_session_meta
    meta = reader(file)
    return str(meta.get("provider") or ""), str(meta.get("model") or "")


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
    отдельно, а вызовы инструментов разбираются по-своему. Текст передаётся как есть:
    клиент приложения рендерит markdown.
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

# Псевдонимы семейств Claude Code: он сам разрешает их в новейшую версию, доступную аккаунту,
# поэтому такой выбор переживает выход новых версий и не ломается об ограничения подписки.
CLAUDE_ALIASES = [
    {"id": "default", "name": "Как настроено в Claude Code", "contextWindow": 200_000},
    {"id": "fable", "name": "Fable — последняя", "contextWindow": 1_000_000},
    {"id": "opus", "name": "Opus — последняя", "contextWindow": 1_000_000},
    {"id": "opusplan", "name": "Opus Plan — Opus в планировании, Sonnet в работе", "contextWindow": 1_000_000},
    {"id": "sonnet", "name": "Sonnet — последняя", "contextWindow": 1_000_000},
    {"id": "haiku", "name": "Haiku — последняя", "contextWindow": 200_000},
]

# Конкретные версии из встроенного каталога установленного Claude Code (порядок — от новых к
# старым). Четвёртое поле — есть ли у версии 1M-вариант: Claude Code принимает его тем же
# идентификатором с суффиксом `[1m]`, и такая строка добавляется рядом с базовой. Список
# повторяет каталог именно этой версии, а не документацию: показать то, чего она не знает,
# значит гарантировать ошибку при выборе.
_CLAUDE_VERSIONS = [
    ("claude-fable-5-1", "Fable 5.1", 1_000_000, False),
    ("claude-fable-5", "Fable 5", 1_000_000, False),
    ("claude-mythos-5-1", "Mythos 5.1", 1_000_000, False),
    ("claude-mythos-5", "Mythos 5", 1_000_000, False),
    ("claude-opus-5", "Opus 5", 1_000_000, False),
    ("claude-opus-4-8", "Opus 4.8", 1_000_000, False),
    ("claude-opus-4-7", "Opus 4.7", 1_000_000, False),
    ("claude-opus-4-6", "Opus 4.6", 200_000, True),
    ("claude-opus-4-5", "Opus 4.5", 200_000, True),
    ("claude-opus-4-1", "Opus 4.1", 200_000, True),
    ("claude-opus-4-0", "Opus 4", 200_000, True),
    ("claude-sonnet-5", "Sonnet 5", 1_000_000, False),
    ("claude-sonnet-4-6", "Sonnet 4.6", 200_000, True),
    ("claude-sonnet-4-5", "Sonnet 4.5", 200_000, True),
    ("claude-sonnet-4-0", "Sonnet 4", 200_000, True),
    ("claude-3-7-sonnet", "Sonnet 3.7", 200_000, False),
    ("claude-3-5-sonnet", "Sonnet 3.5", 200_000, False),
    ("claude-haiku-4-5", "Haiku 4.5", 200_000, True),
    ("claude-3-5-haiku", "Haiku 3.5", 200_000, False),
]


def claude_models():
    """Собирает список моделей Claude Code: псевдонимы семейств и конкретные версии.

    Нужен отдельной функцией, потому что версии бывают с 1M-вариантом: он добавляется рядом с
    базовой строкой, и вручную дублировать имя и окно было бы легко ошибиться.
    """
    models = [dict(entry) for entry in CLAUDE_ALIASES]
    for model_id, name, window, long in _CLAUDE_VERSIONS:
        models.append({"id": model_id, "name": name, "contextWindow": window})
        if long:
            models.append({
                "id": model_id + "[1m]",
                "name": name + " (1M)",
                "contextWindow": 1_000_000,
            })
    return models


CLAUDE_MODELS = claude_models()

# Усилие — сколько модель думает над ответом (`--effort`). Значения и порядок заданы Claude Code;
# модель без поддержки уровня всё равно ответит, взяв своё умолчание, поэтому лишний выбор здесь
# безвреден. Пустой выбор — «как решает Claude Code», а не «средний»: умолчание у моделей разное.
CLAUDE_EFFORTS = [
    {"id": "low", "name": "Низкое — быстрее и дешевле"},
    {"id": "medium", "name": "Среднее"},
    {"id": "high", "name": "Высокое"},
    {"id": "xhigh", "name": "Очень высокое"},
    {"id": "max", "name": "Максимальное — самое долгое и дорогое"},
]


def claude_effort_ids():
    """Идентификаторы уровней усилия: ими проверяется то, что прислало приложение."""
    return {entry["id"] for entry in CLAUDE_EFFORTS}


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


def claude_session_env_dir(session_id):
    """Папка окружения сессии Claude Code: `<профиль>/session-env/<id>`.

    Claude Code складывает сюда окружение запущенного разговора и сам её не убирает: у папки нет
    своего журнала, поэтому после удаления сессии она оставалась мусором (274 папки к 22.09.26).
    Профиль берём тем же способом, что и [claude_projects_dir]: `~/.claude`, если `claude_config_dir`
    не задан.
    """
    if not session_id:
        return None
    return Path(claude_profile() or (Path.home() / ".claude")) / "session-env" / str(session_id)


def session_cwd(harness, session_id):
    """Рабочая папка сессии по её файлу: нужна, чтобы открыть разговор заново.

    Мост может потерять открытую сессию (перезапуск, остановка процесса по простою), а
    приложение продолжает с ней работать — и тогда на вопрос прилетал отказ «сессия не
    открыта». Рабочий каталог записан в самой истории, поэтому разговор поднимается заново без
    участия человека.
    """
    file = find_session_file(harness, session_id)
    if file is None:
        return None
    reader = read_claude_meta if harness == HARNESS_CLAUDE else read_session_meta
    cwd = str(reader(file).get("cwd") or "")
    return cwd or None


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

    # Имя, поставленное командой `/rename` (или флагом `--name`), Claude Code дописывает записью
    # `custom-title` в конец журнала — в разобранных 400 КБ начала его может не быть, а
    # побеждает последняя такая запись. Поэтому ищем её отдельно по всему файлу.
    renamed = last_jsonl_field(data, "custom-title", "customTitle")
    if renamed:
        meta["name"] = renamed
    if not meta["name"]:
        meta["name"] = meta["title"]
    if not meta["startedAt"] or not meta.get("updatedAt"):
        # Файл мог исчезнуть между чтением и этим моментом (разговор удалили): без времени
        # список обойдётся, а падать из-за одного файла не должен.
        try:
            stamp = file.stat().st_mtime
        except OSError:
            stamp = None
        if not meta["startedAt"] and stamp is not None:
            meta["startedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(stamp))
        if not meta.get("updatedAt") and stamp is not None:
            meta["updatedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(stamp))
    return meta


def last_jsonl_field(data, kind, field):
    """Последнее значение поля из записей указанного типа в разобранном журнале сессии.

    Ищем по сырым байтам, а не разбором всех строк: журнал Claude Code измеряется десятками
    мегабайт, а имя, поставленное `/rename`, лежит в самом конце — разбирать ради него весь
    файл при каждом обновлении списка нельзя. `None` — записи такого типа нет.

    Между `"type":` и значением бывает пробел: сам Claude Code пишет компактно, а наш
    `json.dumps` — с пробелами, и строгий поиск `"type":"custom-title"` пропускал бы записи,
    записанные мостом или руками. Поэтому значение ищется как отдельная строка и первое
    совпадение берётся не «где угодно», а слева от последней такой записи в файле.
    """
    quoted = b'"' + kind.encode("utf-8") + b'"'
    index = data.rfind(quoted)
    if index < 0:
        return None
    # имя, встречающееся в тексте сообщений, не путать с типом записи: значение стоит после
    # `"type":` и закрывается переводом строки — иначе строка без поля `type` притворилась бы
    # записью имени
    typed = data.rfind(b'"type"', 0, index)
    if typed < 0:
        return None
    start = data.rfind(b"\n", 0, typed) + 1
    end = data.find(b"\n", typed)
    line = data[start:end if end >= 0 else len(data)]
    try:
        entry = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return None
    if not isinstance(entry, dict) or entry.get("type") != kind:
        return None
    value = entry.get(field)
    return value.strip() if isinstance(value, str) else None


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


def read_file_messages(harness, file):
    """Переписка сессии прямо из её файла, без живого процесса агента.

    Нужна потому, что открыть разговор и посмотреть, что в нём было, — это чтение истории, а не
    работа агента: процесс мог быть погашен по простою или мост перезапускался, и отказывать в
    истории по этой причине нельзя (именно так приложение получало 400 на ровном месте).
    """
    if not file or not file.exists():
        return []
    if harness == HARNESS_CLAUDE:
        return normalize_claude_messages(read_jsonl(file))
    messages = []
    for entry in read_jsonl(file):
        if entry.get("type") == "message" and isinstance(entry.get("message"), dict):
            messages.append(entry["message"])
    return normalize_messages(messages)


def read_jsonl(file):
    """Читает JSONL-файл в список объектов; битые строки пропускаются."""
    entries = []
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
                if isinstance(entry, dict):
                    entries.append(entry)
    except OSError as e:
        log("не смог прочитать %s: %s" % (file, e))
    return entries


# Кэш разобранных метаданных сессии по файлу. Зачем: `read_session_meta` / `read_claude_meta`
# читают файл целиком до конца (имя и счётчики лежат в разных записях, иначе их не собрать), и
# обход всех папок на маке — это тысячи разборов JSON на каждый показ списка разговоров. Файл
# сессии только дописывается, а не переписывается, поэтому пара «размер + mtime» — честный ключ:
# пока она та же, содержимое то же.
_meta_cache = {}
meta_cache_lock = threading.Lock()


def cached_meta(file, reader):
    """Метаданные сессии через кэш: `reader`_base вызывается только при изменении файла."""
    try:
        info = file.stat()
        key = (str(file), info.st_size, info.st_mtime)
    except OSError:
        return reader(file)
    with meta_cache_lock:
        cached = _meta_cache.get(str(file))
        if cached is not None and cached[0] == key:
            return cached[1]
    meta = reader(file)
    with meta_cache_lock:
        _meta_cache[str(file)] = (key, meta)
    return meta


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
    if not meta["startedAt"] or not meta.get("updatedAt"):
        # Файл мог исчезнуть между чтением и этим моментом (разговор удалили) или не читаться
        # вовсе: тогда ни времени старта, ни времени правки нет — лучше пустая строка, чем
        # падение всей ручки списка из-за одного файла.
        try:
            stamp = file.stat().st_mtime
        except OSError:
            stamp = None
        if not meta["startedAt"] and stamp is not None:
            meta["startedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(stamp))
        if not meta.get("updatedAt") and stamp is not None:
            meta["updatedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(stamp))
    return meta


# Кэш времени последнего использования по папкам проекта. Нужен потому, что «самая свежая сессия
# в папке» считается как максимум mtime по всем её файлам истории, а это `stat` на каждый файл
# при каждом вызове `/projects` — то есть работа растёт со всей историей на маке, а не с числом
# проектов. Ключ — число файлов и время правки каталогов истории: `mtime` самой папки проекта
# для этого не годится, он меняется только при создании и удалении имени в каталоге, а
# дописывание существующего файла сессии его не трогает. Поэтому смотрим на папки, где файлы
# действительно лежат (`sessions_dir_for`, `claude_sessions_dir`): их mtime меняется при
# добавлении и удалении файла, а число файлов ловит случай, когда удалили один и добавили
# другой в ту же секунду.
_last_used_cache = {}
last_used_lock = threading.Lock()


def folder_last_used(folder, files):
    """Время последней сессии в папке [folder] по её файлам [files] — с кэшем по их папкам.

    Возвращает ISO-время или `None`, если файлов нет. Значащее для экрана действие — добавить
    сессию или удалить её; дописывание одного и того же файла время в списке не меняет значимо,
    а полноценно отследить его без `stat` по файлам всё равно нельзя. Кэш живёт в памяти
    процесса моста: после его перезапуска первый проход всегда полный.
    """
    if not files:
        return None
    # Ключ — по папкам, где реально лежат файлы истории этой папки проекта (обычно 0–2 штуки),
    # а не по самой папке проекта: см. пояснение выше про mtime.
    signature = []
    for directory in {f.parent for f in files}:
        try:
            signature.append((str(directory), directory.stat().st_mtime))
        except OSError:
            return None
    signature.append(len(files))
    key = str(folder)
    with last_used_lock:
        cached = _last_used_cache.get(key)
        if cached is not None and cached[0] == signature:
            return cached[1]
    try:
        newest = max(f.stat().st_mtime for f in files)
    except OSError:
        return None
    value = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(newest))
    with last_used_lock:
        _last_used_cache[key] = (signature, value)
    return value


# Короткий кэш дорогих ответов: `/projects` пересчитывается обходом всей истории на маке, а
# спрашивает его каждый вход на экран и каждый мастер новой сессии. Пяти секунд хватает, чтобы
# серия запросов одного действия обошлась одним обходом, и мало, чтобы человек увидел устаревший
# список: сессия появляется не чаще, чем он успевает ткнуться в экран дважды.
PROJECTS_CACHE_SECONDS = 5.0
_projects_cache = None
projects_lock = threading.Lock()


def list_projects_cached():
    """Список проектов из короткого кэша — чтобы частое обращение не стоило обхода истории."""
    global _projects_cache
    with projects_lock:
        now = time.time()
        if _projects_cache and now - _projects_cache[0] < PROJECTS_CACHE_SECONDS:
            return _projects_cache[1]
    value = list_projects()
    with projects_lock:
        _projects_cache = (time.time(), value)
    return value


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
        # Время последней сессии в папке — через кэш: `stat` по всем её файлам истории на каждом
        # вызове /projects стоил бы дороже всего остального в этой ручке (см. folder_last_used).
        last = folder_last_used(resolved, files)
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
            cwd = str(cached_meta(files[0], reader).get("cwd") or "")
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


def provider_base_url(provider):
    """Адрес провайдера из `models.json`; пустая строка, если такой провайдер неизвестен.

    Нужен, чтобы у закрытой сессии (процесс погашен по простою, мост перезапускался) правильно
    подписать, где считалась модель: признак «локальная» выводится из адреса, а в журнале
    сессии адреса нет — в нём только имя провайдера.
    """
    name = str(provider or "").strip()
    if not name:
        return ""
    try:
        data = json.loads(PI_MODELS.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    providers = data.get("providers") if isinstance(data, dict) else None
    entry = providers.get(name) if isinstance(providers, dict) else None
    if isinstance(entry, dict):
        return str(entry.get("baseUrl") or "")
    return ""


def list_models(harness=HARNESS_PI):
    """Список моделей харнесса для выбора в приложении.

    У pi он собирается из его собственного каталога (см. ниже), у Claude Code — из каталога
    его версии: псевдонимы семейств (их он сам разрешает в новейшую доступную версию) и
    конкретные версии, включая 1M-варианты. Список придумывать из документации нельзя: он
    должен совпадать с тем, что знает установленный Claude Code.
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


def remove_session_files(key):
    """Удаляет файлы сессии с диска и возвращает путь файла истории (или `None`).

    Харнесс берётся из идентификатора, потому что хранилищ два. У Claude Code рядом с файлом
    истории лежит папка с тем же именем (результаты инструментов, служебные пометки), а ещё
    отдельно от неё — папка окружения в профиле (`session-env/<id>`): без них удаление
    оставляло мусор, который копился сотнями.

    Проверки «файл вернулся» здесь нет намеренно: она стоит 0.4 секунды ожидания, а уборка
    удаляет сотни сессий. Разбирается с этим вызывающий — один раз, после всей пачки.
    """
    harness, session_id = split_key(key)
    file = find_session_file(harness, session_id)
    if file is None:
        return None
    try:
        file.unlink()
        log("удалил файл сессии %s (%s)" % (file, harness))
        workdir = file.parent / session_id
        if workdir.is_dir():
            shutil.rmtree(workdir, ignore_errors=True)
            log("удалил папку сессии %s" % workdir)
        # Окружение сессии лежит в профиле, а не рядом с журналом, поэтому путь считается по id
        # и удаляется отдельно: у pi такой папки нет, у Claude Code — есть у каждой сессии
        envdir = claude_session_env_dir(session_id) if harness == HARNESS_CLAUDE else None
        if envdir is not None and envdir.is_dir():
            shutil.rmtree(envdir, ignore_errors=True)
            log("удалил окружение сессии %s" % envdir)
    except OSError as e:
        raise PiError("не смог удалить файл сессии %s: %s" % (file, e))
    return file


def last_journal_id(file, tail_bytes=64 * 1024):
    """id последней записи журнала: `parentId` для записи, которую мы дописываем в конец.

    Читается только хвост: журнал бывает в десятки мегабайт, а нужна одна последняя строка.
    Обрывок последней записи (харнесс пишет построчно и может не успеть) пропускается — берём
    предыдущую целую. `None` означает, что id взять неоткуда: запись без родителя харнессы
    примут, а вот угадывать его нельзя.
    """
    try:
        with file.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - tail_bytes))
            data = handle.read()
    except OSError:
        return None
    for line in reversed(data.splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line.decode("utf-8", "replace"))
        except ValueError:
            continue
        if isinstance(entry, dict) and isinstance(entry.get("id"), str):
            return entry["id"]
    return None


def write_session_name(file, harness, session_id, clean):
    """Дописывает имя в журнал сессии: одна строка в конец файла."""
    if harness == HARNESS_CLAUDE:
        entry = {"type": "custom-title", "customTitle": clean, "sessionId": session_id}
    else:
        entry = {
            "type": "session_info",
            "id": uuid.uuid4().hex[:8],
            "parentId": last_journal_id(file),
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + ".000Z",
            "name": clean,
        }
    try:
        with file.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError as e:
        raise PiError("не смог записать имя сессии %s: %s" % (file, e))
    log("переименовал сессию %s (%s): %s" % (file, harness, clean))
    return clean


def clean_session_name(name):
    """Проверяет имя разговора и приводит его к одной строке."""
    # Переводы строк в имени сломали бы разбор журнала: запись — это одна строка
    clean = " ".join(str(name or "").split())
    if not clean:
        raise PiError("пустое имя")
    if len(clean) > MAX_NAME_CHARS:
        raise PiError("имя длиннее %d символов" % MAX_NAME_CHARS)
    return clean


def flush_pending_name(session):
    """Дописывает отложенное имя, как только у сессии появился журнал.

    Имя может прийти раньше первого сообщения — например, разговор заводят из доски
    пул-реквестов и сразу зовут его `repo#123`. Журнала в этот момент ещё нет, поэтому имя
    лежит в памяти сессии и уезжает в файл при первой же возможности.
    """
    if not session or not session.pending_name:
        return
    file = session_file(session)
    if file is None:
        return
    try:
        write_session_name(file, session.harness, session.id, session.pending_name)
    except PiError as e:
        log("отложенное имя не записалось (%s): %s" % (session.key, e))
        return
    session.pending_name = ""


def set_session_name(key, name):
    """Ставит разговору новое имя — записью в его собственный журнал.

    Имя харнессы хранят сами, в журнале сессии, а не в отдельном хранилище моста: у pi это
    запись `session_info`, у Claude Code — `custom-title` (её же пишут его `/rename` и флаг
    `--name`). Пишем одну строку в конец файла и ничего не переписываем: журнал только растёт,
    а живой процесс сессии от этого не сбивается. Оба харнесса читают такие записи по принципу
    «побеждает последняя», поэтому новое имя сразу видно и в приложении, и в `/resume` на маке.

    `parentId` у записи pi — id последней записи журнала: так имя остаётся записью того же
    разговора, а не вторым корнем дерева. Возвращает сохранённое имя.
    """
    harness, session_id = split_key(key)
    clean = clean_session_name(name)
    file = find_session_file(harness, session_id)
    if file is None:
        # Журнала ещё нет — сессию только что открыли и в ней не было ни одного сообщения.
        # Имя не теряем: живая сессия помнит его и запишет сама (см. flush_pending_name).
        live = POOL.maybe(key)
        if live is None:
            raise PiError("сессия не найдена: %s" % key)
        live.pending_name = clean
        log("запомнил имя сессии %s до появления журнала: %s" % (key, clean))
        return clean
    return write_session_name(file, harness, session_id, clean)


def purge_session(key):
    """Удаляет одну сессию и проверяет, не вернул ли файл живой процесс.

    Проверка нужна из-за сессий, которые ведёт кто-то снаружи: у Claude Code так работают
    разговоры, открытые в терминале (`claude -r`) — процесс держит разговор и пишет его журнал
    заново сразу после удаления. Приложение по этому признаку честно говорит «удалить отсюда
    нельзя», вместо того чтобы показывать успех и оставлять разговор в списке.
    """
    file = remove_session_files(key)
    if file is None:
        return {"deleted": False, "restored": False}
    time.sleep(0.4)
    restored = file.exists()
    if restored:
        log("файл %s восстановлен живым процессом: разговор ведётся снаружи" % file)
    return {"deleted": not restored, "restored": restored}


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


class RunUi:
    """Накопленное состояние текущего прогона — то же, что показывает экран приложения.

    Зачем: поток ответа нельзя продолжить с середины. Приложение подключается к идущему
    прогону (вернулось на экран, порвалась связь), а между его снимком истории и подпиской
    терялись дельты — в переписке появлялась дырка, и часть ответа пропадала навсегда.
    Поэтому мост при каждой подписке отдаёт не только будущие события, но и снимок уже
    накопленного: приложение заменяет им хвост ответа, и пропусков не остаётся.

    Разбор событий повторяет клиентский: текст, «размышления», порядок блоков (текст, карточка
    инструмента, снова текст) и вывод инструментов.
    """

    def __init__(self):
        """Заводит пустое состояние прогона."""
        self.reset()

    def reset(self):
        """Начинает прогон с пустого состояния; вызывается перед отправкой сообщения."""
        self.text = ""
        self.reasoning = ""
        self.blocks = []   # порядок кусков ответа и карточек инструментов
        self.tools = {}    # id вызова -> карточка

    def empty(self):
        """Пусто ли накопленное: снимок нужен, только когда агенту уже есть что показать."""
        return not (self.text or self.reasoning or self.blocks)

    def feed(self, events):
        """Добавляет готовые события экрана в накопленное состояние."""
        for event in events:
            kind = event.get("type")
            if kind == "delta":
                text = str(event.get("text") or "")
                self.text += text
                self._block("text", text)
            elif kind == "reasoning":
                text = str(event.get("text") or "")
                self.reasoning += text
                self._block("reasoning", text)
            elif kind == "tool_call":
                self._tool(event, running=True)
            elif kind == "tool_start":
                self._tool(event, running=True)
            elif kind == "tool_update":
                self._tool(event, running=True, keep_args=True)
            elif kind == "tool_end":
                self._tool(event, running=False, keep_args=True)

    def _block(self, kind, text):
        """Дописывает кусок текста в последний блок того же вида или заводит новый.

        Порядок блоков — это порядок работы агента. Если между двумя текстами встала карточка
        инструмента, начинается новый блок: иначе новый текст оказался бы выше карточки и
        разговор читался бы не в том порядке, в каком шёл.
        """
        if not text:
            return
        if self.blocks and self.blocks[-1].get("type") == kind:
            self.blocks[-1]["text"] += text
            return
        self.blocks.append({"type": kind, "text": text})

    def _tool(self, event, running, keep_args=False):
        """Добавляет или обновляет карточку вызова инструмента и ссылку на неё в блоках."""
        call_id = str(event.get("id") or "")
        if not call_id:
            return
        card = self.tools.get(call_id)
        args = event.get("args") if isinstance(event.get("args"), dict) else {}
        if card is None:
            card = {
                "id": call_id,
                "name": str(event.get("name") or ""),
                "args": args,
                "output": "",
                "isError": False,
                "running": running,
            }
            self.tools[call_id] = card
            # Карточка встаёт в блоки на своё место — там, где инструмент вызван по ходу ответа
            self.blocks.append({"type": "tool", "id": call_id})
            return
        if not card["name"] and event.get("name"):
            card["name"] = str(event["name"])
        if args and not keep_args:
            card["args"] = args
        # У прогресса и завершения вывод накопленный целиком, поэтому заменяем, а не дописываем
        if event.get("text"):
            card["output"] = str(event["text"])
        card["isError"] = bool(event.get("isError"))
        card["running"] = running

    def item(self):
        """Снимок накопленного в том же виде, в каком приходит история сессии."""
        return {
            "kind": "assistant",
            "text": self.text,
            "reasoning": self.reasoning,
            "blocks": [dict(block) for block in self.blocks],
            "tools": [dict(card) for card in self.tools.values()],
            "error": "",
        }


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
        # Имя, поставленное до появления журнала: у только что открытой сессии файла ещё нет, а
        # имя харнессы хранят записью в нём. Запись уходит в журнал, как только он появится
        # (см. flush_pending_name), а до тех пор имя отдаётся приложению из памяти.
        self.pending_name = ""
        self.stderr_tail = []       # хвост stderr процесса — попадает в текст ошибки
        self.counters = {"userMessages": 0, "assistantMessages": 0, "toolCalls": 0}
        self.partial_seen = False   # пришли ли частичные куски текущего ответа (у Claude)
        # Текст и идентификатор сообщения, которое агент выполняет прямо сейчас: по ним
        # отсекаются повторные отправки того же вопроса (см. is_duplicate). Снимается на конце
        # прогона. Идентификатор присылает приложение, и он точнее сравнения текста: два
        # осознанно одинаковых сообщения («продолжай», «продолжай») различимы.
        self.current_prompt = None
        self.current_id = ""
        # Накопленное состояние текущего прогона: уходит подписчику снимком, чтобы он не терял
        # куски ответа при подключении к идущей работе (см. RunUi и subscribe).
        self.run_ui = RunUi()
        # Сообщения, присланные пока агент работал: их не отклоняем, а ставим в очередь и
        # отправляем по завершении текущего прогона. Это и есть «общая сессия» между
        # устройствами: телефон дописывает «и поправь тесты», пока мак считает, и это доезжает.
        self.queue = []

    @property
    def key(self):
        """Идентификатор сессии наружу: с именем харнесса, потому что хранилищ два."""
        return session_key(self.harness, self.id)

    def subscribe(self):
        """Подписывает поток SSE и вместе с подпиской отдаёт снимок идущего прогона.

        Очередь и снимок берутся под одним замком: событие попадает либо в снимок (если
        обработано до подписки), либо в очередь (если после) — но не в оба места и не в никуда.
        Без этого между «прочитать состояние ответа» и «подписаться» терялись дельты, и в
        переписке появлялась дырка (см. RunUi).

        Подписка ставится ДО отправки сообщения: события первого шага иначе можно потерять.
        Возвращает пару «очередь событий», «снимок прогона или None».
        """
        events = queue.Queue()
        with self.lock:
            self.subscribers.append(events)
            # Снимок нужен только у идущего прогона: у законченного история есть в /messages
            snapshot = None if (not self.busy or self.run_ui.empty()) else self.run_ui.item()
        return events, snapshot

    def unsubscribe(self, events):
        """Снимает подписку: клиент ушёл или ответ закончился."""
        with self.lock:
            if events in self.subscribers:
                self.subscribers.remove(events)

    def enqueue(self, text, message_id=""):
        """Ставит сообщение в очередь сессии и возвращает его номер в очереди.

        Номер нужен приложению, чтобы показать «в очереди: 2», а не молчать: человек должен
        видеть, что его сообщение принято и ждёт своей очереди. [message_id] присылает
        приложение — по нему повтор узнаётся точно, без сравнения текста.
        """
        self.queue.append({"text": text, "at": time.time(), "id": str(message_id or "")})
        self.touched = time.time()
        log("сессия %s: сообщение поставлено в очередь (%d-е)" % (self.id, len(self.queue)))
        return len(self.queue)

    def start_run(self, text, message_id=""):
        """Запоминает ушедшее агенту сообщение и начинает с чистого снимка прогона.

        Ставится перед записью сообщения в процесс, снимается на завершающем событии прогона
        (см. _finish_run). Отдельным методом, а не внутри prompt наследника: сообщение уходит
        агенту из двух мест (ручка prompt и очередь), и знать про повторы должно каждое.
        """
        self.current_prompt = text
        self.current_id = str(message_id or "")
        self.run_ui.reset()

    def forget_run(self):
        """Снимает отметку о текущем прогоне: его либо закончили, либо он не состоялся.

        Нужна, чтобы отказ отправить сообщение не оставлял сессию «с занятым текстом»: иначе
        следующая попытка того же вопроса считалась бы повтором, хотя агенту ничего не ушло.
        """
        self.current_prompt = None
        self.current_id = ""

    def is_duplicate(self, text, message_id=""):
        if message_id:
            if self.current_id and self.current_id == message_id:
                return True
            if any(item.get("id") == message_id for item in self.queue):
                return True
            if self.current_prompt is not None and self.current_prompt == text:
                return True
            return any(item.get("text") == text for item in self.queue)
        if self.current_prompt is not None and self.current_prompt == text:
            return True
        return any(item.get("text") == text for item in self.queue)

    def queue_position(self, text, message_id=""):
        """Место в очереди у того же сообщения; 0 — оно и есть текущий прогон.

        Нужно ответу ручки queue: приложение показывает «в очереди: N», и для повтора это число
        должно указывать на настоящее место его сообщения, а не на конец очереди. Сообщение
        ищется по идентификатору, а если его нет — по тексту (старая сборка приложения).
        """
        for index, item in enumerate(self.queue, start=1):
            if message_id and item.get("id") == message_id:
                return index
        if message_id:
            return 0
        for index, item in enumerate(self.queue, start=1):
            if item.get("text") == text:
                return index
        return 0

    def _deliver_queued(self):
        """Отправляет следующее сообщение из очереди, если агент уже свободен.

        Вызывается из читателя потока на завершающем событии прогона. Саму отправку делает
        отдельный поток: читатель обязан вернуться к чтению stdout, иначе ответ модели (в том
        числе подтверждение команды) некому будет разобрать и всё встанет.
        """
        if not self.queue:
            return
        item = self.queue.pop(0)
        log("сессия %s: отдаю из очереди (%d осталось)" % (self.id, len(self.queue)))
        # Занятость выставляем здесь же, до запуска потока: иначе наблюдатель успел бы решить,
        # что прогон закончился и новых не будет, и отключился бы ровно перед ответом.
        # Текст прогона отмечаем тоже здесь: между «взял из очереди» и записью в процесс мост
        # успевает принять запрос, и по этому признаку он тоже должен увидеть повтор.
        self.busy = True
        self.start_run(item["text"], item.get("id") or "")
        threading.Thread(target=self._send_queued, args=(item,), daemon=True).start()

    def _send_queued(self, item):
        """Отправляет сообщение из очереди агенту; сбой снимает занятость и виден на экране."""
        try:
            self.prompt(item["text"])
            self._dispatch({
                "type": "queued_started",
                "text": item["text"],
                "queue": len(self.queue),
            })
        except PiError as e:
            self.busy = False
            self.forget_run()
            self._dispatch({
                "type": "error",
                "message": "не смог отправить сообщение из очереди: %s" % e,
            })

    def _dispatch(self, event):
        """Обрабатывает одно событие харнесса: перевод, состояние сессии, рассылка.

        Единственное место, где событие проходит целиком, и вызывается оно только из читателя
        stdout — ровно один раз на событие. Раньше перевод (вместе с накоплением расхода, счёт-
        чиков и признака «частичные куски уже были») делал каждый поток SSE по своему экземпляру
        события: расход умножался на число открытых потоков, а снятая любым из них занятость
        позволяла следующему сообщению уйти в процесс мимо очереди, да ещё и поток закрывался на
        середине начавшегося из очереди прогона. Теперь подписчикам уходят уже готовые события
        экрана: им остаётся только записать их в свой поток, ничего не решая.

        Состояние сессии меняется здесь и в переводе — постольку, поскольку он и занимается
        разбором служебного (расход, счётчики, идентификатор модели).
        """
        translated, done = translate(self, event)
        # Накопление снимка идёт до рассылки: подписчику, который подключится сразу после
        # события, этот кусок должен быть уже виден в снимке, а не потеряться между ними
        self.run_ui.feed(translated)
        if done:
            self._finish_run(event)
        self._publish(translated, done)

    def _finish_run(self, event):
        """Отмечает конец прогона, даже когда за ним никто не смотрит.

        Занятость снимается здесь и только здесь: пока прогон идёт, сессия занята по-настоящему,
        и по этому признаку решается, ставить сообщение в очередь или отдавать его агенту прямо.
        Вызов идёт из читателя потока, поэтому снятие не зависит от того, смотрит ли кто-то на
        ответ: иначе разговор остался бы «занятым» навсегда.
        """
        self.busy = False
        self.forget_run()
        self.touched = time.time()
        log("сессия %s: прогон завершён (%s), в очереди %d" % (
            self.id, event.get("type"), len(self.queue)))
        # Прогон закончился — отдаём агенту то, что прислали, пока он считал
        self._deliver_queued()

    def _publish(self, translated, done=False):
        """Рассылает готовые события экрана всем открытым потокам SSE этой сессии.

        Вместе с событиями уходит и признак «прогон на этом событии закончился»: считать его по
        состоянию сессии (занята или нет) нельзя — состояние меняется в другом потоке, и поток
        приложения успевал увидеть «свободна» раньше, чем мост успевал отдать из очереди
        следующее сообщение.
        """
        # Под тем же замком, что и subscribe: иначе событие могло попасть и в снимок
        # подписчика, и в его очередь сразу — тогда клиент показал бы текст дважды
        with self.lock:
            for q in list(self.subscribers):
                q.put((translated, done))

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
        """Будит всех ожидающих после смерти процесса, чтобы запросы не висели вечно.

        Заодно снимаем занятость: процесс умер, значит прогона больше нет, и оставлять сессию
        «занятой» значило бы отвечать 409 на каждый следующий вопрос без выхода из положения.
        """
        self.busy = False
        self.forget_run()
        for key, q in list(self.pending.items()):
            q.put({"type": "response", "id": key, "success": False, "error": reason})
        self.pending.clear()
        # Подписчикам уходит уже готовое событие экрана: смерть процесса они видят той же
        # ошибкой, что и любую другую, и про внутренний «fatal» знать не должны.
        for q in list(self.subscribers):
            q.put(([{"type": "error", "message": reason}], True))

    def alive(self):
        """Жив ли процесс."""
        return self.proc is not None and self.proc.poll() is None

    def _restart(self):
        """Поднимает процесс заново, продолжая ту же сессию (он мог умереть или быть погашен).

        Продолжение идёт по идентификатору сессии: у pi это `--session-id`, у Claude Code —
        `--resume`, и оба берут историю из своего файла, так что разговор не теряется.
        """
        self.busy = False
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
        if session_id and not self.provider and not self.model:
            # Процесс поднимается заново (остановка по простою, перезапуск моста, обрыв туннеля),
            # и модель берётся не из общего умолчания, а из выбора этой сессии: сначала из памяти
            # моста, затем из её журнала. Иначе разговор молча съезжал на первого провайдера
            # models.json — а им идёт `local`.
            key = session_key(self.harness, session_id)
            remembered = session_choice(key)
            self.provider = str(remembered.get("provider") or "")
            self.model = str(remembered.get("model") or "")
            provider = self.provider or provider
            model = self.model or model
            if not self.provider and not self.model:
                provider, model = journal_model(self.harness, session_id) or (provider, model)
                self.provider, self.model = provider, model
            if self.provider or self.model:
                log("сессия %s: поднимаю с прежней моделью %s/%s" % (
                    session_id, self.provider or "?", self.model or "?"))
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
                # Своя сессия процесса: `launchctl kickstart -k` (перезапуск моста) гасит мост
                # вместе с его группой процессов, и без этого флага туда попадают живые сессии —
                # ответ агента обрывался прямо посреди работы. Отделившись, pi перезапуск
                # переживает и завершается сам: stdin закрывается, а RPC-режим на конце ввода
                # гасит себя штатно, дописав состояние сессии.
                start_new_session=True,
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
                self._dispatch(message)

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
        # Запоминаем на диске: у pi смена модели живёт только в живом процессе, а после подъёма
        # заново он взял бы умолчание. Это и есть источник выбора для [_start].
        self.provider, self.model = provider, model
        remember_session_choice(session_key(self.harness, self.id), provider=provider, model=model)

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

    def __init__(self, cwd, session_id=None, model=None, effort=None):
        """Поднимает процесс Claude Code в папке [cwd], продолжая сессию [session_id].

        Идентификатор новой сессии задаём сами (`--session-id`): свой Claude Code сообщает
        только вместе с первым ответом, а он нужен сразу — иначе приложение не смогло бы ни
        запомнить разговор, ни показать его в списке сессий. Продолжение идёт через `--resume`
        с тем же идентификатором.

        [effort] — уровень усилия (`--effort`); пусто означает «как решает Claude Code». Свой
        у модели он разный, поэтому пустое значение — это именно отказ от выбора, а не средний
        уровень; проверяем его здесь, чтобы опечатка не превращалась молча в умолчание.
        `None` — «про выбор ничего не сказали»: берётся уровень из настроек моста — так его не
        теряет сессия, поднятая заново без участия приложения (см. [remember_claude_effort]).
        """
        super().__init__(cwd, model=model)
        self.id = session_id or str(uuid.uuid4())
        # Модель и усилие поднятой заново сессии берутся из памяти моста: в отличие от pi,
        # Claude Code не пишет `model_change` в журнал в том же виде, поэтому второго источника
        # (журнала) здесь нет — без этой памяти выбор человека терялся бы при каждом перезапуске
        # процесса (смена модели/усилия, простой, перезапуск моста).
        remembered = session_choice(session_key(self.harness, self.id))
        if not self.model:
            self.model = str(remembered.get("model") or "")
        if effort is None:
            # Пустое значение в памяти — это именно отказ от выбора, поэтому через `or` его
            # подменять нельзя: различаем «не знаем» (`None`) и «знаем, что пусто» (`""`).
            stored = remembered.get("effort")
            effort = stored if isinstance(stored, str) else CONFIG.get("claude_effort")
        effort = str(effort or "").strip()
        if effort and effort not in claude_effort_ids():
            raise PiError("неизвестный уровень усилия: %s" % effort)
        #: Уровень усилия этой сессии; задаётся при запуске и меняется перезапуском процесса
        self.effort = effort
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
        if self.effort:
            # Уровень усилия: без него Claude Code берёт умолчание модели (у каждой своё),
            # поэтому пустой выбор — это именно «пусть решает сам»
            cmd += ["--effort", self.effort]

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
                # Причина та же, что у pi выше: перезапуск моста не должен убивать идущий ответ.
                start_new_session=True,
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
            self._dispatch(event)

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
        Уровень усилия при этом остаётся прежним.
        """
        self.model = model
        remember_session_choice(session_key(self.harness, self.id), model=model)
        self.stop()
        self._start(self.id)

    def set_effort(self, effort):
        """Меняет уровень усилия: как и модель, он задаётся при запуске, поэтому процесс перезапускается.

        Разговор продолжается из файла (`--resume`) — тот же путь, что и у смены модели:
        теряется только прогрев промпта, а история, инструменты и контекст остаются.
        """
        effort = str(effort or "").strip()
        if effort and effort not in claude_effort_ids():
            raise PiError("неизвестный уровень усилия: %s" % effort)
        self.effort = effort
        remember_claude_effort(effort)
        remember_session_choice(session_key(self.harness, self.id), effort=effort)
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
            # Уровень усилия показываем как есть: пусто — «умолчание Claude Code», и врать
            # конкретным уровнем, которого человек не выбирал, нельзя
            "effort": self.effort,
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


def _session_brief(session):
    """Возвращает снимок сессии для экрана в формате JSON.

    Минимальный набор полей, который понимает клиентский AgentSessionInfo:
    id, busy, contextPercent, contextTokens, contextWindow, model, modelName,
    provider, messages, cost, tokens и т.д.
    """
    state = session.state if isinstance(session.state, dict) else {}
    model = state.get("model") if isinstance(state.get("model"), dict) else {}
    context = state.get("contextUsage") if isinstance(state.get("contextUsage"), dict) else {}
    tokens = state.get("tokens") if isinstance(state.get("tokens"), dict) else {}
    meta = session.start_meta or {}
    context_estimated = bool(context.get("estimated")) if isinstance(context, dict) else False
    return {
        "id": session.key,
        "harness": session.harness,
        "harnessName": HARNESS_NAMES.get(session.harness, session.harness),
        "contextEstimated": context_estimated,
        "path": session.cwd,
        "name": str(
            session.pending_name or state.get("sessionName") or meta.get("name") or ""
        ),
        "model": str(model.get("id") or ""),
        "modelName": str(model.get("name") or ""),
        "provider": str(model.get("provider") or ""),
        "local": is_local_model(model),
        "thinkingLevel": str(state.get("thinkingLevel") or ""),
        "effort": str(state.get("effort") or ""),
        "busy": session.busy,
        "messages": int(state.get("messageCount") or 0),
        "contextTokens": context.get("tokens"),
        "contextWindow": context.get("contextWindow"),
        "contextPercent": context.get("percent", 0),
        "tokensInput": tokens.get("input") or 0,
        "tokensOutput": tokens.get("output") or 0,
        "tokensCacheRead": tokens.get("cacheRead") or 0,
        "tokensTotal": tokens.get("totalTokens") or tokens.get("total") or 0,
        "cost": float(state.get("cost") or 0),
        "userMessages": int(state.get("userMessages") or 0),
        "assistantMessages": int(state.get("assistantMessages") or 0),
        "toolCalls": int(state.get("toolCalls") or 0),
        "startedAt": state.get("startedAt"),
        "updatedAt": session.touched,
        "sessionFile": str(session_file(session)) if session_file(session) else "",
    }


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
        # полностью устоявшийся прогон: ни ретраев, ни очереди продолжений.
        # Возвращаем `done` с текущим снимком сессии, чтобы клиент обновил
        # busy, контекст-процент и другие поля.
        session.busy = False
        session.touched = time.time()
        # Минимальный снимок сессии: обновляем состояние перед отдачей.
        try:
            session.state = session.refresh_state()
        except Exception as e:
            log("не смог обновить состояние сессии %s: %s" % (session.id, e))
        return [{"type": "done", "session": _session_brief(session)}], True

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
    """Переводит событие харнесса в события экрана (см. переводы выше).

    В том же потоке идут и наши собственные сообщения — о очереди, о простое, о сбое процесса.
    Их пропускаем насквозь: переводить там нечего, а потерять их нельзя — приложение по ним
    показывает «в очереди: 2» и снимает эту подпись, когда сообщение ушло агенту.
    """
    kind = event.get("type")
    if kind in OWN_EVENTS:
        # Наши собственные сообщения (очередь, простой) переводить нечего, но терять их нельзя:
        # по ним приложение показывает «в очереди: N». Наш отказ («не смог отправить сообщение
        # из очереди») — это ещё и конец прогона: продолжения не будет.
        return [event], kind == "error"
    if kind == "fatal":
        # Процесс харнесса умер: для экрана это ошибка и конец прогона, чем бы он ни был занят
        return [{"type": "error", "message": str(event.get("message") or "сбой харнесса")}], True
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

    def open(self, cwd, harness=HARNESS_PI, session_id=None, provider=None, model=None, effort=None):
        """Отдаёт сессию в папке [cwd], поднимая процесс нужного харнесса, если его ещё нет.

        Занятая сессия не переоткрывается: два клиента в одной сессии — это два писателя в один
        файл истории, и разговор бы разъехался. Проверка «занято» живёт в ручке prompt, здесь же
        важно не потерять уже поднятый процесс.

        [model] и [effort] — выбор для запускаемой сессии: у pi это пара «провайдер/модель», у
        Claude Code — модель и уровень усилия.
        """
        key = session_key(harness, session_id) if session_id else ""
        with self.lock:
            if key and key in self.sessions:
                session = self.sessions[key]
                if not session.alive():
                    session._restart()
                session.touched = time.time()
                return session

            if harness == HARNESS_CLAUDE:
                session = ClaudeSession(cwd, session_id, model=model, effort=effort)
            else:
                session = PiSession(cwd, session_id, model=model, provider=provider)
            if not session.id:
                detail = session.stderr_tail[-1] if session.stderr_tail else "без вывода"
                session.stop()
                raise PiError("%s не сообщил идентификатор сессии (%s)" % (harness, detail))
            # Запоминаем выбор на диске: приложение присылает его только для новой сессии, и без
            # этой памяти поднятый заново процесс (простой, перезапуск моста) взял бы модель по
            # умолчанию. У pi и Claude Code запись идёт после запуска, когда уже известен id.
            remember_session_choice(
                session.key,
                provider=provider,
                model=model,
                effort=session.effort if harness == HARNESS_CLAUDE else None,
            )
            # если такой процесс уже был под другим ключом — закрываем дубль
            existing = self.sessions.get(session.key)
            if existing is not None and existing is not session:
                session.stop()
                existing.touched = time.time()
                return existing
            self.sessions[session.key] = session
            return session

    def maybe(self, key):
        """Живая сессия по ключу или `None`; идентификатор без имени харнесса считается pi.

        Имя харнесса в идентификаторе появилось вместе со вторым агентом, и сборка приложения,
        которая про него не знает, присылает прежний вид (`<id>` без префикса). Такой запрос
        относится к pi — и раньше, когда агент был один, это было ровно то же самое.
        """
        keys = [str(key)]
        if not any(str(key).startswith(h + "--") for h in HARNESS_NAMES):
            keys.append(session_key(HARNESS_PI, key))
        with self.lock:
            session = next((self.sessions[k] for k in keys if k in self.sessions), None)
        if session is not None and not session.alive():
            session._restart()
        return session

    def find(self, key):
        """Находит живую сессию по ключу или бросает понятную ошибку."""
        session = self.maybe(key)
        if session is None:
            raise PiError("сессия не открыта: сначала откройте её в приложении")
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


class DeltaBundle:
    """Копит куски текста ответа и отдаёт их одним событием.

    Зачем: модель печатает по слову, и каждое слово уходило отдельным кадром SSE, отдельным
    TCP-сегментом через reverse-SSH туннель и отдельным разбором в приложении. Склейка за 80 мс
    сокращает и трафик, и число пробуждений экрана, не меняя порядка: перед любым не-текстовым
    событием (карточка инструмента, конец прогона) пачка отдаётся вперёд него.
    """

    def __init__(self):
        """Заводит пустую пачку."""
        self.reset()

    def reset(self):
        """Очищает пачку и снимает срок ближайшей отправки."""
        self.text = ""
        self.reasoning = ""
        self.due = 0.0

    def feed(self, translated):
        """Раскладывает события на текстовые (в пачку) и остальные (их отдают сразу).

        Возвращает события, которые обязаны уйти не вместе с пачкой, а в своём месте: карточка
        инструмента между двумя кусками текста задаёт порядок ответа, и текст из-за неё не должен
        оказаться выше или ниже, чем он был у харнесса.
        """
        rest = []
        for event in translated:
            kind = event.get("type")
            if kind == "delta":
                self.text += str(event.get("text") or "")
            elif kind == "reasoning":
                self.reasoning += str(event.get("text") or "")
            else:
                rest.append(event)
        if (self.text or self.reasoning) and not self.due:
            self.due = time.time() + DELTA_FLUSH_SECONDS
        return rest

    def due_now(self):
        """Пора ли отдавать накопленное: пачка не пуста и срок вышел."""
        return bool((self.text or self.reasoning) and time.time() >= self.due)

    def take(self):
        """Забирает накопленное событиями экрана в исходном порядке."""
        events = []
        if self.text:
            events.append({"type": "delta", "text": self.text})
        if self.reasoning:
            events.append({"type": "reasoning", "text": self.reasoning})
        self.reset()
        return events


# Кэш списка разговоров: список пересчитывается обходом истории на маке (stat по каждому файлу
# сессии), а приложение спрашивает его регулярно и не одним экраном. Пяти секунд хватает, чтобы
# несколько запросов подряд получили один и тот же ответ; инвалидировать вручную не нужно —
# список приходит из файлов, и его свежесть задаётся этим сроком.
_sessions_cache = {}
_sessions_cache_lock = threading.Lock()


def cached_sessions(key, build):
    now = time.time()
    with _sessions_cache_lock:
        entry = _sessions_cache.get(key)
        if entry is not None and now - entry[0] < SESSIONS_CACHE_SECONDS:
            return entry[1]
    value = build()
    with _sessions_cache_lock:
        _sessions_cache[key] = (now, value)
        while len(_sessions_cache) > 32:
            oldest = min(_sessions_cache, key=lambda k: _sessions_cache[k][0])
            del _sessions_cache[oldest]
    return value


def page_items(items, params):
    """Отдаёт последние [limit] элементов истории до индекса [before].

    Приложение открывает разговор с конца: у длинной сессии история — это мегабайты JSON по
    туннелю, и тянуть её целиком при каждом открытии незачем. `before` — индекс в полной истории
    (не включая): по нему запрашивается предыдущая страница, без него пагинация «вверх» была бы
    невозможна. Без `limit` отдаётся всё — так работает сборка приложения, которая о страницах
    ещё не знает.

    Отвечает `items`, `total` (сколько всего сообщений) и `hasMore` (есть ли что-то выше).
    """
    total = len(items)
    before = max(0, min(_int_param(params, "before", total), total))
    limit = _int_param(params, "limit", 0)
    start = max(0, before - limit) if limit > 0 else 0
    window = items[start:before]
    return {"items": window, "total": total, "hasMore": start > 0}


def _int_param(params, name, default):
    """Целое из параметров строки запроса; [default] — если параметра нет или он не число."""
    raw = (params.get(name) or [""])[0]
    try:
        return int(str(raw).strip())
    except (TypeError, ValueError):
        return default


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
        концов туннеля. Поле нужно на случай, если мост
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
        """Читает тело запроса как JSON-объект (пустое тело — пустой объект).

        Потолок размера проверяется по `Content-Length` до чтения: сообщение человеку отдаёт
        ручка, а тело в сотни мегабайт успело бы занять память раньше, чем сработала бы
        проверка длины текста.
        """
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY_BYTES:
            raise PiError("тело запроса больше %d МБ" % (MAX_BODY_BYTES // (1024 * 1024)))
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
                self._json(200, {"projects": list_projects_cached()})
            elif path == "/harnesses":
                self._json(200, {"harnesses": harness_status()})
            elif path == "/models":
                harness = str((params.get("harness") or [HARNESS_PI])[0]).strip().lower() or HARNESS_PI
                # Уровни усилия есть только у Claude Code: у pi размышления задаются уровнем
                # самой модели, и отдельного выбора к ней не прилагается
                self._json(200, {
                    "models": list_models(harness),
                    "harness": harness,
                    "efforts": CLAUDE_EFFORTS if harness == HARNESS_CLAUDE else [],
                })
            elif path == "/providers":
                self._json(200, {"providers": provider_list()})
            elif path == "/sessions":
                self._list_sessions(params)
            elif path.startswith("/sessions/"):
                parts = path.split("/")
                # Историю отдаём и без живого процесса: чтение разговора не должно требовать,
                # чтобы агент был запущен (процесс гасится по простою, мост перезапускается).
                session = POOL.maybe(parts[2])
                if len(parts) == 4 and parts[3] == "messages":
                    # Историю отдаём страницей: последние [limit] сообщений до индекса [before]
                    if session is not None:
                        brief = self._session_brief(session)
                        items = session.messages()
                    else:
                        harness, native_id = split_key(parts[2])
                        file = find_session_file(harness, native_id)
                        if file is None:
                            raise PiError("сессия не найдена: %s" % parts[2])
                        brief = self._file_brief(harness, native_id, file)
                        items = read_file_messages(harness, file)
                    self._json(200, {"session": brief, **page_items(items, params)})
                elif len(parts) == 4 and parts[3] == "events":
                    if session is None:
                        raise PiError("сессия не открыта: подключиться к её ответу нельзя")
                    self._events(session)
                elif len(parts) == 3:
                    if session is not None:
                        session.refresh_state()
                        self._json(200, {"session": self._session_brief(session)})
                    else:
                        harness, native_id = split_key(parts[2])
                        file = find_session_file(harness, native_id)
                        if file is None:
                            raise PiError("сессия не найдена: %s" % parts[2])
                        self._json(200, {"session": self._file_brief(harness, native_id, file)})
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
                # Остановка обрабатывается до поиска в пуле: это уборка, и повторять её на уже
                # закрытой сессии не ошибка. Раньше «Стоп» на такой сессии отвечал 400, и
                # человек видел ошибку там, где всё в порядке.
                if action == "queue":
                    # Сообщение в занятую сессию: не отказ, а очередь. Приложение шлёт сюда, когда
                    # у него уже открыт поток текущего прогона: второй поток дал бы двойной текст.
                    text = str(body.get("text") or "").strip()
                    message_id = str(body.get("id") or "").strip()
                    if not text:
                        raise PiError("пустое сообщение")
                    if len(text) > MAX_MESSAGE_CHARS:
                        raise PiError("сообщение длиннее %d символов" % MAX_MESSAGE_CHARS)
                    session = POOL.maybe(parts[2]) or self._reopen(parts[2])
                    if session is None:
                        raise PiError("сессия не открыта: сначала откройте её в приложении")
                    if not session.busy and not session.queue:
                        # Сессия успела освободиться, пока приложение решало, куда слать: очередь
                        # не нужна. Отвечаем именно так, а не принимаем молча — иначе сообщение
                        # потерялось бы: приложение по этому ответу отправляет его обычным
                        # вопросом (ручка prompt), и там оно уходит агенту.
                        self._json(200, {"queued": False, "position": 0})
                        return
                    if session.is_duplicate(text, message_id):
                        # Такое же сообщение уже в работе или в очереди: второй раз не кладём, а
                        # говорим об этом прямо. Место считаем по тому же сообщению: подпись
                        # «в очереди: N» на экране должна указывать на настоящее место.
                        log("сессия %s: повтор того же сообщения — в очередь не ставлю" % session.id)
                        self._json(200, {
                            "queued": True,
                            "duplicate": True,
                            "position": session.queue_position(text, message_id),
                        })
                        return
                    self._json(200, {"queued": True, "position": session.enqueue(text, message_id)})
                    return
                # Переименование обрабатывается до поиска в пуле: имя лежит в журнале сессии, а не
                # в процессе, и переименовать можно в том числе закрытый разговор
                if action == "name":
                    self._json(200, {"name": set_session_name(parts[2], body.get("name"))})
                    return
                if action == "abort":
                    session = POOL.maybe(parts[2])
                    if session is None:
                        self._json(200, {"ok": True, "aborted": False})
                        return
                    session.abort()
                    self._json(200, {"ok": True, "aborted": True})
                    return
                # Сессия могла быть потеряна мостом (перезапуск, простой) — тогда поднимаем её
                # заново из файла: приложение в этот момент просто продолжает разговор, и
                # отказывать ему в этом незачем.
                session = POOL.maybe(parts[2])
                if session is None and action == "prompt":
                    session = self._reopen(parts[2])
                if session is None:
                    session = POOL.find(parts[2])
                if action == "prompt":
                    self._prompt(session, body)
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
                elif action == "effort":
                    # Уровень усилия есть только у Claude Code: у pi «размышления» — свойство
                    # модели, и отдельного выбора к ней не прилагается
                    if session.harness != HARNESS_CLAUDE:
                        raise PiError("уровень усилия есть только у Claude Code")
                    # Пустая строка — вернуться к умолчанию модели: это осмысленный выбор, и
                    # отказывать в нём нельзя
                    session.set_effort(str(body.get("effort") or ""))
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
        подтверждением.
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
                outcome = purge_session(parts[2])
                self._json(200, {
                    "ok": True,
                    # счётчики, а не флаги: у уборки их тоже два, и приложению проще читать
                    # одинаковый ответ у обеих ручек
                    "deleted": 1 if outcome["deleted"] else 0,
                    # 1 — файл вернул живой процесс: разговор ведётся снаружи
                    # (открыт в терминале), и удалить его отсюда нельзя
                    "restored": 1 if outcome["restored"] else 0,
                })
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
        """Сессии из файлов истории: одной папки или сразу всех проектов.

        Работают и когда процессы не подняты: список читается прямо из файлов. Без `path`
        отдаются сессии всех проектов — приложению нужен один общий список разговоров, и
        обходить папки по одной снаружи значило бы делать десятки запросов на каждое
        обновление. Харнесс задаёт вызывающий (`harness=pi|claude`), а без него отдаются оба
        списка с пометкой, чей это разговор: приложение показывает их вместе, различая по значку.
        """
        raw = (params.get("path") or [""])[0]
        asked = str((params.get("harness") or [""])[0]).strip()

        if raw:
            path = allowed_path(raw)
            if path is None:
                raise PiError("папка вне разрешённых корней: %s" % raw)
            folders = [path]
        else:
            # Список папок — из короткого кэша: эта ветка и есть частый запрос списка разговоров,
            # и обход истории на маке здесь нужен только чтобы узнать, какие папки показывать.
            folders = [Path(str(p["path"])) for p in list_projects_cached()]

        sessions = cached_sessions((tuple(str(f) for f in folders), asked), lambda: self._build_sessions(folders, asked))
        self._json(200, {"path": str(folders[0]) if raw else "", "sessions": sessions})

    def _build_sessions(self, folders, asked):
        """Собирает список разговоров по папкам — та работа, которую кэширует [_list_sessions].

        Отдельным методом, а не телом выше: кэш должен хранить готовый ответ, а не повторять
        обход истории и `stat` по каждому файлу на каждый запрос приложения.
        """
        sessions = []
        for folder in folders:
            if asked in ("", HARNESS_PI):
                for file in session_files(folder):
                    # `path` — рабочая папка разговора: без неё строка общего списка не знает,
                    # в каком проекте открывать сессию
                    sessions.append({**cached_meta(file, read_session_meta), "harness": HARNESS_PI, "path": str(folder)})
            if asked in ("", HARNESS_CLAUDE):
                for file in claude_session_files(folder):
                    sessions.append({**cached_meta(file, read_claude_meta), "harness": HARNESS_CLAUDE, "path": str(folder)})
        # по дате создания, новые сверху: два списка складываются в один, и порядок в нём не
        # должен меняться от того, что в каком-то разговоре только что что-то произошло — иначе
        # строки прыгали бы под пальцем. Что разговор жив, видно по значку работы
        sessions.sort(key=lambda s: s.get("startedAt") or "", reverse=True)
        for session in sessions:
            session["id"] = session_key(session["harness"], session["id"])
            # Сессия может работать прямо сейчас (агент продолжает и без наблюдателя): в списке
            # это видно значком, иначе кажется, что разговор стоит
            running = POOL.maybe(session["id"])
            session["busy"] = bool(running and running.busy)
        return sessions

    def _open_session(self, body):
        """Открывает сессию в выбранной папке (или продолжает существующую по id).

        Провайдер и модель можно задать здесь же: у pi моделей бывает несколько (локальная и
        удалённая по API), и для новой сессии выбор делается в момент открытия — потом его
        меняет ручка `model`, не перезапуская разговор. У Claude Code здесь же принимается
        `effort`: он не записывается в файл разговора, поэтому приложение шлёт его и для уже
        существующей сессии — иначе возобновлённый процесс взял бы умолчание модели.
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
        effort = str(body.get("effort") or "").strip() or None
        # Выбор усилия помним в настройках моста: он не лежит в файле разговора, а процесс
        # может быть поднят заново уже без приложения (см. remember_claude_effort)
        if harness == HARNESS_CLAUDE and effort is not None:
            remember_claude_effort(effort)
        session = POOL.open(path, harness, session_id, provider=provider, model=model, effort=effort)
        session.refresh_state()
        self._json(200, {"session": self._session_brief(session)})

    def _reopen(self, key):
        """Поднимает сессию из её файла, если мост её потерял; иначе `None`.

        Рабочий каталог берётся из самой истории, поэтому человеку не нужно ничего открывать
        заново: он продолжает разговор, а процесс агента поднимается под ним.
        """
        harness, native_id = split_key(key)
        cwd = session_cwd(harness, native_id)
        if not cwd:
            return None
        path = allowed_path(cwd)
        if path is None:
            raise PiError("сессия открыта в папке вне разрешённых корней: %s" % cwd)
        log("поднимаю потерянную сессию %s заново в %s" % (key, path))
        return POOL.open(path, harness, native_id)

    def _session_brief(self, session):
        """Описание сессии для экрана: модель, контекст, расход, счётчики и время.

        Всё берётся из одного снимка состояния (`get_state` + `get_session_stats`), который
        обновляется перед отдачей: приложение показывает этими числами, сколько окна модели
        занято и не пора ли сжимать разговор, а по времени видно, как долго идёт работа.

        `local` — признак того, что модель считает на этом маке, а не по API: по нему
        приложение подписывает сессию, чтобы удалённая модель не выглядела как локальная.
        """
        # Журнал мог появиться с последнего обращения: тогда отложенное имя уезжает в него
        flush_pending_name(session)
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
            # имя: у живого pi оно в состоянии, а если человек его не задавал, падает на
            # имя/заголовок из файла сессии — иначе шапка показывала бы папку вместо разговора
            "name": str(
                session.pending_name or state.get("sessionName") or meta.get("name") or ""
            ),
            "model": str(model.get("id") or ""),
            "modelName": str(model.get("name") or ""),
            "provider": str(model.get("provider") or ""),
            "local": is_local_model(model),
            "thinkingLevel": str(state.get("thinkingLevel") or ""),
            # Уровень усилия: только у Claude Code; пусто — «умолчание модели»
            "effort": str(state.get("effort") or ""),
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

    def _file_brief(self, harness, native_id, file):
        """Описание сессии по её файлу: для закрытой сессии, когда процессов нет.

        Числа контекста и расхода здесь отсутствуют намеренно: их знает только живой агент, а
        придумывать нули значило бы показывать «контекст 0» как факт. Остальное — имя, модель,
        время, счётчики — лежит в файле и отдаётся как есть.
        """
        reader = read_claude_meta if harness == HARNESS_CLAUDE else read_session_meta
        meta = reader(file)
        provider_name = str(meta.get("provider") or "")
        return {
            "id": session_key(harness, native_id),
            "harness": harness,
            "harnessName": HARNESS_NAMES.get(harness, harness),
            "contextEstimated": harness == HARNESS_CLAUDE,
            "path": str(meta.get("cwd") or ""),
            "name": str(meta.get("name") or ""),
            "model": str(meta.get("model") or ""),
            "modelName": str(meta.get("model") or ""),
            "provider": str(meta.get("provider") or ""),
            "local": harness != HARNESS_CLAUDE and is_local_model(
                {"provider": provider_name, "baseUrl": provider_base_url(provider_name)}
            ),
            "thinkingLevel": "",
            "busy": False,
            "messages": int(meta.get("messages") or 0),
            "contextTokens": None,
            "contextWindow": None,
            "contextPercent": 0,
            "tokens": {"input": 0, "output": 0, "cacheRead": 0, "total": 0},
            "cost": 0,
            "userMessages": int(meta.get("userMessages") or 0),
            "assistantMessages": int(meta.get("assistantMessages") or 0),
            "toolCalls": int(meta.get("toolCalls") or 0),
            "startedAt": meta.get("startedAt"),
            "updatedAt": meta.get("updatedAt"),
            "sessionFile": str(file),
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

    def _events(self, session, queued=0, duplicate=False):
        """Отдаёт поток событий идущего прогона, ничего агенту не отправляя.

        [queued] — номер в очереди, если этим же запросом человек дописал сообщение в занятую
        сессию: приложение показывает «в очереди: N», а дальше видит и текущий ответ, и ответ
        на своё сообщение — поток не закрывается между прогонами, пока очередь не опустеет.

        [duplicate] — сообщение уже выполняется или стоит в очереди, второй раз агенту оно не
        уходит. Приложение видит событие `duplicate` и показывает, что повтор не отправлен: без
        него отправка выглядела бы принятой, а ответ пришёл бы не на неё.

        Зачем ручка нужна и без очереди: приложение подключается к разговору, который идёт (его
        начали с другого устройства, или экран открыли заново во время работы). Без неё оставался
        только отказ «сессия занята», и человек видел ошибку вместо ответа, который в этот момент
        писался. Здесь мы просто смотрим со стороны: разрыв соединения работу НЕ прерывает — за
        это отвечает ручка `prompt`, у которой своя семантика.
        """
        # Подписка и снимок берутся одним действием и до решения «свободна»: иначе между
        # проверкой занятости и подпиской прогон мог завершиться, его `done` ушёл бы в пустоту,
        # и поток остался бы открытым до смерти процесса — приложение вечно показывало бы работу
        events, snapshot = session.subscribe()
        if not session.busy and not queued and snapshot is None:
            # Свободна и снимка нет: говорить нечего, и держать поток открытым значило бы
            # показывать вечную загрузку. Приложение по этому событию остаётся в обычном состоянии.
            session.unsubscribe(events)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            self._event({"type": "idle"})
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache, no-transform")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self._event({"type": "accepted"})
            if duplicate:
                self._event({"type": "duplicate"})
            if queued:
                self._event({"type": "queued", "position": queued})
            # Снимок идущего прогона: приложение заменяет им хвост ответа, поэтому кусок,
            # напечатанный между его снимком истории и подпиской, больше не теряется
            if snapshot is not None:
                self._event({"type": "snapshot", "item": snapshot})
            bundle = DeltaBundle()
            silent_since = time.time()
            while True:
                # Пачка отдаётся не реже, чем раз в EVENT_TICK, даже если поток не прерывается:
                # иначе при непрерывном выводе она росла бы до первой паузы
                if bundle.due_now():
                    self._send_bundle(bundle)
                    silent_since = time.time()
                try:
                    translated, done = events.get(timeout=EVENT_TICK)
                except queue.Empty:
                    if not session.alive():
                        self._event({"type": "error", "message": "процесс %s завершился" % session.harness})
                        break
                    # Пока агент молчит (модель думает, инструмент работает), шлём событие-пульс:
                    # без трафика мобильный NAT и промежуточные прокси рвут соединение молча, и
                    # приложение не отличает такую смерть от долгой работы. Пульс идёт обычным
                    # событием, а не комментарием SSE: по нему приложение видит, что связь жива,
                    # и не считает молчание обрывом (см. сторож в agent_controller.dart).
                    if time.time() - silent_since >= HEARTBEAT_SECONDS:
                        silent_since = time.time()
                        self._event({"type": "ping"})
                    continue
                rest = bundle.feed(translated)
                if rest:
                    # Порядок: накопленный текст уходит до карточки инструмента, иначе новый
                    # текст оказался бы выше неё и разговор читался бы не по порядку
                    self._send_bundle(bundle)
                    for ours in rest:
                        self._event(ours)
                    silent_since = time.time()
                if done:
                    self._send_bundle(bundle)
                    self._event({"type": "done", "session": self._settled_brief(session)})
                    silent_since = time.time()
                    # Есть очередь — прогон начнётся сразу после этого (занятость уже поднята в
                    # _deliver_queued): закрывать поток значило бы заставить приложение
                    # переподключаться к следующему ответу. Закрываем, только когда работы нет.
                    if not (session.busy or session.queue):
                        log("наблюдатель сессии %s отключён: прогон завершён, очередь пуста" % session.id)
                        break
        except (BrokenPipeError, ConnectionResetError):
            pass  # смотрящий ушёл: прогон продолжается, это его дело
        finally:
            session.unsubscribe(events)

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
        # Идентификатор сообщения от приложения: по нему повтор узнаётся точно, без сравнения
        # текста. Пустой — старая сборка приложения, тогда работает прежнее сравнение
        message_id = str(body.get("id") or "").strip()
        if not text:
            raise PiError("пустое сообщение")
        if len(text) > MAX_MESSAGE_CHARS:
            raise PiError("сообщение длиннее %d символов" % MAX_MESSAGE_CHARS)
        if session.is_duplicate(text, message_id):
            # Такое же сообщение уже выполняется или ждёт очереди — второй прогон не запускаем, а
            # подключаем приложение к идущему. Раньше повтор принимался и отрабатывался целиком:
            # после обрыва связи приложение шло в эту ручку снова и снова, и один и тот же
            # вопрос прогонялся несколько раз.
            log("сессия %s: повтор того же сообщения — прогон не запускаю" % session.id)
            # Место в очереди передаём вместе с повтором: если такое же сообщение там уже стоит,
            # приложение показывает его настоящее место, а не молчит про очередь.
            self._events(session, queued=session.queue_position(text, message_id), duplicate=True)
            return
        if session.busy:
            # Занятую сессию больше не отклоняем: сообщение встаёт в очередь, а этот поток
            # показывает, что происходит сейчас, и продолжается, когда дойдёт до очереди.
            self._events(session, queued=session.enqueue(text, message_id))
            return

        # Подписка и снимок — одним действием: отказ принять сообщение виден событием, а
        # подключившийся поток не теряет ни одного события между снимком и подпиской
        events, _ = session.subscribe()
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

        try:
            # подписка стоит ДО отправки сообщения: события первого шага иначе можно потерять
            try:
                # Текст прогона отмечаем до записи в процесс: между отметкой и записью мост может
                # принять ещё один такой же вопрос, и он должен быть виден как повтор
                session.start_run(text, message_id)
                session.prompt(text)
            except PiError as e:
                # Заголовки потока уже отправлены, поэтому ответить кодом нельзя — отказ
                # уходит событием. Так приходит, например, отказ харнесса принять второй вопрос
                # в занятую сессию, если её занял кто-то помимо моста. Занятость при этом
                # снимаем: без этого сессия осталась бы «занятой» навсегда, и каждый следующий
                # вопрос уходил бы в очередь, которую никто не разбирает.
                session.forget_run()
                session.busy = False
                self._event({"type": "error", "message": str(e)})
                return
            self._event({"type": "accepted"})
            bundle = DeltaBundle()
            silent_since = time.time()
            while True:
                # Пачка отдаётся не реже, чем раз в EVENT_TICK (см. пояснение в _events)
                if bundle.due_now():
                    self._send_bundle(bundle)
                    silent_since = time.time()
                try:
                    translated, done = events.get(timeout=EVENT_TICK)
                except queue.Empty:
                    # пустой такт — проверка, жив ли ещё процесс; заодно держим соединение
                    # живым пульсом (см. _events)
                    if not session.alive():
                        self._event({"type": "error", "message": "процесс %s завершился" % session.harness})
                        break
                    if time.time() - silent_since >= HEARTBEAT_SECONDS:
                        silent_since = time.time()
                        self._event({"type": "ping"})
                    continue
                rest = bundle.feed(translated)
                if rest:
                    self._send_bundle(bundle)
                    for ours in rest:
                        self._event(ours)
                    silent_since = time.time()
                if done:
                    self._send_bundle(bundle)
                    # описание сессии собираем только теперь: расход и контекст обновляются
                    # ровно в конце прогона, и раньше этих чисел просто нет
                    self._event({"type": "done", "session": self._settled_brief(session)})
                    silent_since = time.time()
                    # Есть очередь — прогон начнётся сразу после этого (занятость уже поднята в
                    # _deliver_queued), и поток продолжается: закрывать его значило бы заставить
                    # приложение переподключаться к ответу, который оно уже смотрит.
                    if not (session.busy or session.queue):
                        log("поток сессии %s закрыт: прогон завершён (занята=%s, очередь=%d)" % (
                            session.id, session.busy, len(session.queue)))
                        break
        except (BrokenPipeError, ConnectionResetError):
            # Клиент ушёл: экран закрыли, приложение свернули, связь пропала. Работу НЕ гасим —
            # человек вернётся и продолжит смотреть ответ (для этого есть ручка /events), а
            # прерывает работу только явное «Стоп». Раньше разрыв убивал прогон, и ответ
            # обрывался на полпути — ровно то, что выглядело как «агент застрял».
            log("наблюдатель сессии %s отключился, работа продолжается" % session.id)
        finally:
            # Занятость здесь НЕ снимаем: если наблюдатель ушёл, а агент продолжает считать,
            # сессия действительно занята до конца прогона — снимает её переводчик событий на
            # завершающем событии харнесса (agent_settled или result).
            session.unsubscribe(events)
            session.touched = time.time()
            try:
                self._event({"type": "closed"})
            except (BrokenPipeError, ConnectionResetError, ValueError):
                pass

    def _send_bundle(self, bundle):
        """Отдаёт накопленные куски ответа одним кадром (см. DeltaBundle)."""
        for event in bundle.take():
            self._event(event)

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
