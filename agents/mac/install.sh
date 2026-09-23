#!/bin/bash
# Install / refresh ALL launchd agents from this folder (cloudlyru/agents/mac/*.plist).
# launchd reads per-user agents only from ~/Library/LaunchAgents, so this copies
# the plists there. Running jobs are NOT reloaded here; changes apply on next
# reboot (or reload the specific label manually: launchctl kickstart -k gui/501/<label>).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT"
DST="$HOME/Library/LaunchAgents"
mkdir -p "$ROOT/logs" 2>/dev/null || true

count=0
for p in "$SRC"/com.agent.*.plist; do
  [ -e "$p" ] || continue
  cp "$p" "$DST/$(basename "$p")"
  count=$((count+1))
done
echo "deployed $count plists to $DST"
echo "labels: $(ls "$SRC"/com.agent.*.plist | xargs -n1 basename | sed 's/com.agent.//;s/.plist//' | tr '\n' ' ')"
echo "NOTE: changes apply on next reboot (running jobs keep current defs)."
