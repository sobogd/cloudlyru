#!/usr/bin/env python3

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

PORT = int(os.environ.get("PI_BRIDGE_PORT", "18820"))
HOST = os.environ.get("PI_BRIDGE_HOST", "127.0.0.1")

CONFIG_PATH = Path(os.environ.get("PI_BRIDGE_CONFIG", str(Path.home() / ".pi-bridge.json")))

PI_SESSIONS = Path.home() / ".pi" / "agent" / "sessions"
PI_MODELS = Path.home() / ".pi" / "agent" / "models.json"
PI_AUTH = Path.home() / ".pi" / "agent" / "auth.json"

SESSIONS_PATH = Path(os.environ.get(
    "PI_BRIDGE_SESSIONS", str(Path.home() / ".pi-bridge-sessions.json")
))

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

COMMAND_TIMEOUT = 60.0
STATE_TIMEOUT = 8.0
IDLE_STOP_SECONDS = 1800.0
MAX_MESSAGE_CHARS = 20_000
HEARTBEAT_SECONDS = 15
DELTA_FLUSH_SECONDS = 0.08
EVENT_TICK = 0.05
SESSIONS_CACHE_SECONDS = 5.0
MAX_BODY_BYTES = 4 * 1024 * 1024
MAX_NAME_CHARS = 120
OWN_EVENTS = {"queued", "queued_started", "idle", "error"}

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

_models_cache = None
models_lock = threading.Lock()


def log(message):
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with log_lock:
        sys.stderr.write("[%s] %s\n" % (stamp, message))
        sys.stderr.flush()


def load_config():
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
        "roots": [str(Path.home() / "work")],
        "depth": 2,
        "pi": "pi",
        "provider": "",
        "model": "",
        "claude_effort": "",
        "token": secrets.token_hex(24),
    }
    save_config(cfg)
    log("создал %s — токен и корни внутри файла, откройте его и впишите в приложение" % CONFIG_PATH)
    return cfg


def save_config(cfg):
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding="utf-8")
    os.chmod(CONFIG_PATH, 0o600)


def remember_claude_effort(effort):
    value = str(effort or "").strip()
    if str(CONFIG.get("claude_effort") or "") == value:
        return
    CONFIG["claude_effort"] = value
    try:
        save_config(CONFIG)
    except OSError as e:
        log("не смог сохранить уровень усилия в %s (%s)" % (CONFIG_PATH, e))


CONFIG = load_config()


_sessions_lock = threading.Lock()


def session_choice(key):
    if not key:
        return {}
    with _sessions_lock:
        data = read_json_file(SESSIONS_PATH)
    entry = data.get(key)
    return entry if isinstance(entry, dict) else {}


def remember_session_choice(key, provider=None, model=None, effort=None):
    if not key:
        return
    with _sessions_lock:
        data = read_json_file(SESSIONS_PATH)
        entry = data.get(key)
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
    if not session_id:
        return "", ""
    file = file or find_session_file(harness, session_id)
    if file is None:
        return "", ""
    reader = read_claude_meta if harness == HARNESS_CLAUDE else read_session_meta
    meta = reader(file)
    return str(meta.get("provider") or ""), str(meta.get("model") or "")


def default_model():
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
    encoded = str(cwd).lstrip(os.sep).replace("/", "-").replace("\\", "-").replace(":", "-")
    return PI_SESSIONS / ("--%s--" % encoded)


def content_text(content):
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
    if not isinstance(content, list):
        return ""
    return "".join(
        str(b.get("thinking") or "")
        for b in content
        if isinstance(b, dict) and b.get("type") == "thinking"
    )


def normalize_messages(messages):
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
                        if text.strip():
                            blocks.append({"type": "text", "text": text})
                    elif kind == "thinking":
                        thinking = str(block.get("thinking") or "")
                        if thinking.strip():
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

            error = message.get("errorMessage")
            if not blocks and not error:
                continue
            if items and items[-1].get("kind") == "assistant":
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

    for item in items:
        if item.get("kind") != "assistant":
            continue
        item["text"] = "".join(b["text"] for b in item["blocks"] if b["type"] == "text")
        item["reasoning"] = "".join(b["text"] for b in item["blocks"] if b["type"] == "reasoning")
    return items


HARNESS_PI = "pi"
HARNESS_CLAUDE = "claude"
HARNESS_NAMES = {HARNESS_PI: "pi", HARNESS_CLAUDE: "Claude Code"}

