# CloudlyRu — деплой runbook

Автодеплой: **push в main** (по путям `src/**`, `prisma/**`, `package.json`, `pnpm-lock.yaml`, `.env.example`)
→ GitHub Actions собирает → `deployer@<SERVER_IP>` → pm2 `cloudlyru` (:8305, 127.0.0.1) → nginx `files.iq-factura.com`.

Чего автодеплой НЕ делает: не накатывает `deploy/nginx/cloudlyru.conf` (конфиг nginx живёт на сервере
отдельно, см. ниже) и не трогает `deploy/` на сервере как конфиг системы — только кладёт каталог
в бандл приложения (скрипты cron берутся оттуда).

Ручной запуск: `gh workflow run deploy.yml -f run_migrations=true` (в репо `sobogd/cloudlyru`).

## Секреты репозитория (sobogd/cloudlyru)

Уже установлены автоматически:

| Secret | Значение |
|---|---|
| `SERVER_IP` | 46.225.143.221 |
| `SSH_KEY` | приватный ключ deployer (тот же, что ходит в прод) |
| `S3_FILES_ACCESS_KEY` | из `~/work/.env` |
| `S3_FILES_SECRET_KEY` | из `~/work/.env` |
| `DATABASE_URL` | `postgresql://cloudly:…@127.0.0.1:5432/cloudly` (значение в `~/work/.env` → `CLOUDLY_DATABASE_URL`) |
| `ADMIN_LOGIN` | `admin` |
| `ADMIN_PASSWORD` | см. `~/work/.env` → `CLOUDLY_ADMIN_PASSWORD` |

## Переменные окружения

Полный шаблон — `.env.example` (все значения с комментариями). Здесь — то, что важно именно
на проде; дефолт и смысл каждой переменной сверены с `src/config/env.ts`.

В проде приложение откажется стартовать, если не заданы: `DATABASE_URL` (дефолта нет нигде),
`S3_FILES_ACCESS_KEY`, `S3_FILES_SECRET_KEY`, `ADMIN_LOGIN`, `ADMIN_PASSWORD`. Пароль
первого владельца не может быть `admin`, начинаться с `change_me` или совпадать с логином —
это фатально, а короче 12 символов допускается, но пишет предупреждение в лог: на пустой БД
владелец создаётся именно этой парой, а `/auth/login` публичный. Ключа сессии нет: cookie —
32 случайных байта, в БД лежит их sha256 (`SESSION_SECRET` раньше был в шаблоне и деплое,
но код не читал его ни разу и переменная удалена).

Переменные из схемы `src/config/env.ts` (валидируются при старте, есть в `.env.example`):

| Переменная | Дефолт | Что делает |
|---|---|---|
| `LOG_LEVEL` | `log` | `error`/`warn`/`log`/`debug`/`verbose`. На `log` пишутся только медленные запросы, на `debug`/`verbose` — полный лог запросов (чанки релея загрузки — тысячи запросов на файл). |
| `RATE_LIMIT_DEFAULT_PER_MIN` | `1200` | Лимит запросов в минуту на IP для ручек без явного `@RateLimit` (файлы, WebDAV, `/apk`). `0` полностью выключает дефолт и оставляет только явные лимиты — аварийный выход. |

Остальные читает только тот модуль, которому они нужны, — напрямую из окружения, при импорте;
пустое значение, мусор и неположительное число означают дефолт, нулевых значений нет (лимит —
это защита, а не настройка вкуса). В `.env.example` их пока нет: если меняешь, добавляй в `.env`
руками.

