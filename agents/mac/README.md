# cloudlyru/agents/mac — Mac status + control (memory for AI agents: **AGENTS.md**)


> **Для ИИ-агентов: читай `AGENTS.md`** — там память проекта (структура, ключевые
> факты: persist keychain, ротация login keychain на Tahoe, AEAT-доступ, Chrome-ключ).

Remote management panel for the Mac, reachable at **https://status.iq-factura.com**
(basic auth) through a reverse SSH tunnel + nginx on the VPS.

Single-file Python server (stdlib only), managed by launchd as `com.agent.mac-status`,
bound to `127.0.0.1:18810`.

## What it does

Dark "Mac control" web panel (build v11):

- **PWA** — installable app: web app manifest + service worker + PNG icons
  (192/512, embedded base64) are served by the panel itself, so Chrome on
  Android offers **Install app / Add to Home screen** — it then opens in its
  own standalone window (no address bar), like a real app, not a tab.
  `/api/*` is never cached; the shell page is cached offline-capable.
- **System status** — CPU (load 1/5/15 + busy %), RAM (used GB/%), disks (real
  volumes), top processes, battery/power, public IP (ipify), LAN IP, hostname,
  uptime. Refreshed every 3 s.
- **History** — CPU/RAM chart for the last ~100 min, sampled every 15 s.
- **Security** — firewall state, remote login, last logins (`last`).
- **WARP (Cloudflare One, corporate Zero Trust "tangem")** — live connection state
  of the WARP tunnel (from `/usr/local/bin/warp-cli -j status`, org shown) with
  **connect / disconnect / reconnect** buttons. Reconnect = disconnect + connect,
  so the corporate tunnel drops for a few seconds (normal — the reverse tunnel
  self-heals). Works with no sudo from the launchd GUI context.
- **Actions** — reboot, sleep now, firewall ON, sleep OFF, restart status/tunnel.
- **Claude (tangem, `~/.claude-work`)** — remote agent status, subscription auth
  state, and a re-login flow (authorize URL → paste code) usable from a phone.
- **Env files** — `/envs`: lists every file whose name contains `.env`
  recursively under `~/work` (node_modules/.git/.venv/dist/… skipped), opens any
  of them in a browser editor and saves atomically. A timestamped backup is kept
  in `~/.mac-status-env-backups` before every save. Only files with `.env` in the
  name are editable; path traversal is rejected. Root overridable via
  `MAC_STATUS_ENV_ROOT`.
- **Console** — `/term`: plain single-line console to the Mac (one persistent
  `bash --noprofile --norc -i` over a pty; no terminal emulator, output is text).
  Output pane is 80vh, one input line + Enter below. HTTP polling transport
  (`/api/term/poll`), so it works through the nginx reverse proxy without
  WebSocket. Whole lines are posted on Enter (`/api/term/input`); a ^C button
  sends SIGINT so long-running commands can be interrupted while the shell
  stays alive; `cd`/state persists between lines; "reset session" starts a
  fresh shell. **"↑ rerun" button** re-executes the previous command (POST
  `/api/term/again`); history lives in the server process (last 50 lines), so
  it survives page reloads, shell resets and works from any device — `↑`/`↓`
  in the input browse it. Shell/CWD overridable via `MAC_STATUS_TERM_SHELL` /
  `MAC_STATUS_TERM_CWD`. **Full shell access to the Mac** — same trust level as
  the reboot action, keep behind basic auth.
- **GitHub Actions** — `/actions`: file-backed Tangem workflow dashboard. It
  reads the work token directly from `~/work/.env`, shows current run state,
  recalculates average duration from the latest five successful runs, accepts a
  branch or tag plus every configured `workflow_dispatch` input, and can launch
  or rerun workflows. The editable list lives in `github-actions.json` next to
  the server; the page can add or remove entries without a database.

## Endpoints

