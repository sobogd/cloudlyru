# pi-bridge — мост между приложением CloudlyRu и харнессом pi

Раздел «Проекты» в приложении: выбираешь папку проекта — и дальше разговариваешь с
харнессом [pi](https://github.com/earendil-works/pi) (`@earendil-works/pi-coding-agent`),
который работает в этой папке: читает файлы, правит их, запускает команды. Модель — та же
локальная (`llama.cpp` на этом маке, `qwen/qwen3.5-9b`), что и у раздела «Чат».

```
телефон / мак (приложение CloudlyRu)
   │ HTTPS + SSE
Cloudflare  pi.iq-factura.com + Access (service token)
   │ туннель (cloudflared, com.agent.pi-tunnel)
мост  agents/pi-bridge/server.py, 127.0.0.1:18820
   │ JSON-строки по stdio, процесс на сессию
pi    pi --mode rpc  (cwd = папка проекта)
   └── llama.cpp 127.0.0.1:1234
```

Мост — тонкий адаптер и не более: он не думает, не хранит историю и не знает про модели.
История — файлы сессий pi (`~/.pi/agent/sessions/--<путь>--/`), инструменты, контекст и
сжатие — тоже pi. Поэтому разговор, начатый в приложении, виден в терминале (`pi -r`), и
наоборот.

## Что делает мост

| Ручка | Зачем |
|---|---|
| `GET /health` | жив ли мост, какая версия pi, что в пуле процессов |
| `GET /projects` | проекты: корни из allowlist плюс папки с `.git` внутри них |
| `GET /sessions?path=<папка>` | сессии проекта (файлы pi): имя, время, число сообщений |
| `POST /sessions` | открыть сессию: поднять процесс pi в папке проекта |
| `GET /sessions/<id>` | модель, расход контекста, занятость |
| `GET /sessions/<id>/messages` | переписка в виде, готовом для экрана |
| `POST /sessions/<id>/prompt` | отправить сообщение; ответ идёт потоком SSE |
| `POST /sessions/<id>/abort` | остановить генерацию |
| `POST /sessions/<id>/compact` | сжать контекст |
| `POST /sessions/<id>/model` | сменить модель |
| `DELETE /sessions/<id>` | закрыть процесс (файл истории остаётся) |

События потока: `delta`, `reasoning`, `tool_call`, `tool_start`, `tool_update`, `tool_end`,
`status`, `usage`, `ui`, `done`, `error`. Полный список ищется в `server.py` в `_prompt`.

Настройки — `~/.pi-bridge.json` (создаётся при первом запуске, режим 600): порт, токен,
allowlist корней, глубина поиска проектов, провайдер и модель. Если провайдер и модель не
заданы, берётся первая модель из `~/.pi/agent/models.json`.

## Установка

### 1. Мост

```bash
cp agents/pi-bridge/com.agent.pi-bridge.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.agent.pi-bridge.plist
# первый запуск создаст ~/.pi-bridge.json с токеном — его вписывают в приложение
curl -s http://127.0.0.1:18820/health
curl -s -H "Authorization: Bearer $(python3 -c "import json;print(json.load(open('$HOME/.pi-bridge.json'))['token'])")" \
     http://127.0.0.1:18820/projects | head -c 400
```

Корни правятся в `~/.pi-bridge.json` (`roots`): по умолчанию это `~/work`. Внутри корней
мост показывает папки с `.git` (и те, где уже есть сессии pi) — файловой системы наружу нет.

### 2. Туннель Cloudflare

Один раз, руками (нужен браузер и зона `iq-factura.com`):

```bash
cloudflared tunnel login
cloudflared tunnel create pi
cloudflared tunnel route dns pi pi.iq-factura.com
cp agents/pi-bridge/config.yml.example ~/.cloudflared/config.yml   # и вписать UUID
cp agents/pi-bridge/com.agent.pi-tunnel.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.agent.pi-tunnel.plist
```

Затем в Cloudflare Zero Trust → Access → Applications создаётся self-hosted приложение на
`pi.iq-factura.com` с политикой Service Auth и парой service token. `CF-Access-Client-Id` и
`CF-Access-Client-Secret` вписываются в приложении (раздел «Проекты» → шестерёнка). Токен
моста из `~/.pi-bridge.json` — там же: Access закрывает вход, токен моста даёт второй рубеж
и отдельный отзыв.

### 3. Приложение

Раздел открывается иконкой терминала в шапке «Чата». Настройки: адрес моста (по умолчанию
`https://pi.iq-factura.com`), токен моста, пара Cloudflare Access.

## Диагностика

```bash
launchctl list | grep -E "pi-bridge|pi-tunnel"
tail -20 /tmp/pi-bridge.err.log /tmp/pi-tunnel.err.log
# снаружи: 401 без токена, 200 с ним
curl -s -o /dev/null -w '%{http_code}\n' https://pi.iq-factura.com/health
```

| Что видно | Что значит |
|---|---|
| «мост недоступен» в приложении | мост или туннель не поднят: смотреть `launchctl list` |
| `401` от Cloudflare | истёк или не тот service token Access |
| `401 неверный токен моста` | не совпал токен в настройках раздела |
| «сессия занята» | в этой сессии уже идёт генерация (в том числе из терминала) |
| пустой список проектов | в корнях нет папок с `.git` — проверить `roots` в `~/.pi-bridge.json` |

## Что важно знать

**Один клиент на сессию.** Два писателя в один JSONL-файл pi развели бы разговор, поэтому
занятая сессия отвечает `409`, а не принимает второй запрос. Сессия, открытая в терминале
на маке, для моста не «занята» — он про неё не знает; если хочется работать в двух местах
сразу, в приложении лучше начать новую сессию.

**Подтверждений нет.** Политика раздела — «разрешать всё без вопросов»: у pi в RPC-режиме
диалоги приходят от расширений событием `extension_ui_request`, и мост отвечает на них сам
(`confirm` → да, `select` → первый вариант, `input` → отмена). Каждый автоответ пишется в
`/tmp/pi-bridge.err.log` — по нему видно, что агент сделал без человека.

**Песочницы у pi нет** (см. `docs/security.md` самого pi): инструменты работают с правами
пользователя, поэтому единственная граница — allowlist корней в настройках моста, токены
(Access + моста) и то, что порт 18820 слушает только loopback.

**Процессы гасятся по простою** (30 минут): каждый живой процесс pi держит контекст модели в
памяти, а память на этом маке дороже пары секунд на запуск. Продолжение разговора после
остановки поднимает процесс заново — сессия лежит в файле, ничего не теряется.
