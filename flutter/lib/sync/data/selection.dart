import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../section.dart';
import 'selection_rules.dart';

/// Выбранные папки разделов. Хранятся как пути в обычных настройках: это не секрет,
/// а шифрованное хранилище занято токеном устройства.
///
/// Один список на раздел, ключ — `sync_folders_<раздел>` (строки ключей заданы константами
/// ниже). В наборе всегда «антицепочка» (правила — в [SelectionRules]): выбранная папка и её
/// подпапки в списке одновременно не лежат.
///
/// Пользуются: экран выбора папок (`FolderTreeScreen` — отметить и снять), наполнение
/// очереди ([QueueBuilder]) и зеркало (`MirrorEngine`, `MirrorWatcher`), фоновый проход
/// (`background_pass.dart`).
class Selection {
  /// [_prefs] — обычные настройки приложения: список путей переживает перезапуск.
  Selection(this._prefs);

  final SharedPreferences _prefs;

  /// Ключи выбора по разделам. Строки заданы явно и менять их нельзя: под ними уже лежат
  /// выборы папок у всех, кто пользуется приложением.
  ///
  /// Собирать ключ из [Section.storageKey] (`'sync_folders_${section.storageKey.toLowerCase()}'`)
  /// нельзя: правка имени ветки перечисления или его значения молча превратила бы выбор
  /// в пустой, а пустой выбор — это «в разделе ничего не отмечено», и уборка очереди сняла бы
  /// все строки раздела.
  static const String _filesKey = 'sync_folders_files';
  static const String _photosKey = 'sync_folders_photos';

  /// Пути, выбранные в разделе (именно отмеченные, без «покрытых» подпапок).
  ///
  /// Отдаёт копию набора: правки результата в настройки не попадают — менять выбор можно
  /// только через [choose], [unchoose] и [clear].
  /// Нетронутый раздел читается как пустой набор; диск при этом не читается вовсе —
  /// существование самих папок проверяет обход ([DeviceFiles.scan]).
  Set<String> paths(Section section) =>
      (_prefs.getStringList(_key(section)) ?? const <String>[]).toSet();

  /// Отметить папку: возвращает новый набор (поддерево вбирается целиком, подпапки и предки
  /// из набора уходят) и записывает его в настройки — побочный эффект записи в
  /// SharedPreferences, сети и файлов не касается.
  Future<Set<String>> choose(Section section, String path) =>
      _store(section, SelectionRules.choose(paths(section), path));

  /// Снять выбор: возвращает новый набор и записывает его в настройки.
  ///
  /// [childDirsOf] — синхронный листинг прямых подпапок: он нужен, когда снимаемая папка была
  /// покрыта выбранным предком — предка «раскрывают» в его подпапки (см. [SelectionRules.unchoose]).
  /// Список читает вызывающий (диск — не дело хранилища настроек).
  Future<Set<String>> unchoose(
    Section section,
    String path,
    List<String> Function(String) childDirsOf,
  ) => _store(
    section,
    SelectionRules.unchoose(paths(section), path, childDirsOf),
  );

  /// Снять весь выбор раздела: пустой список пишется в настройки, а не удаляется — так
  /// «ничего не выбрано» не отличается от «выбор ещё не трогали».
  Future<Set<String>> clear(Section section) =>
      _store(section, const <String>{});

  /// Сколько папок отмечено в разделе: этим живёт сводка раздела.
  int count(Section section) => paths(section).length;

  /// Записать набор в настройки и вернуть его же — интерфейсу нужен новый выбор сразу,
  /// не перечитывая настройки.
  ///
  /// Список сортируется, чтобы в настройках лежал один и тот же список при одном и том же
  /// выборе: Set порядок не хранит, и без сортировки запись выглядела бы новой на каждом
  /// сохранении.
  ///
  /// Результат записи проверяется: молча не сохранённый выбор выглядит как сохранённый —
  /// дерево показывает папку отмеченной, а после перезапуска выбор пуст, и уборка снимает
  /// строки раздела. Показывать ошибку здесь некому (метод возвращает только набор), поэтому
  /// отказ уходит в журнал.
  Future<Set<String>> _store(Section section, Set<String> paths) async {
    final list = paths.toList()..sort();
    if (!await _prefs.setStringList(_key(section), list)) {
      debugPrint('cloudly-sync: выбор папок не сохранён: ${_key(section)}');
    }
    return paths;
  }

  /// Ключ раздела в настройках — один из заданных выше; соответствие проверяет `switch`
  /// без `default`: новый раздел не скомпилируется, пока ему не назначат ключ.
  String _key(Section section) => switch (section) {
    Section.files => _filesKey,
    Section.photos => _photosKey,
  };
}
