import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/mirror_store.dart';
import '../device/media_rules.dart';
import '../device/native_fs.dart';
import '../net/sync_api.dart';
import '../queue/upload_plan.dart';
import 'failure_streak.dart';
import 'mirror_folders.dart';
import 'mirror_models.dart';
import 'mirror_rules.dart';

/// Облачная сторона зеркала: то, что изменилось в облаке, доезжает до телефона.
///
/// Два источника, и оба нужны:
///   • журнал изменений (`GET /sync/changes`) — обычный путь, курсор по `seq`;
///   • полный проход по содержимому папок — когда курсора ещё нет (зеркало только включили)
///     или когда сервер ответил `resetRequired` (журнал подрезан, догнать по нему нельзя).
///
/// Свои же правки пропускаются: в строке журнала есть `deviceId`, и строка, сделанная этим
/// устройством, локально уже учтена — иначе собственная выгрузка приезжала бы назад и догон
/// зацикливался бы.
///
/// Удаления из облака применяются к телефону без предохранителя — это явное указание сервера,
/// а не догадка по неполному снимку (так же ведёт себя Google Drive). Страховка — корзина
/// на сервере: 30 дней и восстановление.
class MirrorPull {
  MirrorPull(
    this._api,
    this._store,
    this._deviceId,
    this._onProgress, {
    NativeFs? native,
  }) : _native = native ?? NativeFs();

  final SyncApi _api;
  final MirrorStore _store;
  final String? _deviceId;
  final void Function(String) _onProgress;
  final NativeFs _native;

  /// Потолок страниц журнала за один проход: остальное доедет следующим.
  static const int _maxPages = 200;

  /// Потолок глубины обхода облака: защита от петли в дереве.
  static const int _maxDepth = 64;

  int downloaded = 0;
  int deletedLocal = 0;
  int conflicts = 0;
  int failed = 0;
  int renamedLocal = 0;

  /// Полный проход потребовался (не было курсора или журнал подрезан).
  bool rescanned = false;

  /// Ошибка, после которой проход дальше не имеет смысла (нет сети, отозван токен).
  String? fatal;

  /// Сбои скачивания подряд: без счётчика проход ждал бы таймаута на каждом файле.
  final FailureStreak _downloads = FailureStreak();

  /// Догнать облако. Первый раз — полный проход и курсор на текущей голове журнала: сначала
  /// голова, потом содержимое. Изменения, случившиеся во время полного прохода, приедут
  /// журналом и применятся повторно — применение идемпотентно, а потеряться ничего не может.
  Future<void> catchUp() async {
    final cursor = await _store.cursor();
    if (cursor == null) {
      // Голову снимаем ДО полного прохода: правки, случившиеся во время прохода, приедут
      // журналом с этой головы. Наоборот нельзя — курсор перепрыгнул бы их.
      int? head;
      try {
        head = await _api.syncHead();
      } catch (_) {}
      await fullPull();
      if (fatal == null && head != null) await _store.setCursor(head);
      return;
    }
    var since = cursor;
    for (var guard = 0; guard < _maxPages; guard++) {
      ChangesPage page;
      try {
        page = await _api.changes(since);
      } on SyncApiException catch (e) {
        // Сервер ограничивает частоту: это «повтори позже», а не поломка. Курсор не двигаем —
        // следующий заход продолжит с того же места.
        if (e.status == 429 || e.status >= 500) return;
        fatal = e.status == 401
            ? 'токен отозван — войдите заново'
            : 'журнал изменений недоступен: ${e.message}';
        return;
      } catch (e) {
        fatal = 'журнал изменений недоступен: $e';
        return;
      }
      if (page.resetRequired) {
        // по этому курсору часть изменений уже не восстановить: только полный проход.
        // Курсор ставим ровно в голову, снятую до прохода: иначе признак «нужен рескан» не гас бы
        // никогда, и полный проход шёл бы на каждом событии.
        int? head;
        try {
          head = await _api.syncHead();
        } catch (_) {}
        await fullPull();
        if (fatal == null && head != null) await _store.setCursor(head);
        return;
      }
      for (final change in page.changes) {
        if (fatal != null) return;
        try {
          await _apply(change);
        } catch (e) {
          failed += 1;
        }
      }
      since = page.nextSeq;
      await _store.setCursor(since);
      if (!page.hasMore) return;
    }
  }

