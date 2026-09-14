#!/bin/sh
#
# Приём письма от нашего Postfix и передача его приложению.
#
# Postfix отдаёт сюда письмо целиком (stdin) и адрес получателя (argv), а мы отправляем его
# в приложение на localhost. Коды выхода важны, потому что от них зависит судьба письма:
#
#   0   — принято, Postfix убирает его из очереди;
#   75  — временная неудача (EX_TEMPFAIL): письмо остаётся в очереди и повторится.
#         Так отвечаем, когда приложение недоступно или само сказало «пока не готово»;
#         отправитель при этом ничего не теряет — очереди хватает на несколько суток;
#   1   — постоянная неудача: отправитель получит отказ. Так отвечаем на явный мусор
#         (письмо слишком большое, пустое тело) — повторять его бессмысленно.
#
# Ни одна служебная операция (создание каталога, запись лога, чтение токена) не должна
# мешать доставке: сначала письмо, потом всё остальное. Поэтому логирование тихое, а
# неудачный redirect не имеет права оборвать вызов приложения — на этом скрипт уже падал:
# каталога logs не было, redirect не срабатывал, и curl вообще не запускался.
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

RECIPIENT="${1:-}"
APP_DIR="${CLOUDLY_APP_DIR:-/home/deploy/apps/cloudlyru}"
ENV_FILE="$APP_DIR/.env"
URL="http://127.0.0.1:8305/api/v1/mail/inbound"
# Ответ и поток ошибок curl — во временные файлы: /tmp есть всегда, в отличие от каталога
# приложения, которого после переустановки может не оказаться.
OUT_TMP="/tmp/mail-inbound.out.$$"
ERR_TMP="/tmp/mail-inbound.err.$$"

LOG_DIR="$APP_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/mail-inbound.log"
[ -w "$LOG_DIR" ] || LOG="/tmp/mail-inbound.log"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true
}

if [ -z "$RECIPIENT" ]; then
  log "ОТКАЗ: не передан получатель"
  exit 1
fi

if [ ! -r "$ENV_FILE" ]; then
  log "ОЖИДАНИЕ: нет файла $ENV_FILE"
  exit 75
fi
TOKEN=$(grep -m1 '^MAIL_INBOUND_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
if [ -z "$TOKEN" ]; then
  # Токен не заведён — это ошибка настройки, а не письма: пусть письмо подождёт в очереди,
  # чем отправитель получит отказ.
  log "ОЖИДАНИЕ: MAIL_INBOUND_TOKEN не задан в $ENV_FILE"
  exit 75
fi

# --max-time с запасом: приложение разбирает письмо, кладёт вложения в S3 и пишет в БД.
# Письмо читается со stdin и уходит как есть, поэтому Content-Type — сам тип письма.
CODE=$(curl -sS --max-time 180 -o "$OUT_TMP" -w '%{http_code}' \
  -X POST "$URL?to=$RECIPIENT" \
  -H "X-Mail-Inbound-Token: $TOKEN" \
  -H 'Content-Type: message/rfc822' \
  --data-binary @- 2>"$ERR_TMP")
RC=$?

ANSWER=$(cat "$OUT_TMP" 2>/dev/null)
CURL_ERR=$(cat "$ERR_TMP" 2>/dev/null)
rm -f "$OUT_TMP" "$ERR_TMP"

if [ "$RC" -ne 0 ]; then
  log "ОЖИДАНИЕ: приложение недоступно (curl $RC: $CURL_ERR), получатель $RECIPIENT"
  exit 75
fi

case "$CODE" in
  200)
    log "принято: $RECIPIENT ($ANSWER)"
    exit 0
    ;;
  503)
    log "ОЖИДАНИЕ: приложение ответило 503, получатель $RECIPIENT ($ANSWER)"
    exit 75
    ;;
  413)
    log "ОТКАЗ: письмо слишком большое, получатель $RECIPIENT"
    exit 1
    ;;
  5*)
    log "ОЖИДАНИЕ: приложение ответило $CODE, получатель $RECIPIENT ($ANSWER)"
    exit 75
    ;;
  *)
    log "ОТКАЗ: приложение ответило $CODE, получатель $RECIPIENT ($ANSWER)"
    exit 1
    ;;
esac
