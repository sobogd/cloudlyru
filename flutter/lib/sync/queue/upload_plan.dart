/// Решения выгрузки, вынесенные в чистые функции: их проверяют тесты без устройства
/// (test/sync/upload_plan_test.dart). Ошибка здесь стоит либо не уехавшего файла, либо
/// затирания чужой версии в облаке.
///
/// Пользуются: [UploadRunner] (очередь) и зеркало (`MirrorEngine`, `MirrorPull`).
/// Побочных эффектов нет — ни сети, ни файлов, ни базы.
abstract final class UploadPlan {
  /// Что делать с файлом, если знать, что уже лежит на сервере.
  ///
  /// [localSha] — хэш файла на телефоне, посчитанный до выгрузки.
  /// [serverSha] — содержимое, которое лежит в облаке по этому имени (null — ничего нет).
  ///
  /// Возвращает: `create` — записи нет, заводим новую; `skip` — содержимое уже там;
  /// `replace` — перезаписываем (вызывающий обязан передать серверу ожидаемый хэш, чтобы
  /// не затереть чужую версию, появившуюся за время выгрузки).
  static UploadAction decide(String localSha, String? serverSha) {
    if (serverSha == null) return UploadAction.create;
    // содержимое уже там: байты не передаём вовсе, сервер сообщит это и сам
    if (serverSha == localSha) return UploadAction.skip;
    return UploadAction.replace;
  }

  /// Свободное имя с суффиксом: `отчёт (2).pdf`. Нужно, когда в облачной папке уже лежит
  /// **чужой** файл с таким именем — перезаписывать не своё нельзя, добавляем рядом.
  ///
  /// [name] — желаемое имя, [taken] — имена, занятые в облачной папке (их собирает
  /// вызывающий: сама функция к серверу не ходит).
  ///
  /// Точка в начале имени расширением не считается (`dot > 0`): в `.nomedia` или `.thumbnails`
  /// расширения нет, и суффикс ставится в конец имени, а не перед точкой.
  /// Номер перебирается до 999 — предел нужен, чтобы цикл заведомо закончился; дальше в имя
  /// идёт метка времени, а на занятое имя ответит уже сервер (409).
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

/// Что делать с файлом в облаке. Считает [UploadPlan.decide], разбирают [UploadRunner] (очередь)
/// и зеркало; в базу значение не пишется — это решение одного прохода.
enum UploadAction { create, replace, skip }
