# AGENTS.md — правила работы в проекте CloudlyRu

Действуют вместе с глобальными правилами (`~/.dsh/AGENTS.md`). Здесь — только то, что
специфично для этого репозитория: сборка, выкладка и проверка на телефоне.

## После правок: сборка, пуш, релиз

1. **Собрать после правок.** Клиент — `flutter analyze` и сборка APK; сервер — `npx tsc --noEmit`
   (или `pnpm run build`). Сломанную сборку не пушить.
2. **Автопуш в main** — `./scripts/gh-push.sh main` (токен берётся из `~/work/.env`, ключ
   `GH_SOBOGD`; других учёток не использовать). Push в `src/**` и `prisma/**` сам запускает
   деплой сервера (`deploy.yml`) — отдельно его дёргать не нужно.
3. **Менялся Flutter — запустить релизную сборку APK**:
   `GH_TOKEN=$(sed -n 's/^GH_SOBOGD=//p' ~/work/.env) gh workflow run android.yml --repo sobogd/cloudlyru`.
   Перед этим поднять `versionCode` в `flutter/pubspec.yaml` (публикация не принимает тот же
   или меньший номер).
4. **За CI не следить.** Запустил workflow — и пошёл дальше: `gh run watch` не нужен, итог
   владельцу не докладывать. Ждать и следить — только если он попросил об этом прямо
   (разово, вручную).

## Телефон по adb — установка сразу

- **Определять подключение самому**: `adb devices` (adb нет в `PATH`, он лежит в
  `/opt/homebrew/share/android-commandlinetools/platform-tools/adb`).
- **Телефон подключён — ставить сборку туда сразу**, не дожидаясь CI:
  `flutter build apk --release` (подпись берётся из `flutter/android/keystore.properties`,
  ключ тот же, что у установленного приложения) и `adb install -r build/app/outputs/flutter-apk/app-release.apk`.
  Данные и настройки при этом сохраняются.
- Телефон не подключён — ничего не выдумывать: собрать APK и сказать, что его можно поставить
  по adb или взять с https://files.iq-factura.com/apk.
- Проверяет работу приложения владелец сам: сценарии через adb не водить, логи ради проверки
  не снимать — это только установка.

## Что где лежит

- `flutter/` — мобильный клиент (Flutter, applicationId `ru.cloudly.sync`).
- `src/` — сервер (NestJS + Prisma), деплой автоматический при push в `src/**`.
- `src/sync/`, `flutter/lib/sync/` — синхронизация: связки «папка устройства ↔ папка облака»
  (`SyncLinks`), зеркало файлов (`MirrorEngine`), очередь выгрузки.
- `FLUTTER.md`, `DEPLOY.md`, `PLAN.md` — подробности по клиенту, выкладке и замыслу.