| Переменная | Дефолт | Что делает |
|---|---|---|
| `DAV_VALIDATE_LOGIN` | выключена | Строгая сверка логина из Basic-авторизации WebDAV с логином владельца токена. Включается только значениями `true`/`1`; по умолчанию чужой логин принимается (токен всё равно проверяется) и в лог идёт предупреждение. |
| `UNZIP_MAX_ENTRIES` | `20000` | Сколько записей центрального каталога архива готовы принять. Проверка идёт до распаковки, то есть zip-бомба отсекается без чтения байтов. |
| `UNZIP_MAX_TOTAL_MB` | `102400` | Потолок суммарного распакованного объёма одной задачи (100 ГиБ). Квот у пользователей нет, потолок общий. |
| `UNZIP_MAX_RATIO` | `200` | Во сколько раз распакованное может превышать сам архив — защита от zip-бомбы. Легитимные архивы фото/видео дают ~1, архивы текстов — десятки. |
| `UNZIP_MAX_ENTRY_RATIO` | `1000` | Коэффициент сжатия одного члена архива: такой член пропускается (остальные распаковываются), а не валит задачу. |
| `UNZIP_MAX_DEPTH` | `32` | Глубина пути внутри архива, сегментов. |
| `UNZIP_MAX_FOLDERS` | `10000` | Сколько папок может создать одна задача (`a/a/a/…` из архива иначе плодит уровни бесконечно). |
| `UNZIP_BUFFER_LIMIT_MB` | `64` | Файлы до этого размера распаковываются в память одним проходом; крупнее — потоком. 64, а не 128: в памяти живёт и буфер, и `Buffer.concat`, а у процесса API потолок 600 МБ (`max_memory_restart` в `deploy/pm2/ecosystem.config.cjs`). |
| `UNZIP_MAX_RESTARTS` | `2` | Сколько раз подряд задачу распаковки можно вернуть в очередь после внезапного перезапуска процесса; сверх этого она снимается как `failed`, а не гоняется по кругу. |

Почта (раздел необязательный, без него сервис работает): `MAIL_SECRET_KEY` — ключ шифрования
паролей аккаунтов, `MAIL_SYNC_ENABLED` — включает синхронизацию (`true` без ключа не валит
старт, но синхронизация не запустится и в лог уйдёт предупреждение), `MAIL_INBOUND_TOKEN` —
токен ручки приёма письма (`POST /api/v1/mail/inbound`); без него приём закрыт, а
`deploy/scripts/mail-inbound.sh` отвечает Postfix'у «повторить позже». Нужны только если
раздел почты используется.

Отдельно — чистка копий писем у провайдера (необратимая): `MAIL_PURGE_ENABLED` её включает,
и по умолчанию она **выключена** — сервис раз в 5 минут пишет в лог, что ничего не удаляет.
Включать лучше в два шага, оба через секреты репозитория (`.env` на сервере перезаписывается
при каждом деплое, правки в нём не живут):

```bash
gh secret set MAIL_PURGE_DRY_RUN --body true    # сначала только отчёт в лог
gh secret set MAIL_PURGE_ENABLED  --body true    # затем само удаление
```

`MAIL_MAX_MESSAGE_MB` (по умолчанию `64`) — потолок размера письма: больше — письмо
пропускается с причиной в логе, курсор за него не двигается.

## Первичная настройка сервера (один раз, root)

```bash
# с локальной машины (значение DATABASE_URL не печатается — идёт по пайпу)
grep '^CLOUDLY_DATABASE_URL=' ~/work/.env | cut -d= -f2- | \
  ssh root@46.225.143.221 'CLOUDLY_DATABASE_URL=$(cat) bash -s' \
    < /Users/sobogd/work/iq-rest/cloudlyru/deploy/scripts/server-bootstrap.sh

# nginx: bootstrap создаёт конфиг только если его ещё нет. Актуальные лимиты
# (client_max_body_size 64g, proxy_read_timeout 1800s, proxy_max_temp_file_size 0)
# лежат в deploy/nginx/cloudlyru.conf — накатывать вручную:
#   sudo cp deploy/nginx/cloudlyru.conf /etc/nginx/sites-available/cloudlyru.conf
#   sudo nginx -t && sudo systemctl reload nginx   (SSL-блок добавит/сохранит certbot)

# TLS (если ещё не выпущен):
ssh root@46.225.143.221 'certbot --nginx -d files.iq-factura.com'
```

Скрипт: каталог `/home/deploy/apps/cloudlyru`, роль+БД Postgres из `CLOUDLY_DATABASE_URL`,
nginx server-блок (отдельный, блоки iq-rest не трогает). Идемпотентен — можно перезапускать.

Медиа-инструменты bootstrap ставит сам: `ffmpeg`/`ffprobe` (видео), `libheif-examples`
(HEIC), `poppler-utils` — `pdfinfo` и `pdftoppm` для превью страниц PDF. На уже
настроенном сервере, где poppler ещё нет, достаточно один раз:

```bash
ssh root@46.225.143.221 'apt-get install -y --no-install-recommends poppler-utils'
# проверка: curl -s https://files.iq-factura.com/api/v1/healthz  (в логе — какие бинари нашлись)
```

## Первый деплой

```bash
# после bootstrap — любой push в main (или):
gh workflow run deploy.yml -f run_migrations=true --repo sobogd/cloudlyru
```

