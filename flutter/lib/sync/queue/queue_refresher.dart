import 'package:flutter/foundation.dart';

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
/// «Очередь» и по кнопке «Обновить». Ничего не выгружает: строки только ставятся в очередь.
class QueueRefresher {
  /// [_api] отдаёт клиент синхронизации (может быть null — токена ещё нет: тогда очередь
  /// соберётся, но без папок сервера), [_prefs] помнит системные папки, [_selection] —
  /// выбранные папки разделов, [_store] — база очереди, [_files] — чтение телефона.
  QueueRefresher(this._api, this._prefs, this._selection, this._store, this._files);

  /// Клиент синхронизации по требованию: `null` значит, что токена ещё нет — тогда папки
  /// сервера не спрашиваются, а очередь собирается из того, что уже известно.
  final SyncApi? Function() _api;
  final SyncPrefs _prefs;
  final Selection _selection;
  final QueueStore _store;
  final DeviceFiles _files;

  /// Один заход: спросить системные папки (если ещё не знаем) и наполнить очередь.
  ///
  /// [onProgress] — текст о ходе работы для интерфейса и журнала; [isCancelled] — проверка
  /// отмены, её спрашивает обход (уход с экрана, выход из аккаунта): без неё обход двадцати
  /// тысяч файлов нельзя прервать, а он держит и проверки, и диск.
  ///
  /// Возвращает итог наполнения (см. [QueueBuildResult]). Побочные эффекты: сеть — запрос
  /// `/auth/me` за папками; SharedPreferences — запись id медиатеки; SQLite — постановка
  /// и уборка строк очереди (внутри [QueueBuilder]).
  ///
  /// Ошибка сети не пробрасывается: папки сервера — удобство, а не условие наполнения,
  /// и очередь соберётся без них. Но и молчать о ней нельзя: без папок раздел «Фото»
  /// не сканируется, и человеку показывают причину отказа, а не совет «войдите в аккаунт»
  /// (см. [QueueBuilder.build] и его `photoProblem`). Ошибки обхода и базы не глушатся —
  /// уходят вызывающему.
  Future<QueueBuildResult> refresh({
    void Function(String)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final progress = onProgress ?? (String _) {};
    final api = _api();

    // Системные папки сервера спрашиваем один раз — пока не знаем медиатеку: она здесь признак
    // того, что папки уже приходили. Остальные id приходят тем же ответом, но очередь ими
    // не пользуется: «Телефон» — легаси раздела, который ведёт зеркало, а корень зеркала
    // записывает ядро синхронизации (у него одного и должен быть владелец этих значений).
    String? photoProblem;
    if (_prefs.photoFolderId.isEmpty) {
      if (api == null) {
        // токена ещё нет — это не «сервер не ответил»: пусть человек не ищет сеть
        photoProblem = '«Фото»: нет токена устройства — войдите в аккаунт';
      } else {
        progress('спрашиваю системные папки…');
        try {
          final folders = await api.systemFolders();
          final photo = folders.photoFolderId;
          if (photo != null && photo.isNotEmpty) await _prefs.setPhotoFolderId(photo);
        } catch (e) {
          // сеть может молчать: очередь соберётся и без папок — просто «Фото» подождёт
          // до следующего захода. Отказ виден и в журнале, и в тексте итога: иначе человек
          // шёл бы выходить и входить в аккаунт, хотя достаточно дождаться сети
          debugPrint('cloudly-sync: системные папки не получены: $e');
          photoProblem = '«Фото»: сервер не ответил — проверьте сеть';
        }
      }
    }

    // билдер создаётся на каждый заход: у него нет состояния между проходами, а база
    // и чтение диска переиспользуются те, что дали снаружи
    final builder = QueueBuilder(_files, _store);
    return builder.build(
      selection: _selection,
      photoFolderId: _prefs.photoFolderId.isEmpty ? null : _prefs.photoFolderId,
      photoProblem: photoProblem,
      onProgress: progress,
      isCancelled: isCancelled,
    );
  }
}
