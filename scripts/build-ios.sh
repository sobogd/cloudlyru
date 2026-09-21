#!/usr/bin/env bash
#
# Сборка Ad Hoc сборки для iPad и iPhone (файл .ipa) и её публикация в /ios.
#
# Почему не `flutter build ipa`: подпись здесь держится на App Store Connect API-ключе,
# а ключ xcodebuild принимает только флагами (`-authenticationKeyPath/-ID/-IssuerID`) —
# сам он `~/.appstoreconnect/private_keys` не просматривает (там его ищет altool, не xcodebuild).
# Пробросить эти флаги через `flutter build ipa` нечем, поэтому архив и экспорт делаются
# xcodebuild-ом напрямую: `-allowProvisioningUpdates` вместе с ключом даёт Xcode право самому
# выпустить distribution-сертификат, завести App ID и собрать Ad Hoc профиль со списком устройств.
#
# Локально: ключ берётся из ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8, значения
# ASC_KEY_ID / ASC_ISSUER_ID / APPLE_TEAM_ID — из окружения, а если их там нет, из ~/work/.env
# (файл читается построчно, значения никуда не печатаются). В CI то же самое приходит секретами.
#
#   ./scripts/build-ios.sh                  # собрать, подписать и опубликовать в /ios
#   ./scripts/build-ios.sh --no-publish     # только собрать (файл в flutter/build/ios/ipa)
#   ASC_KEY_FILE=/путь/к/ключу.p8 ./scripts/build-ios.sh
#
# В CI ключ лежит во временном файле — путь передаётся через ASC_KEY_FILE.
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE="${CLOUDLY_ENV_FILE:-$HOME/work/.env}"
PUBLISH=1
for arg in "$@"; do
  case "$arg" in
    --no-publish) PUBLISH=0 ;;
    *) echo "неизвестный аргумент: $arg" >&2; exit 2 ;;
  esac
done

# Значение переменной: уже заданное в окружении важнее файла (так работает CI).
read_env() {
  local name="$1"
  if [ -n "${!name:-}" ]; then return 0; fi
  [ -f "$ENV_FILE" ] || return 0
  local value
  value="$(sed -n "s/^${name}=//p" "$ENV_FILE" | head -1 | tr -d '\r')"
  [ -n "$value" ] && export "${name}=${value}"
  return 0
}

read_env ASC_KEY_ID
read_env ASC_ISSUER_ID
read_env APPLE_TEAM_ID
: "${ASC_KEY_ID:?нужен ASC_KEY_ID (Key ID ключа App Store Connect)}"
: "${ASC_ISSUER_ID:?нужен ASC_ISSUER_ID (Issuer ID)}"
: "${APPLE_TEAM_ID:?нужен APPLE_TEAM_ID (Team ID аккаунта)}"

KEY_FILE="${ASC_KEY_FILE:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[ -f "$KEY_FILE" ] || {
  echo "нет файла ключа: $KEY_FILE" >&2
  echo "положите .p8 в ~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8 или задайте ASC_KEY_FILE" >&2
  exit 1
}

# Версия — из pubspec.yaml, тот же номер, что у Android и macOS: сборки сравниваются по нему,
# и публикация не примет тот же или меньший номер.
RAW_VERSION="$(sed -n 's/^version:[[:space:]]*//p' flutter/pubspec.yaml | head -1)"
VERSION_NAME="${RAW_VERSION%%+*}"
VERSION_CODE="${RAW_VERSION##*+}"
[ -n "$VERSION_NAME" ] || { echo "в flutter/pubspec.yaml нет version" >&2; exit 1; }
[ "$VERSION_CODE" != "$RAW_VERSION" ] || { echo "в version нет номера после «+»: $RAW_VERSION" >&2; exit 1; }

ARCHIVE="flutter/build/ios/Runner.xcarchive"
EXPORT_DIR="flutter/build/ios/ipa"
EXPORT_OPTIONS="$(mktemp -t cloudly-export-options)"
trap 'rm -f "$EXPORT_OPTIONS"' EXIT

# Способ экспорта называется по-разному в разных Xcode: до 15.3 это `ad-hoc`, дальше
# `release-testing` (одно и то же — установка на устройства из профиля). Пишем оба и пробуем
# по очереди: на новой машине пройдёт первый, на старой — второй.
write_export_options() {
  cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>$1</string>
	<key>teamID</key>
	<string>${APPLE_TEAM_ID}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>compileBitcode</key>
	<false/>
	<key>stripSwiftSymbols</key>
	<true/>
	<key>uploadSymbols</key>
	<false/>
</dict>
</plist>
PLIST
}

# Xcode собирает Flutter-часть своим скриптом внутри проекта, поэтому достаточно сгенерировать
# конфигурацию: Dart-код компилируется уже на этапе archive.
echo "== конфигурация Flutter =="
(cd flutter && flutter build ios --release --config-only)

echo "== архив (подпись через API-ключ) =="
rm -rf "$ARCHIVE"
(cd flutter/ios && xcodebuild \
  -workspace Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "../build/ios/Runner.xcarchive" \
  archive \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  -authenticationKeyPath "$KEY_FILE" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "== экспорт .ipa =="
rm -rf "$EXPORT_DIR"
exported=0
for method in release-testing ad-hoc; do
  write_export_options "$method"
  if (cd flutter && xcodebuild \
    -exportArchive \
    -archivePath "build/ios/Runner.xcarchive" \
    -exportPath "build/ios/ipa" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_FILE" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"); then
    echo "экспорт способом '$method' прошёл"
    exported=1
    break
  fi
  echo "способ '$method' не подошёл, пробую следующий" >&2
done
[ "$exported" = 1 ] || { echo "не удалось экспортировать .ipa" >&2; exit 1; }

IPA="$(ls "$EXPORT_DIR"/*.ipa | head -1)"
[ -n "$IPA" ] || { echo "в $EXPORT_DIR нет .ipa" >&2; exit 1; }
echo "собрано: $IPA ($(du -h "$IPA" | cut -f1))"

if [ "$PUBLISH" = 0 ]; then
  echo "--no-publish: сборка осталась на диске, в /ios не выкладываю"
  exit 0
fi

# Публикация: локально ключи S3 берутся из файла окружения, в CI они уже в переменных.
NODE_ENV_ARGS=()
[ -f "$ENV_FILE" ] && NODE_ENV_ARGS+=("--env-file=$ENV_FILE")
node ${NODE_ENV_ARGS[@]+"${NODE_ENV_ARGS[@]}"} scripts/publish-ios.mjs "$IPA" \
  --version-name "$VERSION_NAME" \
  --version-code "$VERSION_CODE"
