/// Решения выгрузки, вынесенные в чистые функции: их проверяют тесты без устройства.
/// Ошибка здесь стоит либо не уехавшего файла, либо затирания чужой версии в облаке.
abstract final class UploadPlan {
  /// Что делать с файлом, если знать, что уже лежит на сервере.
  ///
  /// [serverSha] — содержимое, которое лежит в облаке по этому имени (null — ничего нет).
  static UploadAction decide(String localSha, String? serverSha) {
    if (serverSha == null) return UploadAction.create;
    // содержимое уже там: байты не передаём вовсе, сервер сообщит это и сам
    if (serverSha == localSha) return UploadAction.skip;
    return UploadAction.replace;
  }

  /// Свободное имя с суффиксом: `отчёт (2).pdf`. Нужно, когда в облачной папке уже лежит
  /// **чужой** файл с таким именем — перезаписывать не своё нельзя, добавляем рядом.
  static String freeName(String name, Set<String> taken) {
    if (!taken.contains(name)) return name;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    for (var i = 2; i < 1000; i++) {
      final candidate = '$base ($i)$ext';
      if (!taken.contains(candidate)) return candidate;
    }
    return '$base (${DateTime.now().millisecondsSinceEpoch})$ext';
  }
}

enum UploadAction { create, replace, skip }