CLAUDE_ALIASES = [
    {"id": "default", "name": "Как настроено в Claude Code", "contextWindow": 200_000},
    {"id": "fable", "name": "Fable — последняя", "contextWindow": 1_000_000},
    {"id": "opus", "name": "Opus — последняя", "contextWindow": 1_000_000},
    {"id": "opusplan", "name": "Opus Plan — Opus в планировании, Sonnet в работе", "contextWindow": 1_000_000},
    {"id": "sonnet", "name": "Sonnet — последняя", "contextWindow": 1_000_000},
    {"id": "haiku", "name": "Haiku — последняя", "contextWindow": 200_000},
]

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

CLAUDE_EFFORTS = [
    {"id": "low", "name": "Низкое — быстрее и дешевле"},
    {"id": "medium", "name": "Среднее"},
    {"id": "high", "name": "Высокое"},
    {"id": "xhigh", "name": "Очень высокое"},
    {"id": "max", "name": "Максимальное — самое долгое и дорогое"},
]


def claude_effort_ids():
    return {entry["id"] for entry in CLAUDE_EFFORTS}


def session_key(harness, session_id):
    if not session_id:
        return ""
    if not harness:
        return str(session_id)
    return "%s--%s" % (harness, session_id)


def split_key(key):
    text = str(key or "")
    for harness in (HARNESS_PI, HARNESS_CLAUDE):
        prefix = harness + "--"
        if text.startswith(prefix):
            return harness, text[len(prefix):]
    return HARNESS_PI, text


def claude_profile():
    value = str(CONFIG.get("claude_config_dir") or "").strip() or str(os.environ.get("CLAUDE_CONFIG_DIR") or "").strip()
    if value:
        return str(Path(value).expanduser())
    return ""


def claude_projects_dir():
    return Path(claude_profile() or (Path.home() / ".claude")) / "projects"


def claude_sessions_dir(cwd):
    encoded = str(cwd).lstrip(os.sep).replace("/", "-").replace("\\", "-").replace(":", "-")
    return claude_projects_dir() / ("-" + encoded)


def claude_session_env_dir(session_id):
    if not session_id:
        return None
    return Path(claude_profile() or (Path.home() / ".claude")) / "session-env" / str(session_id)


def session_cwd(harness, session_id):
    file = find_session_file(harness, session_id)
    if file is None:
        return None
    reader = read_claude_meta if harness == HARNESS_CLAUDE else read_session_meta
    cwd = str(reader(file).get("cwd") or "")
    return cwd or None


def find_session_file(harness, session_id):
    if not session_id:
        return None
    if harness == HARNESS_CLAUDE:
        found = sorted(claude_projects_dir().glob("*/%s.jsonl" % session_id))
    else:
        found = sorted(PI_SESSIONS.glob("*/**%s.jsonl" % session_id))
    return found[0] if found else None


def claude_result_text(content):
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
    for entry in CLAUDE_MODELS:
        if entry["id"] == model:
            return entry["contextWindow"]
    return 200_000


def claude_model_label(model):
    for entry in CLAUDE_MODELS:
        if entry["id"] == model:
            return entry["name"]
    return model


def read_claude_meta(file):
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
                meta["title"] = text[:80]
        elif entry.get("type") == "assistant" and not meta["model"]:
            meta["model"] = str(message.get("model") or "")

    renamed = last_jsonl_field(data, "custom-title", "customTitle")
    if renamed:
        meta["name"] = renamed
    if not meta["name"]:
        meta["name"] = meta["title"]
    if not meta["startedAt"] or not meta.get("updatedAt"):
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
    quoted = b'"' + kind.encode("utf-8") + b'"'
    index = data.rfind(quoted)
    if index < 0:
        return None
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
    folder = claude_sessions_dir(path)
    if not folder.is_dir():
        return []
    files = [p for p in folder.glob("*.jsonl") if p.is_file()]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return files


def session_files(path):
    folder = sessions_dir_for(path)
    if not folder.is_dir():
        return []
    files = [p for p in folder.glob("*.jsonl") if p.is_file()]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return files


def read_file_messages(harness, file):
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


_meta_cache = {}
meta_cache_lock = threading.Lock()


