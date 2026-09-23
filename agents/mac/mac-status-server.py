#!/usr/bin/env python3
"""
mac-status-server.py — remote management panel for the (VPS-style) Mac.

Endpoints (all bound to 127.0.0.1, reached via nginx basic auth + reverse SSH):
  GET  /                  -> HTML panel (cards, history charts, action buttons)
  GET  /api/status        -> JSON: cpu/ram/disk/top/ip/services/security/battery/warp
  GET  /api/history       -> JSON: {t:[...], cpu:[...], mem:[...]} last ~100 min
  POST /api/action        -> {"action": name} from the ACTIONS whitelist below
  POST /api/warp          -> {"op": connect|disconnect|reconnect|status} — Cloudflare
                             WARP corporate tunnel (card on the main page)
  GET  /manifest.json     -> PWA web app manifest (Android Chrome install)
  GET  /sw.js             -> service worker (cache shell, never cache /api/*)
  GET  /icon-192.png /icon-512.png -> PWA icons (PNG8, embedded base64)
  /actions + /api/github-actions/* -> file-backed GitHub Actions dashboard
  /term + /api/term/*     -> plain console over a pty (poll-based); "↑ rerun"
                             re-executes the previous command from server-side
                             history (POST /api/term/again, GET /api/term/history)

Stdlib only.
"""
import base64
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


# ---- PWA (installable app: Android Chrome "Add to Home screen") ------------
# https://status.iq-factura.com is HTTPS, so a web app manifest + a service
# worker with a fetch handler + PNG icons make Chrome offer installing this
# panel as an app. API routes are never cached; the shell page is cached on
# the fly for offline. Icons are flat PNG8 (regenerate with ImageMagick).

PWA_MANIFEST = {
    "id": "/",
    "name": "Mac control",
    "short_name": "Mac",
    "description": "Remote status and control panel for the Mac",
    "start_url": "/",
    "scope": "/",
    "display": "standalone",
    "background_color": "#0d1117",
    "theme_color": "#0d1117",
    "icons": [
        {"src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any"},
        {"src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any"},
        {"src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable"},
    ],
}

PWA_SW = r'''/* mac-status service worker: makes the panel installable as a PWA. */
const CACHE = 'mac-status-v1';
self.addEventListener('install', (e) => self.skipWaiting());
self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((ks) => Promise.all(
      ks.filter((k) => k !== CACHE).map((k) => caches.delete(k))
    )).then(() => self.clients.claim())
  );
});
self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const u = new URL(req.url);
  if (u.origin !== self.location.origin) return;
  if (u.pathname.indexOf('/api/') === 0) {      /* live data: never cache */
    e.respondWith(fetch(req));
    return;
  }
  e.respondWith(
    fetch(req).then((res) => {
      if (res && res.ok) {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(req, copy));
      }
      return res;
    }).catch(() => caches.match(req).then((hit) => hit || caches.match('/')))
  );
});
'''

_ICON_192 = base64.b64decode('''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''')
_ICON_512 = base64.b64decode('''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''')


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