Проверка:

```bash
curl -s https://files.iq-factura.com/api/v1/healthz     # {"ok":true,…}
# логин: ADMIN_LOGIN/CLOUDLY_ADMIN_PASSWORD из ~/work/.env
```

## Мобильное приложение: постоянная ссылка на последнюю сборку

`https://files.iq-factura.com/apk` отдаёт последнюю опубликованную сборку APK (ручки `/apk`
и `/apk/version` в `src/release/`). Байты лежат в релизном артефакте S3
(`release/android/cloudlyru-sync.apk`), рядом — `latest.json` с версией, размером и sha256:
по нему приложение понимает, что вышло обновление (`GET /api/v1/app/android`).

Публикация — ручной прогон workflow `.github/workflows/android.yml`: он собирает Flutter-клиент
(`flutter/`) и заливает подписанный APK (тестов в проекте нет, проверка — `flutter analyze` и
телефон). Перед запуском поднять `versionCode` в
`flutter/pubspec.yaml` (`version: <versionName>+<versionCode>`, сейчас `1.0.0+45`) — скрипт
публикации не даёт положить сборку с тем же или меньшим номером, иначе телефон её как обновление
не увидит:

```bash
gh workflow run android.yml --repo sobogd/cloudlyru
```

Заменять нативный синхронизатор нечем и не нужно: единственный клиент — это приложение из
`flutter/`, у него `applicationId` `ru.cloudly.sync` и та же подпись, поэтому оно встаёт поверх
уже установленного.

Ручная публикация уже собранного APK:

```bash
node --env-file=$HOME/work/.env scripts/publish-apk.mjs \
  flutter/build/app/outputs/apk/release/app-release.apk     # --dry-run: только показать
```

Секреты репозитория для этой сборки: `ANDROID_KEYSTORE_BASE64` (файл
`~/.cloudly-android-release.jks` в base64), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
`ANDROID_KEY_PASSWORD`; S3-ключи берутся из уже установленных `S3_FILES_*`.

## Отдать произвольный файл по ссылке (дамп и т.п.)

```bash
cd /home/deploy/apps/cloudlyru   # или локально, где есть node_modules приложения
set -a; . .env; set +a
export S3_FILES_BUCKET=cloudlyru S3_FILES_ENDPOINT=https://nbg1.your-objectstorage.com S3_FILES_REGION=nbg1

# загрузить и получить временную ссылку (максимум 7 суток — ограничение S3)
node deploy/scripts/s3-upload.mjs dump.sql.gz dist/dump.sql.gz application/gzip
node deploy/scripts/s3-presign.mjs dist/dump.sql.gz 604800
```

Ссылка подписанная: кто её получил — скачает файл, пока не истёк срок. Бакет при этом остаётся
закрытым, публичного доступа к префиксу `dist/` нет.

## Бэкап БД (cron на сервере)

Дампы кладутся в тот же бакет, префикс `db/` (`db/cloudly-<штамп>.sql.gz`), retention —
lifecycle-правилом бакета на префикс `db/` (30 дней). Скрипты едут на сервер вместе с
деплоем (каталог `deploy/` в бандле), поэтому обновляются автоматически.

Cron от пользователя `deployer` (от него же работает приложение — root не нужен,
секреты читаются из `.env` приложения):

```bash
crontab -e   # пользователь deployer
0 3 * * * CLOUDLY_ENV_FILE=/home/deploy/apps/cloudlyru/.env /home/deploy/apps/cloudlyru/deploy/scripts/backup-db.sh >> /home/deploy/cloudlyru-backup.log 2>&1
```

Проверка руками (создаёт дамп и заливает его в S3):

```bash
CLOUDLY_ENV_FILE=/home/deploy/apps/cloudlyru/.env /home/deploy/apps/cloudlyru/deploy/scripts/backup-db.sh
```

Восстановление:

```bash
createdb cloudly_restore
# скачать дамп с ключами S3 (aws cli/mc/любой клиент), затем:
gunzip -c cloudly-<штамп>.sql.gz | psql cloudly_restore
```

## Приём входящей почты (pipe от Postfix)