def cached_meta(file, reader):
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
                    if not meta["model"]:
                        meta["provider"] = str(entry.get("provider") or "")
                        meta["model"] = str(entry.get("modelId") or "")
                elif kind == "session_info":
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
        try:
            stamp = file.stat().st_mtime
        except OSError:
            stamp = None
        if not meta["startedAt"] and stamp is not None:
            meta["startedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(stamp))
        if not meta.get("updatedAt") and stamp is not None:
            meta["updatedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(stamp))
    return meta


_last_used_cache = {}
last_used_lock = threading.Lock()


def folder_last_used(folder, files):
    if not files:
        return None
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


PROJECTS_CACHE_SECONDS = 5.0
_projects_cache = None
projects_lock = threading.Lock()


def list_projects_cached():
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
    depth = int(CONFIG.get("depth") or 2)
    roots = [Path(str(r)).expanduser() for r in (CONFIG.get("roots") or [])]
    seen = set()
    projects = []

    def inside_roots(path):
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
        resolved = inside_roots(path)
        if resolved is None or not resolved.is_dir() or str(resolved) in seen:
            return
        seen.add(str(resolved))
        files = session_files(resolved) + claude_session_files(resolved)
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

    projects.sort(key=lambda p: (p["lastUsed"] is None, p["name"].lower()))
    projects.sort(key=lambda p: p["lastUsed"] or "", reverse=True)
    return projects


def allowed_path(path):
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
    if not file:
        return None
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(file.stat().st_mtime))
    except OSError:
        return None


def is_local_model(model):
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
                "hasKey": True,
            }
            for entry in CLAUDE_MODELS
        ]
    return list_pi_models()


def list_pi_models():
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
            "contextWindow": by_id.get("contextWindow") or row["contextWindow"],
            "maxTokens": by_id.get("maxTokens") or row["maxTokens"],
            "baseUrl": base,
            "local": is_local_model({"baseUrl": base, "provider": row["provider"]}),
            "hasKey": by_id.get("hasKey", info.get("hasKey", True)),
        })

    if not models:
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
        envdir = claude_session_env_dir(session_id) if harness == HARNESS_CLAUDE else None
        if envdir is not None and envdir.is_dir():
            shutil.rmtree(envdir, ignore_errors=True)
            log("удалил окружение сессии %s" % envdir)
    except OSError as e:
        raise PiError("не смог удалить файл сессии %s: %s" % (file, e))
    return file


def last_journal_id(file, tail_bytes=64 * 1024):
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
    clean = " ".join(str(name or "").split())
    if not clean:
        raise PiError("пустое имя")
    if len(clean) > MAX_NAME_CHARS:
        raise PiError("имя длиннее %d символов" % MAX_NAME_CHARS)
    return clean


def flush_pending_name(session):
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
    harness, session_id = split_key(key)
    clean = clean_session_name(name)
    file = find_session_file(harness, session_id)
    if file is None:
        live = POOL.maybe(key)
        if live is None:
            raise PiError("сессия не найдена: %s" % key)
        live.pending_name = clean
        log("запомнил имя сессии %s до появления журнала: %s" % (key, clean))
        return clean
    return write_session_name(file, harness, session_id, clean)


def purge_session(key):
    file = remove_session_files(key)
    if file is None:
        return {"deleted": False, "restored": False}
    time.sleep(0.4)
    restored = file.exists()
    if restored:
        log("файл %s восстановлен живым процессом: разговор ведётся снаружи" % file)
    return {"deleted": not restored, "restored": restored}


def read_json_file(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def write_json_file(path, data, mode=0o600):
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
                    "images": "image" in (m.get("input") or []),
                    **( {"samplingParams": m["samplingParams"]} if isinstance(m.get("samplingParams"), dict) else {} ),
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
        data = payload if isinstance(payload, list) else []
    models = []
    for item in data:
        if isinstance(item, dict) and item.get("id"):
            models.append({"id": str(item["id"]), "name": str(item.get("name") or item["id"])})
        elif isinstance(item, str):
            models.append({"id": item, "name": item})
    return models


def save_provider(body):
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
            "input": ["text", "image"] if item.get("images") else ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
        }
        if item.get("contextWindow"):
            entry["contextWindow"] = int(item["contextWindow"])
        if item.get("maxTokens"):
            entry["maxTokens"] = int(item["maxTokens"])
        sampling = item.get("samplingParams")
        if isinstance(sampling, dict):
            clean = {str(k): v for k, v in sampling.items() if isinstance(v, (int, float, str))}
            if clean:
                entry["samplingParams"] = clean
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
    global _models_cache
    with models_lock:
        _models_cache = None


class PiError(Exception):
    pass


class RunUi:

    def __init__(self):
        self.reset()

    def reset(self):
        self.text = ""
        self.reasoning = ""
        self.blocks = []
        self.tools = {}

    def empty(self):
        return not (self.text or self.reasoning or self.blocks)

    def feed(self, events):
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
        if not text:
            return
        if self.blocks and self.blocks[-1].get("type") == kind:
            self.blocks[-1]["text"] += text
            return
        if not text.strip():
            return
        self.blocks.append({"type": kind, "text": text})

    def _tool(self, event, running, keep_args=False):
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
            self.blocks.append({"type": "tool", "id": call_id})
            return
        if not card["name"] and event.get("name"):
            card["name"] = str(event["name"])
        if args and not keep_args:
            card["args"] = args
        if event.get("text"):
            card["output"] = str(event["text"])
        card["isError"] = bool(event.get("isError"))
        card["running"] = running

    def item(self):
        return {
            "kind": "assistant",
            "text": self.text,
            "reasoning": self.reasoning,
            "blocks": [dict(block) for block in self.blocks],
            "tools": [dict(card) for card in self.tools.values()],
            "error": "",
        }


