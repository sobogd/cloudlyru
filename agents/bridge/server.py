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

import harness_adapter as ha

PORT = int(os.environ.get("BRIDGE_PORT", "18820"))
HOST = os.environ.get("BRIDGE_HOST", "127.0.0.1")

LEGACY_CONFIG_PATH = Path.home() / ".pi-bridge.json"
CONFIG_PATH = Path(os.environ.get("BRIDGE_CONFIG", str(Path.home() / ".agent-bridge.json")))



SESSIONS_PATH = Path(os.environ.get(
    "BRIDGE_SESSIONS", str(Path.home() / ".agent-bridge-sessions.json")
))


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
log_lock = threading.Lock()



def log(message):
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with log_lock:
        sys.stderr.write("[%s] %s\n" % (stamp, message))
        sys.stderr.flush()


def load_config():
    if not CONFIG_PATH.exists() and LEGACY_CONFIG_PATH.exists():
        # одноразовый перенос настроек из старого имени
        CONFIG_PATH.write_bytes(LEGACY_CONFIG_PATH.read_bytes())
        try:
            LEGACY_CONFIG_PATH.unlink()
        except OSError:
            pass
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
        "claude_effort": "",
        "harness": {"grpc": "127.0.0.1:9000", "sse": "http://127.0.0.1:9001"},
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


HARNESS_CLAUDE = "claude"
HARNESS_LLM = "harness"
HARNESS_NAMES = {HARNESS_CLAUDE: "Claude Code", HARNESS_LLM: "LLM harness"}

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
    for harness in (HARNESS_CLAUDE, HARNESS_LLM):
        prefix = harness + "--"
        if text.startswith(prefix):
            return harness, text[len(prefix):]
    return HARNESS_CLAUDE, text


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
    cwd = str(read_claude_meta(file).get("cwd") or "")
    return cwd or None


def find_session_file(harness, session_id):
    if not session_id:
        return None
    if harness == HARNESS_LLM:
        return None
    if harness != HARNESS_CLAUDE:
        return None
    found = sorted(claude_projects_dir().glob("*/%s.jsonl" % session_id))
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
    for harness, binary in ((HARNESS_CLAUDE, CONFIG.get("claude") or "claude"),):
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
    status = ha.LINK.status()
    result.append({
        "harness": HARNESS_LLM,
        "name": HARNESS_NAMES[HARNESS_LLM],
        "available": status is not None,
        "version": ha.MODEL["name"] if status is not None else "",
    })
    return result


def claude_session_files(path):
    folder = claude_sessions_dir(path)
    if not folder.is_dir():
        return []
    files = [p for p in folder.glob("*.jsonl") if p.is_file()]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return files


