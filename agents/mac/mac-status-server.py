#!/usr/bin/env python3
"""
mac-status-server.py — remote management panel for the (VPS-style) Mac.

Endpoints (all bound to 127.0.0.1; reached by the Cloudly backend over a reverse-SSH tunnel,
and requiring the X-Mac-Token header when MAC_SERVICE_TOKEN is set):
  GET  /api/status        -> JSON: cpu/ram/disk/top/ip/services/security/battery/warp
  GET  /api/history       -> JSON: {t:[...], cpu:[...], mem:[...]} last ~100 min
  POST /api/action        -> {"action": name} from the ACTIONS whitelist below
  POST /api/warp          -> {"op": connect|disconnect|reconnect|status} — Cloudflare WARP
  /api/github-actions/*   -> file-backed GitHub Actions dashboard
  /api/pull-requests/*    -> open pull requests of the configured repositories
  /api/envs*              -> list/read/write .env files under ~/work
  /api/term/*             -> console over a pty (poll-based)

Anything outside /api/* returns 404: the browser UI and PWA were removed — the Cloudly app
is the only client.

Stdlib only.
"""
import calendar
import http.server
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import threading
import time
import collections
import urllib.parse
import pty
import fcntl
import termios
import struct
import select
import signal

import github_actions
import pull_requests

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18810
UID = subprocess.run(["id", "-u"], capture_output=True, text=True).stdout.strip() or "501"
GUI = f"gui/{UID}"

# Access log location, overridable via env (plist sets it into the project logs/).
ACCESS_LOG = os.environ.get("MAC_STATUS_ACCESS_LOG") or "/tmp/mac-status-access.log"

# Cloudflare WARP (corporate Zero Trust, org "tangem"): control from the panel.
# /usr/local/bin/warp-cli is a symlink into /Applications/Cloudflare WARP.app.
WARP_CLI = os.environ.get("WARP_CLI") or "/usr/local/bin/warp-cli"

