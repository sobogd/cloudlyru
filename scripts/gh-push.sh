#!/usr/bin/env bash
# Пуш в sobogd/cloudlyru от аккаунта sobogd (основной keychain-токен — bsokolov_tangem,
# у которого нет доступа к этому репо). Токен GH_SOBOGD берётся из ~/work/.env напрямую
# в credential-helper — в логи/аргументы процесса не попадает.
#
# Использование: ./scripts/gh-push.sh <ветка> [ещё аргументы git push] — remote `origin`
# подставляется сам, поэтому в аргументах его быть не должно: `./scripts/gh-push.sh main`.
#
# После пуша перезапускает мост до харнессов, если в уехавших коммитах менялся
# agents/pi-bridge/ (см. scripts/restart-bridge.sh — иначе мост остаётся со старым кодом).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Что именно отправляем: нужно, чтобы найти базу для сравнения. Аргументы могут быть как
# `<ветка>`, так и `<источник>:<назначение>` (`HEAD:main`); ключи (--force, --tags и прочее)
# пропускаем.
TARGET=""
for arg in "$@"; do
  case "$arg" in
    -*) continue ;;
    *:*) TARGET="${arg#*:}" ;;
    *) TARGET="$arg" ;;
  esac
done
TARGET="${TARGET#refs/heads/}"

# Запоминаем то, откуда пушим: после push сравнить с origin/<ветка> уже нечего, поэтому база —
# текущее состояние remote-tracking ref цели (`origin/main` для `HEAD:main`). Если такого ref
# нет (ветку отправляем впервые, отправляем тег), берём upstream текущей ветки.
# `@{push}` намеренно не используем: при push.default=simple он не разрешается, когда локальная
# ветка названа иначе, чем её upstream (обычный случай — ветка ворктри `build174` с upstream
# `main`), и скрипт зря перезапускал мост, убивая заодно сессию агента, который этот пуш и
# запустил.
BEFORE=$(git rev-parse --verify --quiet "refs/remotes/origin/$TARGET" \
  || git rev-parse --verify --quiet '@{upstream}' \
  || true)

# exec здесь не годится: после пуша остаётся работа (перезапуск моста), а exit-код git push
# должен пережить её.
git -c credential.helper= -c 'credential.helper=!f(){ printf "username=x-access-token\npassword=%s\n" "$(sed -n "s/^GH_SOBOGD=//p" ~/work/.env)"; }; f' push origin "$@"

# `--if-changed` сработает только при известной базе: у первой отправки ветки сравнивать не с
# чем, и мост перезапускается сразу — это безопаснее, чем пропустить смену кода.
if [ -n "$BEFORE" ]; then
  ./scripts/restart-bridge.sh --if-changed "$BEFORE" HEAD || true
else
  ./scripts/restart-bridge.sh || true
fi
