import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../section.dart';

/// Выбор папок разделов. Хранится как пути в обычных настройках: это не секрет,
/// а шифрованное хранилище занято токеном устройства.
///
/// Разделом «Файлы» это больше не управляет: там пары «папка устройства ↔ папка облака»
/// задаёт человек связками (см. `SyncLinks`). Остаток выбора читается один раз — из него
/// разово переносятся связки при обновлении приложения ([SyncController] →
/// `_migrateLegacySelection`), а после переноса снимается ([clear]).
class Selection {
  /// [_prefs] — обычные настройки приложения: список путей переживает перезапуск.
  Selection(this._prefs);

  final SharedPreferences _prefs;

  /// Ключ выбора в «Файлах». Строка задана явно и менять её нельзя: под ней уже лежат
  /// выборы папок у всех, кто пользуется приложением. Выбор раздела «Фото» (строка
  /// `sync_folders_photos`) с выгрузкой фото убран и больше не читается.
  static const String _filesKey = 'sync_folders_files';

  /// Пути, выбранные в разделе (именно отмеченные, без «покрытых» подпапок).
  ///
  /// Отдаёт копию набора: правки результата в настройки не попадают.
  /// Нетронутый раздел читается как пустой набор; диск при этом не читается вовсе.
  Set<String> paths(Section section) {
    if (section != Section.files) return const <String>{};
    return (_prefs.getStringList(_filesKey) ?? const <String>[]).toSet();
  }

  /// Снять весь выбор раздела: пустой список пишется в настройки, а не удаляется — так
  /// «ничего не выбрано» не отличается от «выбор ещё не трогали».
  Future<void> clear(Section section) async {
    if (section != Section.files) return;
    if (!await _prefs.setStringList(_filesKey, const <String>[])) {
      debugPrint('cloudly-sync: выбор папок не сохранён: $_filesKey');
    }
  }
}
