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

# Запоминаем то, откуда пушим: после push сравнить с origin/<ветка> уже нечего, а `@{push}`
# до пуша указывает на старое состояние удалённой ветки — это и есть база сравнения.
BEFORE=$(git rev-parse --verify --quiet '@{push}' || true)

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
