import 'package:flutter/foundation.dart';

import 'api/cloudly_api.dart';
import 'api/models.dart';
import 'storage/settings.dart';
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
  }

  Future<void> logout() async {
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
