import 'package:shared_preferences/shared_preferences.dart';

import 'ui_state.dart';

/// Адрес сервера и cookie веб-сессии — в SharedPreferences (без нативных Keystore-плагинов,
/// чтобы старт не мог упасть на инициализации хранилища). Пароль не хранится.
class Settings {
  static const _kServer = 'server_url';
  static const _kSession = 'cloudly_session';

  final SharedPreferences _prefs;

  Settings._(this._prefs);

  static Future<Settings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return Settings._(prefs);
  }

  String get serverUrl {
    final v = _prefs.getString(_kServer);
    return (v == null || v.trim().isEmpty) ? 'https://files.iq-factura.com' : v.trim();
  }

  Future<void> setServerUrl(String url) => _prefs.setString(_kServer, url.trim());

  String? get session => _prefs.getString(_kSession);

  Future<void> setSession(String s) => _prefs.setString(_kSession, s);

  Future<void> clearSession() => _prefs.remove(_kSession);

  UiStateStore get ui => UiStateStore(_prefs);
}
