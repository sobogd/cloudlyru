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

## Бэкап БД (cron на сервере, по желанию)

После первого деплоя на сервере есть `/home/deploy/apps/cloudlyru/.env` — crontab root:

```bash
0 3 * * * CLOUDLY_ENV_FILE=/home/deploy/apps/cloudlyru/.env /home/deploy/apps/cloudlyru/deploy/scripts/backup-db.sh >> /var/log/cloudlyru-backup.log 2>&1
```

(скрипт backup-db.sh лежит в репо `deploy/scripts/` — при необходимости скопировать на сервер;
S3-дампы: prefix `db/`, retention 30 дней — правилом lifecycle на бакете.)
