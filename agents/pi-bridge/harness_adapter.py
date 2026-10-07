"""Адаптер llm-harness для pi-bridge.

llm-harness — один долгоживущий процесс с одним активным разговором:
одновременно разговаривать с несколькими сессиями нельзя. Поэтому:

- команды идут по gRPC (Ask/Stop/Resume/SetSettings/Compact/Status и др.);
- живые события приходят по одной глобальной SSE-ленте без привязки к сессии
  (в них нет session_id), так что мост сам помнит, какая сессия активна;
- чтобы написать в разговор, не являющийся текущим, сначала загружаем его
  (LoadSession) и только потом спрашиваем (Ask).

Сгенерированные pb2-модули (harness_pb2, harness_pb2_grpc) лежат рядом —
собраны из llm-harness/proto/harness.proto.
"""

import json
import threading
import time
import urllib.request

import grpc

import harness_pb2 as pb
import harness_pb2_grpc as pb_grpc

HARNESS = "harness"
NAME = "LLM harness"
TIMEOUT = 20.0
SSE_READ_TIMEOUT = 30

MODEL = {
    "provider": "harness",
    "id": "mtplx",
    "name": "mtplx — qwen3.8-27b",
    "contextWindow": 204_800,
    "maxTokens": 8192,
    "thinking": True,
    "baseUrl": "",
    "local": True,
    "hasKey": True,
}

EFFORTS = [
    {"id": "minimal", "name": "Минимальное — почти без размышлений"},
    {"id": "low", "name": "Низкое"},
    {"id": "medium", "name": "Среднее"},
    {"id": "xhigh", "name": "Очень высокое"},
]
EFFORT_IDS = {e["id"] for e in EFFORTS}


class Err(Exception):
    pass


def grpc_error(exc, fallback):
    code = exc.code() if hasattr(exc, "code") else None
    detail = ""
    try:
        detail = str(exc.details() or "")
    except Exception:
        pass
    if code == grpc.StatusCode.UNAVAILABLE:
        return "LLM harness недоступен: запустите демон на маке"
    if code == grpc.StatusCode.FAILED_PRECONDITION:
        return detail or "harness занят: дождитесь конца текущего прогона"
    return detail or fallback or "ошибка LLM harness"


class Link:
    """gRPC-подключение к демону с ленивой переподключкой."""

    def __init__(self):
        self.addr = "127.0.0.1:9000"
        self.sse = "http://127.0.0.1:9001"
        self._lock = threading.Lock()
        self._channel = None
        self._stub = None

    def configure(self, grpc_addr, sse_base):
        with self._lock:
            self.addr = str(grpc_addr or self.addr).strip() or self.addr
            self.sse = str(sse_base or self.sse).strip().rstrip("/") or self.sse
            self._teardown()

    def _teardown(self):
        channel, self._channel, self._stub = self._channel, None, None
        if channel is not None:
            try:
                channel.close()
            except Exception:
                pass

    def stub(self):
        with self._lock:
            if self._stub is not None:
                try:
                    self._stub.Status(pb.Empty(), timeout=3)
                    return self._stub
                except grpc.RpcError:
                    self._teardown()
            channel = grpc.insecure_channel(self.addr)
            stub = pb_grpc.HarnessStub(channel)
            stub.Status(pb.Empty(), timeout=TIMEOUT)
            self._channel = channel
            self._stub = stub
            return stub

    def call(self, method, request, timeout=TIMEOUT):
        return getattr(self.stub(), method)(request, timeout=timeout)

    def status(self):
        try:
            return self.call("Status", pb.Empty())
        except grpc.RpcError:
            return None


LINK = Link()


