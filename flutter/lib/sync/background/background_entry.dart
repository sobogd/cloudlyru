import 'dart:async';

import 'package:flutter/widgets.dart';

import 'background_bridge.dart';
import 'background_pass.dart';

/// Точка входа фонового изолята.
///
/// Handle этой функции приложение кладёт в настройки при входе в аккаунт
/// ([BackgroundSync.register]), а `SyncJobService` поднимает по нему движок и запускает её —
/// ровно так же, как нативный клиент поднимал свой проход из задания системы.
///
/// Вход в Dart со стороны Android: `SyncJobService.startEngine` → `executeDartCallback` с
/// `DartCallback`, собранным из `FlutterCallbackInformation.lookupCallbackInformation(handle)`.
/// Handle берёт из обычных настроек (`FlutterSharedPreferences`, ключ `flutter.syncbg_callback`)
/// — см. `BackgroundSettings.kt`.
///
/// `vm:entry-point` обязателен: в release-сборке без него функция считается неиспользуемой
/// и выбрасывается из снимка — тогда задание просыпалось бы в пустоту.
///
/// Изолят короткий: сделал проход — сообщил итог — умер вместе с движком. Ничего своего
/// он не держит, всё состояние в базах и настройках.
///
/// ## Какие плагины здесь работают, а какие звать нельзя
///
/// Движок задания поднимается тем же `FlutterEngine(applicationContext)`, что и в приложении,
/// поэтому регистрируются все плагины из `GeneratedPluginRegistrant` — но годятся из них
/// только те, которым не нужна активность:
///
/// * **работают**: `shared_preferences` (аккаунт и признак «задание заведено»),
///   `flutter_secure_storage` (device-токен), `sqflite` (очередь и база зеркала),
///   `path_provider` (каталоги баз); сеть и хэши — вообще чистый Dart (`dio`, `crypto`);
/// * **звать нельзя**: всё, что требует активности или окна, — `file_picker`, `open_filex`,
///   `webview_flutter`, `url_launcher`, `video_player`, `cached_network_image` с показом
///   в интерфейсе. В фоновом задании активности нет вовсе: такой вызов либо бросит исключение,
///   либо повесит проход до предохранителя службы.
///
/// Если появится Dart-only плагин (без нативной части), понадобится
/// `DartPluginRegistrant.ensureInitialized()`: без него его регистрации не окажется в снимке.
/// Сейчас таких зависимостей нет, поэтому и вызова нет.
///
/// Побочных эффектов у самой функции нет: вся работа — в [runBackgroundPass], а она отвечает
/// системе через канал. Исключение здесь никто не поймал бы (запуск идёт из нативного кода),
/// поэтому [runBackgroundPass] устроен так, чтобы не бросать: он всегда доходит до `finished`.
@pragma('vm:entry-point')
void syncBackgroundEntry() {
  // Движок фонового задания поднимается отдельно от приложения: без этой строки плагины
  // (настройки, шифрованное хранилище, базы) в изоляте не зарегистрировались бы
  WidgetsFlutterBinding.ensureInitialized();
  // listenCancel: просьбу «остановись» принимает только фоновый изолят; приложению она
  // не адресована (см. `background_bridge.dart`)
  final channel = BackgroundChannel(listenCancel: true);
  // Ничего не ждём: движок живёт, пока идёт работа, а конец работы служба узнаёт по `finished`.
  // Это единственная причина, по которой функция вообще может вернуться раньше прохода.
  unawaited(runBackgroundPass(channel));
}
