#!/bin/bash
# =============================================================================
# run-llm.sh — keeps the local LLM server (oMLX) serving CloudlyRu and pi.
#
# Managed by launchd (com.agent.llm, RunAtLoad + KeepAlive).
#
# Сервер — oMLX (`brew install omlx`), модель — Qwen3.6-35B-A3B-OptiQ-4bit в формате MLX.
# Сменила Qwen3.8-27B GGUF под llama.cpp 25.09.2026: у MoE 35B-A3B на токен работают только
# ~3B параметров, поэтому при том же объёме весов (~23 ГБ) генерация должна быть заметно
# быстрее плотной 27B. GGUF этой модели на диске нет, а llama.cpp MLX не читает — отсюда
# и смена сервера.
#
# Раньше llama.cpp держали из-за вызова инструментов: у mlx-lm разбор tool_calls был сырой.
# oMLX — отдельный сервер со своим разбором; если в «Чате» или pi инструменты перестанут
# вызываться, первое подозрение — сюда, а откат — вернуть llama-server с GGUF.
#
# Имена моделей. Клиенты (LLM_MODEL сервера CloudlyRu, pi, уже созданные чаты) просят
# `qwen/qwen3.8-27b`, `qwen/qwen3.5-9b`, `qwen/qwen3.5-4b`. У oMLX псевдоним у модели один,
# поэтому вместо псевдонимов включён `model_fallback` в ~/.omlx/settings.json: любое
# незнакомое имя уходит модели по умолчанию. Какая модель по умолчанию, что она закреплена
# в памяти (`is_pinned`) и что размышления выключены (`enable_thinking: false`) — это
# настройки модели в ~/.omlx/model_settings.json, а не флаги этого скрипта.
#
# brew-сервис oMLX (sh.brew.omlx, порт 8000) остановлен: второй экземпляр с тем же каталогом
# моделей и теми же настройками загрузил бы ту же модель ещё раз.
#
# Что проверяет сторож: сервер отвечает на /health. Пока закреплённая модель грузится в
# память, oMLX отвечает 503 со статусом "loading" — это тоже «жив», иначе сторож убивал бы
# сервер посреди загрузки 23 ГБ весов. Упал — поднимает заново и пишет об этом строку в лог.
# =============================================================================
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

OMLX=/opt/homebrew/bin/omlx
# Каталог MLX-моделей: oMLX видит каждую подпапку как модель с id = имя папки.
MODEL_DIR="$HOME/models/mlx"
MODEL="Qwen3.6-35B-A3B-OptiQ-4bit"
PORT=1234
LOG=/tmp/llm-server.log
CHECK_EVERY=30

state=""

# Печатает строку лога с отметкой времени; stdout уходит в лог launchd.
say() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

# Возвращает успех, если на порту живой oMLX: /health отдаёт "healthy" или "loading".
# Смотрим тело, а не код ответа: во время загрузки модели код 503, а чужой сервер на
# том же порту мог бы ответить 200 с чем угодно.
server_ok() {
  curl -s -m 5 "http://127.0.0.1:${PORT}/health" 2>/dev/null | grep -qE '"status":"(healthy|loading)"'
}

# Запускает oMLX в фоне на своём порту; логи сервера идут в отдельный файл,
# в лог launchd попадают только переходы состояния.
start_server() {
  # `--port` из командной строки перекрывает порт из ~/.omlx/settings.json (там 8000).
  nohup "$OMLX" serve --model-dir "$MODEL_DIR" --host 127.0.0.1 --port "$PORT" \
    >>"$LOG" 2>&1 &
  say "omlx запущен (pid $!), модель $MODEL, лог: $LOG"
}

if [ ! -x "$OMLX" ]; then
  say "нет $OMLX — поставь oMLX: brew install omlx"
  exit 1
fi
if [ ! -f "$MODEL_DIR/$MODEL/config.json" ]; then
  say "нет модели $MODEL_DIR/$MODEL — скачай её в $MODEL_DIR"
  exit 1
fi

while :; do
  if ! server_ok; then
    # Сервера нет или он не отвечает. Убиваем подвисшего слушателя порта, чтобы порт не
    # остался занятым мёртвым процессом. Ищем по порту, а не pkill по командной строке:
    # oMLX после старта переименовывает процесс в `omlx-server`, и шаблон по пути
    # бинарника его бы не нашёл.
    lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null
    sleep 1
    start_server
    # Порт oMLX занимает за секунды, а /health отвечает "loading" уже во время загрузки
    # весов, поэтому 30 секунд ожидания хватает.
    for _ in $(seq 1 20); do
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
