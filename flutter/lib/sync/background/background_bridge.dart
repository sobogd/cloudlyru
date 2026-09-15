import 'package:flutter/services.dart';

/// Канал фонового прохода: `ru.cloudly.sync/background` (см. `BackgroundBridge.kt`).
///
/// Одним каналом пользуются обе стороны. Приложение заводит и снимает задание; фоновый изолят
/// спрашивает, не на экране ли приложение, сообщает об итоге и принимает просьбу остановиться,
/// когда система отбирает задание.
///
/// Отдельный канал, а не общий `ru.cloudly.sync/native`: тот отвечает за системные вызовы
/// (доступ к файлам, номера файлов, наблюдение), а здесь — только жизнь фонового задания.
class BackgroundChannel {
  BackgroundChannel({bool listenCancel = false}) {
    // Слушателя ставит только фоновый изолят: приложению просьба «остановись» не адресована.
    if (listenCancel) _channel.setMethodCallHandler(_handle);
  }

  static const MethodChannel _channel = MethodChannel('ru.cloudly.sync/background');

  /// Система отобрала задание: проход должен закончиться на ближайшей проверке, а не на
  /// середине выгрузки. Движок уже такой: `isCancelled` он спрашивает между файлами.
  void Function()? onCancel;

  Future<void> _handle(MethodCall call) async {
    if (call.method == 'cancel') onCancel?.call();
  }

  /// Приложение на экране? Тогда проход делает мгновенный режим: он замечает изменения за
  /// секунды, а проход из фона только спорил бы с ним за базы (см. `background_pass.dart`).
  Future<bool> appInForeground() async =>
      await _channel.invokeMethod<bool>('appInForeground') ?? false;

  /// Остановку просили ещё до того, как изолят поставил слушателя: тогда событие потерялось бы,
  /// поэтому у той стороны есть и флаг, который можно спросить.
  Future<bool> stopRequested() async =>
      await _channel.invokeMethod<bool>('stopRequested') ?? false;

  /// Работа кончена: служба может закрыть движок и доложить системе об итоге.
  Future<void> finished({required bool ok, String? note}) =>
      _channel.invokeMethod<void>('finished', {'ok': ok, 'note': note});

  /// Завести периодическое задание: вызывается приложением при входе в аккаунт.
  Future<bool> ensureJob() async =>
      await _channel.invokeMethod<bool>('ensureJob') ?? false;

  /// Снять задание: при выходе из аккаунта. Без токена оно всё равно ничего не делает,
  /// но пусть не будит приложение зря.
  Future<bool> cancelJob() async =>
      await _channel.invokeMethod<bool>('cancelJob') ?? false;
}
