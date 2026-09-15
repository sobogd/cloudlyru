import 'dart:async';

import '../data/mirror_store.dart';
import '../device/native_fs.dart';
import 'mirror_engine.dart';
import 'mirror_status.dart';
import 'mirror_watcher.dart';

/// Мгновенная реакция, пока приложение работает.
///
/// Два канала:
///   • облако → телефон: частый опрос головы журнала (`GET /sync/head` — крошечный запрос).
///     Голова сдвинулась — сразу догоняем журнал, файлы приезжают за секунды;
///   • телефон → облако: событие файловой системы ([MirrorWatcher]) запускает проход почти
///     сразу, с короткой выдержкой на всплеск событий.
///
/// Пока приложение выгружено из памяти, наблюдать некому — тогда работает только страховочный
/// периодический проход (раз в 15 минут, см. планировщик). Резидентного сервиса с постоянным
/// уведомлением по умолчанию нет: это цена, которую пользователь не выбирал.
///
/// Опрос прекращается, когда токена нет или сервер не отвечает: в Doze сеть всё равно спит,
/// и долбить её каждые три секунды смысла нет — после ошибок пауза становится длинной.
class MirrorLive {
  MirrorLive(this._store, this._engine, this._status, this._watcher, this._native);

  final MirrorStore _store;
  final MirrorEngine _engine;
  final MirrorStatusHolder _status;
  final MirrorWatcher _watcher;
  final NativeFs _native;

  /// Как часто спрашивать голову журнала. Запрос крошечный (одна строка по индексу),
  /// лимит сервера на эту ручку — 240 в минуту, так что 20 в минуту не мешают.
  static const int pollMs = 3000;

  /// В фоне: экран погашен, мгновенность не нужна, а батарея нужна.
  static const int pollBackgroundMs = 30000;

  /// Сервер молчит или сети нет: ждём дольше, но не бросаем опрос совсем.
  static const int failBackoffMs = 60000;

  Timer? _timer;
  bool _running = false;
  int _failures = 0;

  /// Есть ли токен: без него опрашивать нечего и незачем.
  bool Function() hasToken = () => false;

  /// Выключено ли зеркало пользователем: тогда ни опрос, ни проходы не запускаются.
  bool Function() paused = () => false;

  /// Приложение на экране: тогда спрашиваем журнал часто, в фоне — редко.
  bool Function() foreground = () => true;

  /// Куда писать прогресс — его показывает раздел «Файлы».
  void Function(String)? onProgress;

  bool get running => _running;

  /// Запустить цикл опроса. Повторный вызов ничего не делает.
  void start() {
    if (_running) return;
    _running = true;
    _schedule(pollMs);
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _failures = 0;
  }

  void _schedule(int ms) {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: ms), _tick);
  }

  Future<void> _tick() async {
    if (!_running) return;
    var next = foreground() ? pollMs : pollBackgroundMs;
    try {
      // «выключено» значит выключено: ни догона журнала, ни удалений из облака
      if (paused() || !hasToken()) {
        _schedule(next);
        return;
      }

      // файл, отложенный окном стабильности, ждёт своей минуты: возвращаемся к нему
      final retry = MirrorRetryClock(_engine);
      if (await retry.runIfDue(_store)) {
        _failures = 0;
        _schedule(next);
        return;
      }

      // курсора нет — зеркало ещё не сделало первый проход, догонять нечего
      final cursor = await _store.cursor();
      if (cursor == null) {
        _schedule(next);
        return;
      }

      final head = await _engine.syncHead();
      _failures = 0;
      _status.update((s) => s.copyWith(
            checkedAt: DateTime.now().millisecondsSinceEpoch,
            clearError: true,
          ));
      if (head > cursor) {
        await _engine.catchUpCloud(onProgress: onProgress);
      }
    } catch (_) {
      _failures += 1;
      next = failBackoffMs;
    }
    if (_failures == 0 && foreground()) next = pollMs;
    _schedule(next);
  }

  /// Наблюдение за папками и проход по событию файловой системы.
  void bindWatcher() {
    _watcher.onPass = () {
      if (paused() || !hasToken()) return;
      unawaited(_engine.pass(onProgress: onProgress));
    };
  }

  Future<void> dispose() async {
    stop();
    await _watcher.stop();
    await _native.unwatch();
  }
}