PAGE = """<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>Mac control</title>
<meta name="theme-color" content="#0d1117"><meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<link rel="manifest" href="/manifest.json">
<link rel="icon" type="image/png" sizes="192x192" href="/icon-192.png"><link rel="apple-touch-icon" href="/icon-192.png">
<script>if('serviceWorker'in navigator){navigator.serviceWorker.register('/sw.js').catch(function(){})}</script>
<style>
:root{color-scheme:dark}body{font-family:ui-monospace,Menlo,monospace;background:#0d1117;color:#e6edf3;margin:0;padding:20px;max-width:1080px;margin:0 auto}
h1{font-size:18px;margin:0 0 2px}h2{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:#8b949e;margin:0 0 10px}
.sub{color:#8b949e;font-size:12px;margin-bottom:14px}
.sec{color:#8b949e;font-size:13px;font-weight:700;letter-spacing:.1em;margin:22px 0 10px;border-bottom:1px solid #21262d;padding-bottom:6px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}
.card{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:12px}
.big{font-size:26px;font-weight:700}.row{display:flex;justify-content:space-between;font-size:12px;padding:1px 0}
.row span:first-child{color:#8b949e}.ok{color:#3fb950}.warn{color:#d29922}.bad{color:#f85149}
.bar{height:6px;background:#21262d;border-radius:3px;overflow:hidden;margin-top:6px}.bar>div{height:100%;background:#58a6ff}
table{width:100%;border-collapse:collapse;font-size:12px}td,th{text-align:left;padding:2px 6px 2px 0}td.num{text-align:right}
.twrap{overflow-x:auto;-webkit-overflow-scrolling:touch}
@media(max-width:480px){body{padding:10px}.row{font-size:11px}button{padding:5px 8px;font-size:11px}}
button{background:#21262d;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:6px 10px;font-size:12px;cursor:pointer;margin:2px}
button:hover{border-color:#58a6ff}button.danger{border-color:#f85149;color:#f85149}
.hsec{background:#0b1420;border:1px solid #1f6feb;border-radius:12px;padding:14px;margin-top:16px}
.hsec h2{color:#58a6ff}
canvas{width:100%;height:70px}
#log,#toast{font-size:12px;color:#8b949e;margin-top:10px;white-space:pre-wrap}
</style></head><body>
<h1 id="host">Mac</h1><div style="font-size:10px;color:#8b949e;margin-bottom:2px">build v11</div>
<div style="display:flex;justify-content:space-between;align-items:baseline">
  <div id="dbanner" style="background:#1c2128;border:1px solid #30363d;color:#8b949e;border-radius:8px;padding:6px 10px;font-size:12px">data: waiting for script…</div>
  <div style="white-space:nowrap;margin-left:10px">
    <a href="/actions" style="font-size:12px;color:#d29922;margin-right:12px">github actions →</a>
    <a href="/term" style="font-size:12px;color:#3fb950;margin-right:12px">console →</a>
    <a href="/envs" style="font-size:12px;color:#58a6ff">env files (.env) →</a>
  </div>
</div>
<div class="sub" id="meta"></div>

<div class="sec">SYSTEM</div>
<div class="grid">
  <div class="card"><h2>CPU</h2><div class="big" id="cpu">—</div>
    <div class="row"><span>load</span><span id="cpu-load"></span></div>
    <div class="bar"><div id="cpu-bar" style="width:0%"></div></div></div>
  <div class="card"><h2>Memory</h2><div class="big" id="mem">—</div>
    <div class="row"><span>used</span><span id="mem-detail"></span></div>
    <div class="bar"><div id="mem-bar" style="width:0%"></div></div></div>
  <div class="card"><h2>Power</h2><div class="big" id="batt">—</div>
    <div id="batt-detail" style="font-size:12px;color:#8b949e"></div>
    <div class="bar"><div id="batt-bar" style="width:0%;background:#3fb950"></div></div></div>
  <div class="card"><h2>Public IP</h2><div class="big" id="pubip" style="font-size:20px">—</div>
    <div class="row"><span>lan</span><span id="lan"></span></div></div>
</div>
<div class="grid" style="margin-top:12px">
  <div class="card"><h2>Disk</h2><table id="disk"><tr><th>mount</th><th class="num">used</th><th class="num">free</th><th class="num"></th></tr></table></div>
  <div class="card"><h2>Top processes</h2><table id="top"><tr><th>proc</th><th class="num">cpu%</th><th class="num">mem</th></tr></table></div>
</div>
<div class="grid" style="margin-top:12px">
  <div class="card"><h2>History</h2><canvas id="ch"></canvas>
    <div style="font-size:11px;color:#8b949e"><span style="color:#58a6ff">— CPU</span> <span style="color:#3fb950">— RAM</span> (last ~100 min)</div></div>
  <div class="card"><h2>Security</h2>
    <div class="row"><span>Firewall</span><span id="fw"></span></div>
    <div class="row"><span>Remote login</span><span id="rl"></span></div>
    <div style="margin-top:6px"><b style="font-size:11px;color:#8b949e">last logins</b>
      <table id="logins"></table></div></div>
</div>
<div class="card" style="grid-column:1/-1;margin-top:12px"><h2>System actions</h2>
  <button onclick="act('restart-status')">restart status</button>
  <button onclick="act('firewall-on')">firewall ON</button>
  <button onclick="act('sleep-off')">sleep OFF</button>
  <button class="danger" onclick="act('reboot')">reboot mac</button>
  <button class="danger" onclick="act('sleep')">sleep now</button>
  <div id="toast"></div></div>

<div class="hsec">
  <h2>REVERSE TUNNEL · VPS→mac</h2>
  <div class="row"><span>tunnel</span><span id="htun"></span></div>
  <div style="margin-top:10px">
    <button onclick="act('restart-tunnel')">restart tunnel</button>
  </div>
</div>

<div class="hsec" style="border-color:#6e7681">
  <h2 style="color:#8b949e">WARP · Cloudflare One (corporate)</h2>
  <div class="row"><span>connection</span><span id="wst">—</span></div>
  <div class="row"><span>organization</span><span id="worg">—</span></div>
  <div style="margin-top:10px">
    <button id="wb-c" onclick="warpop('connect')">connect</button>
    <button id="wb-d" class="danger" onclick="warpop('disconnect')">disconnect</button>
    <button id="wb-r" onclick="warpop('reconnect')">reconnect</button>
    <span id="wmsg" style="font-size:11px;color:#8b949e;margin-left:6px"></span>
  </div>
</div>

<div class="hsec" style="border-color:#c8a14b">
  <h2 style="color:#d29922">CLAUDE · tangem (~/.claude-work)</h2>
  <div class="row"><span>remote agent (launchd)</span><span id="clagent"></span></div>
  <div class="row"><span>subscription auth</span><span id="clauth"></span></div>
  <div class="row"><span>account</span><span id="clemail"></span></div>
  <div class="row"><span>login flow</span><span id="clstate"></span></div>
  <div style="margin-top:10px">
    <button id="clstart" onclick="act('claude-start')">start agent</button>
    <button id="clrestart" onclick="act('claude-restart')">restart agent</button>
    <button id="clgo" style="background:#9a6700;border-color:#9a6700;padding:8px 14px" onclick="cllogin()">start login (get URL)</button>
    <span id="clmsg" style="font-size:12px;color:#8b949e"></span>
  </div>
  <div id="clurlwrap" style="display:none;margin-top:8px">
    <div style="font-size:11px;color:#8b949e;margin-bottom:4px">1 · authorize with tangem (opens in a new tab):</div>
    <button id="clopen" style="background:#1f6feb;border-color:#1f6feb;padding:8px 16px;font-size:13px" onclick="var u=document.getElementById('clurl').textContent.trim();if(u)window.open(u,'_blank')">open authorize URL in browser</button>
    <div style="font-size:10px;color:#8b949e;margin-top:5px">tap the button; if nothing opens, copy this:</div>
    <code id="clurl" style="color:#58a6ff;font-size:10px;word-break:break-all;display:block;margin-top:2px"></code>
    <div style="font-size:11px;color:#8b949e;margin:8px 0 2px">2 · after authorizing, paste the code here and submit:</div>
    <input id="clcode" type="text" autocomplete="off" spellcheck="false" placeholder="paste code…" style="width:70%;background:#0d1117;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:6px;font-family:ui-monospace,monospace">
    <button id="clsubmit" onclick="clcode()">submit code</button>
    <div id="cllog" style="font-size:11px;color:#8b949e;margin-top:6px;white-space:pre-wrap"></div>
  </div>
</div>
  <div class="sec" style="margin-top:20px">CRON · scheduled jobs</div>
  <div class="card">
    <div class="row"><span>cron daemon</span><span id="crondaemon"></span></div>
    <div class="row"><span>crontab</span><span id="cronctab"></span></div>
    <div class="twrap"><table id="crontab" style="margin-top:8px">
      <tr><th>job</th><th>on</th><th>tick</th><th>24h</th><th style="text-align:right"></th></tr>
    </table></div>
    <div style="margin-top:8px"><button onclick="cronop(null,'install')">install/repair crontab</button></div>
    <div id="cronlog" style="font-size:11px;color:#8b949e;margin-top:5px"></div>
  </div>
<div class="sec" style="margin-top:20px">GITHUB ACTIONS · Tangem</div>
<div class="card">
  <div class="row"><span>source</span><span>github-actions.json</span></div>
  <div style="margin-top:8px"><button onclick="location.href='/actions'">open workflows, status and controls</button></div>
  <div style="font-size:10px;color:#6e7681;margin-top:5px">live status, recent average duration, branch/tag inputs, run and rerun</div>
</div>
<div id="log"></div>
<script>
const $=id=>document.getElementById(id);
const FMT=bytes=>bytes.toFixed(1)+' GB';
async function act(a){if((a==='reboot'||a==='sleep')&&!confirm(a+'?'))return;
  try{const r=await fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:a})});
    $('toast').textContent=(await r.json()).msg;}
  catch(e){$('toast').textContent='err '+e;}}
function wmsg(t){const m=$('wmsg');if(m)m.textContent=t;}
function wbusy(b){['wb-c','wb-d','wb-r'].forEach(i=>{const el=$(i);if(el)el.disabled=b;});}
async function warpop(op){
  wbusy(true);wmsg('starting '+op+' — corporate tunnel may drop for a few seconds…');
  try{const r=await fetch('/api/warp',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({op})});
    const d=await r.json();
    wmsg((d.ok?'✓ ':'✗ ')+(d.msg||op+' done'));
  }catch(e){wmsg('err '+e);}
  finally{wbusy(false);setTimeout(tick,1500);}
}
function chart(cpu,mem){const c=$('ch'),x=c.getContext('2d');const W=c.width=320,H=c.height=70;
  x.clearRect(0,0,W,H);const n=cpu.length;if(!n)return;
  const mx=i=>Math.max(5,...i);const px=a=>a.map((v,idx)=>[W*(idx/(n-1||1)),H-(H*v/mx(a))]);
  const line=(pts,col)=>{x.strokeStyle=col;x.lineWidth=1.5;x.beginPath();pts.forEach((p,i)=>i?x.lineTo(p[0],p[1]):x.moveTo(p[0],p[1]));x.stroke();};
  line(px(mem),'#3fb950');line(px(cpu),'#58a6ff');}
let _busy=false;
async function jget(url,ms){const ac=new AbortController();const to=setTimeout(()=>ac.abort(),ms||8000);
  try{return await fetch(url,{cache:'no-store',signal:ac.signal});}finally{clearTimeout(to);}}
async function tick(){
  if(_busy)return;_busy=true;
  try{const r=await jget('/api/status');
    if(!r.ok||!(r.headers.get('content-type')||'').includes('json'))throw new Error('upstream '+r.status);
    const s=await r.json();
    $('host').textContent=s.host;$('meta').textContent='uptime '+s.uptime+' · '+new Date(s.ts*1000).toLocaleString();
    $('cpu').textContent=(s.cpu.busy==null?'?':s.cpu.busy+'%');$('cpu-load').textContent=s.cpu.load1+' / '+s.cpu.load5+' / '+s.cpu.load15;
    $('cpu-bar').style.width=Math.min(100,s.cpu.busy??0)+'%';
    $('mem').textContent=(s.mem.used_pct==null?'?':s.mem.used_pct+'%');
    $('mem-detail').textContent=(s.mem.used_gb!=null?FMT(s.mem.used_gb)+' / '+FMT(s.mem.total_gb):'');
    $('mem-bar').style.width=Math.min(100,s.mem.used_pct??0)+'%';
    const b=s.battery;if(b.present){$('batt').textContent=(b.percent==null?'?':b.percent+'%');
      $('batt-detail').textContent=(b.source==='Battery'?'🔋 ':'🔌 ')+b.state;
      $('batt-bar').style.width=(b.percent??0)+'%';
      $('batt').className='big '+(b.source==='Battery'&&b.percent<20?'bad':'');
    }else{$('batt').textContent='—';$('batt-detail').textContent='no battery';$('batt-bar').style.width='0%';}
    $('pubip').textContent=s.public_ip||'—';$('lan').textContent=(s.net.ip||'')+' ('+(s.net.iface||'')+')';
    let dh='';s.disk.forEach(d=>{dh+='<tr><td>'+d.mount+'</td><td class="num">'+FMT(d.used_gb)+'</td><td class="num">'+FMT(d.avail_gb)+'</td><td class="num">'+(d.pct||'')+'</td></tr>';});
    $('disk').innerHTML='<tr><th>mount</th><th class="num">used</th><th class="num">free</th><th class="num"></th></tr>'+dh;
    let th='';s.top.forEach(t=>{th+='<tr><td>'+t.comm+'</td><td class="num">'+t.cpu.toFixed(0)+'</td><td class="num">'+t.rss_mb+'MB</td></tr>';});
    $('top').innerHTML='<tr><th>proc</th><th class="num">cpu%</th><th class="num">mem</th></tr>'+th;
    const sec=s.security||{};$('fw').textContent=sec.firewall;$('fw').className=(sec.firewall==='on'?'ok':'bad');
    $('rl').textContent=sec.remote_login;
    let lh='';(sec.logins||[]).forEach(l=>{lh+='<tr><td>'+l.user+'</td><td>'+l.day+' '+l.time+'</td><td>'+l.host+'</td></tr>';});
    $('logins').innerHTML=lh;
    const w=s.warp||{};
    $('worg').textContent=w.org||'—';
    const wst=$('wst');
    if(w.ok){const wt=(w.state||'').toLowerCase();
      let cls='warn',txt=w.state||'unknown';
      if(wt==='connected')cls='ok';else if(wt==='disconnected')cls='bad';
      wst.innerHTML='<span class="'+cls+'">'+txt+'</span>'+(w.reason?' <span style="color:#8b949e">· '+w.reason+'</span>':'');
    }else{wst.innerHTML='<span class="bad">unavailable</span>'+(w.error?' <span style="color:#8b949e">· '+String(w.error).slice(0,80)+'</span>':'');}
    const sv=s.services||{};
    const tun=sv['com.agent.mac-tunnel'];
    $('htun').innerHTML=tun&&tun.running?'<span class="ok">up</span>':'<span class="bad">down</span>';
    $('log').textContent='✓ '+new Date().toLocaleTimeString()+' · data ok';
    $('dbanner').innerHTML='<span class="ok">data: OK</span> · '+new Date().toLocaleTimeString();
  }catch(e){$('log').textContent='⚠ no data '+new Date().toLocaleTimeString()+' · '+((e&&e.name==='AbortError')?'timeout':((e&&e.message)||e));
    $('dbanner').innerHTML='<span class="bad">data: error</span> · '+((e&&e.name==='AbortError')?'timeout':((e&&e.message)||e));}
  finally{_busy=false;}
}
async function hist(){try{const r=await jget('/api/history',6000);if(!r.ok)return;const h=await r.json();chart(h.cpu,h.mem);}catch(e){}}
async function clrefresh(){
  try{const r=await jget('/api/claude',6000);
    if(!r.ok||!(r.headers.get('content-type')||'').includes('json'))return;
    const c=await r.json();
    $('clagent').innerHTML=c.agentRunning?('<span class="ok">running</span>'+(c.agentPid&&c.agentPid!=='-'?' pid '+c.agentPid:'')):'<span class="bad">stopped</span>';
    $('clstart').style.display=c.agentRunning?'none':'';
    $('clauth').innerHTML=c.loggedIn?'<span class="ok">logged in</span> ('+c.authMethod+')':'<span class="bad">logged OUT</span>';
    $('clemail').textContent=c.email||'—';
    if(c.loginRunning){$('clstate').innerHTML='<span class="warn">login in progress…</span>';
      if(c.url){$('clurlwrap').style.display='block';$('clurl').textContent=c.url;$('clstate').innerHTML='<span class="warn">waiting for your code…</span>';}
    }else{$('clstate').textContent=c.loggedIn?'idle':'needs login';}
  }catch(e){}
}
async function cllogin(){
  $('clmsg').textContent='starting…';$('cllog').textContent='';
  try{const r=await fetch('/api/claude/login',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
    const d=await r.json();
    $('clmsg').textContent=d.msg;
    if(d.url){$('clurlwrap').style.display='block';$('clurl').textContent=d.url;}
    await clrefresh();
  }catch(e){$('clmsg').textContent='err '+e;}
}
async function clcode(){
  const code=$('clcode').value.trim();if(!code)return;
  $('cllog').textContent='submitting…';
  try{const r=await fetch('/api/claude/code',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({code})});
    const d=await r.json();
    $('cllog').textContent=(d.log||[]).join('\\n');
    $('clmsg').textContent=d.msg;
    if(d.ok){$('clcode').value='';$('clurlwrap').style.display='none';}
    await clrefresh();
  }catch(e){$('cllog').textContent='err '+e;}
}
function ago(iso){
  if(!iso)return null;
  const t=Date.parse(iso);if(isNaN(t))return iso;
  const s=Math.max(0,(Date.now()-t)/1000);
  if(s<90)return Math.round(s)+'s ago';
  if(s<5400)return Math.round(s/60)+'m ago';
  return Math.round(s/3600)+'h ago';
}
async function cronrefresh(){
  try{const r=await jget('/api/cron',6000);
    if(!r.ok)return;const d=await r.json();
    $('crondaemon').innerHTML=d.daemon_running?'<span class="ok">running</span>':'<span class="bad">not running</span>';
    $('cronctab').innerHTML=d.crontab_ok?'<span class="ok">readable</span>':'<span class="bad" title="'+(d.crontab_error||'').replace(/"/g,'&quot;')+'">error</span>';
    const tb=$('crontab');
    while(tb.rows.length>1)tb.deleteRow(1);
    (d.jobs||[]).forEach(j=>{
      const tr=tb.insertRow();
      const c0=tr.insertCell();c0.textContent=j.name;
      if(j.running)c0.innerHTML+=' <span class="warn" title="сейчас выполняется">●</span>';
      const c1=tr.insertCell();c1.innerHTML=j.installed?'<span class="ok">yes</span>':'<span class="bad">no</span>';
      const c2=tr.insertCell();
      c2.innerHTML=j.last_tick?((j.stale?'<span class="warn">':'')+ago(j.last_tick)+(j.stale?'</span>':'')):'<span class="bad">never</span>';
      const c3=tr.insertCell();
      const a=j.attempts_24h;
      if(a){
        const cls=a.fail>0?'warn':'ok';
        let title=a.last_fail_reason?String(a.last_fail_reason):'';
        if(a.last_run_duration_s!=null)title+=(title?' · ':'')+'last run '+a.last_run_duration_s+'s, '+(a.last_run_failed||0)+' failed';
        c3.innerHTML='<span class="'+cls+'"'+(title?(' title="'+title.replace(/"/g,'&quot;')+'"'):'')+'>'+a.ok+'/'+a.fail+'</span>';
      }else c3.textContent='—';
      const c4=tr.insertCell();c4.style.textAlign='right';
      const b=document.createElement('button');b.textContent='run';
      b.onclick=function(){cronop(j.name,'run');};
      c4.appendChild(b);
    });
  }catch(e){$('cronlog').textContent='err '+e;}
}
async function cronop(job,op){
  $('cronlog').textContent=(job||'crontab')+' '+op+'…';
  try{const r=await fetch('/api/cron',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({job,op})});
    const d=await r.json();$('cronlog').textContent=d.msg||(job||'crontab')+' '+op;
    setTimeout(cronrefresh,1500);
  }catch(e){$('cronlog').textContent='err '+e;}
}
clrefresh();tick();hist();cronrefresh();
setInterval(tick,3000);setInterval(hist,15000);setInterval(clrefresh,5000);setInterval(cronrefresh,10000);
</script></body></html>"""


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


