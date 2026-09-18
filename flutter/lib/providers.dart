import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
// legacy-API: `ChangeNotifierProvider` живёт здесь с первых версий приложения. Работает он
// ровно так, как нужно (`AppState` и `SyncController` — обычные `ChangeNotifier`), но новый
// код на нём писать не стоит, а перевод на `Notifier`/`NotifierProvider` затронет и чужие
// экраны, которые читают эти провайдеры. Поэтому долг осознанный и отмечен здесь.
import 'package:flutter_riverpod/legacy.dart';

import 'app_state.dart';
import 'features/gallery/data/gallery_store.dart';
import 'features/gallery/data/gallery_sync.dart';
import 'media/thumb_cache.dart';
import 'media/thumb_store.dart';
import 'storage/settings.dart';
import 'sync/sync_controller.dart';

// Три провайдера, из которых состоит вся связка приложения. Кто кого создаёт и в каком порядке
// — важно для понимания запуска, потому что обычно это не «провайдеры создают состояние»,
// а наоборот:
//
//   main()                       — читает настройки и поднимает дерево до первого кадра
//     Settings.load()            — SharedPreferences: адрес сервера, cookie сессии, UI-состояние
//     AppState(settings)         — владеет api-клиентом, пользователем и очередью загрузки
//     ProviderScope(overrides)   — отдаёт готовые settings и state дереву вместо фабрик
//       CloudlyApp               — корень; в build читает appStateProvider
//         initState              — attachSync(syncControllerProvider): единственная связка
//           SyncController.start — начинается, когда user уже не null
//     state.restore()            — уже в фоне: по сохранённой cookie спрашивает /auth/me,
//                                  снимает checking и уведомляет слушателей
//
// Почему settings и AppState переопределяются, а не создаются фабриками: восстановление входа
// асинхронное (внутри запрос в сеть с таймаутами 20+60 с), и если ждать его до первого кадра,
// приложение показывало бы нативную заставку до полутора минут. Поэтому дерево поднимается
// сразу, а `checking` в `AppState` держит спиннер, пока сессия не проверена.
//
// Синхронизатор в этой схеме — единственный, кто создаётся провайдером: он тяжёлый (базы,
// нативные вызовы) и до первого чтения провайдера не существует вовсе. Первым его читает
// `CloudlyApp.initState`, то есть уже после восстановления сессии, и тут же передаёт в
// `attachSync`. Если вход уже восстановлен — `attachSync` сразу запускает синхронизацию; если
// нет — она стартует позже, из `AppState.login`. Выход из аккаунта гасит её через
// `AppState.logout` (`signOut` отзывает device-токен), не удаляя сам провайдер: следующий вход
// оживит тот же объект.

/// Адрес сервера, cookie сессии и UI-состояние.
///
/// Фабрика намеренно бросает [UnimplementedError]: настроек «по умолчанию» не бывает —
/// без реального хранилища сессию негде взять, и молчаливая подмена пустышкой дала бы
/// необъяснимые 401 вместо внятной ошибки на старте. **Провайдер обязательно переопределяется
/// в `main`** готовым [Settings]; не переопределён он может оказаться только в тестах, и там
/// это должно падать сразу.
final settingsProvider = Provider<Settings>(
  (ref) => throw UnimplementedError('settingsProvider переопределяется в main() готовым Settings'),
);

/// Глобальное состояние приложения: адрес сервера, клиент API, текущий пользователь и очередь
/// загрузки.
///
/// Здесь только запасная фабрика. **В рабочем приложении провайдер переопределяется в `main`**
/// уже собранным [AppState]. Фабрика срабатывает лишь там, где переопределения нет (тесты) —
/// и она сама запускает восстановление входа: без этого `checking` остался бы `true` навсегда
/// и приложение показывало бы вечный спиннер. Требует, чтобы [settingsProvider] был
/// переопределён тоже: без настроек она бросит исключение.
final appStateProvider = ChangeNotifierProvider<AppState>((ref) {
  final state = AppState(ref.read(settingsProvider));
  // не ждём: уведомление придёт слушателям, а первый кадр не должен ждать сеть
  unawaited(state.restore());
  return state;
});

/// Синхронизатор живёт на всё приложение: разделы, настройки и очередь смотрят в одно
/// состояние — иначе две копии показывали бы разное.
///
/// Создаётся лениво, при первом чтении (это делает `CloudlyApp.initState`), и живёт до конца
/// процесса: `ref.onDispose` нужен не для выхода из аккаунта, а на случай разрушения scope
/// (в рабочем приложении его не разрушают). Замечание на будущее: сейчас `dispose` снимает
/// только мгновенный режим, а сторож, базы и наблюдение за папками закрывает `signOut` —
/// значит при разрушении scope без выхода из аккаунта они останутся жить (см.
/// `SyncController.dispose`). Выход из аккаунта синхронизатор не удаляет, а гасит себя
/// изнутри ([SyncController.signOut]) — объект остаётся и оживает при следующем входе.
final syncControllerProvider = ChangeNotifierProvider<SyncController>((ref) {
  final controller = SyncController();
  ref.onDispose(controller.dispose);
  return controller;
});

/// Хранилище и очередь миниатюр галереи.
///
/// Открывается один раз на приложение: каталог данных читается с диска, и держать по копии
/// на экран незачем — очередь общая, а её прогресс и счётчики должны быть одни на всех.
///
/// Клиент API берётся функцией, а не значением: адрес сервера и сессия меняются в рантайме
/// (вход, выход, смена сервера в настройках), а очередь и уже скачанные миниатюры при этом
/// пересоздавать не нужно — каждая загрузка просто берёт текущий клиент.
final thumbCacheProvider = FutureProvider<ThumbCache>((ref) async {
  final store = await ThumbStore.open();
  return ThumbCache(store: store, apiOf: () => ref.read(appStateProvider).api);
});

/// Локальный индекс галереи и его синхронизация с сервером.
///
/// Индекс лежит в своей базе (`cloudly-gallery.db`) и читается с диска: раздел показывает всю
/// библиотеку без сети, а сервер догоняет список журналом изменений и верхней страницей ленты.
/// Полное наполнение индекса идёт фоном и продолжается между открытиями раздела.
///
/// Журнал приходит по device-токену ([SyncController.api]), а лента — по веб-сессии: два разных
/// доступа к одному аккаунту, и оба уже есть у приложения.
final galleryProvider = FutureProvider<GallerySync>((ref) async {
  final store = await GalleryStore.open();
  return GallerySync(
    store: store,
    apiOf: () => ref.read(appStateProvider).api,
    changesApiOf: () => ref.read(syncControllerProvider).api,
  );
});