  /// Полный проход по папкам зеркала: состояние облака переносится на телефон.
  Future<void> fullPull() async {
    rescanned = true;
    for (final root in (await _store.roots()).values) {
      if (fatal != null) return;
      _onProgress('облако: ${root.cloudPath}');
      try {
        await _pullFolder(root.cloudId, root.localPath, 0);
      } catch (e) {
        if (e is IOException) {
          fatal = 'облако недоступно: $e';
        } else {
          failed += 1;
        }
      }
    }
  }

  /// Папка облака целиком: подпапки, затем записи.
  Future<void> _pullFolder(String folderId, String localPath, int depth) async {
    if (depth > _maxDepth || fatal != null) return;
    await ensureLocalDir(localPath);
    await _store.registerDir(folderId, localPath);
    final children = await _api.children(folderId);
    for (final entry in children.folderIds.entries) {
      final childPath = p.join(localPath, entry.key);
      final known = await _store.dirPath(entry.value);
      if (known == null) {
        await ensureLocalDir(childPath);
        await _store.registerDir(entry.value, childPath);
      } else if (known != childPath) {
        await _moveLocalDir(known, childPath);
        await _store.moveDir(entry.value, childPath);
      }
      await _pullFolder(entry.value, childPath, depth + 1);
    }
    for (final entry in children.entries) {
      if (fatal != null) return;
      try {
        await _reconcile(
          folderId: folderId,
          name: entry.name,
          entryId: entry.id,
          sha256: entry.sha256,
          size: entry.size,
          clientMtime: entry.clientMtime,
          localDir: localPath,
        );
      } catch (_) {
        failed += 1;
      }
    }
  }

  /// Одно изменение журнала.
  Future<void> _apply(CloudChange change) async {
    // своя же правка: локально она уже сделана тем проходом, который её отправил
    if (_deviceId != null &&
        change.deviceId != null &&
        change.deviceId == _deviceId) {
      return;
    }
    if (change.target == 'folder') {
      await _applyFolder(change);
    } else {
      await _applyEntry(change);
    }
  }

  Future<void> _applyFolder(CloudChange change) async {
    final known = await _store.dirPath(change.targetId);
    if (change.op == 'delete') {
      if (known == null) return;
      // Папку сняли с выбора — её файлы трогать нельзя: удаление в облаке относится
      // к облачной копии, а не к тому, что лежит на телефоне вне зеркала
      if (!await _underRoots(known)) return;
      // в журнале на папку одно событие: поддерево удалено целиком
      await _deleteKnownSubtree(known);
      return;
    }
    // create | update | move | restore: папка должна существовать на телефоне
    final parentId = change.folderId;
    if (parentId == null) return;
    final parent = await _store.dirPath(parentId);
    if (parent == null) return;
    final path = p.join(parent, change.name);
    if (known != null && known != path) {
      await _moveLocalDir(known, path);
      await _store.moveDir(change.targetId, path);
      renamedLocal += 1;
      return;
    }
    if (known == null) {
      await ensureLocalDir(path);
      await _store.registerDir(change.targetId, path);
    }
  }

  Future<void> _applyEntry(CloudChange change) async {
    final parentId = change.folderId;
    if (parentId == null) return;
    final parent = await _store.dirPath(parentId);
    if (parent == null) return;
    if (change.op == 'delete') {
      final row = await _store.fileByEntry(change.targetId);
      if (row == null) return;
      if (!await _underRoots(row.path)) return;
      await _deleteLocalFile(row);
      return;
    }
    await _reconcile(
      folderId: change.folderId,
      name: change.name,
      entryId: change.targetId,
      sha256: change.sha256,
      size: change.size,
      clientMtime: change.clientMtime,
      localDir: parent,
    );
  }

