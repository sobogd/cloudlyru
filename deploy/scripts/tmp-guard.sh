#!/usr/bin/env bash
#
# Страховка от утечки временных файлов конвертера (раздел /tmp).
#
# Приложение убирает свои файлы само (см. QueueService.removeJobTmp), но если процесс убили —
# SIGKILL, OOM, `pm2 reload` в момент задачи — finally не отрабатывает, и файлы остаются.
# 13.09.2026 так и вышло: ночь конвертации HEIC накопила в /tmp 53 ГБ, диск (75 ГБ) кончился,
# API отвечал 500, автодеплой падал на scp («Process exited with status 1»).
#
# Скрипт удаляет файлы задач конвертера старше TMP_GUARD_MIN минут (по умолчанию 180) и пишет
# в лог, сколько освободил. Файлы создаёт пользователь deployer, поэтому root не нужен.
#
# Cron (пользователь deployer, от него же работает приложение):
#   */15 * * * * /home/deploy/apps/cloudlyru/deploy/scripts/tmp-guard.sh >> /home/deploy/cloudlyru-tmp-guard.log 2>&1
#
set -uo pipefail

TMP_DIR="${TMP_GUARD_DIR:-/tmp}"
TMP_GUARD_MIN="${TMP_GUARD_MIN:-180}"
# Префикс ровно тот, что у временных файлов очереди (TMP_PREFIX в src/queue/queue.service.ts).
TMP_GUARD_PATTERN="${TMP_GUARD_PATTERN:-clq-*}"

avail_kb() { df -Pk "$TMP_DIR" | awk 'NR==2 {print $4}'; }

before_kb="$(avail_kb)"
count="$(find "$TMP_DIR" -maxdepth 1 -name "$TMP_GUARD_PATTERN" -mmin +"$TMP_GUARD_MIN" 2>/dev/null | wc -l | tr -d ' ')"

if [[ "${count:-0}" -eq 0 ]]; then
  exit 0
fi

find "$TMP_DIR" -maxdepth 1 -name "$TMP_GUARD_PATTERN" -mmin +"$TMP_GUARD_MIN" -exec rm -rf -- {} + 2>/dev/null || true
after_kb="$(avail_kb)"
freed_mb=$(( (after_kb - before_kb) / 1024 ))

echo "[tmp-guard] $(date '+%Y-%m-%dT%H:%M:%S%z') удалено файлов: ${count} (старше ${TMP_GUARD_MIN} мин), освобождено ~${freed_mb} МБ, свободно $(( after_kb / 1024 / 1024 )) ГБ"
