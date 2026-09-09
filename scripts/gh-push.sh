#!/usr/bin/env bash
# Пуш в sobogd/cloudlyru от аккаунта sobogd (основной keychain-токен — bsokolov_tangem,
# у которого нет доступа к этому репо). Токен GH_SOBOGD берётся из ~/work/.env напрямую
# в credential-helper — в логи/аргументы процесса не попадает.
#
# Использование: ./scripts/gh-push.sh [аргументы git push, напр. origin main]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec git -c credential.helper= -c 'credential.helper=!f(){ printf "username=x-access-token\npassword=%s\n" "$(sed -n "s/^GH_SOBOGD=//p" ~/work/.env)"; }; f' push origin "$@"
