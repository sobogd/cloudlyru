#!/usr/bin/env bash
#
# Сборка Ad Hoc сборки для iPad и iPhone (файл .ipa) и её публикация в /ios.
#
# Подпись автоматическая (`-allowProvisioningUpdates` вместе с ключом App Store Connect):
# Xcode сам выпускает профиль, обновляет список устройств и подписывает сборку. Разница только
# в том, какие сертификаты у него под рукой:
#
#   в CI (задан IOS_SIGNING_PEM) — в одноразовую связку ключей кладутся стабильные сертификаты
#     Apple Development и Apple Distribution: первым Xcode подписывает архив, вторым — Ad Hoc
#     экспорт. Выпускать новые сертификаты ему нечем и незачем;
#   на своём маке (переменной нет) — личные сертификаты из связки ключей, как было всегда.
#
# Почему так. Раньше на раннере не было ни одного сертификата, и Xcode выпускал себе новые
# на каждый прогон (в имени таких сертификатов стоит «Created via API»). Аккаунт упирался
# в лимит Apple, поэтому перед сборкой воркфлоу чистил хвосты прошлых прогонов — то есть
# каждая сборка отзывала сертификаты предыдущей. С готовыми личностями в связке ключей этого
# не происходит. Сами сертификаты разово готовит scripts/asc-signing-setup.mjs.
#
# Почему не `flutter build ipa`: ключ App Store Connect xcodebuild принимает только флагами
# (`-authenticationKeyPath/-ID/-IssuerID`) — сам он `~/.appstoreconnect/private_keys` не
# просматривает (там его ищет altool, не xcodebuild). Пробросить эти флаги через
# `flutter build ipa` нечем, поэтому архив и экспорт делаются xcodebuild-ом напрямую.
#
# Локально: ключ берётся из ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8, значения
# ASC_KEY_ID / ASC_ISSUER_ID / APPLE_TEAM_ID — из окружения, а если их там нет, из ~/work/.env
# (файл читается построчно, значения никуда не печатаются). В CI то же самое приходит секретами.
#
#   ./scripts/build-ios.sh                  # собрать, подписать и опубликовать в /ios
#   ./scripts/build-ios.sh --no-publish     # только собрать (файл в flutter/build/ios/ipa)
#   ./scripts/build-ios.sh --force          # опубликовать поверх того же номера сборки
#   ASC_KEY_FILE=/путь/к/ключу.p8 ./scripts/build-ios.sh
#
# --force нужен, когда пересобирают ту же версию (проверка на устройстве): публикация
# с тем же номером иначе отказала бы, а страница /ios/install всё равно отдаёт последнюю
# загруженную сборку. Кнопкой «Обновить» такое обновление не увидит никто — номер не вырос.
#
# Про устройства: список устройств зашит в профиль Ad Hoc, но ведёт его Xcode — новое
# устройство подхватывается само (`-allowProvisioningDeviceRegistration`), а установить на него
# сборку можно с момента, когда профиль обновился. Посмотреть, какие сертификаты сейчас
# в аккаунте, — scripts/asc-certs.mjs (он же умеет отзывать лишние вручную); сами сертификаты
# для CI выпускает scripts/asc-signing-setup.mjs.
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE="${CLOUDLY_ENV_FILE:-$HOME/work/.env}"
PUBLISH=1
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --no-publish) PUBLISH=0 ;;
    --force) FORCE=1 ;;
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

# Временное хозяйство CI: каталог и связка ключей, а также то, что было в машине до нас
# (всё это возвращается на место в cleanup).
SIGN_TMP=""
KEYCHAIN_NAME=""
ORIGINAL_DEFAULT=""
ORIGINAL_KEYCHAINS=""
EXPORT_OPTIONS=""

# Уборка за собой: файл export options и временная связка ключей. Связку и списки связок
# возвращаем в исходное состояние: локальный прогон с секретами — обычное дело при проверке
# подписи, и он не должен менять настройки машины, на которой идёт. Вызывается на любом
# выходе, в том числе на ошибке, поэтому все переменные существуют заранее.
cleanup() {
  if [ -n "$EXPORT_OPTIONS" ]; then rm -f "$EXPORT_OPTIONS"; fi
  if [ -n "$ORIGINAL_DEFAULT" ]; then security default-keychain -d user -s $ORIGINAL_DEFAULT 2>/dev/null || true; fi
  if [ -n "$ORIGINAL_KEYCHAINS" ]; then security list-keychains -d user -s $ORIGINAL_KEYCHAINS 2>/dev/null || true; fi
  if [ -n "$KEYCHAIN_NAME" ]; then security delete-keychain "$KEYCHAIN_NAME" 2>/dev/null || true; fi
  if [ -n "$SIGN_TMP" ]; then rm -rf "$SIGN_TMP"; fi
}

# Статус выхода сохраняем до уборки: иначе сборка, упавшая на подписи, отчиталась бы успехом
# (уборка последним действием возвращает ноль).
trap 'STATUS=$?; cleanup; exit $STATUS' EXIT