class AgentSession:

    harness = ""

    def __init__(self, cwd, model=None):
        self.cwd = str(cwd)
        self.id = ""
        self.model = model or ""
        self.proc = None
        self.reader = None
        self.lock = threading.Lock()
        self.pending = {}
        self.subscribers = []
        self.busy = False
        self.touched = time.time()
        self.state = {}
        self.start_meta = None
        self.file_cache = None
        self.pending_name = ""
        self.stderr_tail = []
        self.counters = {"userMessages": 0, "assistantMessages": 0, "toolCalls": 0}
        self.partial_seen = False
        self.current_prompt = None
        self.current_id = ""
        self.run_ui = RunUi()
        self.queue = []

    @property
    def key(self):
        return session_key(self.harness, self.id)

    def subscribe(self):
        events = queue.Queue()
        with self.lock:
            self.subscribers.append(events)
            snapshot = None if (not self.busy or self.run_ui.empty()) else self.run_ui.item()
        return events, snapshot

    def unsubscribe(self, events):
        with self.lock:
            if events in self.subscribers:
                self.subscribers.remove(events)

    def enqueue(self, text, message_id=""):
        self.queue.append({"text": text, "at": time.time(), "id": str(message_id or "")})
        self.touched = time.time()
        log("сессия %s: сообщение поставлено в очередь (%d-е)" % (self.id, len(self.queue)))
        return len(self.queue)

    def start_run(self, text, message_id=""):
        self.current_prompt = text
        self.current_id = str(message_id or "")
        self.run_ui.reset()

    def forget_run(self):
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
        if not self.queue:
            return
        item = self.queue.pop(0)
        log("сессия %s: отдаю из очереди (%d осталось)" % (self.id, len(self.queue)))
        self.busy = True
        self.start_run(item["text"], item.get("id") or "")
        threading.Thread(target=self._send_queued, args=(item,), daemon=True).start()

    def _send_queued(self, item):
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
        translated, done = translate(self, event)
        self.run_ui.feed(translated)
        if done:
            self._finish_run(event)
        self._publish(translated, done)

    def _finish_run(self, event):
        self.busy = False
        self.forget_run()
        self.touched = time.time()
        log("сессия %s: прогон завершён (%s), в очереди %d" % (
            self.id, event.get("type"), len(self.queue)))
        self._deliver_queued()

    def _publish(self, translated, done=False):
        with self.lock:
            for q in list(self.subscribers):
                q.put((translated, done))

    def _write(self, payload):
        self.touched = time.time()
        try:
            self.proc.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
            self.proc.stdin.flush()
        except (OSError, ValueError) as e:
            raise PiError("процесс %s не принимает команды: %s" % (self.harness, e))

    def stop(self):
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
        self.busy = False
        self.forget_run()
        for key, q in list(self.pending.items()):
            q.put({"type": "response", "id": key, "success": False, "error": reason})
        self.pending.clear()
        for q in list(self.subscribers):
            q.put(([{"type": "error", "message": reason}], True))

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def _restart(self):
        with self.lock:
            if self.alive():
                return
            self.busy = False
            self._start(self.id)

    def prompt(self, text):
        raise NotImplementedError

    def abort(self):
        raise NotImplementedError

    def refresh_state(self):
        raise NotImplementedError

    def messages(self):
        raise NotImplementedError


