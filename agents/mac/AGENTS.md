# AGENTS.md — cloudlyru/agents/mac: управление Mac'ом (статус + контроль). Память проекта для ИИ-агентов

> **Этот файл — память проекта.** Всё, что связано со СТАТУСОМ и УПРАВЛЕНИЕМ этого
> Mac'а, живёт ЗДЕСЬ (`/Users/sobogd/work/cloudlyru/agents/mac`). Если задача про «статус-панель»,
> «управление маком», «окна по слоям», «нотификации», «Chrome разлогинивается»,
> «AEAT/налоговая Испании» — начинай с этого файла.

## Что это за проект
Удалённое управление личным Mac'ом (unattended, auto-login, macOS 26.6.2 Tahoe,
build 25G83) через веб-панель + локальный инструментарий действий для агента.
Публичный адрес: `https://status.iq-factura.com` (статус-панель, nginx basic auth
`sobogd`/пароль из `.env` `MY_PASSWORD`), через reverse-SSH-туннель на VPS
`46.225.143.221` (nginx). Домены/прод трогать нельзя.

## Структура
```
cloudlyru/agents/mac/                     ← git-репозиторий (единый источник ВСЕГО)
├── mac-status-server.py      ← код статус-панели (127.0.0.1:18810, stdlib-only)
│                               + стр. /envs: список+редактор .env под ~/work
│                                 (/api/envs, /api/envs/read, /api/envs/write,
│                                 бэкапы до записи: ~/.mac-status-env-backups)
│                               + стр. /term: простая консоль — одна строка ввода,
│                                 вывод текстом (bash --norc -i на pty, без эмулятора;
│                                 /api/term/poll, /api/term/input, кнопка ^C, reset)
├── README.md                 ← описание панели, endpoint'ы (/api/status, /api/action…)
├── AGENTS.md                 ← этот файл
├── install.sh                ← деплой всех plist из agents/ в ~/Library/LaunchAgents
├── agents/                   ← ВСЕ launchd-агенты (plist-исходники + обёртки)
│   ├── com.agent.*.plist     ← 6 агентов (mac-status, mac-tunnel, claude-tangem,
│   │                           whisper, llm, llm-mt)
│   ├── run-*.sh              ← обёртки запуска, на которые ссылаются plist
├── nginx/                    ← reference VPS-конфиг статус-панели
│                               (status.iq-factura.conf)
└── logs/
```

## Ключевые факты/память (проверено в сессии)
- **macOS 26.6.2 (Tahoe)**, Swift-тулчейн сломан → всё через pyobjc `.venv`.
  Экран 1512×982 pt, Retina 2x (OCR/скриншоты в device-px → для кликов делить на 2).
- **Ротация login keychain на Tahoe + auto-login**: loginwindow НЕ может разблокировать
  login keychain почти при каждом буте (ошибка `-25293` → `login.keychain-db` →
  `login_renamed_N`). **НИЧЕГО важного не хранить в login keychain** — слетит.
- **Решение: `~/Library/Keychains/persist.keychain-db`** — БЕЗ пароля, `no-timeout`,
  ПЕРВЫЙ в search list. В нём: **Chrome Safe Storage** (стабильный ключ шифрования
  cookies, значение `9f1fce45…`) и **AEAT-сертификат**. Ротация login его не касается.
  Агент `com.agent.keychain-unlock` удалён (2026-09-23): если после ребута Chrome/AEAT
  не видят ключи, разблокировать `persist.keychain-db` вручную.
- **GUI-инструменты агента УДАЛЕНЫ** (2026-09-23): инвентаризация окон (`winlist.py`),
  мышь/клавиатура (`osctl.py`), Vision OCR (`ocr.py`/`ocr.swift`), GUI-примитивы
  (`gui.py`) и поиск авиабилетов (`gflights.py`). Управление Mac'ом теперь только через
  HTTP-ручки статус-панели (`mac-status-server.py`), без автоматизации экрана.
- **AEAT (налоговая Испании)**: рабочий доступ — **curl** с сертификатом
  `~/.aeat/cert.pem` + `~/.aeat/key.pem` (chmod 600; извлечены из
  `/Users/sobogd/Downloads/certespana.p12`, пароль p12 — `P12_PASSWORD` в
  `/Users/sobogd/work/iq-rest/.env`). Сессия: куки в `/tmp/aeat-cookies.txt` (заново после ребута).
  Поток: `ResumenInteresados` → POST `SvInteresadosQuery` (поля F_TIPO_CONSULTA=,
  F_LEIDA=, CLASGTE=20/0/, QUE_MODO=NORMAL, F_FECHA_DESDE/HASTA=dd-mm-YYYY) → список →
  `DetalleSede?ncc=<id>`. Пользователь SOKOLOV BOGDAN Z1894474S, есть представляемое
  лицо SHALIA ANASTASIIA Z1894510M (раздел «En nombre propio» не показывает её).
