# CloudlyRu — деплой runbook

Автодеплой: **push в main** (по путям `src/**`, `prisma/**`, `web/**`, `package.json`, `pnpm-lock.yaml`, `.env.example`)
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
| `SESSION_SECRET` | см. `~/work/.env` → `CLOUDLY_SESSION_SECRET` |
| `ADMIN_LOGIN` | `admin` |
| `ADMIN_PASSWORD` | см. `~/work/.env` → `CLOUDLY_ADMIN_PASSWORD` |

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

## Android-клиент: постоянная ссылка на последнюю сборку

`https://files.iq-factura.com/apk` отдаёт последнюю опубликованную сборку APK (ручки `/apk`
и `/apk/version` в `src/release/`). Байты лежат в релизном артефакте S3
(`release/android/cloudlyru-sync.apk`), рядом — `latest.json` с версией, размером и sha256:
по нему приложение понимает, что вышло обновление (`GET /api/v1/app/android`).

Публикация — push в `main` по `android/**` (workflow `.github/workflows/android.yml`), вручную
нужен только поднятый `versionCode` в `android/app/build.gradle.kts`. Ручная публикация уже
собранного APK:

```bash
node --env-file=$HOME/work/.env scripts/publish-apk.mjs \
  android/app/build/outputs/apk/release/app-release.apk     # --dry-run: только показать
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
без строки это нормальная загрузка «в полёте».

