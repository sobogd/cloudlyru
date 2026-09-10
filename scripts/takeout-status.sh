#!/bin/bash
# Статус переноса Google Takeout → CloudlyRu.
# Запуск на VPS: /root/takeout/status.sh
# Источник данных — state-файл скрипта импорта (без дублей из БД).

set -a
. /home/deploy/apps/cloudlyru/.env
set +a
cd /root/takeout || exit 1
LOG=run-v2.log

echo "=== ПРОЦЕСС ==="
if ps -eo cmd | grep -q "[n]ode takeout-stream-to-cloudly.mjs"; then
  ps -eo etime,pcpu,cmd | awk '/node takeout-stream/ && !/awk/ {printf "  работает, %s, CPU %s%%\n", $1, $2}'
else
  if [ -f COOKIE_DEAD ]; then
    echo "  ОСТАНОВЛЕН: нужна свежая Google-cookie (обнови cookie.txt и запусти снова)"
  elif [ -f ALL_DONE ]; then
    echo "  ЗАВЕРШЁН: все архивы перенесены"
  else
    echo "  не запущен"
  fi
fi

echo
echo "=== ПРОГРЕСС ВСЕГО ПЕРЕНОСА ==="
python3 - <<'PY'
import json, os
p = "/root/takeout/.takeout-state.json"
s = json.load(open(p)) if os.path.exists(p) else {}
sizes = s.get("sizes", {})
prog = s.get("progress", {})
done = s.get("done", [])
gb = lambda b: b / 1e9
total = sum(sizes.values())
done_b = sum(sizes.get(u, 0) for u in done)
live = sum(v.get("received", 0) for v in prog.values())
cur = min(done_b + live, total) if total else done_b
n = len(sizes) or (len(done) + len(prog))
print("  архивов готово: %d из %d" % (len(done), n))
if total:
    print("  объём: %.1f из %.1f ГБ (%.1f%%)" % (gb(cur), gb(total), cur / total * 100))
for u, v in sorted(prog.items(), key=lambda x: -x[1].get("received", 0)):
    nm = u.split("/")[-1].split("?")[0].replace("takeout-", "").replace(".zip", "")
    tot = v.get("total") or sizes.get(u, 1)
    rec = v.get("received", 0)
    print("    в работе %s: %.1f/%.1f ГБ (%.0f%%)" % (nm, gb(rec), gb(tot), rec / tot * 100))
if s.get("suspect"):
    print("  ВНИМАНИЕ, подозрительные: " + ", ".join(s["suspect"]))
PY

echo
echo "=== СКОРОСТЬ И ETA (последняя строка скрипта) ==="
grep -a "^\[прогресс\]" "$LOG" 2>/dev/null | tail -1 | sed 's/^/  /'
[ -z "$(grep -a '^\[прогресс\]' "$LOG" 2>/dev/null | tail -1)" ] && echo "  (пока нет)"

echo
echo "=== ЧТО ВИДНО В РАЗДЕЛЕ «ФАЙЛЫ» ==="
curl -s -o /dev/null -c /tmp/st.txt \
  -H "Content-Type: application/json" \
  -d "{\"login\":\"${ADMIN_LOGIN:-admin}\",\"password\":\"$ADMIN_PASSWORD\"}" \
  http://127.0.0.1:8305/api/v1/auth/login
FID=$(curl -s -b /tmp/st.txt http://127.0.0.1:8305/api/v1/folders | python3 -c 'import sys,json
d = json.load(sys.stdin)
ids = [f["id"] for f in d["folders"] if f["name"] == "GooglePhotos-Takeout"]
print(ids[0] if ids else "")')
if [ -z "$FID" ]; then
  echo "  папки пока нет (создастся при старте)"
else
  curl -s -b /tmp/st.txt "http://127.0.0.1:8305/api/v1/folders/$FID/children" | python3 -c 'import sys,json
d = json.load(sys.stdin)
tot = sum(e["size"] for e in d["entries"])
print("  файлов: %d | суммарно: %.2f ГБ" % (len(d["entries"]), tot / 1e9))
for e in sorted(d["entries"], key=lambda x: x["name"]):
    print("   OK %s %.2f ГБ" % (e["name"], e["size"] / 1e9))'
fi
