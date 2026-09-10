# CloudlyRu — деплой runbook

Автодеплой: **push в main** (по путям `src/**`, `prisma/**`, `package.json`, `pnpm-lock.yaml`, `.env.example`)
→ GitHub Actions собирает → `deployer@<SERVER_IP>` → pm2 `cloudlyru` (:8305, 127.0.0.1) → nginx `files.iq-factura.com`.

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
