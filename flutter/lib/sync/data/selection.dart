import 'package:shared_preferences/shared_preferences.dart';

import '../section.dart';
import 'selection_rules.dart';

/// Выбранные папки разделов. Хранятся как пути в обычных настройках: это не секрет,
/// а шифрованное хранилище занято токеном устройства.
class Selection {
  Selection(this._prefs);

  final SharedPreferences _prefs;

  /// Пути, выбранные в разделе (именно отмеченные, без «покрытых» подпапок).
  Set<String> paths(Section section) =>
      (_prefs.getStringList(_key(section)) ?? const <String>[]).toSet();

  Future<Set<String>> choose(Section section, String path) =>
      _store(section, SelectionRules.choose(paths(section), path));

  Future<Set<String>> unchoose(
    Section section,
    String path,
    List<String> Function(String) childDirsOf,
  ) =>
      _store(section, SelectionRules.unchoose(paths(section), path, childDirsOf));

  Future<Set<String>> clear(Section section) => _store(section, const <String>{});

  /// Сколько папок отмечено в разделе: этим живёт сводка раздела.
  int count(Section section) => paths(section).length;

  Future<Set<String>> _store(Section section, Set<String> paths) async {
    final list = paths.toList()..sort();
    await _prefs.setStringList(_key(section), list);
    return paths;
  }

  String _key(Section section) => 'sync_folders_${section.storageKey.toLowerCase()}';
}
