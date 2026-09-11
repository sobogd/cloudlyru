# CloudlyRu

Личное self-hosted облако: сервер на VPS, веб-клиент, Android-клиент для телефона.
Прод — <https://files.iq-factura.com>, репозиторий — `sobogd/cloudlyru`.

Принцип хранения: файлы лежат объектами в S3 (Hetzner Object Storage) с адресацией по
SHA-256 (одинаковое содержимое не дублируется), дерево папок, метаданные, доступы и
корзина — в Postgres на том же VPS.

## Что внутри

| Каталог | Что это |
|---|---|
| `src/` | API (NestJS + Prisma): авторизация, файлы и папки, загрузки (в том числе частями прямо в S3), превью и конвертация медиа, корзина, шаринг-ссылки, WebDAV, журнал изменений для клиентов |
| `web/` | Веб-клиент (React + Vite SPA), раздаётся тем же сервером из `web/dist` |
| `android/` | Android-клиент: разделы «Файлы» и «Фото» со списком файлов выбранных папок телефона, настройки с входом, обновление по кнопке. Синхронизация переделывается — в 0.4.0 её в приложении нет (см. `ANDROID.md`) |
| `deploy/` | nginx-конфиг, pm2-процесс, серверные скрипты (бэкап БД, уборка сирот в бакете) |
| `scripts/` | Утилиты: публикация APK, локальные проверки контрактов и медиа-метаданных |
| `prisma/` | Схема БД и миграции |

Документация: [`DEPLOY.md`](DEPLOY.md) — деплой и эксплуатация, [`ANDROID.md`](ANDROID.md) —
как устроен и почему так сделан Android-клиент, [`android/README.md`](android/README.md) —
сборка и установка приложения, [`PLAN.md`](PLAN.md) — план развития и принятые решения.

## Локальный запуск

```bash
pnpm install
cp .env.example .env          # DATABASE_URL, SESSION_SECRET, ADMIN_PASSWORD; ключи S3 — по желанию
pnpm exec prisma migrate deploy
pnpm build && pnpm start      # http://127.0.0.1:8305

pnpm --dir web install && pnpm --dir web dev   # веб-клиент с hot-reload (Vite)
```

Без ключей S3 поднимается только API: файловые операции требуют объектного хранилища.

## Прод

Автодеплой: push в `main` по путям `src/**`, `prisma/**`, `web/**`, `package.json`,
`pnpm-lock.yaml`, `.env.example` → GitHub Actions (`.github/workflows/deploy.yml`) собирает
сервер и веб, кладёт бандл на VPS и перезапускает pm2 `cloudlyru` (:8305, только локально)
за nginx `files.iq-factura.com`. Ручной запуск — `gh workflow run deploy.yml`.

Проверка: `curl -s https://files.iq-factura.com/api/v1/healthz` → `{"ok":true,…}`.

## Android-клиент: одна ссылка и обновление по кнопке

**Скачать приложение: <https://files.iq-factura.com/apk>** — ссылка постоянная и всегда
отдаёт последнюю опубликованную сборку. Версию, размер и sha256 этой сборки отдаёт
`GET /api/v1/app/android` (там же — `published: false`, если сборки ещё нет).

В приложении есть «Проверить обновление» (проверяется и само при старте): если на сервере
лежит сборка с большим `versionCode`, появляется карточка с кнопкой **«Обновить»** — она
скачивает APK, проверяет его по размеру и sha256 и открывает системный установщик.
Полностью молча обновиться APK-приложение не может: Android в любом случае показывает
диалог установки, и подтвердить его нужно один раз. Браузер, поиск файла в «Загрузках»
и ручной выбор APK при этом не нужны.

### Как выпустить новую сборку

Сборка и публикация автоматические, но номер версии поднимает человек — по нему телефон
и понимает, что вышло обновление:

1. Поднять `versionCode` (и `versionName`) в `android/app/build.gradle.kts`.
2. Push в `main`, если менялся `android/**` (или `gh workflow run android.yml`).
3. GitHub Actions (`.github/workflows/android.yml`) прогоняет юнит-тесты, собирает
   подписанный релиз и публикует его в релизный артефакт S3 — `/apk` сразу отдаёт новую сборку.

Если `versionCode` не поднят, шаг публикации падает с понятным сообщением: сборка с тем же
номером не появится в приложении как обновление, а тихо подменять файл по ссылке — значит
оставить телефон на старой версии.

Вручную (например, чтобы опубликовать уже собранный APK):

```bash
node --env-file=$HOME/work/.env scripts/publish-apk.mjs \
  android/app/build/outputs/apk/release/app-release.apk          # + --dry-run, чтобы только посмотреть
```

Сборка на маке:

```bash
cd android
JAVA_HOME=/opt/homebrew/opt/openjdk@21 ./gradlew :app:testDebugUnitTest :app:assembleRelease
```

Релиз подписывается ключом из `android/keystore.properties` (в git не попадает; в CI — из
секретов репозитория). Ставится APK поверх только той же подписью: ключ терять нельзя,
иначе обновление потребует удаления приложения.

## Проверки

```bash
pnpm build                                                 # сервер компилируется
cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@21 ./gradlew :app:testDebugUnitTest

# контрактные проверки на локальной БД (не на проде):
DATABASE_URL=postgresql://user@127.0.0.1:5432/cloudly_dev SESSION_SECRET=dev-secret-0123456789 \
  node scripts/m3-sync-check.mjs
DATABASE_URL=postgresql://user@127.0.0.1:5432/cloudly_dev SESSION_SECRET=dev-secret-0123456789 \
  node scripts/media-meta-check.mjs
```