# Service token for /api/*: only the Cloudly backend (the sole holder of the value) may drive
# the panel over the reverse-SSH tunnel. Read from the environment first, then from ~/work/.env
# (secrets stay out of plists, same as github_actions). Empty = check disabled, so the browser
# panel behind nginx basic-auth keeps working until the token is provisioned on both sides.
def _load_service_token():
    tok = (os.environ.get("MAC_SERVICE_TOKEN") or "").strip()
    if tok:
        return tok
    try:
        with open(os.path.expanduser("~/work/.env"), "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MAC_SERVICE_TOKEN="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


SERVICE_TOKEN = _load_service_token()

ACTIONS = {
    "reboot":          "sudo -n shutdown -r now",
    "sleep":           "sudo -n pmset sleepnow",
    "restart-tunnel":  f"launchctl kickstart -k {GUI}/com.agent.mac-tunnel",
    "restart-status":  f"launchctl kickstart -k {GUI}/com.agent.mac-status",
    "firewall-on":     "sudo -n /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on",
    "sleep-off":       "sudo -n pmset -a sleep 0 disablesleep 1",
    "claude-start":    f"launchctl kickstart {GUI}/com.agent.claude-tangem",
    "claude-restart":  f"launchctl kickstart -k {GUI}/com.agent.claude-tangem",
}

_CACHES = {"ip": {"t": 0, "v": None}, "sec": {"t": 0, "v": None},
           "warp": {"t": 0, "v": None}, "worg": {"t": 0, "v": None}}
_HIST = collections.deque(maxlen=400)  # ~100 min at 15s


def sh(cmd, timeout=8):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return (r.stdout or "").strip()
    except Exception:
        return ""


def cached(key, ttl, fetch):
    c = _CACHES[key]
    if time.time() - c["t"] > ttl:
        try:
            c["v"] = fetch()
            c["t"] = time.time()
        except Exception:
            pass
    return c["v"]


def _public_ip():
    return sh("curl -sS -m 6 https://api.ipify.org", timeout=8) or None


def _services():
    out = {}
    for label in ("com.agent.mac-tunnel", "com.agent.mac-status",
                  "com.agent.claude-tangem"):
        m = re.search(rf"^(\S+)\s+(\S+)\s+{re.escape(label)}\s*$",
                      sh("launchctl list"), re.M)
        out[label] = {"pid": m.group(1) if m else None, "status": m.group(2) if m else None,
                      "running": bool(m and m.group(1) != "-")}
    return out


def _security():
    fw = sh("sudo -n /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate", timeout=6)
    rl = sh("sudo -n systemsetup -getremotelogin", timeout=6)
    logins = []
    for line in sh("last -n 8").splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 6:
            logins.append({"user": parts[0], "mon": parts[3], "day": parts[4],
                           "time": parts[5], "host": parts[6] if len(parts) > 6 else ""})
    return {
        "firewall": ("on" if "enabled" in fw.lower() or fw.lower().endswith("= 1") else
                     ("off" if "disabled" in fw.lower() or "= 0" in fw else "?")),
        "remote_login": ("On" if "On" in rl else ("Off" if "Off" in rl else "?")),
        "logins": logins[:6],
    }


def _warp_status():
    """Cloudflare WARP state via `warp-cli -j status` (org name cached 5 min).
    Result: {ok, installed, state: "Connected"/"Disconnected"/…, reason, org}."""
    if not os.path.exists(WARP_CLI):
        return {"ok": False, "installed": False, "state": None,
                "reason": "", "org": None, "error": "warp-cli not found"}
    out = sh(f"{WARP_CLI} -j status", timeout=6)
    try:
        st = json.loads(out)
    except ValueError:
        return {"ok": False, "installed": True, "state": None,
                "reason": "", "org": None,
                "error": (out or "warp-cli: no output")[:200]}
    org = cached("worg", 300,
                 lambda: sh(f"{WARP_CLI} registration organization", timeout=6) or None)
    reason = st.get("reason") or ""
    if isinstance(reason, dict):
        # e.g. {"SettingsChanged": {...}} — show just the event kind
        reason = (list(reason.keys())[0] if reason else "") or "settings changed"
    return {"ok": True, "installed": True,
            "state": str(st.get("status") or "?"),
            "reason": str(reason)[:60],
            "org": org}


def _warp_op(op):
    """Connect/disconnect/reconnect the corporate WARP tunnel. Commands are
    idempotent; reconnect = disconnect + connect (the tunnel drops for a few
    seconds — normal, launchd keeps the reverse tunnel self-healing). Waits up
    to ~25 s for the daemon to reach the expected state before replying."""
    if op == "status":
        return _warp_status()
    if op not in ("connect", "disconnect", "reconnect"):
        return {"ok": False, "msg": f"unknown warp op: {op}"}
    if not os.path.exists(WARP_CLI):
        return {"ok": False, "msg": "warp-cli not found"}
    goal = "Connected" if op in ("connect", "reconnect") else "Disconnected"
    if op == "reconnect":
        cmd = f"{WARP_CLI} disconnect; sleep 2; {WARP_CLI} connect"
    else:
        cmd = f"{WARP_CLI} {op}"
    try:
        p = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True)
    except Exception as e:
        return {"ok": False, "msg": f"cannot start warp {op}: {e}"}
    _CACHES["warp"]["t"] = 0
    out = ""
    try:
        out, _ = p.communicate(timeout=4)  # cli returns quickly; tunnel settles async
    except subprocess.TimeoutExpired:
        pass
    deadline = time.time() + 25
    last = None
    while time.time() < deadline:
        time.sleep(1)
        try:
            last = _warp_status()
        except Exception:
            last = None
        if last and last.get("ok") and last.get("state") == goal:
            _CACHES["warp"]["t"] = 0
            return {"ok": True, "msg": f"warp {op} — now {last.get('state')}",
                    "state": last.get("state")}
    _CACHES["warp"]["t"] = 0
    st = last or _warp_status()
    if st.get("ok"):
        return {"ok": st.get("state") == goal, "state": st.get("state"),
                "msg": f"warp {op} — state is {st.get('state')}"
                       + (f" · cli: {(out or '').strip()[-120:]}" if out.strip() else "")}
    return {"ok": False, "msg": f"warp {op} — cannot read status: {st.get('error') or '?'}"}


