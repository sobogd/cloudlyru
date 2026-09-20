#!/usr/bin/env bash
# Собрать релиз Flutter-клиента (Flutter + Android APK + macOS)
#
# Использование: ./scripts/build-release.sh
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "=== Сборка Flutter ==="
cd flutter
flutter analyze || exit 1
flutter build apk --release
echo "✓ APK: build/app/outputs/flutter-apk/app-release.apk"
flutter build macos --release
echo "✓ macOS: build/Release/app/Cloudly.app"
cd ..

echo "=== Публикация ==="
TOKEN=$(sed -n 's/^GH_SOBOGD=//p' ~/work/.env)
curl -s -o /dev/null -w "%{http_code}" -X POST "https://api.github.com/repos/sobogd/cloudlyru/dispatches" \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"event_type":"workflow_dispatch","client_payload":{"ref":"main"}}'

echo "✓ Сборки отправлены в CI"
echo ""
echo "Результаты:"
echo "  Android: https://files.iq-factura.com/apk"
echo "  macOS:   https://files.iq-factura.com/macos"