ENV_PAGE = """<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>Env files</title>
<meta name="theme-color" content="#0d1117"><link rel="manifest" href="/manifest.json">
<link rel="icon" type="image/png" sizes="192x192" href="/icon-192.png"><link rel="apple-touch-icon" href="/icon-192.png">
<script>if('serviceWorker'in navigator){navigator.serviceWorker.register('/sw.js').catch(function(){})}</script>
<style>
:root{color-scheme:dark}*{box-sizing:border-box}
body{font-family:ui-monospace,Menlo,monospace;background:#0d1117;color:#e6edf3;margin:0;padding:16px;max-width:1200px;margin:0 auto}
h1{font-size:18px;margin:0 0 2px}.sub{color:#8b949e;font-size:12px}
a{color:#58a6ff;text-decoration:none;font-size:12px}
.top{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px;margin-bottom:10px}
button{background:#21262d;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:6px 10px;font-size:12px;cursor:pointer}
button:hover{border-color:#58a6ff}button:disabled{opacity:.5;cursor:default}
button.ok{background:#238636;border-color:#238636;color:#fff}
input[type=text]{background:#0d1117;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:6px 8px;font-size:12px;width:220px;font-family:inherit}
.layout{display:flex;gap:12px;align-items:stretch}
.pane{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:10px}
#list{width:44%;min-width:300px;overflow:auto;max-height:calc(100vh - 170px)}
#edit{flex:1;display:flex;flex-direction:column}
@media(max-width:900px){.layout{flex-direction:column}#list{width:100%;max-height:35vh}}
#head{font-size:12px;color:#8b949e;border-bottom:1px solid #21262d;padding-bottom:6px;margin-bottom:6px}
.row{display:flex;align-items:center;gap:8px;padding:5px 6px;border-radius:6px;cursor:pointer;font-size:12px;border:1px solid transparent}
.row:hover{background:#1c2128}.row.sel{background:#1f6feb22;border-color:#1f6feb}
.rpath{word-break:break-all;flex:1}.rsize{color:#8b949e;font-size:10px;white-space:nowrap}
.b{font-size:9px;padding:1px 6px;border-radius:8px;white-space:nowrap}
.b.live{background:#3fb95022;color:#3fb950;border:1px solid #3fb95066}
.b.sample{background:#8b949e22;color:#8b949e;border:1px solid #30363d}
textarea{flex:1;width:100%;min-height:46vh;background:#0d1117;color:#e6edf3;border:1px solid #30363d;border-radius:8px;padding:10px;font-family:ui-monospace,Menlo,monospace;font-size:12px;resize:vertical;white-space:pre;tab-size:2}
textarea:disabled{opacity:.6}
#status{font-size:11px;color:#8b949e;margin-top:6px;white-space:pre-wrap;min-height:14px}
#cur{font-size:11px;color:#58a6ff;word-break:break-all;margin-bottom:6px;min-height:14px}
.bar{display:flex;gap:8px;align-items:center;margin-top:8px;flex-wrap:wrap}
#rootline{color:#8b949e;font-size:11px;margin-bottom:8px}
</style></head><body>
<div class="top">
  <div><h1>ENV files</h1><div class="sub">edit .env files anywhere under ~/work</div></div>
  <div><a href="/">← back to status</a></div>
</div>
<div id="rootline"></div>
<div class="layout">
  <div class="pane" id="list">
    <div id="head" style="display:flex;gap:6px;align-items:center">
      <input type="text" id="q" placeholder="filter…" oninput="render()">
      <span style="margin-left:auto" id="cnt"></span>
      <button onclick="load(true)" title="rescan">↻</button>
    </div>
    <div id="rows"></div>
  </div>
  <div class="pane" id="edit">
    <div id="cur">select a file from the list →</div>
    <textarea id="ta" placeholder="…" disabled spellcheck="false"></textarea>
    <div class="bar">
      <button class="ok" id="saveb" onclick="save()" disabled>save</button>
      <button onclick="reloadf()" disabled id="reloadb">reload from disk</button>
      <span id="hint" style="font-size:10px;color:#8b949e">before every save a backup is kept in ~/.mac-status-env-backups</span>
    </div>
    <div id="status"></div>
  </div>
</div>
<script>
let FILES=[],cur=null,orig='';
const $=id=>document.getElementById(id);
const esc=s=>s.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
async function load(force){
  try{const r=await fetch('/api/envs'+(force?'?refresh=1':''),{cache:'no-store'});
    const d=await r.json();if(!d.ok)throw new Error(d.msg);
    FILES=d.files;render();$('rootline').textContent='root: '+d.root+' · '+d.count+' files';
  }catch(e){st('list error: '+e);}
}
function kind(k){return '<span class="b '+k+'">'+k+'</span>';}
function render(){
  const q=($('q').value||'').toLowerCase();
  const rows=$('rows');rows.innerHTML='';
  let shown=0;
  FILES.forEach(f=>{
    if(q&&!f.path.toLowerCase().includes(q))return;shown++;
    const r=document.createElement('div');r.className='row'+(cur&&f.path===cur?' sel':'');
    r.innerHTML=kind(f.kind)+'<span class="rpath">'+esc(f.path)+'</span><span class="rsize">'+
      (f.size>1048576?(f.size/1048576).toFixed(1)+'M':f.size>1024?(f.size/1024).toFixed(1)+'k':f.size)+
      ' · '+new Date(f.mtime*1000).toLocaleDateString()+'</span>';
    r.onclick=()=>open(f.path);
    rows.appendChild(r);
  });
  $('cnt').textContent=shown+'/'+FILES.length;
}
async function open(p){
  cur=p;orig='';$('ta').disabled=true;$('ta').value='';$('cur').textContent=p;render();st('loading…');
  try{const r=await fetch('/api/envs/read?path='+encodeURIComponent(p),{cache:'no-store'});
    const d=await r.json();
    if(!d.ok){st('error: '+d.msg);return;}
    orig=d.content;$('ta').value=d.content;$('ta').disabled=false;$('saveb').disabled=false;$('reloadb').disabled=false;
    $('cur').textContent=p+' · '+d.size+' bytes · '+new Date(d.mtime*1000).toLocaleString();
    st('loaded — edit and press save');
  }catch(e){st('error: '+e);}
}
function reloadf(){if(cur)open(cur);}
async function save(){
  if(!cur)return;st('saving…');
  try{const r=await fetch('/api/envs/write',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({path:cur,content:$('ta').value})});
    const d=await r.json();
    if(d.ok){orig=$('ta').value;st('✓ '+d.msg);load(true);}
    else st('✗ '+d.msg);
  }catch(e){st('✗ '+e);}
}
function st(m){$('status').textContent=m;}
document.addEventListener('keydown',e=>{
  if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='s'){e.preventDefault();save();}
  if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='r'&&cur){e.preventDefault();reloadf();}
});
load();
</script></body></html>"""


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


