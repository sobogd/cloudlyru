import 'dart:io';

import 'package:flutter/services.dart';

/// Папка, к которой iOS дала доступ: путь, имя для человека и признак «читается прямо сейчас».
///
/// Отдельный класс, а не [RootFolder] из `native_fs.dart`: корни выбора и папки, выбранные
/// в «Файлах», — разные вещи (вторые ещё и могут перестать читаться), и смешивать их значило бы
/// тащить платформенную особенность в общий тип.
class IosFolder {
  const IosFolder(this.path, this.name, this.granted);

  final String path;
  final String name;
  final bool granted;
}

/// Папки, доступные приложению на iOS, — те, что человек выбрал в системном «Файлах».
///
/// На iOS обойти диск нечего: приложение заперто в своей песочнице, и папка появляется только
/// через системный диалог. Право на доступ к выбранной папке (security scope) держит нативная
/// часть (`ios/Runner/FolderAccess.swift`) — из Dart `startAccessingSecurityScopedResource`
/// не вызвать, а без него ни один путь не читается. Здесь только разговор с ней.
///
/// Исключений наружу нет, как и у всего слоя доступа к файлам: не ответил канал, нет платформы,
/// человек закрыл диалог — это «пусто», а не сбой. Сказать об этом человеку нечем и незачем:
/// пустой список папок на экране и есть ответ.
class IosFolders {
  const IosFolders();

  /// Канал тот же, что у нативной части: имя и поля ответа менять надо с обеих сторон сразу.
  static const MethodChannel _channel = MethodChannel('ru.cloudly.sync/folders');

  /// Папки, доступные приложению сейчас. Пустой список — ничего не выбрано.
  Future<List<IosFolder>> roots() async {
    if (!Platform.isIOS) return const [];
    try {
      final raw = await _channel.invokeListMethod<dynamic>('list');
      return (raw ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map(_parse)
          .whereType<IosFolder>()
          .toList(growable: false);
    } catch (_) {
      // канала нет (не iOS, сборка без нативного кода) или он ответил ошибкой
      return const [];
    }
  }

  /// Показать системный выбор папки. `null` — человек закрыл диалог (это не ошибка).
  Future<IosFolder?> pick() async {
    if (!Platform.isIOS) return null;
    try {
      final raw = await _channel.invokeMapMethod<dynamic, dynamic>('pick');
      return raw == null ? null : _parse(raw);
    } catch (_) {
      return null;
    }
  }

  /// Забыть папку: нативная часть закрывает доступ и стирает закладку, поэтому папка исчезает
  /// из списка и после перезапуска приложения уже не вернётся.
  Future<void> forget(String path) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('remove', {'path': path});
    } catch (_) {
      // не вышло — папка останется в списке, и человек попробует ещё раз
    }
  }

  /// Разбор ответа нативной части. Непонятный ответ — `null`: путь приходит с той стороны,
  /// и пустой путь означал бы корень файловой системы.
  IosFolder? _parse(Map<dynamic, dynamic> raw) {
    final path = raw['path'];
    if (path is! String || path.isEmpty) return null;
    final name = raw['name'];
    final granted = raw['granted'];
    return IosFolder(
      path,
      name is String && name.isNotEmpty ? name : path.split('/').last,
      granted is bool ? granted : true,
    );
  }
}
