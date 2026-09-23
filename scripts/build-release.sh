#!/usr/bin/env bash
#
# Локальный релиз Flutter-клиента: сборка на своём маке и публикация в S3, без GitHub Actions.
#
#   ./scripts/build-release.sh all                # Android, macOS и iOS на один номер
#   ./scripts/build-release.sh android macos      # только перечисленные платформы
#   ./scripts/build-release.sh ios --force        # публикация поверх того же номера
#
# Почему локально, а не в Actions: сборка идёт по инкременту — Gradle-кэш, DerivedData,
# уже установленные CocoaPods, — и повторный выпуск занимает минуты вместо десятков минут
# на холодном раннере. Шаги те же, что были у workflow: `flutter analyze`, релизная сборка
# платформы, публикация через scripts/publish-*.mjs. Из инструментов нужны только Xcode,
# Android SDK, Flutter (stable) и ключи S3 из ~/work/.env.
#
# Про номер сборки. Он берётся из `version:` в flutter/pubspec.yaml (`1.0.0+123` → имя 1.0.0,
# номер 123) и общий для платформ: из него выходит CFBundleVersion на macOS и iOS и versionCode
# на Android. Поэтому обычный выпуск — это «поднять номер один раз и собрать на него все три
# платформы»: publish-*.mjs не принимает сборку с тем же или меньшим номером, и платформа,
# пропущенная в этом выпуске, позже с этим номером уже не опубликуется.
#
# `--force` публикует сборку с тем же номером поверх релизной. Нужен для пересборки одной и
# той же версии, когда идёт проверка на устройстве: кнопкой «Обновить» такое обновление не
# увидит никто (номер не вырос), на Android сборку ставят по adb, на iPad — страницей /ios/install.
#
# Ключи S3 (`S3_FILES_*`) читаются из ~/work/.env через `node --env-file`: в окружение самого
# скрипта они не экспортируются и в вывод не попадают. Другой путь — через CLOUDLY_ENV_FILE.
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE="${CLOUDLY_ENV_FILE:-$HOME/work/.env}"
[ -f "$ENV_FILE" ] || { echo "нет файла с ключами S3: $ENV_FILE" >&2; exit 1; }

# Разбор аргументов: имена платформ и необязательный --force. `all` — это все три сразу.
# Платформы можно перечислять в любом порядке; ни одной — ошибка, а не «собери что-нибудь».
FORCE=0
PLATFORMS=()
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    android|macos|ios) PLATFORMS+=("$arg") ;;
    all) PLATFORMS=(android macos ios) ;;
    *) echo "неизвестный аргумент: $arg (нужно android, macos, ios, all или --force)" >&2; exit 2 ;;
  esac
done
if [ "${#PLATFORMS[@]}" -eq 0 ]; then
  echo "укажите платформы: android, macos, ios или all" >&2
  exit 2
fi

# Номер и имя версии — из pubspec.yaml, того самого файла, из которого Flutter берёт их для
# всех платформ. Обе части обязательны: без номера после «+» публикация сравнивать сборки
# не сможет, а без имени нечего показать в приложении.
RAW_VERSION="$(sed -n 's/^version:[[:space:]]*//p' flutter/pubspec.yaml | head -1)"
VERSION_NAME="${RAW_VERSION%%+*}"
VERSION_CODE="${RAW_VERSION##*+}"
[ -n "$VERSION_NAME" ] || { echo "в flutter/pubspec.yaml нет version" >&2; exit 1; }
[ "$VERSION_CODE" != "$RAW_VERSION" ] || { echo "в version нет номера сборки после «+»: $RAW_VERSION" >&2; exit 1; }

echo "релиз $VERSION_NAME (номер $VERSION_CODE): ${PLATFORMS[*]}"

# Публикация сборки скриптом платформы. `--force` дописывается в конец аргументов, когда
# релиз пересобирается на тот же номер: скрипты публикации понимают его одинаково.
#
# @param … аргументы publish-*.mjs (путь к сборке и, у macOS, ещё имя версии с номером).
publish() {
  local args=("$@")
  if [ "$FORCE" = 1 ]; then
    args+=(--force)
  fi
  node --env-file="$ENV_FILE" "${args[@]}"
}

# Android: подписанный release-APK и его публикация. Подпись — flutter/android/keystore.properties,
# тот же ключ, что у установленного приложения; версию для latest.json publish-apk.mjs читает
# сам из output-metadata.json рядом с APK.
#
# Побочно: файлы сборки в flutter/build/ и объекты в S3.
build_android() {
  (cd flutter && flutter build apk --release)
  publish scripts/publish-apk.mjs flutter/build/app/outputs/apk/release/app-release.apk
}

# macOS: архив с Cloudly.app и его публикация. ditto, а не zip: он сохраняет права и
# символические ссылки внутри бандла — обычный zip их теряет, и распакованное приложение
# не запускается. Имя версии и номер передаются флагами: из самого архива их взять негде.
#
# Побочно: файлы сборки в flutter/build/ и объекты в S3.
build_macos() {
  (cd flutter && flutter build macos --release)
  local dir=flutter/build/macos/Build/Products/Release
  (cd "$dir" && ditto -c -k --keepParent Cloudly.app Cloudly.zip)
  publish scripts/publish-macos.mjs "$dir/Cloudly.zip" \
    --version-name "$VERSION_NAME" --version-code "$VERSION_CODE"
}

# iOS: сборка и публикация живут в scripts/build-ios.sh — там автоматическая подпись (на маке
# личным сертификатом, в CI — стабильным из секретов) и экспорт .ipa. Номер он берёт из pubspec
# сам, а файл окружения прокидывается, чтобы ключи S3 читались из того же места, что у остальных
# платформ.
#
# Побочно: файлы сборки в flutter/build/ios/ и объекты в S3.
build_ios() {
  local args=()
  if [ "$FORCE" = 1 ]; then
    args+=(--force)
  fi
  CLOUDLY_ENV_FILE="$ENV_FILE" ./scripts/build-ios.sh ${args[@]+"${args[@]}"}
}

# Анализ — один раз на весь выпуск: та же проверка, что стояла перед сборкой в workflow,
# и она дешевле сборки, поэтому сломанный код до Gradle и Xcode не доходит.
(cd flutter && flutter analyze)

for platform in "${PLATFORMS[@]}"; do
  echo "=== $platform ==="
  "build_$platform"
done

echo ""
echo "готово: $VERSION_NAME ($VERSION_CODE)"
echo "  Android: https://files.iq-factura.com/apk"
echo "  macOS:   https://files.iq-factura.com/macos"
echo "  iOS:     https://files.iq-factura.com/ios/install (установка по воздуху)"
