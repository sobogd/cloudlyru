import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'app_state.dart';
import 'storage/settings.dart';
import 'sync/sync_controller.dart';

final settingsProvider = Provider<Settings>(
  (ref) => throw UnimplementedError(),
);

final appStateProvider = ChangeNotifierProvider<AppState>(
  (ref) => AppState(ref.read(settingsProvider)),
);

/// Синхронизатор живёт на всё приложение: разделы, настройки и очередь смотрят в одно
/// состояние — иначе две копии показывали бы разное.
final syncControllerProvider = ChangeNotifierProvider<SyncController>((ref) {
  final controller = SyncController();
  ref.onDispose(controller.dispose);
  return controller;
});