  /// Решение по одной записи облака: скачать, перенести или не трогать.
  ///
  /// Запись, содержимое которой совпадает с уже выгруженным (по хэшу), не скачивается: это
  /// либо наша собственная выгрузка, либо файл, который уже лежит на телефоне. Если же
  /// на телефоне содержимое своё и отличается — оно не затирается: локальная версия уходит
  /// в конфликтную копию, каноническое имя занимает версия облака (так же поступает Drive).
  Future<void> _reconcile({
    required String? folderId,
    required String name,
    required String entryId,
    required String? sha256,
    required int size,
    required int? clientMtime,
    required String localDir,
  }) async {
    final path = p.join(localDir, name);
    var row = await _store.fileByEntry(entryId);

    // запись переименована или перенесена в облаке: повторяем это на телефоне
    if (row != null && row.path != path) {
      final from = File(row.path);
      final to = File(path);
      if (await from.exists() &&
          !await to.exists() &&
          await from.parent.exists()) {
        await to.parent.create(recursive: true);
        try {
          await from.rename(path);
          final moved = row.copyWith(
            path: path,
            cloudFolderId: folderId ?? row.cloudFolderId,
          );
          await _store.moveFile(row.path, moved);
          row = moved;
          renamedLocal += 1;
        } catch (_) {
          // файл занят или его унесли: строку не трогаем, следующий проход разберётся
        }
      } else if (!await from.exists()) {
        row = null;
      }
    }

    // содержимое облака — ровно то, что у нас уже есть: скачивать нечего
    if (row != null &&
        sha256 != null &&
        row.sha256?.toLowerCase() == sha256.toLowerCase()) {
      return;
    }

    final file = File(path);
    if (!await file.exists()) {
      // Служебные и скрытые имена сканер не обходит: тянуть их к себе — значит завести строку,
      // которой на следующем проходе «не будет», и унести облачный файл в корзину
      if (MediaRules.isHidden(name) || MediaRules.isJunk(name)) return;
      await downloadInto(entryId, folderId, path, sha256, size, clientMtime);
      return;
    }

    final stat = await file.stat();
    final localSize = stat.size;
    final localMtime = stat.modified.millisecondsSinceEpoch;

    // локальный файл не менялся с прошлой сверки — облако новее, скачиваем
    final localUntouched =
        row != null && row.size == localSize && row.mtime == localMtime;
    // файла нет в известных (строка потеряна или файл появился до включения зеркала):
    // содержимое совпадает по размеру и дате устройства-источника — значит это он и есть
    final adopted =
        row == null &&
        clientMtime != null &&
        clientMtime > 0 &&
        localSize == size &&
        localMtime == clientMtime;
    if (adopted) {
      await _store.putFile(
        MirrorRow(
          path: path,
          cloudFolderId: folderId ?? '',
          entryId: entryId,
          inode: await _native.inode(path),
          size: localSize,
          mtime: localMtime,
          sha256: sha256,
        ),
      );
      return;
    }
    if (localUntouched) {
      await downloadInto(entryId, folderId, path, sha256, size, clientMtime);
      return;
    }

    // менялось и там, и тут: никто не затирается молча
    if (!await _saveConflictCopy(file)) {
      failed += 1;
      _onProgress('не удалось отодвинуть $name — конфликт не разрешён');
      return;
    }
    conflicts += 1;
    // строку снимаем: конфликтную копию выгрузит следующий проход как новый файл
    if (row != null) await _store.dropFile(row.path);
    await downloadInto(entryId, folderId, path, sha256, size, clientMtime);
  }

  /// Путь лежит внутри папки, которая выбрана сейчас: только такие удаления применяем.
  Future<bool> _underRoots(String path) async =>
      MirrorRules.underRoots(path, (await _store.roots()).keys);

  /// Удаление папки, пришедшее из облака. Убираем ровно то, что знает зеркало: файлы — по
  /// своим строкам, папки — только пустые. Сносить каталог целиком нельзя: там могут лежать
  /// только что скопированные файлы, служебные имена и то, что не смогло уехать, —
  /// восстанавливать их было бы нечем.
  Future<void> _deleteKnownSubtree(String localPath) async {
    for (final row in await _store.filesUnder(localPath)) {
      await _deleteLocalFile(row);
    }
    final dirs = await _store.dirsUnder(localPath);
    dirs.sort((a, b) => b.$2.length.compareTo(a.$2.length));
    for (final (id, path) in dirs) {
      final dir = Directory(path);
      if (await dir.exists() && await _isEmpty(dir)) {
        try {
          await dir.delete();
        } catch (_) {}
      }
      await _store.dropDir(id);
    }
    final dir = Directory(localPath);
    // папка уходит только если действительно опустела: незнакомые файлы остаются,
    // и тогда она вернётся в облако следующим проходом
    if (await dir.exists() && await _isEmpty(dir)) {
      try {
        await dir.delete();
      } catch (_) {}
    }
  }

