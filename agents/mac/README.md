# cloudlyru/agents/mac — агенты MacBook (память: AGENTS.md)

Reverse-SSH-туннель и локальные сервисы домашнего MacBook, которые использует приложение
Cloudly. Статус-панель (`mac-status-server.py`) — **только API** на `127.0.0.1:18810`:
браузерный UI и PWA удалены, единственный клиент — бэкенд Cloudly (`src/mac/`).

## Сервисы (launchd; `install.sh` раскатывает plist-ы в `~/Library/LaunchAgents`)

| label | что делает |
| --- | --- |
| `com.agent.mac-status` | панель API на `:18810` |
| `com.agent.mac-tunnel` | reverse-SSH туннель Mac → VPS (см. порты ниже) |
| `com.agent.whisper` | whisper.cpp `:1238` — распознавание речи |
| `com.agent.claude-tangem` | сессия Claude в `~/.claude-work` (в launchd `disabled`) |

`com.agent.omlx` (oMLX `:8000` — главная локальная модель) и
`com.user.llm-tunnel` (туннель `9999→8000` наружу) — в репо
`~/work/llm-tunnel` (plist и скрипт `run-omlx-serve.sh`), раскатывает
deploy-агент того репо.
`com.agent.mtplx` (mtplx) выведен из эксплуатации: plist и скрипт — в
`archived/` этой папки.
Старые `com.agent.llm*` (llama.cpp) — предшественники; их plist'ы остались
в папке и при повторном `./install.sh` вернутся в LaunchAgents — убрать
оттуда, если llama.cpp больше не используется.

Туннель отдаёт на VPS (loopback самого VPS): `18810` панель, `18812`→`1234`,
`18818`→`1238`, `18820` мост агентов (`agents/bridge`), `18822`→`1235`. Наружу ничего не смотрит.

## Ручки панели (`/api/*`; требуется `X-Mac-Token`, если задан `MAC_SERVICE_TOKEN`)

| Method | Path | Что |
| --- | --- | --- |
| GET | `/api/status` | снимок: cpu/ram/disk/top/ip/services/security/battery/warp |
| GET | `/api/history` | `{t,cpu,mem}` за ~100 мин |
| POST | `/api/action` | `{action}` из белого списка |
| POST | `/api/warp` | `{op: connect\|disconnect\|reconnect\|status}` |
| GET/POST | `/api/claude`, `/api/claude/login`, `/api/claude/code` | статус и вход Claude |
| GET/POST | `/api/github-actions*` | дашборд и запуск workflow |
| GET/POST | `/api/pull-requests*` | открытые PR: задача из заголовка, статус ревью, обсуждение после ЧР |
| GET/POST | `/api/envs*` | список/чтение/запись `.env` под `~/work` |
| GET/POST | `/api/term/*` | консоль (опрос по HTTP) |

Всё вне `/api/*` возвращает `404`.

## Установка и перезапуск

```bash
./install.sh                                            # plist-ы из этой папки → ~/Library/LaunchAgents
launchctl kickstart -k gui/$(id -u)/com.agent.<label>   # перезапуск конкретного агента
```

Списки настраиваются рядом с кодом: workflow — в `github-actions.json`, репозитории
пул-реквестов — в `pull-requests.json`. Обе ручки `*/config` правят те же файлы.
Токен GitHub для обеих — `GH_BSOKOLOV_TANGEM` из `~/work/.env`.

Токен панели: `MAC_SERVICE_TOKEN` (в `~/work/.env` или в окружении). Пусто — проверка выключена.