- **Известный баг macOS (Sequoia и Tahoe)**: p12-импорты в keychain складывают
  элементы, но `SecIdentity` НЕ формируется (`find-identity` = 0) — Chrome/Safari не
  увидят client-сертификат. Для AEAT в браузере нужен **Firefox со своим NSS
  cert-store** (`pk12util` стоит в /opt/homebrew/bin) — keychain не участвует.
- **Keychain**: securityd-операции на запертых keychain ВИСЯТ — всегда
  watchdog'и (`sleep N; kill`).
- **Логин-пароль Mac'а = `2208`** (= `MACOS_PASSWORD` в `/Users/sobogd/work/iq-rest/.env`; он же пароль
  свежесозданного login keychain). kcpassword тоже 2208.
- **Сервис-токен панели**: `/api/*` требует `X-Mac-Token`, если задан `MAC_SERVICE_TOKEN`
  (env или `~/work/.env`). Значение знают только бэкенд Cloudly и панель; браузерный путь
  nginx подставляет заголовок сам (`nginx/status.iq-factura.conf`). Не задан — проверка выключена.
- **Инфраструктура**: статус-панель :18810, reverse-туннель самовосстанавливается
  (WARP tangem рвёт TCP). Auto-login включён, FileVault off, WARP Zero Trust tangem включён.
  WARP (Cloudflare One, org tangem) управляется из панели статуса: карточка WARP —
  connect/disconnect/reconnect через `/usr/local/bin/warp-cli` (POST /api/warp),
  состояние — в `/api/status`.warp. Reconnect рвёт сеть на пару секунд
  (reverse-туннель переживает); CLI не требует sudo из gui-сессии.
- **Статус-панель = PWA**: `/manifest.json` + `/sw.js` + иконки (base64 встроены в
  mac-status-server.py) → ставится с Android Chrome как приложение (standalone-окно,
  без вкладок). `/api/*` service worker не кеширует. **ВАЖНО**: Chrome НЕ регистрирует
  service worker за HTTP basic auth (скрипт SW приходит с 401) → на VPS nginx пути
  `/sw.js`, `/manifest.json`, `/icon-192.png`, `/icon-512.png` отключены от auth
  (`auth_basic off`, секретов там нет), страницы и `/api/*` под паролем. Из-за
  basic-auth окно приложения может снова спросить пароль после очистки кеша
  авторизации Chrome.
- **Полезные пути**: login keychain старые версии — `~/Library/Keychains/login_renamed_*.keychain-db`
  (бэкапы, не удалять без нужды). `.env` секретов — `/Users/sobogd/work/iq-rest/.env`.

## Как агенту действовать
1. Задача про статус/управление → `mac-status-server.py`/README. GUI-автоматизация и
   папка `control/` удалены (2026-09-23).
2. Любое изменение служб → править в `cloudlyru/agents/mac/`, затем `./install.sh`
   (копирует plist в `~/Library/LaunchAgents`; применится после ребута, либо
   `launchctl kickstart -k gui/501/<label>`).
3. git: коммитить изменения в cloudlyru/agents/mac (сообщения на англ., по-существу).



# Secrets handling — global hard rule

Applies in every project and every agent session (this repo included). Full policy: `~/work/AGENTS.md`.

- **Never** pass secrets into chat or agent contexts: no `.env` values, GitHub PATs/tokens,
  SMTP keys/passwords, SSH keys or DB credentials in chat messages, prompts, subagent tasks,
  or tool arguments that get logged.
- **Never** hand a token/API key to an agent to hold or forward, and never write secret values
  into files that could be committed. Never dump secret-bearing files (`~/work/.env`,
  `<project>/.env`) with file-reading tools — that leaks them into the transcript.
- Read secrets **only via local scripts**, feeding the consuming tool straight through stdin
  (`node --env-file=.env …`, `gh secret set` / `gh auth login --with-token` from stdin,
  nodemailer tests, …). Never echo the value.
- When verifying a secret, report only metadata: set/not set, length, prefix class
  (`github_pat_`, `xsmtpsib-`), booleans.

Personal token store: `~/work/.env` (mode 600, outside git) — keys `GH_SOBOGD`,
`GH_BSOKOLOV_TANGEM`. Global copies of this rule: `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`.

## Git Token — Universal Helper

**Всегда используйте скрипт === Git Token Helper ===
This script helps you use the correct GitHub token for each project.

Detected NON-TANGEM project
Using token: GH_SOBOGD

GH_TOKEN is now set to: github_pat_11AKLQQ7I...

You can now run your gh commands:
  gh workflow run <workflow.yml>
  gh push
  gh auth status

IMPORTANT: Never use 'gh auth login' without a token - it will activate
the default account (sobogd) which doesn't work for Tangem projects.** перед операциями с GitHub.



Скрипт автоматически определяет проект и подставляет правильный токен:
- **Тангем проекты** (, ) → 
- **Все остальные** → 