class Hub:
    """Подписчик глобальной SSE-ленты harness: разбирает события и развозит
    их по прикреплённым сессиям моста. Активную сессию треким сами: в потоке
    событий session_id нет, а gRPC-ответы знают, кто активен."""

    def __init__(self):
        self.lock = threading.Lock()
        self.attached = {}
        self.active = ""
        self.root = ""

    def start(self):
        threading.Thread(target=self._loop, name="harness-sse", daemon=True).start()

    def set_active(self, session_id):
        sid = str(session_id or "")
        if sid and sid != self.active:
            with self.lock:
                self.active = sid

    def attach(self, session):
        if not session.id:
            return
        with self.lock:
            self.attached.setdefault(session.id, set()).add(session)

    def detach(self, session):
        with self.lock:
            if not session.id:
                return
            group = self.attached.get(session.id)
            if group:
                group.discard(session)
                if not group:
                    self.attached.pop(session.id, None)

    def _loop(self):
        while True:
            try:
                self._read_once()
            except Exception:
                pass
            time.sleep(1)

    def _read_once(self):
        seq = 0
        try:
            health = json.loads(urllib.request.urlopen(LINK.sse + "/health", timeout=5).read())
            seq = int(health.get("seq") or 0)
        except Exception:
            pass
        with urllib.request.urlopen(LINK.sse + "/events?since=%d" % seq, timeout=SSE_READ_TIMEOUT) as stream:
            for raw in stream:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                try:
                    event = json.loads(line[len("data:"):].strip())
                except ValueError:
                    continue
                if isinstance(event, dict):
                    self.route(event)

    def route(self, event):
        etype = str(event.get("type") or "")
        if etype in ("session_loaded", "session_reset"):
            root = str(event.get("root") or "") or root_from_path(event.get("path"))
            if root and root != self.root:
                self.root = root
            if etype == "session_reset":
                sid = str(event.get("session_id") or "")
                if sid:
                    with self.lock:
                        self.active = sid
                    targets = list(self.attached.get(sid) or ())
                else:
                    targets = []
                for session in targets:
                    session._dispatch(event)
            return
        sid = str(event.get("session_id") or self.active)
        if sid:
            with self.lock:
                self.active = sid
                targets = list(self.attached.get(sid) or ())
        else:
            targets = []
        for session in targets:
            session._dispatch(event)


HUB = Hub()


def init(grpc_addr, sse_base):
    LINK.configure(grpc_addr, sse_base)
    status = LINK.status()
    if status is not None:
        HUB.set_active(status.session_id)
        root = str(getattr(status, "root", "") or "") or root_from_path(getattr(status, "loaded_from", ""))
        if root:
            HUB.root = root
    HUB.start()


def _sync_root():
    """Подтягиваем root демона после команды, которая могла его сменить."""
    status = LINK.status()
    if status is None:
        return
    root = str(getattr(status, "root", "") or "") or root_from_path(getattr(status, "loaded_from", ""))
    if root:
        HUB.root = root


def available():
    return LINK.status() is not None


def _require_status():
    status = LINK.status()
    if status is None:
        raise Err("LLM harness недоступен: запустите демон на маке")
    return status


def _check(reply, field="message"):
    message = getattr(reply, field, "")
    if message:
        raise Err(str(message))


def new_session(root=""):
    try:
        reply = LINK.call("NewSession", pb.NewSessionRequest(root=root))
        HUB.set_active(reply.session_id)
        _sync_root()
        return str(reply.session_id or "")
    except grpc.RpcError as e:
        raise Err(grpc_error(e, "не удалось создать сессию harness"))


def load_session(native_id, root=""):
    try:
        reply = LINK.call("LoadSession", pb.LoadSessionRequest(session_id=native_id, root=root))
        HUB.set_active(reply.session_id or native_id)
        _sync_root()
    except grpc.RpcError as e:
        raise Err(grpc_error(e, "не удалось загрузить сессию harness"))


def _load_if_needed(native_id, root=""):
    status = _require_status()
    if str(status.session_id or "") != native_id:
        try:
            LINK.call("LoadSession", pb.LoadSessionRequest(session_id=native_id, root=root))
            HUB.set_active(native_id)
            _sync_root()
        except grpc.RpcError as e:
            raise Err(grpc_error(e, "harness занят другим разговором: дождитесь конца прогона"))