def collect():
    now = time.time()

    # CPU
    la = sh("sysctl -n vm.loadavg")
    load = re.findall(r"[\d.]+", la)[:3] if la else ["?", "?", "?"]
    idle = None
    top = sh("top -l 1 -n 0 | grep 'CPU usage'", timeout=5)
    m_idle = re.search(r"([\d.]+)% idle", top or "")
    if m_idle:
        idle = float(m_idle.group(1))
    busy = None if idle is None else round(100.0 - idle, 1)

    # RAM
    total_gb = None
    try:
        total_gb = round(int(sh("sysctl -n hw.memsize")) / 1073741824, 1)
    except Exception:
        pass
    free_pct = None
    mfp = re.search(r"free percentage:\s*(\d+)%", sh("memory_pressure"))
    if mfp:
        free_pct = float(mfp.group(1))
    used_pct = None if free_pct is None else round(100.0 - free_pct, 1)
    used_gb = None
    if used_pct is not None and total_gb is not None:
        used_gb = round(total_gb * used_pct / 100.0, 1)

    # Disk (real volumes only: macOS df -> mount is the LAST column)
    disks = []
    seen = set()
    for line in sh("df -k -l").splitlines()[1:]:
        p = line.split()
        if len(p) < 9:
            continue
        mount = p[-1]
        if mount not in ("/", "/System/Volumes/Data") and not mount.startswith("/Volumes/"):
            continue
        if mount in seen:
            continue
        seen.add(mount)
        try:
            disks.append({"mount": mount,
                          "size_gb": round(int(p[1]) / 1048576),
                          "used_gb": round(int(p[2]) / 1048576),
                          "avail_gb": round(int(p[3]) / 1048576),
                          "pct": p[4]})
        except ValueError:
            continue
    disks.sort(key=lambda d: d["size_gb"], reverse=True)

    # Top processes (instant-ish: ps lifetime %cpu; sort by it)
    tops = []
    for line in sh("ps -Ao rss=,%cpu=,comm= -r").splitlines():
        p = line.split(None, 2)
        if len(p) == 3:
            try:
                tops.append({"rss_mb": round(int(p[0]) / 1024), "cpu": float(p[1]),
                             "comm": p[2][:40]})
            except ValueError:
                pass
    tops.sort(key=lambda t: t["cpu"], reverse=True)

    # Battery / power
    batt_raw = sh("pmset -g batt")
    batt = {"present": "-InternalBattery" in batt_raw or "InternalBattery" in batt_raw}
    if batt["present"]:
        batt["source"] = "AC" if "AC Power" in batt_raw else ("Battery" if "Battery Power" in batt_raw else "?")
        m_pct = re.search(r"(\d+)%", batt_raw)
        batt["percent"] = int(m_pct.group(1)) if m_pct else None
        state = "?"
        for s in ("charged", "charging", "discharging"):
            if s in batt_raw:
                state = s
                break
        batt["state"] = state
    else:
        batt = {"present": False}

    # Uptime
    boot = sh("sysctl -n kern.boottime")
    uptime = ""
    m = re.search(r"sec = (\d+)", boot)
    if m:
        secs = int(now) - int(m.group(1))
        d, rem = divmod(max(secs, 0), 86400)
        h, rem = divmod(rem, 3600)
        uptime = f"{d}d {h}h {rem // 60}m"

    # Network
    iface = sh("route -n get default 2>/dev/null | awk '/interface:/{print $2}'")
    ip = sh(f"ipconfig getifaddr {iface}") if iface else ""

    return {
        "host": sh("scutil --get ComputerName") or sh("hostname") or "mac",
        "ts": now,
        "cpu": {"load1": load[0], "load5": load[1], "load15": load[2], "busy": busy},
        "mem": {"total_gb": total_gb, "used_gb": used_gb, "used_pct": used_pct},
        "disk": disks,
        "top": tops[:6],
        "public_ip": cached("ip", 60, _public_ip),
        "services": _services(),
        "security": cached("sec", 30, _security),
        "battery": batt,
        "uptime": uptime or None,
        "net": {"iface": iface or None, "ip": ip or None},
        "warp": cached("warp", 2, _warp_status),
    }


def _sampler():
    while True:
        try:
            s = collect()
            cpu = s["cpu"]["busy"]
            mem = s["mem"]["used_pct"]
            if cpu is not None and mem is not None:
                _HIST.append([int(time.time()), cpu, mem])
        except Exception:
            pass
        time.sleep(15)


def do_action(name):
    if name not in ACTIONS:
        return {"ok": False, "msg": f"unknown action: {name}"}
    subprocess.Popen(ACTIONS[name], shell=True)
    _CACHES["sec"]["t"] = 0
    return {"ok": True, "msg": f"{name} started"}


# ---------------------------------------------------------------------------
# Cron jobs (real crontab, not launchd) monitored from this panel. Each is a
# lock+log wrapper script; "installed" checks the line is present in
# `crontab -l`, "last tick"/"24h ok/fail" come from its own log files.
# ---------------------------------------------------------------------------
CRON_JOBS = [
    {
        "name": "release-notifier",
        "line": "*/5 * * * * /Users/sobogd/work/release-bot/notify.sh",
        "script": "/Users/sobogd/work/release-bot/notify.sh",
        "log": "/Users/sobogd/work/release-bot/notify.log",
        "json_log": None,
        "interval_min": 5,
    },
    {
        "name": "pr-status-sync",
        "line": "*/30 * * * * /Users/sobogd/work/jira-tools/pr_status_sync_cron.sh",
        "script": "/Users/sobogd/work/jira-tools/pr_status_sync_cron.sh",
        "log": "/Users/sobogd/work/jira-tools/pr_status_sync.run.log",
        "json_log": "/Users/sobogd/work/jira-tools/pr_status_sync.log.jsonl",
        "interval_min": 30,
    },
]
_CRON_TICK_RE = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) tick\b")


def _crontab_raw():
    try:
        r = subprocess.run(["crontab", "-l"], capture_output=True, text=True, timeout=6)
    except Exception as e:
        return {"ok": False, "lines": [], "error": str(e)}
    if r.returncode != 0:
        return {"ok": False, "lines": [], "error": (r.stderr or "crontab -l failed").strip()}
    return {"ok": True, "lines": [l for l in r.stdout.splitlines() if l.strip()], "error": None}


def _cron_daemon_running():
    return bool(sh("pgrep -x cron"))


def _cron_last_tick(log_path):
    try:
        with open(log_path, "r", errors="ignore") as f:
            text = f.read()
    except OSError:
        return None
    ticks = _CRON_TICK_RE.findall(text)
    return ticks[-1] if ticks else None


