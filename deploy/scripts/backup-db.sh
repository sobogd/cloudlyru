#!/usr/bin/env bash
#
# Ежедневный дамп БД CloudlyRu → S3 (prefix db/), retention 30 дней — правилом lifecycle
# на бакете (или чистить lifecycle-правилом по префиксу db/).
#
# Требования на сервере: rclone (или aws cli). Скрипт читает /opt/cloudlyru/.env (chmod 600).
# Cron:  0 3 * * * /opt/cloudlyru/deploy/scripts/backup-db.sh >> /var/log/cloudlyru-backup.log 2>&1
#
set -euo pipefail

ENV_FILE="${CLOUDLY_ENV_FILE:-/opt/cloudlyru/.env}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "[backup] .env не найден: $ENV_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a && . "$ENV_FILE" && set +a

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$(mktemp /tmp/cloudly-dump-XXXXXX.sql.gz)"
RCONF="$(mktemp /tmp/cloudly-rclone-XXXXXX.conf)"
trap 'rm -f "$OUT" "$RCONF"' EXIT
chmod 600 "$RCONF"

# Дамп (одной транзакцией) -> gzip
pg_dump "$DATABASE_URL" --clean --if-exists --no-owner --single-transaction | gzip > "$OUT"

# rclone remote из env (значения не светятся в аргументах процесса)
cat > "$RCONF" <<EOF
[s3]
type = s3
provider = Other
access_key_id = $S3_FILES_ACCESS_KEY
secret_access_key = $S3_FILES_SECRET_KEY
endpoint = $S3_FILES_ENDPOINT
region = $S3_FILES_REGION
force_path_style = true
EOF

rclone --config "$RCONF" copyto "$OUT" "s3:$S3_FILES_BUCKET/db/cloudly-$STAMP.sql.gz"
echo "[backup] OK $(date -Is) -> s3://$S3_FILES_BUCKET/db/cloudly-$STAMP.sql.gz"
