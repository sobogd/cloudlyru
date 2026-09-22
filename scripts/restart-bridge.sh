#!/usr/bin/env bash
# Перезапуск моста до харнессов (agents/pi-bridge/server.py, launchd com.agent.pi-bridge).
#
# Зачем. Мост — долгоживущий python-процесс под launchd с KeepAlive: launchd поднимает его
# только когда процесс упал, а не когда на диске появился новый код. После правки
# agents/pi-bridge/** в памяти остаётся старая версия, и мост отвечает по-старому — например,
# отдаёт прежний список моделей Claude Code и пустой список уровней усилия, хотя в коде они
# уже есть. kickstart -k гасит процесс принудительно (`-k`), launchd поднимает его заново
# уже с новым кодом.
#
# Использование:
#   ./scripts/restart-bridge.sh            — перезапустить, если мост вообще загружен
#   ./scripts/restart-bridge.sh --quiet    — то же, но без вывода при успехе (для хуков)
#   ./scripts/restart-bridge.sh --if-changed <commit> [<commit>]
#                                          — перезапустить, только если в диапазоне коммитов
#                                            (или в одиночном коммите) менялся agents/pi-bridge/
#
# Код возврата: 0 — мост перезапущен или перезапуск не требовался; 1 — агент не загружен
# (мост на этой машине не стоит, перезапускать нечего).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

LABEL="com.agent.pi-bridge"
QUIET=0
RANGE=()

# Разбираем аргументы вручную: их мало, а getopt ради двух ключей усложнил бы скрипт.
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --if-changed) shift; RANGE=("$@"); break ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

log() { [ "$QUIET" = 1 ] || echo "$@"; }

# Агент не загружен — это не ошибка правки, а другая машина (например, чужой мак или CI).
# Молча выходим с единицей, чтобы вызывающий сам решил, считать ли это проблемой.
if ! launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  log "мост $LABEL не загружен — перезапускать нечего"
  exit 1
fi

# Режим «только если код менялся». В диапазоне коммитов (origin/main..HEAD или один коммит)
# ищем правки в каталоге моста: если их нет, текущий процесс и так актуален.
if [ ${#RANGE[@]} -gt 0 ]; then
  BASE="${RANGE[0]}"
  HEAD_REF="${RANGE[1]:-HEAD}"
  if ! CHANGED=$(git diff --name-only "$BASE" "$HEAD_REF" -- agents/pi-bridge/); then
    echo "не удалось сравнить $BASE..$HEAD_REF — перезапускаю мост на всякий случай" >&2
  elif [ -z "$CHANGED" ]; then
    log "agents/pi-bridge/ в $BASE..$HEAD_REF не менялся — мост не трогаю"
    exit 0
  fi
fi

launchctl kickstart -k "gui/$(id -u)/$LABEL"

# Ждём, пока новый процесс поднимется и ответит /health: иначе вызывающий скрипт продолжит
# работу, не зная, поднялся ли мост. Порт и адрес берём те же, что у моста по умолчанию.
PORT=$(python3 -c 'import json,pathlib;p=pathlib.Path.home()/".pi-bridge.json";print((json.loads(p.read_text()).get("port") if p.exists() else None) or 18820)' 2>/dev/null || echo 18820)
for _ in $(seq 1 20); do
  if curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    log "мост перезапущен (:${PORT})"
    exit 0
  fi
  sleep 0.5
done

echo "мост не ответил на :${PORT}/health за 10 с — смотрите /tmp/pi-bridge.err.log" >&2
exit 1