Письмо для наших ящиков Postfix отдаёт скрипту `deploy/scripts/mail-inbound.sh`: получатель
приходит аргументом, само письмо — на stdin. Скрипт читает `MAIL_INBOUND_TOKEN` из `.env`
приложения и отправляет письмо в `POST /api/v1/mail/inbound` на localhost; без токена приём
закрыт. Коды выхода значимы для очереди Postfix: `0` — принято, `75` — временная неудача
(приложение недоступно, ответило 503 или токен не задан), `1` — постоянная (пустое письмо,
слишком большое, любой другой отказ приложения). Путь закрыт снаружи в
`deploy/nginx/cloudlyru.conf` (`location = /api/v1/mail/inbound { return 403; }`), поэтому
ручка достижима только с самой машины.

Получателя ручка берёт из заголовков письма (`Delivered-To`/`X-Original-To`), а `?to=`
в URL остаётся запасным вариантом: Express декодирует `+` в пробел, и письмо на
`user+tag@domain` иначе не нашло бы свой аккаунт. Скрипт кодирует адрес в query-строке
процентами по той же причине.

## Место на диске: три уровня защиты

13.09.2026 диск VPS (75 ГБ) заполнился за ночь: конвертер оставлял в `/tmp` временные файлы
HEIC (`clq-*.png` + вытащенный gain map) — 4 442 файла, 53 ГБ. Последствия: API отвечал 500,
автодеплой падал на scp, Postgres не мог писать. Защита теперь на трёх уровнях:

1. **Приложение убирает за собой.** `QueueService.removeJobTmp` в `finally` задачи удаляет все
   файлы с префиксом `clq-<jobId>` (не только каталог задачи), а не только каталог: раньше
   производные файлы от `heif-convert`/`ffmpeg`/`pdftoppm` оставались навсегда.
2. **Приложение не добивает диск.** Перед выдачей новых задач `tick()` смотрит свободное место
   (`MIN_FREE_BYTES`, 5 ГБ): места мало — новые задачи не берутся, начатые досчитываются, в лог
   раз в 10 минут пишется предупреждение. Свободное место видно в приложении: «Настройки →
   Очередь превью → диск сервера», там же красная строка, когда конвертация из-за места встала.
3. **Страховка на сервере (cron).** Если процесс убили (SIGKILL/OOM/`pm2 reload` в момент
   задачи), `finally` не отрабатывает. Скрипт `deploy/scripts/tmp-guard.sh` удаляет файлы
   конвертера старше 180 минут:

```bash
crontab -e   # пользователь deployer
*/15 * * * * /home/deploy/apps/cloudlyru/deploy/scripts/tmp-guard.sh >> /home/deploy/cloudlyru-tmp-guard.log 2>&1
```

Проверка места и мусора руками:

```bash
df -h /                     # свободное место
ls /tmp/clq-* | wc -l       # файлы задач: в норме единицы (только активные)
TMP_GUARD_MIN=60 /home/deploy/apps/cloudlyru/deploy/scripts/tmp-guard.sh   # чистка старше часа
```

Требования: `pg_dump` и `node` — модуль `@aws-sdk/client-s3` берётся из `node_modules`
приложения, отдельный rclone/aws-cli не нужен.

## Уборка «зомби»-объектов в бакете

Объект без строки `Asset` в БД приложению уже не виден: удалить его может только
уборщик. Такие объекты остаются, если строка исчезла в обход приложения (сброс БД
локального инстанса, ручной SQL) или если S3 не ответил на удаление при очистке корзины.

```bash
cd /home/deploy/apps/cloudlyru
set -a && . ./.env && set +a
node deploy/scripts/sweep-orphans.mjs                       # dry-run: только показать
node deploy/scripts/sweep-orphans.mjs --min-age-hours=1     # показать и свежие
node deploy/scripts/sweep-orphans.mjs --apply               # удалить
```

Не трогает `db/` (дампы) и объекты моложе 24 часов: при загрузке файл сначала
копируется в `files/<sha>`, и только потом создаётся строка `Asset` — свежий объект
без строки это нормальная загрузка «в полёте». Префикс `release/` (сборки APK) уборщик
тоже не трогает: он удаляет только `files/`, `view/` и незавершённые `files/tmp/`,
а всё остальное лишь перечисляет как «непонятные ключи».

Такой объект появляется ещё и в одном штатном случае: приложение удаляет байты не сразу,
а с выдержкой в минуту и повторной проверкой, что строк с этим sha не появилось
(`scheduleObjectDeletion` в `src/files/files.service.ts`), — если процесс перезапустился
в окне выдержки, объект остаётся без строки, и в лог уходит строка «подберёт sweep-orphans».

