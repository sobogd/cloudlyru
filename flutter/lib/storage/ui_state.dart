import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Единое хранилище UI-состояния — порт `web/src/storage.ts`.
/// Позиция, открытая деталка и вкладка переживают закрытие приложения.
class UiStateStore {
  static const _key = 'cloudlyru:ui';
  final SharedPreferences _prefs;

  UiStateStore(this._prefs);

  Map<String, dynamic> read() {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final v = json.decode(raw);
      return v is Map ? v.cast<String, dynamic>() : {};
    } catch (_) {
      return {};
    }
  }

  void patch(Map<String, dynamic> patch) {
    final cur = read();
    cur.addAll(patch);
    _prefs.setString(_key, json.encode(cur));
  }

  void clear() => _prefs.remove(_key);
}