TERM_PAGE = """<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>Console</title>
<meta name="theme-color" content="#0d1117"><link rel="manifest" href="/manifest.json">
<link rel="icon" type="image/png" sizes="192x192" href="/icon-192.png"><link rel="apple-touch-icon" href="/icon-192.png">
<script>if('serviceWorker'in navigator){navigator.serviceWorker.register('/sw.js').catch(function(){})}</script>
<style>
:root{color-scheme:dark}*{box-sizing:border-box}
body{font-family:ui-monospace,Menlo,monospace;background:#0d1117;color:#e6edf3;margin:0;padding:14px;max-width:1100px;margin:0 auto}
.top{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:8px}
button{background:#21262d;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:6px 11px;font-size:12px;cursor:pointer}
button:hover{border-color:#58a6ff}button.go{background:#238636;border-color:#238636;color:#fff}
button.up{background:#1f6feb;border-color:#1f6feb;color:#fff;font-weight:600}
button.up:hover{background:#388bfd;border-color:#388bfd}
#out{height:62dvh;background:#010409;border:1px solid #30363d;border-radius:10px;padding:10px;
  overflow-y:auto;white-space:pre-wrap;word-break:break-word;font-size:13px;line-height:1.45}
.row{display:flex;gap:8px;margin-top:8px;align-items:stretch}
#inp{flex:1;background:#0d1117;color:#e6edf3;border:1px solid #30363d;border-radius:8px;padding:9px 10px;
  font-family:ui-monospace,Menlo,monospace;font-size:13px;outline:none}
#inp:focus{border-color:#58a6ff}
.ctr{display:flex;gap:6px;margin-top:6px;flex-wrap:wrap}
</style></head><body>
<div class="top">
  <button onclick="location.href='/'">← status</button>
  <button onclick="location.href='/envs'">env files</button>
  <button class="up" onclick="again()" title="re-run the previous command">↑ rerun</button>
  <button onclick="sendKey('\\x03')" title="SIGINT (Ctrl-C)">^C</button>
  <button onclick="resetSess()" title="kill the shell and start a new one">reset</button>
  <button onclick="clearScr()" title="clear the output pane">clear</button>
</div>
<div id="out"></div>
<div class="row">
  <input id="inp" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="command…">
  <button class="go" onclick="run()">enter ↵</button>
</div>
<div class="ctr">
  <button onclick="histMove(1)" title="previous command into the input (↑)">↑ prev</button>
  <button onclick="histMove(-1)" title="next command into the input (↓)">↓ next</button>
  <button onclick="sendKey('\\x03')" title="interrupt the running command">^C interrupt</button>
  <button onclick="sendKey('\\x04')" title="end of input / exit the shell">^D</button>
</div>
<script>
const $=id=>document.getElementById(id),out=$('out'),inp=$('inp');
let after=0,polling=false,dead=false,logText='',pollTimer=null;
// The page chrome is buttons only: diagnostics go into the output pane itself,
// in the same [bracketed] style as the shell-lifecycle notices.
const note=m=>append('\\n['+m+']\\n');
function clean(s){
  s=s.replace(/\\x1b\\[[0-9;?]*[ -/]*[@-~]/g,'').replace(/\\x1b\\][^\\x07]*?(?:\\x07|\\x1b\\\\)/g,'');
  s=s.replace(/\\r\\n/g,'\\n').replace(/\\r/g,'\\n').replace(/[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]/g,'');
  return s;
}
function append(s){
  if(!s)return;
  logText+=s;
  if(logText.length>600000){logText=logText.slice(-400000);}
  out.textContent=logText;
  out.scrollTop=out.scrollHeight;
}
async function openSess(){
  try{const r=await fetch('/api/term/open',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
    const d=await r.json();
    dead=!d.ok;
    if(!d.ok)note('shell error: '+(d.msg||'?'));
    else if(!d.already)note('shell ready (pid '+(d.pid||'?')+')');
    if(d.ok&&!polling){polling=true;if(pollTimer)clearInterval(pollTimer);pollTimer=setInterval(poll,250);}
  }catch(e){note('err '+e);}
}
let q=Promise.resolve();
function send(s){
  q=q.then(()=>fetch('/api/term/input',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({data:s})}).catch(()=>{}));
}
// Dead shell (server restarted / shell exited) -> start a fresh one instead of
// making the user hunt for "reset session"; history is server-side, so it lives on.
async function ensureShell(){
  if(!dead)return true;
  append('\\n[shell gone — starting a new session]\\n');
  await resetSess();
  return !dead;
}
async function sendKey(k){if(!await ensureShell()){append('\\n[no shell — check the server]\\n');return;}send(k);}
async function run(){
  const c=inp.value;inp.value='';
  if(!c.trim())return;
  if(!await ensureShell()){inp.value=c;return;}
  send(c+'\\r');
  histReset();
  q=q.then(loadHist);   // refresh after the input POST lands server-side
  inp.focus();
}
async function poll(){
  try{const r=await fetch('/api/term/poll?after='+after,{cache:'no-store'});
    if(!r.ok)return;
    const d=await r.json();
    if(d.out){append(clean(d.out));after=d.after;}
    if(d.dead&&!dead){dead=true;polling=false;if(pollTimer){clearInterval(pollTimer);pollTimer=null;}
      note('shell exited — the next command starts a new one');}
  }catch(e){}
}
async function resetSess(){
  logText='';out.textContent='';after=0;polling=false;dead=true;
  if(pollTimer){clearInterval(pollTimer);pollTimer=null;}
  try{const r=await fetch('/api/term/reset',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
    const d=await r.json();
    if(d.ok)await openSess();else note('reset failed: '+(d.msg||'?'));
  }catch(e){note('err '+e);}
}
function clearScr(){logText='';out.textContent='';}
// ---- command history (server-side, newest first) -------------------------
let hist=[],hidx=-1,draft='';
async function loadHist(){
  try{const r=await fetch('/api/term/history',{cache:'no-store'});
    const d=await r.json();if(d.ok)hist=d.hist||[];
  }catch(e){}
}
function histReset(){hidx=-1;draft='';}
function histMove(dir){                       // +1 = older (↑), -1 = newer (↓)
  if(!hist.length){loadHist();return;}
  if(dir>0){if(hidx<0)draft=inp.value;hidx=Math.min(hidx+1,hist.length-1);}
  else{if(hidx<0)return;hidx--;}
  inp.value=hidx<0?draft:hist[hidx];
  // No autofocus: on a phone that pops the on-screen keyboard over the output.
  // The caret still goes to the end so an already-focused field stays usable.
  try{inp.setSelectionRange(inp.value.length,inp.value.length);}catch(e){}
}
async function again(){                        // ↑ rerun: re-execute last command
  if(!await ensureShell())return;
  try{const r=await fetch('/api/term/again',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
    const d=await r.json();
    histReset();
    if(!d.ok)note('cannot rerun: '+(d.msg||'?'));
    if(d.ok)q=q.then(loadHist);
  }catch(e){note('err '+e);}
}
inp.addEventListener('keydown',e=>{
  if(e.key==='Enter'){e.preventDefault();run();}
  else if(e.key==='ArrowUp'){e.preventDefault();histMove(1);}
  else if(e.key==='ArrowDown'){e.preventDefault();histMove(-1);}
  else{histReset();}
});
window.addEventListener('keydown',e=>{
  if(e.ctrlKey&&e.key.toLowerCase()==='c'&&document.activeElement!==inp){sendKey('\\x03');}
});
openSess();
loadHist();
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, obj, ctype="application/json"):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_raw(self, code, body, ctype, cache="no-store"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", cache)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        """True if the request may touch /api/*: disabled until a token is configured."""
        if not SERVICE_TOKEN:
            return True
        return self.headers.get("X-Mac-Token", "") == SERVICE_TOKEN

    def do_GET(self):
        if self.path.startswith("/api/") and not self._authorized():
            self._send(401, {"ok": False, "msg": "unauthorized"})
            return
        p = self.path.split("?", 1)[0]
        if p in ("/manifest.json", "/manifest.webmanifest"):
            self._send_raw(200, json.dumps(PWA_MANIFEST).encode(),
                           "application/manifest+json", "public, max-age=600")
        elif p == "/sw.js":
            self._send_raw(200, PWA_SW.encode(),
                           "application/javascript; charset=utf-8", "no-cache")
        elif p in ("/icon-192.png", "/icon-512.png", "/favicon.ico"):
            icon = _ICON_512 if p == "/icon-512.png" else _ICON_192
            self._send_raw(200, icon, "image/png", "public, max-age=86400")
        elif self.path.startswith("/api/status"):
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
        elif self.path == "/actions" or self.path.startswith("/actions?"):
            self._send_raw(200, github_actions.ACTIONS_PAGE.encode(),
                           "text/html; charset=utf-8")
        elif self.path.startswith("/api/envs/list"):
            self._send(200, {"ok": True, "root": ENV_ROOT, "count": len(_env_scan()),
                             "files": _env_scan()})
        elif self.path.startswith("/api/envs/read"):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            self._send(200, _env_read((q.get("path") or [""])[0]))
        elif self.path.startswith("/api/envs"):
            self._send(200, {"ok": True, "root": ENV_ROOT, "count": len(_env_scan()),
                             "files": _env_scan()})
        elif self.path == "/envs" or self.path.startswith("/envs?"):
            body = ENV_PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith("/api/term/history"):
            self._send(200, _term_history())
        elif self.path.startswith("/api/term/poll"):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            self._send(200, _term_poll((q.get("after") or ["0"])[0]))
        elif self.path == "/term" or self.path.startswith("/term?"):
            body = TERM_PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith("/api/term/open"):
            self._send(200, _term_start())
        else:
            body = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

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
