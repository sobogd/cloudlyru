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
/// `vm:entry-point` обязателен: в release-сборке без него функция считается неиспользуемой
/// и выбрасывается из снимка — тогда задание просыпалось бы в пустоту.
///
/// Изолят короткий: сделал проход — сообщил итог — умер вместе с движком. Ничего своего
/// он не держит, всё состояние в базах и настройках.
@pragma('vm:entry-point')
void syncBackgroundEntry() {
  WidgetsFlutterBinding.ensureInitialized();
  final channel = BackgroundChannel(listenCancel: true);
  // Ничего не ждём: движок живёт, пока идёт работа, а конец работы служба узнаёт по `finished`.
  unawaited(runBackgroundPass(channel));
}
