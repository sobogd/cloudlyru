#!/usr/bin/env bash
# Пуш в sobogd/cloudlyru от аккаунта sobogd (основной keychain-токен — GH_SOBOGD из ~/work/.env)
# Автоматически запускает деплой сервера (deploy.yml) после пуша
#
# Использование: ./scripts/push-to-main.sh <ветка> [ещё аргументы git push]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TOKEN=$(sed -n 's/^GH_SOBOGD=//p' ~/work/.env)

git -c credential.helper= \
  -c 'credential.helper=!f(){ printf "username=x-access-token\npassword=%s\n" "$TOKEN"; }; f' \
  push origin "$@"

echo "✓ Пуш выполнен. Деплой сервера запущен автоматически."