  /// Файл из облака удаляют: локальную правку, которая ещё не уехала, сохраняем копией.
  Future<void> _deleteLocalFile(MirrorRow row) async {
    final file = File(row.path);
    if (await file.exists()) {
      final stat = await file.stat();
      final edited =
          stat.size != row.size ||
          stat.modified.millisecondsSinceEpoch != row.mtime;
      if (edited) {
        if (await _saveConflictCopy(file)) conflicts += 1;
      } else {
        try {
          await file.delete();
          deletedLocal += 1;
        } catch (_) {}
      }
    }
    await _store.dropFile(row.path);
  }

  /// Отодвинуть файл под свободным именем с пометкой конфликта: ничего не теряем.
  Future<bool> _saveConflictCopy(File file) async {
    final dir = file.parent;
    Set<String> taken;
    try {
      taken = (await dir.list().toList())
          .map((e) => p.basename(e.path))
          .toSet();
    } catch (_) {
      return false;
    }
    final base = MirrorRules.conflictName(
      p.basename(file.path),
      DateTime.now().millisecondsSinceEpoch,
    );
    var name = base;
    var counter = 1;
    while (taken.contains(name) && counter < 100) {
      name = UploadPlan.freeName(base, taken);
      counter += 1;
      taken.add(name);
    }
    try {
      await file.rename(p.join(dir.path, name));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Скачать запись в путь на телефоне и запомнить её как выгруженную.
  Future<bool> downloadInto(
    String entryId,
    String? folderId,
    String path,
    String? sha256,
    int size,
    int? clientMtime,
  ) async {
    final dest = File(path);
    await dest.parent.create(recursive: true);
    try {
      await _api.downloadToFile(entryId, dest, expectedSha256: sha256);
      // дата файла берётся с устройства-источника: иначе следующий проход счёл бы только что
      // скачанный файл изменённым на телефоне и выгрузил бы его назад
      if (clientMtime != null && clientMtime > 0) {
        try {
          await dest.setLastModified(
            DateTime.fromMillisecondsSinceEpoch(clientMtime),
          );
        } catch (_) {}
      }
      final stat = await dest.stat();
      await _store.putFile(
        MirrorRow(
          path: dest.path,
          cloudFolderId: folderId ?? '',
          entryId: entryId,
          inode: await _native.inode(dest.path),
          size: stat.size,
          mtime: stat.modified.millisecondsSinceEpoch,
          sha256: sha256,
        ),
      );
      downloaded += 1;
      _downloads.success();
      _onProgress('скачано: ${p.basename(dest.path)}');
      return true;
    } catch (e) {
      failed += 1;
      // Сеть легла или токен отозван: продолжать бессмысленно — каждый следующий файл
      // стоил бы ещё одного таймаута
      if (_downloads.failure(e)) {
        fatal = _downloads.reason;
        return false;
      }
      // Самая частая причина отказа файловой системы — имя: сервер разрешает символы и длину,
      // которых на телефоне (особенно на карте памяти) не бывает
      final name = p.basename(dest.path);
      final nameProblem =
          name.length > 255 ||
          name.contains(RegExp(r'[\\:*?"<>|]')) ||
          name.endsWith('.') ||
          name.endsWith(' ');
      _onProgress(
        nameProblem
            ? 'не скачалось «$name»: такое имя недопустимо на телефоне — переименуйте в облаке'
            : 'не скачалось $name: $e',
      );
      return false;
    }
  }

  /// Переименование или перенос папки на телефоне вместе со всем, что под ней.
  Future<void> _moveLocalDir(String fromPath, String toPath) async {
    final from = Directory(fromPath);
    final to = Directory(toPath);
    await to.parent.create(recursive: true);
    if (await from.exists() && !await to.exists()) {
      try {
        await from.rename(toPath);
      } catch (_) {}
    }
    for (final row in await _store.filesUnder(fromPath)) {
      final path = toPath + row.path.substring(fromPath.length);
      await _store.moveFile(row.path, row.copyWith(path: path));
    }
    for (final (id, path) in await _store.dirsUnder(fromPath)) {
      if (path == fromPath) continue;
      await _store.moveDir(id, toPath + path.substring(fromPath.length));
    }
  }

  Future<bool> _isEmpty(Directory dir) async {
    try {
      return await dir.list().isEmpty;
    } catch (_) {
      return false;
    }
  }
}