class PiSession(AgentSession):

    harness = "pi"

    def __init__(self, cwd, session_id=None, provider=None, model=None):
        super().__init__(cwd, model=model)
        self.id = session_id or ""
        self.provider = provider or ""
        self._start(session_id)

    def _start(self, session_id):
        provider, model = default_model()
        provider = self.provider or provider
        model = self.model or model
        if session_id and not self.provider and not self.model:
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
            cmd += ["--session-id", session_id]
        if provider:
            cmd += ["--provider", provider]
        if model:
            cmd += ["--model", model]
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
                bufsize=1,
                start_new_session=True,
            )
        except OSError as e:
            raise PiError("не удалось запустить pi (%s): %s" % (CONFIG.get("pi"), e))

        self.reader = threading.Thread(target=self._read_stdout, daemon=True)
        self.reader.start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

        state = self.command("get_state", timeout=COMMAND_TIMEOUT)
        self.id = str(state.get("sessionId") or self.id or "")
        self.state = state

    def _read_stdout(self):
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

        self._fail_waiters("процесс pi завершился")

    def _read_stderr(self):
        for line in self.proc.stderr:
            line = line.rstrip()
            if not line:
                continue
            self.stderr_tail.append(line)
            del self.stderr_tail[:-20]
            log("pi: %s" % line[:300])

    def _answer_ui(self, message):
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
            return
        log("автоответ на диалог расширения (%s): %s — %s" % (method, shown, title[:120]))
        self._write(response)
        self._publish({"type": "ui", "method": method, "title": title, "auto": shown})

    def command(self, kind, timeout=COMMAND_TIMEOUT, **fields):
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
        self.command("prompt", message=text)

    def abort(self):
        if self.proc is None or self.proc.poll() is not None:
            return
        try:
            self._write({"id": uuid.uuid4().hex, "type": "abort"})
        except PiError as e:
            log("не смог отправить abort в сессию %s: %s" % (self.id, e))

    def set_model(self, provider, model):
        self.command("set_model", provider=provider, modelId=model)
        self.provider, self.model = provider, model
        remember_session_choice(session_key(self.harness, self.id), provider=provider, model=model)

    def messages(self, timeout=STATE_TIMEOUT):
        data = self.command("get_messages", timeout=timeout)
        messages = data.get("messages")
        return normalize_messages(messages if isinstance(messages, list) else [])

    def refresh_state(self, timeout=COMMAND_TIMEOUT):
        try:
            self.state = self.command("get_state", timeout=timeout)
            stats = self.command("get_session_stats", timeout=timeout)
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

    harness = "claude"

    def __init__(self, cwd, session_id=None, model=None, effort=None):
        super().__init__(cwd, model=model)
        self.id = session_id or str(uuid.uuid4())
        remembered = session_choice(session_key(self.harness, self.id))
        if not self.model:
            self.model = str(remembered.get("model") or "")
        if effort is None:
            stored = remembered.get("effort")
            effort = stored if isinstance(stored, str) else CONFIG.get("claude_effort")
        effort = str(effort or "").strip()
        if effort and effort not in claude_effort_ids():
            raise PiError("неизвестный уровень усилия: %s" % effort)
        self.effort = effort
        self.last_usage = {}
        self._start(session_id)

    def _start(self, session_id):
        cmd = [
            str(CONFIG.get("claude") or "claude"),
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
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
            cmd += ["--effort", self.effort]

        env = dict(os.environ)
        profile = claude_profile()
        if profile:
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
                bufsize=1,
                start_new_session=True,
            )
        except OSError as e:
            raise PiError("не удалось запустить claude (%s): %s" % (CONFIG.get("claude"), e))

        self.reader = threading.Thread(target=self._read_stdout, daemon=True)
        self.reader.start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

        time.sleep(0.6)
        if not self.alive():
            detail = self.stderr_tail[-1] if self.stderr_tail else "без вывода"
            raise PiError("Claude Code не запустился: %s" % detail)

    def _read_stdout(self):
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
            session_id = str(event.get("session_id") or "")
            if session_id:
                self.id = session_id
                self.file_cache = None
            model = str(event.get("model") or "")
            if model and (not self.model or self.model == "default"):
                self.model = model
            self._dispatch(event)

        self._fail_waiters("процесс claude завершился")

    def _read_stderr(self):
        for line in self.proc.stderr:
            line = line.rstrip()
            if not line:
                continue
            self.stderr_tail.append(line)
            del self.stderr_tail[:-20]
            log("claude: %s" % line[:300])

    def prompt(self, text):
        self.counters["userMessages"] += 1
        self._write({
            "type": "user",
            "message": {"role": "user", "content": [{"type": "text", "text": text}]},
        })

    def abort(self):
        self._write({"type": "control_request", "request": {"subtype": "interrupt"}})

    def set_model(self, provider, model):
        self.model = model
        remember_session_choice(session_key(self.harness, self.id), model=model)
        self.stop()
        self._start(self.id)

    def set_effort(self, effort):
        effort = str(effort or "").strip()
        if effort and effort not in claude_effort_ids():
            raise PiError("неизвестный уровень усилия: %s" % effort)
        self.effort = effort
        remember_claude_effort(effort)
        remember_session_choice(session_key(self.harness, self.id), effort=effort)
        self.stop()
        self._start(self.id)

    def refresh_state(self):
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
        session.busy = False
        session.touched = time.time()
        try:
            session.state = session.refresh_state(timeout=STATE_TIMEOUT)
        except Exception as e:
            log("не смог обновить состояние сессии %s: %s" % (session.id, e))
        return [{"type": "done", "session": _session_brief(session)}], True

    if kind in ("auto_retry_start", "auto_retry_end", "extension_error", "queue_update"):
        return [{**event, "type": kind}], False

    return out, False