# --- стабильные сертификаты для CI ------------------------------------------------------------
# Раннер живёт один прогон, своей связки ключей у него нет: без этого блока Xcode под
# автоматической подписью выпускал себе новые сертификаты на каждый прогон (архиву нужна
# development-личность, экспорту Ad Hoc — distribution). Кладём в одноразовую связку обе
# готовые личности, и Xcode собирает профили под них, ничего в аккаунте не заводя.
if [ -n "${IOS_SIGNING_PEM:-}" ]; then
  SIGN_TMP="$(mktemp -d -t cloudly-signing)"
  KEYCHAIN_NAME="$SIGN_TMP/cloudly.keychain-db"
  # Пароль одноразовой связки ключей: она живёт один прогон и наружу не выходит, поэтому
  # годится случайный — хранить его дольше негде и незачем.
  KEYCHAIN_PASS="$(openssl rand -hex 16)"
  ORIGINAL_DEFAULT="$(security default-keychain -d user | tr -d ' "')"
  ORIGINAL_KEYCHAINS="$(security list-keychains -d user | tr -d ' "')"

  security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_NAME"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_NAME"
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_NAME"
  # -T и set-key-partition-list вместе дают codesign пользоваться ключами без запроса пароля:
  # спросить его в CI некому, и на этом обычно застревают немые сборки.
  PEM_FILE="$SIGN_TMP/signing.pem"
  printf '%s' "$IOS_SIGNING_PEM" | base64 -d > "$PEM_FILE"
  security import "$PEM_FILE" -k "$KEYCHAIN_NAME" -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN_NAME" >/dev/null
  rm -f "$PEM_FILE"
  # В списке связок наша идёт первой, остальные — следом: xcodebuild ищет личности по порядку,
  # и стабильный сертификат должен попадаться раньше всего, что найдётся в других связках
  # (в CI их и нет, а на своём маке рядом может лежать личный сертификат разработчика).
  # Список составляем из того, что уже есть, а не переписываем своим: с чужой связкой в одиночку
  # Apple-сертификат перестаёт считаться действительным (проверка подписи не находит корневые).
  security list-keychains -d user -s "$KEYCHAIN_NAME" $(security list-keychains -d user | tr -d ' "')
  security default-keychain -d user -s "$KEYCHAIN_NAME"

  # Личности берём из связки, а не из секрета: имена сертификатов составляет Apple
  # («Apple Development: Имя (TEAM)», «Apple Distribution: Имя (TEAM)»), и держать их копию
  # в секретах незачем. Именно этими личностями Xcode и должен подписать сборку.
  OUR_IDENTITIES="$(security find-identity -v -p codesigning "$KEYCHAIN_NAME" | sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]* "\(.*\)"$/\1/p')"
  [ -n "$OUR_IDENTITIES" ] || {
    echo "в IOS_SIGNING_PEM нет сертификатов — пересоберите подпись: scripts/asc-signing-setup.mjs" >&2
    exit 1
  }
  echo "сертификаты для сборки (стабильные, из секретов):"
  printf '%s\n' "$OUR_IDENTITIES" | sed 's/^/  /'
fi

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

# Шаг подписи, который нужен и архиву, и экспорту: право Xcode самому выпускать профили
# и регистрировать устройства, плюс ключ App Store Connect для этого права (флагами, см. шапку).
SIGNING_ARGS=(
  -allowProvisioningUpdates
  -allowProvisioningDeviceRegistration
  -authenticationKeyPath "$KEY_FILE"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

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
  ${SIGNING_ARGS[@]+"${SIGNING_ARGS[@]}"})

# Проверка после архива: в CI сборка обязана быть подписана одним из наших сертификатов.
# Если Xcode выпустил под неё новую личность (протухший или отозванный сертификат, лимит),
# узнать об этом надо здесь — иначе аккаунт снова начнёт копить сертификаты, а сборки падать
# на лимите, ради чего вся эта возня и затевалась.
if [ -n "${IOS_SIGNING_PEM:-}" ]; then
  SIGNED_BY="$(codesign -dvv "$ARCHIVE/Products/Applications/Runner.app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  if ! printf '%s\n' "$OUR_IDENTITIES" | grep -Fxq "$SIGNED_BY"; then
    echo "архив подписан не нашим сертификатом: «${SIGNED_BY}»; ожидался один из:" >&2
    printf '%s\n' "$OUR_IDENTITIES" | sed 's/^/  /' >&2
    exit 1
  fi
  echo "подписан нашим сертификатом: ${SIGNED_BY}"
fi

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
    ${SIGNING_ARGS[@]+"${SIGNING_ARGS[@]}"}); then
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

# Публикация: ключи S3 лежат в файле окружения — скрипт публикации получает их через
# `node --env-file`, в переменные окружения этого скрипта они не попадают.
NODE_ENV_ARGS=()
if [ -f "$ENV_FILE" ]; then NODE_ENV_ARGS+=("--env-file=$ENV_FILE"); fi
# Флаг пересборки той же версии — до самого публикатора, решение о перезаписи принимает он.
FORCE_ARGS=()
if [ "$FORCE" = 1 ]; then FORCE_ARGS+=(--force); fi
node ${NODE_ENV_ARGS[@]+"${NODE_ENV_ARGS[@]}"} scripts/publish-ios.mjs "$IPA" \
  --version-name "$VERSION_NAME" \
  --version-code "$VERSION_CODE" \
  ${FORCE_ARGS[@]+"${FORCE_ARGS[@]}"}
