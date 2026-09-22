#!/usr/bin/env python3
"""Разовая уборка мусора, который остаётся от удалённых сессий Claude Code и pi.

Что чистит:
  * `~/.claude-work/session-env/<id>` — папки окружения без парного журнала;
  * `<профиль>/projects/<проект>/<uuid>/` — папки сессии, чей журнал `<uuid>.jsonl` уже удалён;
  * пустые `~/.pi/agent/sessions/--*--/`.

Профиль Claude Code берётся из `~/.pi-bridge.json` (`claude_config_dir`), как это делает мост.
Папки, изменённые за последний час, не трогаются: у только что стартовавшего разговора журнал
может ещё не появиться на диске.

Запуск: `python3 scripts/clean-agent-junk.py` (по умолчанию dry-run) и `... --apply` для удаления.
"""

import json
import os
import re
import shutil
import sys
import time
from pathlib import Path

BRIDGE_CONFIG = Path.home() / ".pi-bridge.json"
PI_SESSIONS = Path.home() / ".pi" / "agent" / "sessions"
HOUR = 3600
UUID_DIR = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def claude_profile():
    """Профиль Claude Code: `claude_config_dir` из настроек моста, иначе `~/.claude`."""
    try:
        config = json.loads(BRIDGE_CONFIG.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        config = {}
    value = str(config.get("claude_config_dir") or "").strip() or str(os.environ.get("CLAUDE_CONFIG_DIR") or "").strip()
    return Path(value).expanduser() if value else Path.home() / ".claude"


def journal_ids(projects):
    """Все идентификаторы живых сессий: имена файлов `<id>.jsonl` в папках проектов."""
    ids = set()
    if not projects.is_dir():
        return ids
    for file in projects.glob("*/*.jsonl"):
        ids.add(file.stem)
    return ids


def old_enough(path):
    """Папку трогали больше часа назад — значит, журнал бы уже успел появиться."""
    try:
        return time.time() - path.stat().st_mtime > HOUR
    except OSError:
        return False


def find_junk(profile):
    """Находит всё, что подлежит уборке: список путей с пояснением, почему это мусор."""
    junk = []
    projects = profile / "projects"
    live = journal_ids(projects)
    env_root = profile / "session-env"
    if env_root.is_dir():
        for entry in sorted(env_root.iterdir()):
            if entry.is_dir() and entry.name not in live and old_enough(entry):
                junk.append((entry, "окружение удалённой сессии"))
    if projects.is_dir():
        # Папки сессий лежат на уровень ниже проектов: `projects/<проект>/<uuid>/`, поэтому обход
        # идёт по двум уровням, а журналы ищутся рядом с папкой (`<uuid>.jsonl`)
        for folder in sorted(projects.glob("*/*")):
            if not folder.is_dir() or not UUID_DIR.match(folder.name):
                continue
            if not (folder.parent / (folder.name + ".jsonl")).exists() and old_enough(folder):
                junk.append((folder, "папка сессии без журнала"))
    if PI_SESSIONS.is_dir():
        for folder in sorted(PI_SESSIONS.iterdir()):
            if folder.is_dir() and not any(folder.iterdir()):
                junk.append((folder, "пустая папка pi-сессий"))
    return junk


def main():
    """Печатает найденное и удаляет его, если передан `--apply`."""
    apply = "--apply" in sys.argv
    profile = claude_profile()
    junk = find_junk(profile)
    print("профиль Claude Code: %s" % profile)
    print("мусора найдено: %d" % len(junk))
    for path, why in junk:
        print("  %-4s %s (%s)" % ("удалю" if apply else "—", path, why))
        if apply:
            shutil.rmtree(path, ignore_errors=True)
    if not apply:
        print("это холостой прогон; для удаления запустите с --apply")


if __name__ == "__main__":
    main()
