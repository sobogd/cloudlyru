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
# Токен берём из .env приложения (его пишет деплой из секрета репозитория), чтобы он
# переживал обновления и не заводился руками на сервере. Снаружи ручка ещё и закрыта
# в nginx, но токен — вторая линия.
set -u

RECIPIENT="${1:-}"
APP_DIR="${CLOUDLY_APP_DIR:-/home/deploy/apps/cloudlyru}"
ENV_FILE="$APP_DIR/.env"
LOG="$APP_DIR/logs/mail-inbound.log"
URL="http://127.0.0.1:8305/api/v1/mail/inbound"

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
TOKEN=$(grep -m1 '^MAIL_INBOUND_TOKEN=' "$ENV_FILE" | cut -d= -f2-)
if [ -z "$TOKEN" ]; then
  # Токен не заведён — это ошибка настройки, а не письма: пусть письмо подождёт в очереди,
  # чем отправитель получит отказ.
  log "ОЖИДАНИЕ: MAIL_INBOUND_TOKEN не задан в $ENV_FILE"
  exit 75
fi

# --max-time с запасом: приложение разбирает письмо, кладёт вложения в S3 и пишет в БД
CODE=$(curl -sS --max-time 180 -o /tmp/mail-inbound.out -w '%{http_code}' \
  -X POST "$URL?to=$RECIPIENT" \
  -H "X-Mail-Inbound-Token: $TOKEN" \
  -H 'Content-Type: message/rfc822' \
  --data-binary @- 2>>"$LOG")
RC=$?

if [ "$RC" -ne 0 ]; then
  log "ОЖИДАНИЕ: приложение недоступно (curl $RC), получатель $RECIPIENT"
  exit 75
fi

case "$CODE" in
  200)
    log "принято: $RECIPIENT ($(cat /tmp/mail-inbound.out 2>/dev/null))"
    exit 0
    ;;
  503)
    log "ОЖИДАНИЕ: приложение ответило 503, получатель $RECIPIENT ($(cat /tmp/mail-inbound.out 2>/dev/null))"
    exit 75
    ;;
  413)
    log "ОТКАЗ: письмо слишком большое, получатель $RECIPIENT"
    exit 1
    ;;
  *)
    # 5xx — проблема на нашей стороне, письмо стоит повторить; 4xx — мусор в письме.
    if [ "$CODE" -ge 500 ] 2>/dev/null; then
      log "ОЖИДАНИЕ: приложение ответило $CODE, получатель $RECIPIENT"
      exit 75
    fi
    log "ОТКАЗ: приложение ответило $CODE, получатель $RECIPIENT ($(cat /tmp/mail-inbound.out 2>/dev/null))"
    exit 1
    ;;
esac
