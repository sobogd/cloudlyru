import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api/cloudly_api.dart';
import 'api/models.dart';
import 'storage/settings.dart';
import 'sync/sync_controller.dart';
import 'upload/upload_queue.dart';

/// Глобальное состояние: адрес сервера, токен, текущий пользователь.
class AppState extends ChangeNotifier {
  final Settings settings;
  CloudlyApi api;

  UserInfo? user;
  bool checking = true;
  String? loginError;

  AppState(this.settings) : api = CloudlyApi(serverUrl: settings.serverUrl);

  late final UploadQueue uploads = UploadQueue(() => api);

  /// Синхронизатор: он не часть интерфейса, а отдельная подсистема со своими базами,
  /// поэтому живёт в провайдере, а сюда только подключается (см. [attachSync]).
  SyncController? _sync;

  /// Привязка синхронизатора. Провайдер строится после восстановления сессии, поэтому
  /// при уже готовом входе синхронизация стартует тут же — иначе она ждала бы следующего
  /// события, которого при запуске приложения не будет.
  void attachSync(SyncController sync) {
    if (identical(_sync, sync)) return;
    _sync = sync;
    if (user != null) unawaited(_startSync());
  }

  /// Синхронизация начинается только со входом: без сессии у неё нет ни токена устройства,
  /// ни облака, куда лить.
  Future<void> _startSync() async {
    final sync = _sync;
    final current = user;
    if (sync == null || current == null) return;
    await sync.start(api, current.login);
  }

  Future<void> restore() async {
    final s = settings.session;
    if (s != null && s.isNotEmpty) {
      api.session = s;
      try {
        user = await api.me();
      } catch (_) {
        user = null;
      }
    }
    if (user != null) await _startSync();
    checking = false;
    notifyListeners();
  }

  Future<void> login(String login, String password) async {
    loginError = null;
    notifyListeners();
    // свежий клиент: вход не должен утащить старую сессию
    final fresh = CloudlyApi(serverUrl: settings.serverUrl);
    final cookie = await fresh.login(login, password);
    await settings.setSession(cookie);
    api.session = cookie;
    user = await api.me();
    notifyListeners();
    await _startSync();
  }

  Future<void> logout() async {
    // первым делом синхронизатор: он отзывает свой токен устройства, а тот даёт полный
    // доступ к облаку мимо приложения и без веб-сессии
    await _sync?.signOut();
    try {
      await api.logout();
    } catch (_) {}
    await settings.clearSession();
    api = CloudlyApi(serverUrl: settings.serverUrl);
    user = null;
    notifyListeners();
  }

  void setLoginError(String? e) {
    loginError = e;
    notifyListeners();
  }
}
