#!/usr/bin/env bash
#
# Ежедневный дамп БД CloudlyRu → S3 (префикс db/).
# Retention — lifecycle-правилом бакета на префикс db/ (30 дней), см. DEPLOY.md.
#
# Требуется: pg_dump (любой версии ≥ сервера БД) и node с модулями приложения
# (@aws-sdk/client-s3 лежит в node_modules рядом). Конфигурация — из .env приложения.
#
# Cron (пользователь deployer, от которого работает приложение):
#   0 3 * * * CLOUDLY_ENV_FILE=/home/deploy/apps/cloudlyru/.env \
#     /home/deploy/apps/cloudlyru/deploy/scripts/backup-db.sh >> /home/deploy/cloudlyru-backup.log 2>&1
#
set -euo pipefail

APP_DIR="${CLOUDLY_APP_DIR:-/home/deploy/apps/cloudlyru}"
ENV_FILE="${CLOUDLY_ENV_FILE:-$APP_DIR/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[backup] .env не найден: $ENV_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a && . "$ENV_FILE" && set +a

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "[backup] DATABASE_URL пуст" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$(mktemp /tmp/cloudly-dump-XXXXXX.sql.gz)"
trap 'rm -f "$OUT"' EXIT

# Дамп согласованным снимком (pg_dump сам берёт repeatable read), без владельца,
# чтобы восстанавливалось в любую роль. Внимание: --single-transaction — опция
# pg_restore, а не pg_dump: с ней этот скрипт раньше падал и бэкапов не было вообще.
pg_dump "$DATABASE_URL" --clean --if-exists --no-owner | gzip > "$OUT"

# Проверяем, что дамп не пустой и целый: иначе «успешный» бэкап может оказаться мусором
if ! gzip -t "$OUT"; then
  echo "[backup] дамп повреждён (gzip -t)" >&2
  exit 1
fi
# имя таблицы идёт со схемой — CREATE TABLE public."FileEntry".
# Важно: именно zgrep, а не `zcat | grep -q` — при pipefail короткое замыкание grep
# даёт SIGPIPE для zcat, и проверка ложно срабатывает.
if ! zgrep -qE 'CREATE TABLE[^;]*"FileEntry"' "$OUT"; then
  echo "[backup] в дампе нет таблиц приложения — не загружаю" >&2
  exit 1
fi

SIZE="$(stat -c %s "$OUT")"
if (( SIZE < 10000 )); then
  echo "[backup] дамп подозрительно мал ($SIZE байт) — не загружаю" >&2
  exit 1
fi

node "$APP_DIR/deploy/scripts/s3-upload.mjs" "$OUT" "db/cloudly-$STAMP.sql.gz"
echo "[backup] OK $(date -Is) → s3://${S3_FILES_BUCKET:-cloudlyru}/db/cloudly-$STAMP.sql.gz ($((SIZE / 1024)) КиБ)"