def ask(native_id, prompt, root=""):
    """Вопрос в разговор: если он не активен — сначала грузим. state='queued'
    в ответе значит, что демон к тому моменту ушёл в прогон: просто ждём,
    harness сам достанет сообщение из очереди."""
    _load_if_needed(native_id, root)
    try:
        reply = LINK.call("Ask", pb.AskRequest(prompt=prompt, session_id=native_id), timeout=30)
        HUB.set_active(reply.session_id or native_id)
        return reply
    except grpc.RpcError as e:
        raise Err(grpc_error(e, "не удалось задать вопрос harness"))


def stop_run(native_id):
    if str(_require_status().session_id or "") != native_id:
        return
    try:
        # Ответ Stop — это статус прогона, а не ошибка: после успешной остановки
        # в нём last_error = "stopped by user", проверять его на ошибочность нельзя.
        LINK.call("Stop", pb.Empty())
    except grpc.RpcError as e:
        raise Err(grpc_error(e, "не удалось остановить прогон"))


def resume_run(native_id):
    if str(_require_status().session_id or "") != native_id:
        return
    try:
        _check(LINK.call("Resume", pb.Empty()), "last_error")
    except grpc.RpcError as e:
        raise Err(grpc_error(e, "не удалось продолжить прогон"))


def delete_session(native_id, root=""):
    try:
        reply = LINK.call("DeleteSession", pb.DeleteSessionRequest(session_id=native_id, root=root))
        HUB.set_active(reply.session_id)
        _sync_root()
    except grpc.RpcError as e:
        raise Err(grpc_error(e, "не удалось удалить сессию harness"))


def rename_session(native_id, name, root=""):
    try:
        reply = LINK.call("RenameSession", pb.RenameSessionRequest(session_id=native_id, name=name, root=root))
        if not reply.ok:
            raise Err(str(reply.error or "не удалось переименовать сессию"))
        return str(name)
    except grpc.RpcError as e:
        raise Err(grpc_error(e, "не удалось переименовать сессию"))


def set_effort(effort):
    if effort not in EFFORT_IDS:
        raise Err("неизвестный уровень размышлений: %s" % effort)
    try:
        LINK.call("SetSettings", pb.Settings(thinking_effort=effort))
    except grpc.RpcError as e:
        raise Err(grpc_error(e, "не удалось сменить уровень размышлений"))


def compact_now(keep_last=0):
    try:
        reply = LINK.call("Compact", pb.CompactRequest(keep_last_messages=keep_last), timeout=900)
        if not reply.ok:
            raise Err("сжатие контекста не выполнено")
        return {
            "summaryPreview": str(reply.summary_preview or ""),
            "tokensBefore": int(reply.tokens_before or 0),
            "tokensAfter": int(reply.tokens_after or 0),
        }
    except grpc.RpcError as e:
        raise Err(grpc_error(e, "не удалось сжать контекст"))


def fetch_messages(native_id, root=""):
    """GetMessages читает только активный разговор, так что при необходимости
    сначала загружаем нужный."""
    _load_if_needed(native_id, root)
    try:
        reply = LINK.call("GetMessages", pb.GetMessagesRequest(), timeout=60)
    except grpc.RpcError as e:
        raise Err(grpc_error(e, "не удалось прочитать сообщения"))
    return normalize_messages(list(reply.m))


def list_sessions(root=""):
    try:
        reply = LINK.call("ListSessions", pb.ListSessionsRequest(root=root))
    except grpc.RpcError:
        raise Err("LLM harness недоступен: запустите демон на маке")
    return [session_brief(info) for info in reply.sessions]


def find_brief(native_id):
    try:
        reply = LINK.call("ListSessions", pb.ListSessionsRequest())
    except grpc.RpcError:
        return None
    for info in reply.sessions:
        if info.id == native_id:
            return session_brief(info)
    return None


def ms_to_iso(ms):
    if not ms:
        return ""
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms / 1000)) + "Z"


def root_from_path(path):
    parts = [p for p in str(path or "").split("/") if p]
    if len(parts) >= 3 and parts[-1] == "session.jsonl" and parts[-2] == ".llm-harness":
        return "/" + "/".join(parts[:-2])
    return ""


def session_brief(info):
    return {
        "id": info.id,
        "harness": HARNESS,
        "path": str(info.root or HUB.root or ""),
        "name": str(info.name or ""),
        "preview": str(info.preview or "")[:120],
        "messages": int(info.messages or 0),
        "busy": False,
        "startedAt": ms_to_iso(info.created_ms),
        "updatedAt": ms_to_iso(info.updated_ms),
    }


