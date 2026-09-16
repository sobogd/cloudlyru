import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Системные папки сервера и настройки синхронизации, которые не секрет.
///
/// Токен устройства здесь не лежит: он даёт полный доступ к облаку, и его место — шифрованное
/// хранилище системы (см. SyncApi и DeviceTokenStore).
///
/// Пользуются: ядро синхронизации (`SyncController`), наполнение очереди ([QueueRefresher])
/// и фоновый проход (`background_pass.dart`).
class SyncPrefs {
  SyncPrefs(this._prefs);

  final SharedPreferences _prefs;

  // Ключи значений. Менять нельзя: там уже лежат данные с прошлых сборок.
  static const String _photoFolderKey = 'sync_photo_folder_id';
  static const String _phoneFolderKey = 'sync_phone_folder_id';
  static const String _mirrorFolderKey = 'sync_mirror_folder_id';
  static const String _putBackKey = 'sync_put_back_touched';

  /// Медиатека: куда льётся раздел «Фото» (плоско, без структуры папок).
  ///
  /// Пустая строка означает «ещё не знаем»: у только что установленного приложения id нет,
  /// его приносит ответ сервера (см. [QueueRefresher.refresh]). Для наполнения очереди пустое
  /// значение — не «льём в никуда», а «раздел пока не сканируем».
  String get photoFolderId => _prefs.getString(_photoFolderKey) ?? '';

  /// Запомнить id медиатеки: пишет в SharedPreferences (сети не касается).
  Future<void> setPhotoFolderId(String id) => _setString(_photoFolderKey, id);

  /// Легаси-папка «Телефон»: раздел «Файлы» ведёт зеркало, и очередь туда больше не льёт.
  /// Значение приходит тем же ответом сервера, что и медиатека, и сохраняется вместе с ним:
  /// ключ остался от сборок, где очередь ещё заливала «Файлы».
  String get phoneFolderId => _prefs.getString(_phoneFolderKey) ?? '';

  /// Запомнить легаси-id папки «Телефон»: пишет в SharedPreferences.
  /// Читателей у значения сейчас нет — ключ ведётся вместе с остальными папками.
  Future<void> setPhoneFolderId(String id) => _setString(_phoneFolderKey, id);

  /// Корень зеркала этого устройства. Кэш нужен, чтобы настройки показывали папку даже
  /// без сети; истина — ответ сервера на `/auth/me`.
  ///
  /// Пустая строка — «корень ещё не спрашивали»: настройки тогда показывают незнание,
  /// а не пустой путь.
  String get mirrorFolderId => _prefs.getString(_mirrorFolderKey) ?? '';

  /// Запомнить корень зеркала этого устройства: пишет в SharedPreferences, чтобы настройки
  /// показывали папку и без сети.
  Future<void> setMirrorFolderId(String id) => _setString(_mirrorFolderKey, id);

  /// Разрешение «доступ ко всем файлам» уже спрашивали: подсказку показываем один раз.
  /// Флаг ставится один раз и назад не снимается — системное разрешение может быть отозвано,
  /// но подсказка при этом не должна возвращаться на каждом запуске.
  bool get putBackTouched => _prefs.getBool(_putBackKey) ?? false;

  /// Отметить, что подсказку про «доступ ко всем файлам» уже показывали: назад флаг
  /// не снимается, поэтому подсказка больше не появится.
  ///
  /// Отказ записи виден только в журнале: показать его некому (так же, как у id папок).
  Future<void> setPutBackTouched() async {
    if (!await _prefs.setBool(_putBackKey, true)) {
      debugPrint('cloudly-sync: отметка о подсказке не сохранена');
    }
  }

  /// Записать строку настроек, проверив результат.
  ///
  /// `SharedPreferences` возвращает признак записи, и игнорировать его нельзя: незаписанный
  /// id системной папки выглядит как «сервер её не отдал», а сброшенный флаг — как «подсказку
  /// ещё не показывали». Показывать отказ в интерфейсе здесь нечем, поэтому он уходит
  /// в журнал.
  Future<void> _setString(String key, String value) async {
    if (!await _prefs.setString(key, value)) {
      debugPrint('cloudly-sync: настройка не сохранена: $key');
    }
  }
}