def _cron_attempts_24h(json_log_path):
    """Aggregate the last 24h of a job's JSON-lines attempt log, if it has one.
    "run_start"/"run_end" are run-level markers, not per-key attempts -- only
    the last "run_end" is used, to report the last full run's duration."""
    if not json_log_path or not os.path.isfile(json_log_path):
        return None
    ok = fail = 0
    last_fail = None
    last_run_end = None
    try:
        with open(json_log_path, "r", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                event = o.get("event", "key")
                if event == "run_end":
                    last_run_end = o
                    continue
                if event != "key":
                    continue
                if o.get("success"):
                    ok += 1
                else:
                    fail += 1
                    last_fail = o.get("reason") or o.get("outcome") or last_fail
    except OSError:
        pass
    return {"ok": ok, "fail": fail, "last_fail_reason": last_fail,
            "last_run_duration_s": (last_run_end or {}).get("duration_s"),
            "last_run_failed": (last_run_end or {}).get("failed")}


def _cron_job_running(script_path):
    return bool(sh("pgrep -f %s" % shlex.quote(script_path)))


def _cron_status():
    ct = _crontab_raw()
    jobs = []
    for j in CRON_JOBS:
        installed = any(j["script"] in l for l in ct["lines"])
        last_tick = _cron_last_tick(j["log"])
        stale = None
        if last_tick:
            try:
                age_min = (time.time() - calendar.timegm(
                    time.strptime(last_tick, "%Y-%m-%dT%H:%M:%SZ"))) / 60
                stale = age_min > j["interval_min"] * 3
            except (ValueError, OverflowError):
                stale = None
        jobs.append({
            "name": j["name"], "line": j["line"], "installed": installed,
            "last_tick": last_tick, "stale": stale, "interval_min": j["interval_min"],
            "running": _cron_job_running(j["script"]),
            "attempts_24h": _cron_attempts_24h(j.get("json_log")),
        })
    return {"daemon_running": _cron_daemon_running(),
            "crontab_ok": ct["ok"], "crontab_error": ct["error"], "jobs": jobs}


def _cron_install():
    """Add any missing CRON_JOBS lines to the real crontab, keeping whatever
    else is already there untouched."""
    ct = _crontab_raw()
    lines = list(ct["lines"]) if ct["ok"] else []
    changed = False
    for j in CRON_JOBS:
        if not any(j["script"] in l for l in lines):
            lines.append(j["line"])
            changed = True
    if not changed and ct["ok"]:
        return {"ok": True, "msg": "crontab already has all jobs"}
    tmp = "/tmp/mac-status-crontab.txt"
    try:
        with open(tmp, "w") as f:
            f.write("\n".join(lines) + "\n")
        r = subprocess.run(["crontab", tmp], capture_output=True, text=True, timeout=6)
    except Exception as e:
        return {"ok": False, "msg": str(e)}
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass
    if r.returncode != 0:
        return {"ok": False, "msg": (r.stderr or "crontab install failed").strip()}
    return {"ok": True, "msg": "crontab updated"}


def _cron_op(name, op):
    if op == "install":
        return _cron_install()
    job = next((j for j in CRON_JOBS if j["name"] == name), None)
    if not job:
        return {"ok": False, "msg": f"unknown cron job: {name}"}
    if op == "run":
        subprocess.Popen(job["script"])
        return {"ok": True, "msg": f"{name}: triggered"}
    return {"ok": False, "msg": f"unknown op: {op}"}


# ---------------------------------------------------------------------------
# Claude Code (tangem profile) subscription re-login, done from this page.
# claude auth login prints an authorize URL and then waits for a pasted code
# on stdin — perfect to relay through the page (open URL on the phone, paste
# the code back). BROWSER is neutralised so no browser opens on the Mac.
# ---------------------------------------------------------------------------
CLAUDE_DIR = os.path.expanduser("~/.claude-work")
_claude = {"proc": None, "url": None, "log": [], "t0": 0}


def _claude_env():
    env = dict(os.environ)
    env["CLAUDE_CONFIG_DIR"] = CLAUDE_DIR
    env["BROWSER"] = "/usr/bin/true"
    env["PATH"] = "/Users/sobogd/.nvm/versions/node/v22.22.2/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + env.get("PATH", "")
    return env


def _claude_status():
    st = {}
    try:
        r = subprocess.run(["claude", "auth", "status"], capture_output=True, text=True,
                           timeout=25, env=_claude_env())
        st = json.loads(r.stdout or "{}")
    except Exception:
        pass
    email = None
    try:
        cfg = json.load(open(os.path.join(CLAUDE_DIR, ".claude.json")))
        email = (cfg.get("oauthAccount") or {}).get("emailAddress")
    except Exception:
        pass
    proc = _claude["proc"]
    running = bool(proc and proc.poll() is None)
    ag = re.search(r"^(\S+)\s+\S+\s+com\.agent\.claude-tangem\s*$", sh("launchctl list"), re.M)
    return {
        "dir": CLAUDE_DIR,
        "loggedIn": bool(st.get("loggedIn")),
        "authMethod": st.get("authMethod") or "none",
        "email": email,
        "agentRunning": bool(ag and ag.group(1) != "-"),
        "agentPid": ag.group(1) if ag else None,
        "loginRunning": running,
        "url": _claude["url"] or "",
        "logTail": _claude["log"][-4:],
    }


def _claude_login():
    c = _claude
    if c["proc"] and c["proc"].poll() is None:
        return {"ok": False, "msg": "a login is already running — paste its code"}
    c["url"] = None
    c["log"] = []
    try:
        proc = subprocess.Popen(["claude", "auth", "login", "--claudeai"],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, env=_claude_env())
    except Exception as e:
        return {"ok": False, "msg": f"cannot start login: {e}"}
    c["proc"] = proc
    c["t0"] = time.time()

    def reader():
        try:
            for line in proc.stdout:
                c["log"].append(line.rstrip("\n"))
                m = re.search(r"https://claude\.com[^ \r\n]+", line)
                if m and not c["url"]:
                    c["url"] = m.group(0)
        except Exception:
            pass
        c["log"].append("__EOF__")

    threading.Thread(target=reader, daemon=True).start()
    deadline = time.time() + 10
    while time.time() < deadline:
        if c["url"]:
            return {"ok": True, "url": c["url"],
                    "msg": "open the URL, authorize, then paste the code below"}
        if proc.poll() is not None:
            break
        time.sleep(0.2)
    if c["url"]:
        return {"ok": True, "url": c["url"], "msg": "open the URL and paste the code"}
    return {"ok": False, "msg": "login did not produce a URL: " + " ".join(c["log"][-5:])}


def _claude_code(code):
    c = _claude
    proc = c["proc"]
    if not proc or proc.poll() is not None:
        return {"ok": False, "msg": "no login in progress — press “start login” first"}
    try:
        proc.stdin.write((code or "").strip() + "\n")
        proc.stdin.flush()
    except Exception as e:
        return {"ok": False, "msg": f"cannot send code: {e}"}
    t0 = time.time()
    while time.time() - t0 < 45:
        if proc.poll() is not None:
            ok = proc.returncode == 0
            return {"ok": ok, "msg": "logged in ✓" if ok else "login failed — check code / retry",
                    "log": c["log"][-6:]}
        if not any("Paste code" in l for l in c["log"]) and any("rror" in l for l in c["log"][-3:]):
            break
        time.sleep(0.5)
    return {"ok": False, "msg": "still finishing — refresh status", "log": c["log"][-4:]}




# ---------------------------------------------------------------------------
# .env files: list/edit every file whose name contains ".env", recursively
# under ~/work (used by the /envs page). Stdlib only.
# ---------------------------------------------------------------------------
ENV_ROOT = os.environ.get("MAC_STATUS_ENV_ROOT") or os.path.expanduser("~/work")
_ENV_SKIP_DIRS = {"node_modules", ".git", ".venv", "venv", "dist", "build",
                  ".next", ".turbo", "coverage", "__pycache__", ".cache",
                  "DerivedData", "Pods", ".gradle", ".idea", ".obsidian", ".DS_Store"}
_ENV_BACKUP_DIR = os.path.expanduser("~/.mac-status-env-backups")
_ENV_SCAN_CACHE = {"t": 0, "v": []}
_ENV_MAX_OPEN = 2 * 1024 * 1024  # refuse to show files bigger than 2 MiB in browser


def _env_is_env_name(name):
    """The user asked for any file with a ".env" occurrence in its name."""
    return ".env" in name.lower()


def _env_scan(force=False):
    now = time.time()
    if not force and now - _ENV_SCAN_CACHE["t"] < 3:
        return _ENV_SCAN_CACHE["v"]
    found = []
    if os.path.isdir(ENV_ROOT):
        for dp, dns, fns in os.walk(ENV_ROOT):
            dns[:] = sorted(d for d in dns if d not in _ENV_SKIP_DIRS)
            for fn in fns:
                if not _env_is_env_name(fn):
                    continue
                full = os.path.join(dp, fn)
                try:
                    st = os.stat(full)
                except OSError:
                    continue
                rel = os.path.relpath(full, ENV_ROOT)
                base = fn.lower()
                kind = ("live" if ".env" == base or
                        (base.startswith(".env.") and not any(
                            x in base for x in ("example", "sample", "template", ".env.dist")))
                        else "sample")
                found.append({"path": rel, "name": fn, "size": st.st_size,
                              "mtime": int(st.st_mtime), "kind": kind})
    found.sort(key=lambda f: f["path"].lower())
    _ENV_SCAN_CACHE.update(t=now, v=found)
    return found


def _env_resolve(rel):
    """Turn a client-supplied relative path into a real file inside ENV_ROOT."""
    if not rel or rel.startswith("/") or ".." in rel.split("/"):
        return None
    full = os.path.realpath(os.path.join(ENV_ROOT, rel))
    root = os.path.realpath(ENV_ROOT)
    if full != root and not full.startswith(root + os.sep):
        return None
    if not os.path.isfile(full):
        return None
    if not _env_is_env_name(os.path.basename(full)):
        return None
    return full


def _env_read(rel):
    full = _env_resolve(rel)
    if not full:
        return {"ok": False, "msg": "path is not an editable .env file"}
    try:
        st = os.stat(full)
        if st.st_size > _ENV_MAX_OPEN:
            return {"ok": False, "msg": f"file too big for the browser editor ({st.st_size} bytes)"}
        with open(full, "rb") as f:
            raw = f.read()
        content = raw.decode("utf-8")  # strict: refuse to silently corrupt non-UTF-8
    except UnicodeDecodeError:
        return {"ok": False, "msg": "file is not UTF-8 — open it in a terminal instead"}
    except OSError as e:
        return {"ok": False, "msg": str(e)}
    return {"ok": True, "path": rel, "content": content, "size": len(raw),
            "mtime": int(st.st_mtime)}


def _env_write(rel, content):
    full = _env_resolve(rel)
    if not full:
        return {"ok": False, "msg": "path is not an editable .env file"}
    if not isinstance(content, str):
        return {"ok": False, "msg": "content must be text"}
    if len(content.encode("utf-8")) > 5 * 1024 * 1024:
        return {"ok": False, "msg": "content too large"}
    try:
        st = os.stat(full)
        with open(full, "rb") as f:
            old = f.read()
        if old == content.encode("utf-8"):
            return {"ok": True, "msg": "no changes"}
    except OSError as e:
        return {"ok": False, "msg": str(e)}
    # Safety: keep a timestamped backup before overwriting secrets.
    try:
        os.makedirs(_ENV_BACKUP_DIR, exist_ok=True)
        stem = rel.replace("/", "__")
        os.makedirs(os.path.join(_ENV_BACKUP_DIR, os.path.dirname(stem)), exist_ok=True)
        dst = os.path.join(_ENV_BACKUP_DIR, stem + "." + time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(full, dst)
        # prune: keep the newest 50 backups of this file
        pat = stem + "."
        vers = sorted(n for n in os.listdir(os.path.join(_ENV_BACKUP_DIR, os.path.dirname(stem)))
                      if n.startswith(os.path.basename(pat)))
        for old in vers[:-50]:
            try:
                os.remove(os.path.join(_ENV_BACKUP_DIR, os.path.dirname(stem), old))
            except OSError:
                pass
    except OSError as e:
        return {"ok": False, "msg": f"backup failed: {e}"}
    # Atomic replace: write tmp in same dir, then rename. Keep original mode.
    tmp = full + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8", newline="") as f:
            f.write(content)
        os.chmod(tmp, st.st_mode & 0o7777)
        os.replace(tmp, full)
    except OSError as e:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return {"ok": False, "msg": str(e)}
    _ENV_SCAN_CACHE["t"] = 0  # rescan on next list
    return {"ok": True, "path": rel, "msg": "saved (backup kept in ~/.mac-status-env-backups)",
            "size": len(content.encode("utf-8")), "mtime": int(time.time())}




# ---------------------------------------------------------------------------
# Web console (/term): one persistent shell over a pty, used as a plain
# "type a line, read the output" console (no terminal emulation). The page
# polls /api/term/poll for output deltas and posts whole input lines via
# /api/term/input. Stdlib only (pty). Reset = fresh shell (/api/term/reset).
# We use bash --noprofile --norc -i with a minimal prompt + TERM=dumb: it gives
# the cleanest transcript (no ZLE/bracket-paste noise) while cd state persists
# and ^C still interrupts the foreground command.
# ---------------------------------------------------------------------------
TERM_SHELL = os.environ.get("MAC_STATUS_TERM_SHELL") or "/bin/bash"
TERM_CWD = os.environ.get("MAC_STATUS_TERM_CWD") or os.path.expanduser("~")
_TERM = {"lock": threading.RLock(), "pid": None, "fd": None, "shell": None,
         "reader": None, "dead": True, "t0": 0,
         "buf": collections.deque(), "base": 0, "total": 0}


def _term_env():
    env = dict(os.environ)
    env["TERM"] = "dumb"          # no colors / cursor codes -> clean text transcript
    env["PS1"] = "$ "
    env["PROMPT_COMMAND"] = ""
    env["BASH_SILENCE_DEPRECATION_WARNING"] = "1"
    env.setdefault("LANG", "en_US.UTF-8")
    # Keep the same toolchain PATH the rest of the panel uses.
    env["PATH"] = "/Users/sobogd/.nvm/versions/node/v22.22.2/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["HOME"] = os.path.expanduser("~")
    return env


def _term_args():
    """Shell argv for a clean interactive console that survives ^C."""
    base = os.path.basename(TERM_SHELL)
    if base == "bash":
        return [TERM_SHELL, "--noprofile", "--norc", "-i"]
    return [TERM_SHELL, "-l", "-i"]  # zsh etc.: full login shell


def _term_start():
    with _TERM["lock"]:
        if not _TERM["dead"]:
            return {"ok": True, "pid": _TERM["pid"], "already": True}
        try:
            pid, fd = pty.fork()
        except OSError as e:
            return {"ok": False, "msg": f"fork: {e}"}
        if pid == 0:  # child: exec the console shell on the pty
            try:
                os.chdir(TERM_CWD)
            except OSError:
                pass
            os.execvpe(TERM_SHELL, _term_args(), _term_env())
            os._exit(127)
        _TERM.update(pid=pid, fd=fd, dead=False, t0=time.time(),
                     buf=collections.deque(), base=0, total=0, shell=TERM_SHELL)
        threading.Thread(target=_term_reader, args=(pid, fd), daemon=True).start()
        return {"ok": True, "pid": pid, "already": False}


def _term_reader(pid, fd):
    while True:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        try:
            text = data.decode("utf-8", "replace")
        except Exception:
            text = data.decode("latin-1", "replace")
        with _TERM["lock"]:
            if _TERM["fd"] != fd:
                break
            _TERM["buf"].append(text)
            _TERM["total"] += len(text)
            # Keep only the last ~1 MB of terminal output in memory.
            while _TERM["total"] - _TERM["base"] > 1_000_000 and _TERM["buf"]:
                head = _TERM["buf"].popleft()
                _TERM["base"] += len(head)
    # EOF / error -> session is over; reap the child.
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    with _TERM["lock"]:
        if _TERM["fd"] == fd:
            _TERM["dead"] = True
            _TERM["pid"] = None
            try:
                os.close(fd)
            except OSError:
                pass
            _TERM["fd"] = None


def _term_out_since(after):
    """Return (text, new_after) for everything after absolute index 'after'."""
    with _TERM["lock"]:
        if after < _TERM["base"]:
            after = _TERM["base"]  # old data already trimmed away
        parts = []
        pos = _TERM["base"]
        for chunk in _TERM["buf"]:
            end = pos + len(chunk)
            if end <= after:
                pos = end
                continue
            cut = after - pos
            parts.append(chunk[cut:] if cut > 0 else chunk)
            pos = end
        return "".join(parts), pos


def _term_poll(after):
    txt, new_after = _term_out_since(int(after or 0))
    with _TERM["lock"]:
        dead = _TERM["dead"]
        pid = _TERM["pid"]
    return {"ok": True, "out": txt, "after": new_after, "dead": dead, "pid": pid}


# Command history for the console: lives in the server process, not in the
# browser, so the "↑ rerun" button works from any device/tab and keeps working
# after a page reload or a shell reset. Newest command is last.
TERM_HIST_MAX = 50
_TERM_HIST = []


def _term_hist_add(line):
    """Record one submitted command line (dedupe consecutive repeats)."""
    line = (line or "").strip()
    if not line or line[0] in ("\x03", "\x04"):  # ^C / ^D are not commands
        return
    with _TERM["lock"]:
        if _TERM_HIST and _TERM_HIST[-1] == line:
            return
        _TERM_HIST.append(line)
        del _TERM_HIST[:-TERM_HIST_MAX]


def _term_write(data):
    data = data or ""
    with _TERM["lock"]:
        fd = _TERM["fd"]
        if _TERM["dead"] or fd is None:
            return {"ok": False, "msg": "no terminal session — press reset"}
    if "\r" in data or "\n" in data:  # a submitted line ("cmd\r") -> history
        for part in re.split(r"[\r\n]+", data):
            _term_hist_add(part)
    try:
        os.write(fd, data.encode("utf-8"))
    except OSError as e:
        return {"ok": False, "msg": str(e)}
    return {"ok": True}


def _term_history():
    """Newest-first list of the commands typed in this panel's console."""
    with _TERM["lock"]:
        return {"ok": True, "hist": list(reversed(_TERM_HIST))}


def _term_again(idx=0):
    """Re-run a command from history and re-print it: 0 = last, 1 = previous…"""
    with _TERM["lock"]:
        if not _TERM_HIST:
            return {"ok": False, "msg": "history is empty — run something first"}
        try:
            idx = max(0, min(int(idx or 0), len(_TERM_HIST) - 1))
        except (TypeError, ValueError):
            idx = 0
        cmd = _TERM_HIST[-1 - idx]
        dead = _TERM["dead"]
    if dead:
        return {"ok": False, "dead": True, "cmd": cmd,
                "msg": "shell not running — press reset session"}
    r = _term_write(cmd + "\r")
    if r.get("ok"):
        r["cmd"] = cmd
    return r


def _term_resize(cols, rows):
    try:
        cols = max(20, min(int(cols), 400))
        rows = max(5, min(int(rows), 120))
    except (TypeError, ValueError):
        return {"ok": False, "msg": "bad size"}
    with _TERM["lock"]:
        fd = _TERM["fd"]
        pid = _TERM["pid"]
        if _TERM["dead"] or fd is None:
            return {"ok": False, "msg": "no session"}
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        os.kill(pid, signal.SIGWINCH)
    except OSError as e:
        return {"ok": False, "msg": str(e)}
    return {"ok": True}


def _term_reset():
    with _TERM["lock"]:
        _TERM["dead"] = True
        fd, pid = _TERM["fd"], _TERM["pid"]
        _TERM["fd"] = _TERM["pid"] = None
        _TERM["buf"].clear()
    if pid:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    if fd is not None:
        try:
            os.close(fd)
        except OSError:
            pass
    return _term_start()




class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, obj, ctype="application/json"):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        """True if the request may touch /api/*: disabled until a token is configured."""
        if not SERVICE_TOKEN:
            return True
        return self.headers.get("X-Mac-Token", "") == SERVICE_TOKEN

    def do_GET(self):
        # Панель теперь только API: с ней говорит исключительно бэкенд Cloudly через
        # loopback-туннель, поэтому любой не-/api путь не найден (браузерный UI и PWA удалены).
        if not self.path.startswith("/api/"):
            self._send(404, {"ok": False, "msg": "not found"})
            return
        if not self._authorized():
            self._send(401, {"ok": False, "msg": "unauthorized"})
            return
        if self.path.startswith("/api/status"):
            self._send(200, collect())
        elif self.path.startswith("/api/history"):
            ts, cpu, mem = [], [], []
            for t, c, m in _HIST:
                ts.append(t); cpu.append(c); mem.append(m)
            self._send(200, {"t": ts, "cpu": cpu, "mem": mem})
        elif self.path.startswith("/api/claude"):
            self._send(200, _claude_status())
        elif self.path.startswith("/api/cron"):
            self._send(200, _cron_status())
        elif self.path.startswith("/api/github-actions/refs"):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            self._send(200, github_actions.refs((q.get("repo") or [""])[0]))
        elif self.path.startswith("/api/github-actions"):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            self._send(200, github_actions.dashboard(bool(q.get("refresh"))))
        elif self.path.startswith("/api/pull-requests"):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            self._send(200, pull_requests.board(bool(q.get("refresh"))))
        elif self.path.startswith("/api/envs/list"):
            self._send(200, {"ok": True, "root": ENV_ROOT, "count": len(_env_scan()),
                             "files": _env_scan()})
        elif self.path.startswith("/api/envs/read"):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            self._send(200, _env_read((q.get("path") or [""])[0]))
        elif self.path.startswith("/api/envs"):
            self._send(200, {"ok": True, "root": ENV_ROOT, "count": len(_env_scan()),
                             "files": _env_scan()})
        elif self.path.startswith("/api/term/history"):
            self._send(200, _term_history())
        elif self.path.startswith("/api/term/poll"):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            self._send(200, _term_poll((q.get("after") or ["0"])[0]))
        elif self.path.startswith("/api/term/open"):
            self._send(200, _term_start())
        else:
            self._send(404, {"ok": False, "msg": "not found"})

    def do_POST(self):
        if self.path.startswith("/api/") and not self._authorized():
            self._send(401, {"ok": False, "msg": "unauthorized"})
            return
        try:
            ln = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(ln) or b"{}")
        except Exception:
            data = {}
        if self.path.startswith("/api/action"):
            self._send(200, do_action(data.get("action", "")))
        elif self.path.startswith("/api/github-actions/run"):
            self._send(200, github_actions.dispatch(data))
        elif self.path.startswith("/api/github-actions/rerun"):
            self._send(200, github_actions.rerun(data))
        elif self.path.startswith("/api/github-actions/config"):
            self._send(200, github_actions.edit_config(data))
        elif self.path.startswith("/api/pull-requests/config"):
            self._send(200, pull_requests.edit_config(data))
        elif self.path.startswith("/api/envs/write"):
            self._send(200, _env_write(data.get("path", ""), data.get("content", "")))
        elif self.path.startswith("/api/claude/login"):
            self._send(200, _claude_login())
        elif self.path.startswith("/api/claude/code"):
            self._send(200, _claude_code(data.get("code", "")))
        elif self.path.startswith("/api/claude"):
            self._send(200, _claude_status())
        elif self.path.startswith("/api/warp"):
            self._send(200, _warp_op(data.get("op") or "status"))
        elif self.path.startswith("/api/cron"):
            self._send(200, _cron_op(data.get("job", ""), data.get("op", "")))
        elif self.path.startswith("/api/term/input"):
            self._send(200, _term_write(data.get("data", "")))
        elif self.path.startswith("/api/term/again"):
            self._send(200, _term_again(data.get("idx", 0)))
        elif self.path.startswith("/api/term/resize"):
            self._send(200, _term_resize(data.get("cols", 80), data.get("rows", 24)))
        elif self.path.startswith("/api/term/reset"):
            self._send(200, _term_reset())
        elif self.path.startswith("/api/term/open"):
            self._send(200, _term_start())
        else:
            self._send(404, {"ok": False, "msg": "not found"})

    def log_message(self, *a):
        try:
            with open(ACCESS_LOG, "a") as f:
                f.write(f"{time.strftime('%H:%M:%S')} {self.client_address[0]} {self.requestline}\n")
        except Exception:
            pass


if __name__ == "__main__":
    threading.Thread(target=_sampler, daemon=True).start()
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"mac-control server on http://127.0.0.1:{PORT}")
    srv.serve_forever()
