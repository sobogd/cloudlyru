import 'dart:async';

import 'package:flutter/services.dart';

/// Корень выбора: внутренняя память или карта памяти.
class RootFolder {
  const RootFolder(this.path, this.name);

  final String path;
  final String name;
}

/// Мост к Android API, которого нет в Dart: доступ ко всем файлам, тома памяти, номер файла
/// в файловой системе и события файловой системы.
///
/// Всё остальное синхронизатор делает сам, обычными средствами Dart. Сюда вынесено ровно то,
/// для чего нужен системный вызов, — иначе мост разросся бы до второго приложения.
class NativeFs {
  NativeFs({MethodChannel? method, EventChannel? events})
      : _method = method ?? const MethodChannel(_methodChannel),
        _events = events ?? const EventChannel(_eventChannel);

  static const String _methodChannel = 'ru.cloudly.sync/native';
  static const String _eventChannel = 'ru.cloudly.sync/fileEvents';

  final MethodChannel _method;
  final EventChannel _events;

  Stream<dynamic>? _changes;

  /// Полный доступ ко всем файлам: без него не видно ни дерева папок, ни содержимого.
  ///
  /// Ответ «нет» при любой осечке моста: спрашивать разрешение впустую хуже, чем показать
  /// подсказку, — а мост может быть не зарегистрирован (например, в фоновом изоляте).
  Future<bool> hasAllFilesAccess() async {
    try {
      return await _method.invokeMethod<bool>('hasAllFilesAccess') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Открыть системный экран, где выдаётся доступ ко всем файлам. Разрешение выдаётся
  /// в системном диалоге, поэтому приложение узнаёт о нём, только вернувшись на экран.
  Future<void> openAllFilesSettings() async {
    try {
      await _method.invokeMethod<void>('openAllFilesSettings');
    } catch (_) {}
  }

  /// Корни выбора: внутренняя память и карты памяти.
  Future<List<RootFolder>> storageRoots() async {
    try {
      final raw = await _method.invokeMethod<List<dynamic>>('storageRoots');
      return (raw ?? const [])
          .whereType<Map>()
          .map((m) => RootFolder('${m['path']}', '${m['name']}'))
          .where((r) => r.path.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Номер файла в файловой системе. Ноль означает «не удалось узнать»: тогда переименование
  /// просто не распознаётся и файл уедет заново — это дороже, но не потеря данных, поэтому
  /// сбой моста здесь не роняет обход.
  Future<int> inode(String path) async {
    try {
      return await _method.invokeMethod<int>('inode', {'path': path}) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Номера файлов пачкой: на обходе десятков тысяч файлов один вызов моста вместо каждого —
  /// это разница между «проход идёт» и «проход ползёт». Порядок ответа соответствует порядку
  /// запроса; на сбой отвечаем нулями (см. [inode]).
  Future<List<int>> inodes(List<String> paths) async {
    if (paths.isEmpty) return const [];
    try {
      final raw = await _method.invokeMethod<List<dynamic>>('inodes', {'paths': paths});
      if (raw == null || raw.length != paths.length) return List<int>.filled(paths.length, 0);
      return [for (final v in raw) v is int ? v : 0];
    } catch (_) {
      return List<int>.filled(paths.length, 0);
    }
  }

  /// Как зовётся устройство: этим именем подписывается корень зеркала в облаке.
  Future<String> deviceLabel() async {
    try {
      return await _method.invokeMethod<String>('deviceLabel') ?? 'Android';
    } catch (_) {
      return 'Android';
    }
  }

  /// Взять под наблюдение дерево выбранных папок. Возвращает число наблюдаемых папок;
  /// 0 — наблюдать не за чем или система не дала (тогда остаётся периодический проход).
  Future<int> watch(List<String> paths) async {
    try {
      return await _method.invokeMethod<int>('watch', {'paths': paths}) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> unwatch() async {
    try {
      await _method.invokeMethod<void>('unwatch');
    } catch (_) {}
  }

  /// События файловой системы: любое изменение — повод попросить проход. Что именно
  /// поменялось, сверка увидит сама, поэтому имя события не передаётся.
  Stream<dynamic> get fileChanges =>
      _changes ??= _events.receiveBroadcastStream().asBroadcastStream();
}
