import '../data/queue_store.dart';
import '../data/selection.dart';
import '../data/sync_prefs.dart';
import '../device/device_files.dart';
import '../net/sync_api.dart';
import 'queue_builder.dart';

/// Один заход наполнения очереди, целиком: узнать системные папки сервера (если ещё не знаем),
/// пройти выбранные папки и поставить новое в очередь.
///
/// Вызывается при старте приложения, после изменения выбора папок, при открытии раздела
/// «Очередь» и по кнопке «Обновить». Ничего не выгружает: запуск файлов — ручной.
class QueueRefresher {
  QueueRefresher(this._api, this._prefs, this._selection, this._store, this._files);

  final SyncApi? Function() _api;
  final SyncPrefs _prefs;
  final Selection _selection;
  final QueueStore _store;
  final DeviceFiles _files;

  Future<QueueBuildResult> refresh({void Function(String)? onProgress}) async {
    final progress = onProgress ?? (String _) {};
    final api = _api();

    // системные папки сервера спрашиваем один раз: без них очередь некуда направить,
    // но и наполнять её при отсутствии сети смысла нет
    if (_prefs.photoFolderId.isEmpty && api != null) {
      progress('спрашиваю системные папки…');
      try {
        final folders = await api.systemFolders();
        final photo = folders.photoFolderId;
        if (photo != null && photo.isNotEmpty) await _prefs.setPhotoFolderId(photo);
        final phone = folders.phoneFolderId;
        if (phone != null && phone.isNotEmpty) await _prefs.setPhoneFolderId(phone);
        final mirror = folders.mirrorFolderId;
        if (mirror != null && mirror.isNotEmpty) await _prefs.setMirrorFolderId(mirror);
      } catch (_) {
        // сеть может молчать: очередь соберётся и без папок — просто «Фото» подождёт
      }
    }

    final builder = QueueBuilder(_files, _store);
    return builder.build(
      selection: _selection,
      photoFolderId: _prefs.photoFolderId.isEmpty ? null : _prefs.photoFolderId,
      onProgress: progress,
    );
  }
}