def read_file_messages(harness, file):
    if not file or not file.exists():
        return []
    return normalize_claude_messages(read_jsonl(file))


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
        files = claude_session_files(resolved)
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
                if (path / ".git").exists() or claude_sessions_dir(path).is_dir() or (path / ".llm-harness").is_dir():
                    add(path)

    for folder, reader in (
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
        session.start_meta = read_claude_meta(session.file_cache)
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


def list_models(harness=HARNESS_CLAUDE):
    if harness == HARNESS_LLM:
        return [dict(ha.MODEL)]
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


def write_session_name(file, harness, session_id, clean):
    entry = {"type": "custom-title", "customTitle": clean, "sessionId": session_id}
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
    if session.harness == HARNESS_LLM:
        try:
            ha.rename_session(session.id, session.pending_name, root=getattr(session, "native_root", session.cwd))
        except ha.Err as e:
            log("отложенное имя не записалось (%s): %s" % (session.key, e))
            return
        session.pending_name = ""
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
    if harness == HARNESS_LLM:
        root = ""
        brief = ha.find_brief(session_id)
        if brief is not None:
            root = brief.get("path") or ""
        try:
            return ha.rename_session(session_id, clean, root=root)
        except ha.Err as e:
            raise PiError(str(e))
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

    def refresh_state(self, timeout=COMMAND_TIMEOUT):
        raise NotImplementedError

    def messages(self):
        raise NotImplementedError


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

    def refresh_state(self, timeout=COMMAND_TIMEOUT):
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


class HarnessSession(AgentSession):

    harness = HARNESS_LLM

    def __init__(self, cwd, session_id=None):
        super().__init__(cwd or (ha.HUB.root or ""), model="mtplx")
        self.provider = "harness"
        self.effort = ""
        self.last_usage = {}
        if session_id:
            self.id = str(session_id)
        else:
            try:
                self.id = ha.new_session(root=self.cwd)
            except ha.Err as e:
                raise PiError(str(e))
        if not self.id:
            raise PiError("LLM harness не сообщил идентификатор сессии")
        # корень, в котором живёт сессия в демоне: может отличаться от self.cwd,
        # если сессию открыли, указав другую папку
        brief = ha.find_brief(self.id)
        self.native_root = (brief or {}).get("path") or self.cwd
        ha.HUB.attach(self)

    def alive(self):
        return ha.available()

    def _restart(self):
        pass

    def stop(self):
        ha.HUB.detach(self)

    def prompt(self, text):
        self.counters["userMessages"] += 1
        try:
            ha.ask(self.id, text, root=self.native_root)
        except ha.Err as e:
            raise PiError(str(e))

    def abort(self):
        try:
            ha.stop_run(self.id)
        except ha.Err as e:
            raise PiError(str(e))

    def set_effort(self, effort):
        effort = str(effort or "").strip()
        if effort and effort not in ha.EFFORT_IDS:
            raise PiError("неизвестный уровень размышлений: %s" % effort)
        if effort:
            try:
                ha.set_effort(effort)
            except ha.Err as e:
                raise PiError(str(e))
        self.effort = effort

    def set_model(self, provider, model):
        raise PiError("у LLM harness одна встроенная модель: mtplx")

    def refresh_state(self, timeout=COMMAND_TIMEOUT):
        status = ha.LINK.status()
        if status is None:
            raise PiError("LLM harness недоступен: запустите демон на маке")
        active = str(status.session_id or "") == self.id
        used = int(status.prompt_tokens_last or 0) if active else 0
        window = ha.MODEL["contextWindow"]
        info = ha.find_brief(self.id) or {}
        effort = str(status.settings.thinking_effort or "") if active else self.effort
        if effort:
            self.effort = effort
        usage = dict(self.last_usage) if isinstance(self.last_usage, dict) else {}
        self.state = {
            **self.state,
            "model": {"id": "mtplx", "name": ha.MODEL["name"], "provider": "harness"},
            "thinkingLevel": "on",
            "effort": self.effort,
            "messageCount": int(info.get("messages") or 0) or (self.counters["userMessages"] + self.counters["assistantMessages"]),
            "userMessages": self.counters["userMessages"],
            "assistantMessages": self.counters["assistantMessages"],
            "toolCalls": self.counters["toolCalls"],
            "startedAt": info.get("startedAt") or self.state.get("startedAt"),
            "tokens": {
                "input": int(usage.get("input") or 0),
                "output": int(usage.get("output") or 0),
                "cacheRead": int(usage.get("cacheRead") or 0),
                "total": int(usage.get("total") or 0),
            },
            "contextUsage": {
                "tokens": used,
                "contextWindow": window,
                "percent": round(used / window * 100, 1) if window else 0,
                "estimated": True,
            } if used else None,
            "sessionFile": "",
        }
        return self.state

    def messages(self):
        try:
            return ha.fetch_messages(self.id, root=self.native_root)
        except ha.Err as e:
            raise PiError(str(e))


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
        "path": getattr(session, "native_root", session.cwd),
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
    if session.harness == HARNESS_LLM:
        return ha.translate_harness_event(session, event)
    return translate_claude_event(session, event)


class Pool:

    def __init__(self):
        self.lock = threading.Lock()
        self.sessions = {}
        self.reaper = threading.Thread(target=self._reap, daemon=True)
        self.reaper.start()

    def open(self, cwd, harness=HARNESS_CLAUDE, session_id=None, model=None, effort=None):
        key = session_key(harness, session_id) if session_id else ""
        if key:
            with self.lock:
                session = self.sessions.get(key)
            if session is not None:
                if not session.alive():
                    session._restart()
                session.touched = time.time()
                return session
        session = self._spawn(cwd, harness, session_id, model, effort)
        with self.lock:
            existing = self.sessions.get(session.key)
            if existing is not None and existing is not session:
                session.stop()
                existing.touched = time.time()
                return existing
            self.sessions[session.key] = session
            return session

    def _spawn(self, cwd, harness, session_id, model, effort):
        if harness == HARNESS_CLAUDE:
            session = ClaudeSession(cwd, session_id, model=model, effort=effort)
        elif harness == HARNESS_LLM:
            session = HarnessSession(cwd, session_id)
        else:
            raise PiError("неизвестный харнесс: %s" % harness)
        if not session.id:
            detail = session.stderr_tail[-1] if session.stderr_tail else "без вывода"
            session.stop()
            raise PiError("%s не сообщил идентификатор сессии (%s)" % (harness, detail))
        remember_session_choice(
            session.key,
            model=model,
            effort=session.effort if harness == HARNESS_CLAUDE else None,
        )
        return session

    def maybe(self, key):
        keys = [str(key)]
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
                harness = str((params.get("harness") or [HARNESS_CLAUDE])[0]).strip().lower() or HARNESS_CLAUDE
                self._json(200, {
                    "models": list_models(harness),
                    "harness": harness,
                    "efforts": CLAUDE_EFFORTS if harness == HARNESS_CLAUDE else (ha.EFFORTS if harness == HARNESS_LLM else []),
                })
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
                        if harness == HARNESS_LLM:
                            brief = ha.find_brief(native_id)
                            if brief is None:
                                raise PiError("сессия не найдена: %s" % parts[2])
                            items = []
                            try:
                                items = ha.fetch_messages(native_id, root=brief.get("path") or "")
                            except ha.Err:
                                items = []
                        else:
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
                        if harness == HARNESS_LLM:
                            brief = ha.find_brief(native_id)
                            if brief is None:
                                raise PiError("сессия не найдена: %s" % parts[2])
                            self._json(200, {"session": brief})
                        else:
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
                    if session.harness == HARNESS_LLM:
                        try:
                            data = ha.compact_now()
                        except ha.Err as e:
                            raise PiError(str(e))
                        self._json(200, {"summary": data.get("summaryPreview") or ""})
                        return
                    raise PiError("у Claude Code нет ручной компакции: он сжимает контекст сам")
                elif action == "model":
                    if session.harness == HARNESS_LLM:
                        raise PiError("у LLM harness одна встроенная модель: mtplx")
                    model = str(body.get("modelId") or "").strip()
                    if not model:
                        raise PiError("нужен modelId")
                    session.set_model(HARNESS_CLAUDE, model)
                    session.refresh_state(timeout=STATE_TIMEOUT)
                    self._json(200, {"session": self._session_brief(session)})
                elif action == "effort":
                    if session.harness == HARNESS_LLM:
                        session.set_effort(str(body.get("effort") or ""))
                        session.refresh_state(timeout=STATE_TIMEOUT)
                        self._json(200, {"session": self._session_brief(session)})
                        return
                    if session.harness != HARNESS_CLAUDE:
                        raise PiError("уровень усилия есть только у Claude Code")
                    session.set_effort(str(body.get("effort") or ""))
                    session.refresh_state(timeout=STATE_TIMEOUT)
                    self._json(200, {"session": self._session_brief(session)})
                else:
                    self._json(404, {"error": "неизвестная ручка: %s" % path})
                return
            self._json(404, {"error": "неизвестная ручка: %s" % path})

        self._guard(run)

    def do_DELETE(self):  # noqa: N802
        path, _ = self._route()

        def run():
            parts = path.split("/")
            if len(parts) == 3 and parts[1] == "sessions":
                if split_key(parts[2])[0] == HARNESS_LLM:
                    native_id = split_key(parts[2])[1]
                    session = POOL.take(parts[2])
                    if session is not None:
                        session.stop()
                    root = ""
                    if session is not None:
                        root = getattr(session, "cwd", "")
                    else:
                        brief = ha.find_brief(native_id)
                        if brief is not None:
                            root = brief.get("path") or ""
                    try:
                        ha.delete_session(native_id, root=root)
                    except ha.Err as e:
                        raise PiError(str(e))
                    self._json(200, {"ok": True, "deleted": 1, "restored": 0})
                    return
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
        return {
            "ok": True,
            "harnesses": harness_status(),
            "provider": "",
            "model": "",
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

        sessions = cached_sessions((tuple(str(f) for f in folders), asked), lambda: self._build_sessions(folders, asked, raw=bool(raw)))
        self._json(200, {"path": str(folders[0]) if raw else "", "sessions": sessions})

    def _build_sessions(self, folders, asked, raw=False):
        sessions = []
        if asked == HARNESS_LLM:
            try:
                root = str(folders[0]) if raw else ""
                sessions.extend(ha.list_sessions(root=root))
            except ha.Err:
                pass
        else:
            for folder in folders:
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
        harness = str(body.get("harness") or "").strip().lower() or HARNESS_CLAUDE
        if not raw and harness == HARNESS_LLM:
            raw = ha.HUB.root
        path = allowed_path(raw) if raw else None
        if path is None:
            raise PiError("папка вне разрешённых корней: %s" % raw)
        raw_id = str(body.get("sessionId") or "").strip()
        if harness not in HARNESS_NAMES:
            raise PiError("неизвестный харнесс: %s" % harness)
        session_id = split_key(raw_id)[1] if raw_id else None
        model = str(body.get("model") or "").strip() or None
        effort = str(body.get("effort") or "").strip() or None
        if harness == HARNESS_CLAUDE and effort is not None:
            remember_claude_effort(effort)
        session = POOL.open(path, harness, session_id, model=model, effort=effort)
        session.refresh_state(timeout=STATE_TIMEOUT)
        self._json(200, {"session": self._session_brief(session)})

    def _reopen(self, key):
        harness, native_id = split_key(key)
        if harness == HARNESS_LLM:
            cwd = ""
            brief = ha.find_brief(native_id)
            if brief is not None:
                cwd = brief.get("path") or ""
            if not cwd:
                cwd = ha.HUB.root or str((CONFIG.get("roots") or [str(Path.home() / "work")])[0])
            path = allowed_path(cwd)
            if path is None:
                raise PiError("сессия открыта в папке вне разрешённых корней: %s" % cwd)
            log("поднимаю потерянную сессию harness %s заново в %s" % (key, path))
            return POOL.open(path, harness, native_id)
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
            "path": getattr(session, "native_root", session.cwd),
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
        meta = read_claude_meta(file)
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
            "local": False,
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
    harness_cfg = CONFIG.get("harness") if isinstance(CONFIG.get("harness"), dict) else {}
    ha.init(harness_cfg.get("grpc"), harness_cfg.get("sse"))
    server = ThreadingHTTPServer((host, port), Handler)
    log("мост агента слушает %s:%d, корни: %s" % (host, port, ", ".join(CONFIG.get("roots") or [])))
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
