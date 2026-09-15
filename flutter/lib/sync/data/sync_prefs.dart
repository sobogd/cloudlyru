import 'package:shared_preferences/shared_preferences.dart';

/// Системные папки сервера и настройки синхронизации, которые не секрет.
///
/// Токен устройства здесь не лежит: он даёт полный доступ к облаку, и его место — шифрованное
/// хранилище системы (см. SyncApi и DeviceTokenStore).
class SyncPrefs {
  SyncPrefs(this._prefs);

  final SharedPreferences _prefs;

  static const String _photoFolderKey = 'sync_photo_folder_id';
  static const String _phoneFolderKey = 'sync_phone_folder_id';
  static const String _mirrorFolderKey = 'sync_mirror_folder_id';
  static const String _putBackKey = 'sync_put_back_touched';

  /// Медиатека: куда льётся раздел «Фото» (плоско, без структуры папок).
  String get photoFolderId => _prefs.getString(_photoFolderKey) ?? '';

  Future<void> setPhotoFolderId(String id) =>
      _prefs.setString(_photoFolderKey, id);

  /// Легаси-папка «Телефон»: только читается, раздел «Файлы» ведёт зеркало.
  String get phoneFolderId => _prefs.getString(_phoneFolderKey) ?? '';

  Future<void> setPhoneFolderId(String id) =>
      _prefs.setString(_phoneFolderKey, id);

  /// Корень зеркала этого устройства. Кэш нужен, чтобы настройки показывали папку даже
  /// без сети; истина — ответ сервера на `/auth/me`.
  String get mirrorFolderId => _prefs.getString(_mirrorFolderKey) ?? '';

  Future<void> setMirrorFolderId(String id) =>
      _prefs.setString(_mirrorFolderKey, id);

  /// Разрешение «доступ ко всем файлам» уже спрашивали: подсказку показываем один раз.
  bool get putBackTouched => _prefs.getBool(_putBackKey) ?? false;

  Future<void> setPutBackTouched() => _prefs.setBool(_putBackKey, true);
}
