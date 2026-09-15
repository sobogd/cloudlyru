import 'dart:io';

import '../data/mirror_store.dart';
import '../net/sync_api.dart';

/// Папки зеркала: соответствие путей на телефоне и папок в облаке.
///
/// Путь в облаке повторяет путь на телефоне внутри корня зеркала: выбрали `Download` — в облаке
/// появится `<Имя устройства> - Файлы/Download`, вместе со всей структурой внутри. Папки
/// заводятся идемпотентным `ensure-path`, поэтому проход можно повторять сколько угодно раз.
///
/// Соответствие кэшируется и в памяти, и в базе: правка из журнала знает только `folderId`,
/// и без обратного перевода её некуда положить на телефоне.
class MirrorFolders {
  MirrorFolders(this._api, this._store);

  final SyncApi _api;
  final MirrorStore _store;

  /// Ключ — путь на телефоне: две папки с одинаковым именем на разных томах дают разные записи.
  final Map<String, String> _byLocalPath = {};

  /// Папка для относительного пути (`Download/Telegram`) внутри корня зеркала.
  Future<String> ensure(
    String relDir,
    String localPath,
    String mirrorRootId,
  ) async {
    final cached = _byLocalPath[localPath];
    if (cached != null) {
      await _store.registerDir(cached, localPath);
      return cached;
    }
    final id = await _ensurePath(relDir, mirrorRootId);
    _byLocalPath[localPath] = id;
    await _store.registerDir(id, localPath);
    return id;
  }

  /// Сервер ограничивает частоту (429). Первый проход по дереву заводит десятки папок, и
  /// упереться в лимит на середине — значит уронить проход на ровном месте.
  Future<String> _ensurePath(String path, String parentId) async {
    var waitMs = 2000;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        return await _api.ensurePath(path, parentId);
      } on SyncApiException catch (e) {
        if (e.status != 429 || attempt == 3) rethrow;
        await Future<void>.delayed(Duration(milliseconds: waitMs));
        waitMs *= 2;
      }
    }
    throw StateError('папку $path сервер так и не принял');
  }
}

/// Папка на телефоне: создать, если её нет. Пустая структура тоже должна доехать до облака,
/// поэтому папки заводятся отдельно от файлов.
Future<void> ensureLocalDir(String path) async {
  final dir = Directory(path);
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
}