def translate_claude_event(session, event):
    kind = event.get("type")
    subtype = event.get("subtype")
    out = []

    if kind == "system":
        if subtype == "init":
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
        if event.get("is_error") or (subtype and subtype != "success"):
            return [{"type": "error", "message": str(event.get("result") or "Claude Code вернул ошибку")}], True
        return out, True

    return out, False


def translate(session, event):
    kind = event.get("type")
    if kind in OWN_EVENTS:
        return [event], kind == "error"
    if kind == "fatal":
        return [{"type": "error", "message": str(event.get("message") or "сбой харнесса")}], True
    if session.harness == HARNESS_CLAUDE:
        return translate_claude_event(session, event)
    return translate_pi_event(session, event)


class Pool:

    def __init__(self):
        self.lock = threading.Lock()
        self.sessions = {}
        self.reaper = threading.Thread(target=self._reap, daemon=True)
        self.reaper.start()

    def open(self, cwd, harness=HARNESS_PI, session_id=None, provider=None, model=None, effort=None):
        key = session_key(harness, session_id) if session_id else ""
        if key:
            with self.lock:
                session = self.sessions.get(key)
            if session is not None:
                if not session.alive():
                    session._restart()
                session.touched = time.time()
                return session
        session = self._spawn(cwd, harness, session_id, provider, model, effort)
        with self.lock:
            existing = self.sessions.get(session.key)
            if existing is not None and existing is not session:
                session.stop()
                existing.touched = time.time()
                return existing
            self.sessions[session.key] = session
            return session

    def _spawn(self, cwd, harness, session_id, provider, model, effort):
        if harness == HARNESS_CLAUDE:
            session = ClaudeSession(cwd, session_id, model=model, effort=effort)
        else:
            session = PiSession(cwd, session_id, model=model, provider=provider)
        if not session.id:
            detail = session.stderr_tail[-1] if session.stderr_tail else "без вывода"
            session.stop()
            raise PiError("%s не сообщил идентификатор сессии (%s)" % (harness, detail))
        remember_session_choice(
            session.key,
            provider=provider,
            model=model,
            effort=session.effort if harness == HARNESS_CLAUDE else None,
        )
        return session

    def maybe(self, key):
        keys = [str(key)]
        if not any(str(key).startswith(h + "--") for h in HARNESS_NAMES):
            keys.append(session_key(HARNESS_PI, key))
        with self.lock:
            session = next((self.sessions[k] for k in keys if k in self.sessions), None)
        if session is not None and not session.alive():
            session._restart()
        return session

    def find(self, key):
        session = self.maybe(key)
        if session is None:
            raise PiError("сессия не открыта: сначала откройте её в приложении")
        return session

    def list(self):
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
        with self.lock:
            return self.sessions.pop(session_id, None)

    def take_all(self):
        with self.lock:
            sessions = list(self.sessions.values())
            self.sessions.clear()
            return sessions

    def _reap(self):
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

    def __init__(self):
        self.reset()

    def reset(self):
        self.text = ""
        self.reasoning = ""
        self.due = 0.0

    def feed(self, translated):
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
        return bool((self.text or self.reasoning) and time.time() >= self.due)

    def take(self):
        events = []
        if self.text:
            events.append({"type": "delta", "text": self.text})
        if self.reasoning:
            events.append({"type": "reasoning", "text": self.reasoning})
        self.reset()
        return events


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
    total = len(items)
    before = max(0, min(_int_param(params, "before", total), total))
    limit = _int_param(params, "limit", 0)
    start = max(0, before - limit) if limit > 0 else 0
    window = items[start:before]
    return {"items": window, "total": total, "hasMore": start > 0}


def _int_param(params, name, default):
    raw = (params.get(name) or [""])[0]
    try:
        return int(str(raw).strip())
    except (TypeError, ValueError):
        return default


