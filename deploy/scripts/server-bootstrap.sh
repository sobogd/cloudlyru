#!/usr/bin/env bash
#
# CloudlyRu — ПЕРВИЧНАЯ настройка сервера (выполнить ОДИН раз, root).
# Создаёт: каталог приложения, роль+БД Postgres (из DATABASE_URL), nginx-конфиг.
# nginx-конфиг кладётся как /etc/nginx/sites-available/cloudlyru.conf и включается.
# TLS (certbot) — отдельно, см. DEPLOY.md.
#
# Использование (с локальной машины, значение НЕ светится):
#   grep '^CLOUDLY_DATABASE_URL=' ~/work/.env | cut -d= -f2- | \
#     ssh root@46.225.143.221 'CLOUDLY_DATABASE_URL=$(cat) bash -s' < deploy/scripts/server-bootstrap.sh
#
set -euo pipefail

if [[ -z "${CLOUDLY_DATABASE_URL:-}" ]]; then
  echo "Usage: CLOUDLY_DATABASE_URL=<postgresql://user:pass@127.0.0.1:5432/db> bash server-bootstrap.sh" >&2
  exit 1
fi

URL="$CLOUDLY_DATABASE_URL"
APP_DIR="/home/deploy/apps/cloudlyru"
DOMAIN="files.iq-factura.com"

# --- парсинг postgres://user:pass@host:port/db (perl — без внешних зависимостей) ---
DB_USER="$(printf '%s' "$URL" | perl -ne 'if(/postgresql:\/\/([^:]+):/){print $1}')"
DB_PASS="$(printf '%s' "$URL" | perl -ne 'if(/postgresql:\/\/[^:]+:([^@]+)@/){print $1}')"
DB_NAME="$(printf '%s' "$URL" | perl -ne 'if(/@[^\/]+\/([^?]+)/){print $1}')"
if [[ -z "$DB_USER" || -z "$DB_PASS" || -z "$DB_NAME" ]]; then
  echo "Не удалось разобрать CLOUDLY_DATABASE_URL" >&2
  exit 1
fi

echo "==> 1/3 Каталог приложения"
mkdir -p "$APP_DIR"
chown -R deployer:deployer "$APP_DIR"

echo "==> 2/3 Postgres: роль '$DB_USER' и БД '$DB_NAME'"
if ! command -v psql >/dev/null 2>&1; then
  echo "psql не найден — установите postgresql-client или postgres" >&2
  exit 1
fi
if [[ "$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'")" != "1" ]]; then
  # экранируем одинарные кавычки в пароле и подставляем напрямую (psql -c не интерполирует :'var')
  ESC_PASS="$(printf '%s' "$DB_PASS" | sed "s/'/''/g")"
  sudo -u postgres psql -c "CREATE ROLE \"$DB_USER\" LOGIN PASSWORD '$ESC_PASS'" >/dev/null
  echo "роль создана"
else
  echo "роль уже есть — пропуск"
fi
if [[ "$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")" != "1" ]]; then
  sudo -u postgres psql -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\"" >/dev/null
  echo "БД создана"
else
  echo "БД уже есть — пропуск"
fi

echo "==> 3/3 nginx ($DOMAIN)"
# HTTP-only server block: SSL-секцию добавляет certbot --nginx (см. DEPLOY.md)
cat > /etc/nginx/sites-available/cloudlyru.conf <<'NGINX'
server {
    listen 80;
    server_name files.iq-factura.com;

    client_max_body_size 0;
    client_body_buffer_size 512k;
    proxy_request_buffering off;

    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    location / {
        proxy_pass http://127.0.0.1:8305;
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        send_timeout       300s;
    }
}
NGINX
ln -sf /etc/nginx/sites-available/cloudlyru.conf /etc/nginx/sites-enabled/cloudlyru.conf
nginx -t && systemctl reload nginx
echo "nginx ok. Дальше: sudo certbot --nginx -d $DOMAIN"

echo
echo "Готово. Теперь: первый деплой из Actions (push в main) применит миграции и поднимет pm2 cloudlyru."
