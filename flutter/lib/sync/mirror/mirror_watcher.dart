import 'dart:async';

import '../data/mirror_store.dart';
import '../data/selection.dart';
import '../device/native_fs.dart';
import '../section.dart';
import 'mirror_engine.dart';

/// Наблюдение за выбранными папками: событие файловой системы — повод запустить проход почти
/// сразу, а не ждать пятнадцати минут.
///
/// Это только ускоритель. События теряются при перезапуске процесса, после перезагрузки и в Doze,
/// поэтому истина — периодический проход, а наблюдатель лишь сокращает задержку.
class MirrorWatcher {
  MirrorWatcher(this._native);

  final NativeFs _native;

  /// Выдержка после изменения файла: даём дописаться и склеиваем всплеск событий
  /// (браузер качает файл частями, распаковка архива меняет сотни файлов).
  static const int debounceMs = 1500;

  /// Минимальный промежуток между проходами по событиям: обход диска не бесплатный.
  static const int minGapMs = 30000;

  StreamSubscription<dynamic>? _subscription;
  Timer? _timer;
  int _lastPassAt = 0;
  bool _watching = false;

  /// Сколько папок взято под наблюдение в последний раз: 0 — система не дала наблюдателя.
  int watchedDirs = 0;

  /// Поставить наблюдение за деревом выбранных папок раздела «Файлы».
  Future<void> watch(Selection selection, MirrorStore store) async {
    final paths = selection.paths(Section.files).toList();
    if (paths.isEmpty) {
      await stop();
      return;
    }
    watchedDirs = await _native.watch(paths);
    if (watchedDirs == 0) {
      await stop();
      return;
    }
    _subscription ??= _native.fileChanges.listen((_) => onLocalChange(store));
    _watching = true;
  }

  /// Изменение в папках телефона: проход почти сразу, но не чаще, чем раз в полминуты.
  void onLocalChange(MirrorStore store) {
    _timer ??= Timer(const Duration(milliseconds: debounceMs), () {
      _timer = null;
      final sinceLast = DateTime.now().millisecondsSinceEpoch - _lastPassAt;
      if (sinceLast < minGapMs) {
        _timer = Timer(Duration(milliseconds: minGapMs - sinceLast), () {
          _timer = null;
          _lastPassAt = DateTime.now().millisecondsSinceEpoch;
          onPass?.call();
        });
        return;
      }
      _lastPassAt = DateTime.now().millisecondsSinceEpoch;
      onPass?.call();
    });
  }

  /// Что делать по событию файловой системы: проход зеркала.
  void Function()? onPass;

  bool get watching => _watching;

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _timer?.cancel();
    _timer = null;
    _watching = false;
    watchedDirs = 0;
    await _native.unwatch();
  }
}

/// Держит сроки повторного прохода: файл, изменённый только что, ещё пишется — к нему
/// возвращаемся через окно стабильности, а не выгружаем недописанное.
class MirrorRetryClock {
  const MirrorRetryClock(this.engine);

  final MirrorEngine engine;

  /// Запустить проход, если срок подошёл. Возвращает true, если проход состоялся.
  Future<bool> runIfDue(MirrorStore store) async {
    final raw = await store.meta(MirrorStore.keyRetryAt);
    final retryAt = int.tryParse(raw ?? '');
    if (retryAt == null) return false;
    if (DateTime.now().millisecondsSinceEpoch < retryAt) return false;
    await store.clearMeta(MirrorStore.keyRetryAt);
    await engine.pass();
    return true;
  }
}
