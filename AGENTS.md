# AGENTS.md — правила работы в проекте CloudlyRu

Действуют вместе с глобальными правилами (`~/.dsh/AGENTS.md`). Здесь — только то, что
специфично для этого репозитория: сборка, выкладка и проверка на телефоне.

## После правок: сборка, пуш, релиз

1. **Собрать после правок.** Клиент — `flutter analyze` и сборка APK; сервер — `npx tsc --noEmit`
   (или `pnpm run build`). Сломанную сборку не пушить.
2. **Автопуш в main** — `./scripts/gh-push.sh main` (токен берётся из `~/work/.env`, ключ
   `GH_SOBOGD`; других учёток не использовать). Push в `src/**` и `prisma/**` сам запускает
   деплой сервера (`deploy.yml`) — отдельно его дёргать не нужно.
3. **Менялся Flutter — поднять версию в `pubspec.yaml` и запустить релизные сборки**.
   Перед сборкой обновить `version: 1.0.0+N` в `flutter/pubspec.yaml` (номер сборки +1, чтобы
   Google Play принимал обновление). После правки запустить:
   ```
   source /Users/sobogd/work/.git-token.sh
cd flutter
git add pubspec.yaml
git commit -m "bump version to $N"
git push
cd /Users/sobogd/work/iq-rest/cloudlyru
gh workflow run android.yml --repo sobogd/cloudlyru
gh workflow run macos.yml   --repo sobogd/cloudlyru
gh workflow run ios.yml     --repo sobogd/cloudlyru
   ```
   **Три сборки — Android, macOS, iOS — запускать всегда вместе**, одним заходом на один номер.
   Номер сборки (`+N` в `pubspec.yaml`) общий для платформ: из него выходят `versionCode` на
   Android, `CFBundleVersion` на маке и на iOS. Если номер поднят, а какая-то платформа не
   выпущена, следующая её публикация упадёт: публикующий скрипт не даёт положить сборку с тем
   же или меньшим номером, а поднять номер ещё раз уже нельзя — Android с этим номером выпущен.

   Публикация упадёт с ошибкой, если `versionCode` в релизе равен или больше текущего — нужно
   поднять версию перед запуском рабочих процессов. Поэтому порядок такой: сначала номер, потом
   все три workflow, и только потом следующий номер.

   iOS — не забывать: он публикует Ad Hoc-сборку в https://files.iq-factura.com/ios (ставится
   по воздуху через `.../ios/install`), и пропущенный iOS — это iPad и iPhone, которые к новым
   правкам не обновятся.
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

## Настольное приложение на маке

- Собирается из того же `flutter/` (`flutter build macos --release`), публикуется workflow
  `macos.yml` в https://files.iq-factura.com/macos.
- Установлено в `/Applications/Cloudly.app` и обновляется кнопкой в «Настройках»: приложение
  само скачивает архив, проверяет размер и sha256 и подменяет свой бандл
  (`flutter/lib/features/settings/macos_update.dart`). Ставить сборку руками не нужно.
- Сборка не подписана Developer ID и не нотаризована: своего мака это не касается (архив
  качает само приложение, карантина на нём не появляется), но передать её на чужой мак нельзя —
  Gatekeeper не пустит.
- Проверить сборку до пуша можно локально: `cd flutter && flutter build macos --release`.

## Что где лежит

- `flutter/` — мобильный клиент (Flutter, applicationId `ru.cloudly.sync`).
- `src/` — сервер (NestJS + Prisma), деплой автоматический при push в `src/**`.
- `src/sync/`, `flutter/lib/sync/` — синхронизация: связки «папка устройства ↔ папка облака»
  (`SyncLinks`), зеркало файлов (`MirrorEngine`), очередь выгрузки.
- `src/chat/`, `flutter/lib/features/chat/` — раздел «Чат»: сервер собирает контекст, ходит к
  модели и к поиску, хранит историю и источники ответов; приложение показывает переписку и
  делает ссылки по номерам источников.
- `agents/websearch/` — поиск и чтение страниц для чата: браузером (Playwright поверх
  установленного Chrome), потому что HTTP-клиент с серверного адреса получает капчу. Работает
  **не на сервере, а на маке**: в бандл деплоя не входит, ставится там как launchd
  `com.agent.websearch`. Подробности — в `DEPLOY.md`, раздел про чат.
- `FLUTTER.md`, `DEPLOY.md`, `PLAN.md` — подробности по клиенту, выкладке и замыслу.

## Git Token — Universal Helper

**Всегда используйте скрипт `/Users/sobogd/work/.git-token.sh`** перед операциями с GitHub.

```bash
source /Users/sobogd/work/.git-token.sh
gh workflow run deploy.yml
```

Скрипт автоматически определяет проект и подставляет правильный токен:
- **Тангем проекты** (`/tangem/`, `/tangem-checkout-web/`) → `GH_BSOKOLOV_TANGEM`
- **Все остальные** → `GH_SOBOGD`

**Никогда не используйте `gh auth login` без токена** — это активирует дефолтную учётку
(`sobogd`), у которой токен невалиден для Tangem.

If you see authentication errors with `gh`, run the script first!