def _tool_args(raw_args):
    raw_args = str(raw_args or "")
    if not raw_args:
        return {}
    try:
        parsed = json.loads(raw_args)
        return parsed if isinstance(parsed, dict) else {"raw": raw_args}
    except ValueError:
        return {"raw": raw_args}


def normalize_messages(messages):
    items = []
    for message in messages:
        role = str(message.role or "")
        content = str(message.content or "")
        if role in ("system", "tool") or not content:
            continue
        if role == "user":
            items.append({"kind": "user", "text": content, "blocks": []})
            continue
        blocks = []
        reasoning = str(message.reasoning_content or "")
        if reasoning:
            blocks.append({"type": "reasoning", "text": reasoning})
        if content:
            blocks.append({"type": "text", "text": content})
        calls = list(message.tool_calls or ())
        if content or reasoning:
            items.append({
                "kind": "assistant",
                "text": content,
                "reasoning": reasoning,
                "blocks": blocks,
                "tools": [],
            })
        for call in calls:
            items.append({
                "kind": "assistant",
                "text": "",
                "reasoning": "",
                "blocks": [],
                "tools": [{"id": call.id, "name": call.name,
                           "args": _tool_args(call.arguments),
                           "output": "", "isError": False, "running": False}],
            })
    return items


def translate_harness_event(session, event):
    """Событие глобальной ленты harness -> события моста. Возвращает
    (список, done): done=True только на конце прогона."""
    kind = str(event.get("type") or "")

    if kind == "text_delta":
        return [{"type": "delta", "text": str(event.get("text") or "")}], False
    if kind == "thinking_delta":
        return [{"type": "reasoning", "text": str(event.get("text") or "")}], False
    if kind == "tool_start":
        session.counters["toolCalls"] += 1
        return [{"type": "tool_start",
                 "id": str(event.get("tool_call_id") or ""),
                 "name": str(event.get("tool") or ""),
                 "args": {}}], False
    if kind == "tool_end":
        return [{"type": "tool_end",
                 "id": str(event.get("tool_call_id") or ""),
                 "name": str(event.get("tool") or ""),
                 "text": str(event.get("result_preview") or ""),
                 "isError": not bool(event.get("ok"))}], False
    if kind == "usage":
        usage = event.get("usage") or {}
        prompt = int(usage.get("prompt_tokens") or 0)
        completion = int(usage.get("completion_tokens") or 0)
        cache = int(usage.get("cache_read_input_tokens") or 0)
        session.counters["assistantMessages"] += 1
        session.last_usage = {
            "input": prompt,
            "output": completion,
            "cacheRead": cache,
            "total": int(usage.get("total_tokens") or prompt + completion),
        }
        return [{"type": "usage",
                 "input": prompt,
                 "output": completion,
                 "totalTokens": int(usage.get("total_tokens") or prompt + completion)}], False
    if kind == "run_started":
        return [{"type": "status", "step": "прогон запущен"}], False
    if kind == "queued":
        return [{"type": "status", "step": "сообщение в очереди harness"}], False
    if kind in ("run_done", "run_stopped"):
        return [], True
    if kind == "run_resumed":
        return [{"type": "status", "step": "прогон продолжён"}], False
    if kind == "main_paused":
        return [{"type": "status", "step": "основной агент ждёт подагентов"}], False
    if kind == "subagent_started":
        return [{"type": "status", "step": "подзадача запущена"}], False
    if kind == "subagent_finished":
        return [{"type": "status", "step": "подзадача завершена"}], False
    if kind == "compact_started":
        return [{"type": "status", "step": "сжатие контекста"}], False
    if kind == "compact_done":
        return [{"type": "compacted", "summarized": int(event.get("summarized") or 0)}], False
    if kind == "error":
        return [{"type": "error", "message": str(event.get("message") or "ошибка модели")}], False
    if kind == "session_reset":
        return [{"type": "status", "step": "разговор сброшен"}], False
    return [], False
