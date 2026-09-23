#!/bin/bash
# =============================================================================
# run-whisper.sh — keeps the local speech-recognition server (whisper.cpp)
# serving the translator app.
#
# Managed by launchd (com.agent.whisper, RunAtLoad + KeepAlive). It is the
# speech twin of run-llm.sh: the translation model next door on port 1234 is
# text-only, so voice needs its own engine.
#
# Why whisper.cpp and not a Python stack: the browser already records exactly
# what this server wants (16 kHz mono 16-bit PCM WAV, see lib/wav.ts in the
# translator repo), so nothing is transcoded anywhere, and the model runs on
# Metal. large-v3-turbo is the multilingual turbo checkpoint: ~550 MB, roughly
# 10x real time on this machine, which is what makes a five-minute recording
# come back in tens of seconds instead of minutes.
#
# `--convert` lets the server accept audio that is not 16 kHz mono (it shells
# out to ffmpeg); the app never sends anything else, but the flag costs nothing
# and makes the port usable by hand for debugging. It also means EVERY request
# goes through ffmpeg — the server first dumps the upload into a temp WAV and
# converts it — so `--tmp-dir` below has to be a writable directory, see there.
#
# What the watchdog checks: the server answers its own /health endpoint. Same
# lesson as run-llm.sh — a mere open port proves nothing, a previous occupant
# of the port answered with an error body and a 200.
#
# The port is forwarded to the VPS by the Mac's reverse SSH tunnel as 18818
# (see run-tunnel.sh, and STT_BASE_URL in the translator's deploy).
# =============================================================================
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

WHISPER_SERVER=/opt/homebrew/bin/whisper-server
MODEL="$HOME/models/ggml-large-v3-turbo-q5_0.bin"
PORT=1238
LOG=/tmp/whisper-server.log
# Куда сервер пишет временный WAV перед ffmpeg. Флаг --tmp-dir по умолчанию равен
# ".", то есть текущему каталогу процесса, а launchd запускает этот скрипт с CWD=/ —
# записать файл в корень нельзя, ffmpeg не находит вход и КАЖДЫЙ запрос на
# распознавание отвечает 500 «FFmpeg conversion failed». Приложение показывает это
# как stt_unavailable, то есть голосовой перевод лежит целиком. Свой каталог в /tmp
# (там же, где лог) снимает вопрос.
TMP_DIR=/tmp/whisper-server
CHECK_EVERY=30

# Прошлое состояние — чтобы писать в лог только переходы, а не строку каждые 30 секунд.
state=""

say() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

server_ok() {
  curl -sf -m 5 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1
}

start_server() {
  # Каталог под временные WAV создаём до старта: без него сервер поднимается
  # нормально и отвечает на /health, но валится на каждом запросе — то есть
  # нерабочий движок выглядит живым (см. комментарий к TMP_DIR).
  mkdir -p "$TMP_DIR" || { say "не создать $TMP_DIR — распознавание работать не будет"; exit 1; }

  # Логи сервера идут в отдельный файл: launchd пишет сюда только переходы состояния.
  nohup "$WHISPER_SERVER" \
    -m "$MODEL" \
    --host 127.0.0.1 --port "$PORT" \
    --convert \
    --tmp-dir "$TMP_DIR" \
    >>"$LOG" 2>&1 &
  say "whisper-server запущен (pid $!), лог: $LOG"
}

if [ ! -x "$WHISPER_SERVER" ]; then
  say "нет $WHISPER_SERVER — поставь whisper.cpp: brew install whisper.cpp"
  exit 1
fi
if [ ! -f "$MODEL" ]; then
  say "нет файла модели $MODEL — скачай ggml-large-v3-turbo-q5_0.bin в $HOME/models"
  exit 1
fi

while :; do
  if ! server_ok; then
    # Убиваем возможный подвисший процесс, чтобы не плодить слушателей на одном порту.
    pkill -f "whisper-server.*--port ${PORT}" 2>/dev/null
    sleep 1
    start_server
    for _ in $(seq 1 40); do
      server_ok && break
      sleep 1.5
    done
  fi

  now=down
  server_ok && now=up
  [ "$now" != "$state" ] && say "состояние: ${now}"
  state="$now"

  sleep "$CHECK_EVERY"
done
