# CloudlyRu — мобильное приложение (Flutter)

Android-клиент CloudlyRu: файлы, почта, медиа, карта, корзина, настройки и синхронизация папок
телефона. Единственный клиент сервиса. Как устроено и почему так — [`../FLUTTER.md`](../FLUTTER.md),
сервер — `../src/`, эксплуатация — [`../DEPLOY.md`](../DEPLOY.md).

Пакет — `cloudly_flutter`, `applicationId` — `ru.cloudly.sync` (как у прежнего нативного клиента,
поэтому APK встаёт поверх уже установленного приложения с той же подписью).

## Сборка и проверки

```bash
flutter pub get
flutter analyze
flutter build apk --release   # релизная сборка, подпись — flutter/android/keystore.properties
```

Тестов в проекте нет намеренно (решение владельца): каталог `test/` и зависимость `flutter_test`
удалены, шаг `flutter test` убран из workflow. Проверка перед релизом — `flutter analyze`
(должен быть чистым) и запуск приложения на телефоне.

Релиз публикуется не вручную, а workflow `.github/workflows/android.yml` (порядок — в
[`../FLUTTER.md`](../FLUTTER.md), раздел «Релиз»): он собирает подписанный APK и кладёт его в S3,
откуда сборку отдаёт <https://files.iq-factura.com/apk>.

## Где что лежит

- `lib/features/` — экраны (файлы, почта, медиа, карта, корзина, настройки);
- `lib/api/` — клиент REST API и модели;
- `lib/sync/` — очередь выгрузки и двустороннее зеркало;
- `android/app/src/main/kotlin/ru/cloudly/cloudly_flutter/` — нативный мост к Android API
  (доступ ко всем файлам, `FileObserver`, задания `JobScheduler`).
