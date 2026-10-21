#!/bin/bash
# =============================================================================
# run-mtplx-serve.sh — сторож главной локальной модели (Qwen3.8-27B, MTPLX).
#
# Управляется launchd (com.agent.mtplx, RunAtLoad + KeepAlive): скрипт — вечный
# сторож, проверяет /health каждые 30 секунд и перезапускает сервер при падении.
# После перезагрузки мака launchd поднимает агента при входе в систему, сторож
# поднимает модель — сервер живёт без участия человека.
#
# Сервер запускается со всеми параметрами явно — точная копия живого запуска
# (PID 53771, 2026-10-05) + paged-kv-quantization q8:
#   - turbo-профиль, depth 3, mtp, serial/latency — одиночный агент, минимальная
#     задержка;
#   - verify capture_commit / linear-gdn-from-conv-tape, 4-bit draft head;
#   - paged-kv-quantization q8 — квантованный KV-кеш;
#   - SSD session cache on (cap auto, префикс от 512 токенов) — горячие
#     продолжения сессий;
#   - fan-mode default, reasoning auto/medium (parser qwen3).
#
# Что проверяет сторож: /health отвечает "ok":true. Одного открытого порта
# недостаточно — на порту мог остаться чужой процесс.
#
# Сторож принимает уже запущенный здоровый сервер: он не убивает работающий
# mtplx serve, даже если тот стартован другой командой. Новые параметры
# вступают при полном рестарте (mtplx stop или перезагрузка).
#
# Старт после падения/перезагрузки долгий (веса 27B + warmup), поэтому
# цикл ожидания терпеливее, чем в run-llm-mt.sh: до ~4 минут.
# =============================================================================
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="${HOME:-/Users/sobogd}"
# inline postcommit: стрим хода закрывается только после коммита кэша сессии.
# 300 c — потолок ожидания коммита (дефолт 30 с урезал бы «синхронность» в дыру).
export MTPLX_STREAM_COMMIT_WAIT_MAX_S=300
# mtplx 2.12.0: флаг --session-postcommit-mode убран, режим задаётся переменной.
export MTPLX_SESSION_POSTCOMMIT_MODE=inline

MTPLX=/opt/homebrew/bin/mtplx
PORT=8000
LOG=/tmp/mtplx-serve.log
CHECK_EVERY=30
ENV_FILE=/Users/sobogd/work/.env
MTPLX_API_KEY="$(grep -E '^MTPLX_API_KEY=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)"

# Прошлое состояние — чтобы писать в лог только переходы, а не строку каждые 30 секунд.
state=""

say() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

server_ok() {
  curl -sf -m 5 -H "X-API-Key: ${MTPLX_API_KEY}" "http://127.0.0.1:${PORT}/health" 2>/dev/null | grep -q '"ok":true'
}

start_server() {
  if [ -z "$MTPLX_API_KEY" ]; then
    say "нет MTPLX_API_KEY в $ENV_FILE — не запускаю без ключа"
    return 1
  fi
  # Логи сервера идут в отдельный файл: launchd пишет в свой лог только переходы состояния.
  # Закомментированные флаги — дефолты CLI, оставлены для справки (не влезать в команду:
  # комментарий после «\» глотает продолжение строки и рвёт запуск).
  #   --depth 3 --generation-mode mtp --profile turbo --reasoning auto
  #   --preserve-thinking auto --verify-strategy capture_commit
  #   --verify-core linear-gdn-from-conv-tape --rate-limit 0 --stream-interval 1
  #   --scheduler-mode serial --batching-preset latency --mtp-batch-numerics throughput
  #   --warmup-tokens 16 --retrieval-max-resident 2 --ssd-session-cache on
  #   --ssd-session-cache-max-size auto --ssd-session-cache-min-prefix-tokens 512
  #   --tool-prompt-mode hybrid --chat-template-profile tokenizer
  #   --temperature 1.0 --top-p 0.95 --top-k 20 --reasoning-parser qwen3
  #   --reasoning-effort medium
  nohup "$MTPLX" serve \
    --model /Users/sobogd/.mtplx/models/Youssofal--Qwen3.8-27B-MTPLX-Optimized-Speed \
    --model-id mtplx-qwen38-27b-optimized-speed \
    --host 127.0.0.1 --port "$PORT" \
    --api-key "$MTPLX_API_KEY" \
    --paged-kv-quantization off \
    --fan-mode default \
    >>"$LOG" 2>&1 &
  say "mtplx serve запущен (pid $!), лог: $LOG"
}

stop_hang() {
  # Грациозный стоп (докладывает SSD session cache), затем догоняющий pkill
  # подвисшего процесса: порт занят мёртвым слушателем — классическая причина
  # «перезапустил, а всё равно молчит».
  "$MTPLX" stop >/dev/null 2>&1
  sleep 2
  pkill -f "mtplx.server.openai.*--port ${PORT}" 2>/dev/null
  sleep 1
}

if [ ! -x "$MTPLX" ]; then
  say "нет $MTPLX — установи mtplx (brew install mtplx)"
  exit 1
fi

while :; do
  if ! server_ok; then
    stop_hang
    start_server
    # 27B + warmup: до ~4 минут.
    for _ in $(seq 1 48); do
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