class Handler(BaseHTTPRequestHandler):

    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        log("%s %s" % (self.address_string(), fmt % args))


    def _authorized(self):
        expected = str(CONFIG.get("token") or "")
        if not expected:
            return True
        header = self.headers.get("Authorization") or ""
        provided = header[len("Bearer "):].strip() if header.startswith("Bearer ") else ""
        return hmac.compare_digest(provided, expected)

    def _json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.close_connection = True
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
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
        parsed = urllib.parse.urlparse(self.path)
        return parsed.path.rstrip("/") or "/", urllib.parse.parse_qs(parsed.query)

    def _guard(self, fn):
        if not self._authorized():
            self._json(401, {"error": "неверный токен моста"})
            return
        try:
            fn()
        except PiError as e:
            self._json(400, {"error": str(e)})
        except BrokenPipeError:
            pass
        except Exception as e:  # noqa: BLE001 — сервис не должен падать от одной ручки
            log("ошибка в ручке %s: %r" % (self.path, e))
            self._json(500, {"error": "внутренняя ошибка моста: %s" % e})


    def do_GET(self):  # noqa: N802 — имя диктует BaseHTTPRequestHandler
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
                session = POOL.maybe(parts[2])
                if len(parts) == 4 and parts[3] == "messages":
                    if session is not None:
                        brief = self._session_brief(session)
                        try:
                            items = session.messages()
                        except PiError as e:
                            log("не смог прочитать сообщения сессии %s: %s" % (session.id, e))
                            file = session_file(session)
                            try:
                                items = read_file_messages(session.harness, file) if file is not None else []
                            except PiError:
                                items = []
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
                        session.refresh_state(timeout=STATE_TIMEOUT)
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
                if action == "queue":
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
                        self._json(200, {"queued": False, "position": 0})
                        return
                    if session.is_duplicate(text, message_id):
                        log("сессия %s: повтор того же сообщения — в очередь не ставлю" % session.id)
                        self._json(200, {
                            "queued": True,
                            "duplicate": True,
                            "position": session.queue_position(text, message_id),
                        })
                        return
                    self._json(200, {"queued": True, "position": session.enqueue(text, message_id)})
                    return
                if action == "name":
                    self._json(200, {"name": set_session_name(parts[2], body.get("name"))})
                    return
                if action == "abort":
                    session = POOL.maybe(parts[2])
                    if session is None:
                        self._json(200, {"ok": True, "aborted": False})
                        return
                    session.abort()
                    session.busy = False
                    session.forget_run()
                    self._json(200, {"ok": True, "aborted": True})
                    return
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
                        timeout=900.0,
                        **({"customInstructions": instructions} if isinstance(instructions, str) and instructions else {}),
                    )
                    self._json(200, {"summary": data.get("summary") or ""})
                elif action == "model":
                    provider = str(body.get("provider") or "").strip()
                    model = str(body.get("modelId") or "").strip()
                    if not provider or not model:
                        raise PiError("нужны provider и modelId")
                    session.set_model(provider, model)
                    session.refresh_state(timeout=STATE_TIMEOUT)
                    self._json(200, {"session": self._session_brief(session)})
                elif action == "effort":
                    if session.harness != HARNESS_CLAUDE:
                        raise PiError("уровень усилия есть только у Claude Code")
                    session.set_effort(str(body.get("effort") or ""))
                    session.refresh_state(timeout=STATE_TIMEOUT)
                    self._json(200, {"session": self._session_brief(session)})
                elif action == "ui":
                    self._json(200, self._manual_ui(session, body))
                else:
                    self._json(404, {"error": "неизвестная ручка: %s" % path})
                return
            self._json(404, {"error": "неизвестная ручка: %s" % path})

        self._guard(run)

    def do_DELETE(self):  # noqa: N802
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
                outcome = purge_session(parts[2])
                self._json(200, {
                    "ok": True,
                    "deleted": 1 if outcome["deleted"] else 0,
                    "restored": 1 if outcome["restored"] else 0,
                })
            else:
                self._json(404, {"error": "неизвестная ручка: %s" % path})

        self._guard(run)


    def _health(self):
        provider, model = default_model()
        harnesses = harness_status()
        pi_version = next((h["version"] for h in harnesses if h["harness"] == HARNESS_PI), "")
        return {
            "ok": True,
            "pi": pi_version,
            "harnesses": harnesses,
            "provider": provider,
            "model": model,
            "roots": CONFIG.get("roots") or [],
            "sessions": POOL.list(),
        }

    def _list_sessions(self, params):
        raw = (params.get("path") or [""])[0]
        asked = str((params.get("harness") or [""])[0]).strip()

        if raw:
            path = allowed_path(raw)
            if path is None:
                raise PiError("папка вне разрешённых корней: %s" % raw)
            folders = [path]
        else:
            folders = [Path(str(p["path"])) for p in list_projects_cached()]

        sessions = cached_sessions((tuple(str(f) for f in folders), asked), lambda: self._build_sessions(folders, asked))
        self._json(200, {"path": str(folders[0]) if raw else "", "sessions": sessions})

    def _build_sessions(self, folders, asked):
        sessions = []
        for folder in folders:
            if asked in ("", HARNESS_PI):
                for file in session_files(folder):
                    sessions.append({**cached_meta(file, read_session_meta), "harness": HARNESS_PI, "path": str(folder)})
            if asked in ("", HARNESS_CLAUDE):
                for file in claude_session_files(folder):
                    sessions.append({**cached_meta(file, read_claude_meta), "harness": HARNESS_CLAUDE, "path": str(folder)})
        sessions.sort(key=lambda s: s.get("startedAt") or "", reverse=True)
        for session in sessions:
            session["id"] = session_key(session["harness"], session["id"])
            running = POOL.maybe(session["id"])
            session["busy"] = bool(running and running.busy)
        return sessions

    def _open_session(self, body):
        raw = str(body.get("path") or "").strip()
        path = allowed_path(raw) if raw else None
        if path is None:
            raise PiError("папка вне разрешённых корней: %s" % raw)
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
        if harness == HARNESS_CLAUDE and effort is not None:
            remember_claude_effort(effort)
        session = POOL.open(path, harness, session_id, provider=provider, model=model, effort=effort)
        session.refresh_state(timeout=STATE_TIMEOUT)
        self._json(200, {"session": self._session_brief(session)})

    def _reopen(self, key):
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
        try:
            session.state = session.refresh_state(timeout=STATE_TIMEOUT)
        except PiError as e:
            log("не смог обновить состояние сессии %s: %s" % (session.id, e))
        return self._session_brief(session)

    def _events(self, session, queued=0, duplicate=False):
        events, snapshot = session.subscribe()
        if not session.busy and not queued and snapshot is None:
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
            if snapshot is not None:
                self._event({"type": "snapshot", "item": snapshot})
            bundle = DeltaBundle()
            silent_since = time.time()
            while True:
                if bundle.due_now():
                    self._send_bundle(bundle)
                    silent_since = time.time()
                try:
                    translated, done = events.get(timeout=EVENT_TICK)
                except queue.Empty:
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
                    self._event({"type": "done", "session": self._settled_brief(session)})
                    silent_since = time.time()
                    if not (session.busy or session.queue):
                        log("наблюдатель сессии %s отключён: прогон завершён, очередь пуста" % session.id)
                        break
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            session.unsubscribe(events)

    def _manual_ui(self, session, body):
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
        text = str(body.get("text") or "").strip()
        message_id = str(body.get("id") or "").strip()
        if not text:
            raise PiError("пустое сообщение")
        if len(text) > MAX_MESSAGE_CHARS:
            raise PiError("сообщение длиннее %d символов" % MAX_MESSAGE_CHARS)
        if session.is_duplicate(text, message_id):
            log("сессия %s: повтор того же сообщения — прогон не запускаю" % session.id)
            self._events(session, queued=session.queue_position(text, message_id), duplicate=True)
            return
        if session.busy:
            self._events(session, queued=session.enqueue(text, message_id))
            return

        events, _ = session.subscribe()
        session.busy = True
        session.touched = time.time()

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache, no-transform")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        try:
            try:
                session.start_run(text, message_id)
                session.prompt(text)
            except PiError as e:
                session.forget_run()
                session.busy = False
                self._event({"type": "error", "message": str(e)})
                return
            self._event({"type": "accepted"})
            bundle = DeltaBundle()
            silent_since = time.time()
            while True:
                if bundle.due_now():
                    self._send_bundle(bundle)
                    silent_since = time.time()
                try:
                    translated, done = events.get(timeout=EVENT_TICK)
                except queue.Empty:
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
                    self._event({"type": "done", "session": self._settled_brief(session)})
                    silent_since = time.time()
                    if not (session.busy or session.queue):
                        log("поток сессии %s закрыт: прогон завершён (занята=%s, очередь=%d)" % (
                            session.id, session.busy, len(session.queue)))
                        break
        except (BrokenPipeError, ConnectionResetError):
            log("наблюдатель сессии %s отключился, работа продолжается" % session.id)
        finally:
            session.unsubscribe(events)
            session.touched = time.time()
            try:
                self._event({"type": "closed"})
            except (BrokenPipeError, ConnectionResetError, ValueError):
                pass

    def _send_bundle(self, bundle):
        for event in bundle.take():
            self._event(event)

    def _event(self, payload):
        self.wfile.write(("data: %s\n\n" % json.dumps(payload, ensure_ascii=False)).encode("utf-8"))
        self.wfile.flush()


def main():
    host = str(CONFIG.get("host") or HOST)
    port = int(CONFIG.get("port") or PORT)
    server = ThreadingHTTPServer((host, port), Handler)
    log("мост pi слушает %s:%d, корни: %s" % (host, port, ", ".join(CONFIG.get("roots") or [])))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        for session in POOL.take_all():
            session.stop()
        server.server_close()


if __name__ == "__main__":
    main()