| Method | Path | Description |
| --- | --- | --- |
| GET | `/` | HTML panel |
| GET | `/manifest.json` | PWA web app manifest (`display: standalone`) |
| GET | `/sw.js` | service worker (cache shell, never cache `/api/*`) |
| GET | `/icon-192.png` `/icon-512.png` | PWA icons (PNG8, embedded in the .py) |
| GET | `/api/status` | JSON status snapshot (incl. `warp`, …) |
| GET | `/api/history` | `{t, cpu, mem}` for last ~100 min |
| GET | `/api/claude` | Claude (tangem) login/agent state |
| POST | `/api/warp` | `{"op": "connect"\|"disconnect"\|"reconnect"\|"status"}` — WARP tunnel control |
| POST | `/api/action` | `{"action": "reboot"\|"sleep"\|"restart-status"\|…}` |
| POST | `/api/claude/login` | start a claude auth login, get authorize URL |
| POST | `/api/claude/code` | `{"code": "…"}` — finish the login |
| GET | `/actions` | GitHub Actions status, launch controls and file-backed list editor |
| GET | `/api/github-actions` | Configured workflows with latest run and recent-duration average |
| GET | `/api/github-actions/refs?repo=` | Selectable branches and tags for a repository |
| POST | `/api/github-actions/run` | Dispatch a configured workflow with `repo`, `path`, `ref`, `inputs` |
| POST | `/api/github-actions/rerun` | Re-run a repository run by `run_id` |
| POST | `/api/github-actions/config` | Add/remove one entry in `github-actions.json` |
| GET | `/envs` | HTML page: list + editor for `.env` files under `~/work` |
| GET | `/api/envs` | JSON list of env files (`root`, `files[]` with path/size/mtime/kind) |
| GET | `/api/envs/read?path=` | JSON `{ok, content, size, mtime}` of one env file |
| POST | `/api/envs/write` | `{"path": "…", "content": "…"}` — atomic save + backup |
| GET | `/term` | HTML page: plain console (single input line → text output) |
| POST | `/api/term/open` | start/reuse the persistent bash session |
| GET | `/api/term/poll?after=N` | output delta since byte offset N |
| POST | `/api/term/input` | `{"data": "…"}` — feed input to the shell |
| POST | `/api/term/again` | `{"idx": 0}` — re-run the previous command (0 = last, 1 = one before) |
| GET | `/api/term/history` | `{ok, hist: […]}` — recent console commands, newest first |
| POST | `/api/term/reset` | kill the shell and start a new session |

## Install (on the Mac)

```bash
./install.sh          # copies plist to ~/Library/LaunchAgents and reloads the agent
launchctl list | grep mac-status
curl -s http://127.0.0.1:18810/api/status | head -c 300
```

launchd agent: `RunAtLoad` + `KeepAlive`, so it starts automatically at login
(auto-login is enabled on this Mac → effectively at power-on).

Logs go to `logs/` in this repo (`mac-status.log`, `mac-status.err.log`,
`access.log`), ignored by git.

## Remote access (VPS side — reference only)

`nginx/status.iq-factura.conf` is a reference server block. The Mac keeps a
reverse SSH tunnel (`com.agent.mac-tunnel`, see `agents/run-tunnel.sh`)
to the VPS; nginx there fronts the status server with basic auth. TLS via certbot.

### Service token

`/api/*` requires the `X-Mac-Token` header once `MAC_SERVICE_TOKEN` is set (environment or
`~/work/.env`). The Cloudly backend sends it; the browser panel gets it injected by nginx
(`proxy_set_header X-Mac-Token …` in `nginx/status.iq-factura.conf`). Unset = the check is off.

## Notes

- **PWA install on Android**: in Chrome open https://status.iq-factura.com, log in
  (basic auth), then ⋮ menu → **Install app** / **Add to Home screen**. Chrome
  cannot register a service worker behind HTTP basic auth, so on nginx the paths
  `/sw.js`, `/manifest.json`, `/icon-192.png`, `/icon-512.png` bypass auth
  (`auth_basic off`; they hold no secrets) while the pages and `/api/*` stay
  protected. Because of basic auth the standalone window can re-prompt for login
  when Chrome clears its auth cache (e.g. after a browser restart) — just log in
  again.
- Paths in `com.agent.mac-status.plist` and `install.sh` are absolute for this
  Mac (`/Users/sobogd/work/cloudlyru/agents/mac/…`) — adjust when cloning elsewhere.
- Runtime is `/usr/bin/python3` (3.9, CommandLineTools). Stdlib only.
- Prior location `~/.dsh/mac-status-server.py` is deprecated and removed after the
  move to this repo (2026-09-08).

## control/ — удалён (2026-09-23)

Вся папка удалена: GUI-автоматизация (`winlist`/`osctl`/`ocr`/`gui`), поиск
авиабилетов, `wifictl`, `aeat-import.sh`, `scrollrevert`.


## agents/ — определения ВСЕХ служб (launchd) + обёртки запуска

Единый источник для всех com.agent.* служб этого Mac'а:

- `com.agent.*.plist` — исходники launchd-агентов (mac-status, reverse-tunnel,
  claude-tangem, whisper, llm, llm-mt). Рабочие копии launchd читает из
  `~/Library/LaunchAgents` — их разворачивает `install.sh`.
- `run-*.sh` — обёртки запуска, на которые ссылаются plist.

Пути в plist теперь указывают прямо на `cloudlyru/agents/mac/`; старые пути `~/.dsh`
оставлены симлинками на cloudlyru/agents/mac, чтобы уже запущенные службы работали до
следующей перезагрузки.

Переустановить после правок: `./install.sh` (применится после ребута) либо
вручную: `launchctl kickstart -k gui/$(id -u)/com.agent.<label>`.
