#!/bin/bash
# =============================================================================
# run-omlx-serve.sh — сторож главной локальной модели (oMLX, Qwen3.8-27B, порт 8000).
#
# Управляется launchd (com.agent.omlx, RunAtLoad + KeepAlive): скрипт — вечный
# сторож, проверяет /health каждые 30 секунд и перезапускает сервер при падении.
# После перезагрузки мака launchd поднимает агента при входе в систему, сторож
# поднимает модель — сервер живёт без участия человека.
#
# Работает БЕЗ GUI oMLX.app: omlx-cli serve --headless — самодостаточное
# Python-окружение из Contents/Resources приложения, app-процесс не нужен.
# Модели ищет в ~/.omlx/models (сейчас pyros-vault/Qwen3.8-27B-Uncensored-oQ4e-mtp).
# Auth — из auth-секции ~/.omlx/settings.json; старый mtplx-ключ в sub_keys,
# поэтому клиенты со старым ключом продолжают работать.
#
# Что проверяет сторож: /health отвечает "status":"healthy". Одного открытого
# порта недостаточно — на порту мог остаться чужой процесс.
#
# Сторож принимает уже запущенный здоровый сервер (от app или другого
# запуска): он не убивает работающий omlx-server.
# Загрузка 27B долгая, поэтому цикл ожидания терпеливее: до ~5 минут.
# =============================================================================
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="${HOME:-/Users/sobogd}"

OMLX_CLI=/Applications/oMLX.app/Contents/MacOS/omlx-cli
PORT=8000
LOG=/tmp/omlx-serve.log
CHECK_EVERY=30

# Прошлое состояние — чтобы писать в лог только переходы, а не строку каждые 30 секунд.
state=""

say() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

server_ok() {
  curl -sf -m 5 "http://127.0.0.1:${PORT}/health" 2>/dev/null | grep -q '"status":"healthy"'
}

start_server() {
  nohup "$OMLX_CLI" serve --port "$PORT" --headless >>"$LOG" 2>&1 &
  say "omlx serve запущен (pid $!), лог: $LOG"
}

stop_hang() {
  # Догоняющий pkill подвисшего процесса: порт занят мёртвым слушателем —
  # классическая причина «перезапустил, а всё равно молчит».
  # Процесс при запуске сам переименовывается в "omlx-server" (setproctitle),
  # но до этого cmdline — python ... -m omlx.cli serve: гоняем оба паттерна.
  pkill -f "omlx-server" 2>/dev/null
  pkill -f "omlx.cli serve" 2>/dev/null
  sleep 2
}

if [ ! -x "$OMLX_CLI" ]; then
  say "нет $OMLX_CLI — установи oMLX.app"
  exit 1
fi

while :; do
  if ! server_ok; then
    stop_hang
    start_server
    # 27B + warmup: до ~5 минут.
    for _ in $(seq 1 60); do
      server_ok && break
      sleep 5
    done
  fi

  now=down
  server_ok && now=up
  [ "$now" != "$state" ] && say "состояние: ${now}"
  state="$now"

  sleep "$CHECK_EVERY"
done
