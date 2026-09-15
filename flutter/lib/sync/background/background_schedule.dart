import 'dart:ui' show PluginUtilities;

import 'package:shared_preferences/shared_preferences.dart';

import 'background_bridge.dart';
import 'background_entry.dart';

/// Заведение фонового задания: делается приложением при входе в аккаунт, снимается при выходе.
///
/// Задание живёт в системе (`JobScheduler`), а не в приложении: к моменту его запуска движка
/// приложения может уже не быть. Поэтому всё, что фоновому изоляту нужно до старта, лежит
/// в обычных настройках: адрес сервера, логин и handle точки входа. Токен устройства сюда
/// не попадает — он в шифрованном хранилище, и фоновый изолят читает его сам, как и приложение.
///
/// Ни один вызов отсюда не бросает исключение: вход в аккаунт не должен падать из-за того,
/// что система отказала в задании.
class BackgroundSync {
  /// Задание заведено: по этому признаку получатель перезагрузки решает, возвращать ли его.
  static const String keyEnabled = 'syncbg_enabled';

  /// Адрес сервера и логин: по ним фоновый изолят находит токен устройства в шифрованном
  /// хранилище (ключ `device_token|<сервер>|<логин>`).
  static const String keyServer = 'syncbg_server';
  static const String keyLogin = 'syncbg_login';

  /// Handle точки входа: по нему служба поднимает движок и запускает [syncBackgroundEntry].
  static const String keyCallback = 'syncbg_callback';

  static Future<void> register({required String serverUrl, required String login}) async {
    try {
      final handle = PluginUtilities.getCallbackHandle(syncBackgroundEntry);
      // Точка входа не нашлась — заводить задание нечем; приложение работает как обычно.
      if (handle == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyServer, serverUrl);
      await prefs.setString(keyLogin, login);
      await prefs.setInt(keyCallback, handle.toRawHandle());
      await prefs.setBool(keyEnabled, true);
      await BackgroundChannel().ensureJob();
    } catch (_) {
      // система отказала в задании или настройки недоступны: остаётся обычная работа приложения
    }
  }

  static Future<void> cancel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(keyEnabled, false);
      await BackgroundChannel().cancelJob();
    } catch (_) {}
  }

  /// Заведено ли задание: нужно только тестам и диагностике.
  static Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(keyEnabled) ?? false;
    } catch (_) {
      return false;
    }
  }
}
