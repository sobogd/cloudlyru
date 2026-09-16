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
/// ## Контракт настроек с нативным Kotlin
///
/// Ключи ниже пишет этот класс через `shared_preferences`, а читает `BackgroundSettings.kt`
/// напрямую из файла `FlutterSharedPreferences` с префиксом `flutter.`:
///
/// | ключ | тип | кто читает | зачем |
/// |---|---|---|---|
/// | [keyEnabled] (`flutter.syncbg_enabled`) | `bool` | `SyncBootReceiver`, `BackgroundSettings`, `background_pass.dart` | заведено ли задание: по нему получатель перезагрузки решает, возвращать ли его, а проход — делать ли что-нибудь |
/// | [keyCallback] (`flutter.syncbg_callback`) | `int` (raw handle) | `SyncJobService` через `BackgroundSettings.callbackHandle` | по нему служба поднимает движок и запускает [syncBackgroundEntry]; ноль и меньше — «заведено не было», задание молча заканчивается |
/// | [keyServer], [keyLogin] | `String` | только Dart, фоновый изолят | ключ `device_token|<сервер>|<логин>` в шифрованном хранилище |
///
/// Расхождение с Kotlin здесь стоило бы дорого: если признак «заведено» не прочитается,
/// получатель перезагрузки не вернёт задание, а проход будет тихо ничего не делать.
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

  /// Завести задание при входе в аккаунт.
  ///
  /// [serverUrl] и [login] сохраняются в настройки до постановки задания: фоновый изолят
  /// другого способа узнать аккаунт не имеет. Порядок важен — сначала настройки, потом
  /// задание, иначе первый же запуск застал бы их незаписанными.
  ///
  /// Ничего не возвращает и не бросает: если handle точки входа не нашёлся (`null` — релизная
  /// сборка без `vm:entry-point`), задание не заводится вовсе, а приложение продолжает работать
  /// мгновенным режимом. Отказ системы или недоступные настройки гасятся так же.
  static Future<void> register({required String serverUrl, required String login}) async {
    try {
      final handle = PluginUtilities.getCallbackHandle(syncBackgroundEntry);
      // Точка входа не нашлась — заводить задание нечем; приложение работает как обычно.
      if (handle == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyServer, serverUrl);
      await prefs.setString(keyLogin, login);
      // Raw handle, а не сам объект: в настройках помещается только число, и именно его
      // ждёт Kotlin в `flutter.syncbg_callback`
      await prefs.setInt(keyCallback, handle.toRawHandle());
      await prefs.setBool(keyEnabled, true);
      await BackgroundChannel().ensureJob();
    } catch (_) {
      // система отказала в задании или настройки недоступны: остаётся обычная работа приложения
    }
  }

  /// Снять задание при выходе из аккаунта.
  ///
  /// Сначала гасит признак [keyEnabled], потом снимает задание: если снятие не удастся,
  /// получатель перезагрузки уже не вернёт его, а фоновый проход по признаку ничего не сделает.
  /// Настройки с адресом и логином не стираются — их перезапишет следующий вход.
  /// Исключений не бросает.
  static Future<void> cancel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(keyEnabled, false);
      await BackgroundChannel().cancelJob();
    } catch (_) {}
  }

  /// Заведено ли задание: нужно только тестам и диагностике.
  ///
  /// Это признак из настроек, а не запрос в систему: задание могло не встать (см. [register]),
  /// поэтому «включено» здесь означает «мы просили завести и не снимали». Ошибка чтения
  /// настроек — `false`.
  static Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(keyEnabled) ?? false;
    } catch (_) {
      return false;
    }
  }
}
