import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/mirror_store.dart';
import '../data/selection.dart';
import '../data/selection_rules.dart';
import '../device/hasher.dart';
import '../device/media_rules.dart';
import '../device/native_fs.dart';
import '../net/sync_api.dart';
import '../queue/upload_plan.dart';
import '../queue/uploader.dart';
import '../section.dart';
import 'mirror_folders.dart';
import 'mirror_models.dart';
import 'mirror_pull.dart';
import 'mirror_rules.dart';
import 'mirror_scanner.dart';
import 'mirror_status.dart';

/// Итог прохода: что удалось, что нет и почему.
class MirrorReport {
  int uploaded = 0;
  int downloaded = 0;
  int renamed = 0;
  int deletedInCloud = 0;

  /// Пустые папки, убранные в облаке после переименований и удалений на телефоне.
  int removedFolders = 0;
  int deletedOnPhone = 0;
  int conflicts = 0;
  int failed = 0;
  int unreadable = 0;
  bool capped = false;
  int blockedDeletes = 0;
  String? blockedReason;
  bool rescanned = false;
  bool stopped = false;
  String? error;
  int finishedAt = DateTime.now().millisecondsSinceEpoch;

  String text() {
    final out = StringBuffer('выгружено: $uploaded, скачано: $downloaded');
    if (renamed > 0) out.write(', переименовано: $renamed');
    if (deletedInCloud > 0) out.write(', удалено в облаке: $deletedInCloud');
    if (removedFolders > 0) out.write(', пустых папок убрано: $removedFolders');
    if (deletedOnPhone > 0) out.write(', удалено на телефоне: $deletedOnPhone');
    if (conflicts > 0) out.write(', конфликтов: $conflicts');
    if (failed > 0) out.write(', ошибок: $failed');
    if (unreadable > 0) out.write(', папок без доступа: $unreadable');
    if (capped) out.write(', обход неполный');
    if (blockedDeletes > 0) {
      out.write(', удаления приостановлены: $blockedDeletes');
    }
    if (stopped) out.write(', проход не закончен — продолжу в следующий раз');
    final err = error;
    if (err != null) out.write(' · $err');
    return out.toString();
  }
}

/// Двустороннее зеркало выбранных папок раздела «Файлы»: содержимое телефона и папки в облаке
/// совпадает в обе стороны — как «зеркалирование» в Google Drive, но без «оптимизировать место»:
/// приложение никогда не удаляет файл на телефоне ради свободного места.
///
/// Порядок прохода:
///   1. корни — выбранная папка телефона получает свою папку в облаке;
///   2. облако → телефон: догон журнала (или полный проход, если курсора ещё нет);
///   3. телефон → облако: новые и изменившиеся файлы, переименования, удаления.
///
/// Облако идёт первым не случайно: решения по телефону принимаются по свежему состоянию
/// облака, иначе проход выгрузил бы версию, которую в облаке только что заменили.
///
/// Предохранители, без которых зеркало однажды выкосит облако:
///   • папка не читается или обход неполный — удаления в облаке не отправляются вовсе;
///   • пропало слишком много за один проход — удаления приостанавливаются до подтверждения.
/// Снятие галочки с папки удалением не считается: удаление приходит только из сравнения
/// с файловой системой.
class MirrorEngine {
  MirrorEngine(
    this._api,
    this._store,
    this._selection, {
    MirrorStatusHolder? status,
    NativeFs? native,
  }) : _status = status ?? MirrorStatusHolder(),
       _native = native ?? NativeFs();

  final SyncApi Function() _api;
  final MirrorStore _store;
  final Selection _selection;
  final MirrorStatusHolder _status;
  final NativeFs _native;

  /// Проход ограничен по времени: фоновая работа под присмотром системы, а не вечная.
  static const int defaultBudgetMs = 8 * 60 * 1000;

  /// Один проход за раз. Проход запускают трое: опрос журнала (мгновенный режим), событие
  /// файловой системы и периодическое задание системы. Без замка они наложились бы друг на
  /// друга и стали бы спорить за одни и те же строки состояния.
  bool _busy = false;

  MirrorStatusHolder get status => _status;

  /// Голова журнала изменений: нужна мгновенному режиму, чтобы понять, есть ли что догонять.
  Future<int> syncHead() => _api().syncHead();

  /// @param budgetMs сколько можно работать за один проход. Фоновая работа ограничена системой,
  ///        а выгрузка гигабайтов идёт часами: остаток доедет следующим проходом.
  /// @param manual ручная сверка из настроек: работает и когда автоматика выключена.
  Future<MirrorReport> pass({
    void Function(String)? onProgress,
    bool Function()? isCancelled,
    int budgetMs = defaultBudgetMs,
    bool manual = false,
  }) async {
    final progress = onProgress ?? (String _) {};
    final cancelled = isCancelled ?? () => false;
    if (!manual && await _store.meta(MirrorStore.keyPaused) == '1') {
      return MirrorReport()..error = 'зеркало выключено';
    }
    if (_busy) return MirrorReport()..error = 'проход уже идёт';
    _busy = true;
    try {
      return await _passLocked(progress, cancelled, budgetMs);
    } finally {
      _busy = false;
    }
  }

  Future<MirrorReport> _passLocked(
    void Function(String) onProgress,
    bool Function() isCancelled,
    int budgetMs,
  ) async {
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final report = MirrorReport();
    final inCloud = await _store.inCloud();
    final local = await _store.localTotals();
    _status.update(
      (s) => s.copyWith(
        phase: MirrorPhase.scan,
        currentName: null,
        clearCurrentName: true,
        currentSent: 0,
        currentTotal: 0,
        passUploadedFiles: 0,
        passUploadedBytes: 0,
        passDownloaded: 0,
        passFailed: 0,
        blocked: 0,
        clearError: true,
        startedAt: startedAt,
        inCloudFiles: inCloud.files,
        inCloudBytes: inCloud.bytes,
        localFiles: local.files,
        localBytes: local.bytes,
      ),
    );

    final SyncApi api;
    try {
      api = _api();
    } catch (e) {
      return _finish(report..error = 'нет доступа к синхронизации: $e');
    }

    MeInfo me;
    try {
      me = await api.meInfo();
    } catch (e) {
      return _finish(report..error = 'нет связи с сервером: $e');
    }
    final mirrorRootId = me.mirrorFolderId;
    if (mirrorRootId == null || mirrorRootId.isEmpty) {
      return _finish(
        report
          ..error = 'сервер не отдал корень зеркала — проверьте подключение',
      );
    }
    // Состояние зеркала принадлежит аккаунту И своему корню: строки `files` описывают записи
    // в конкретной папке облака. Сменили сервер или логин — строки прошлого аккаунта сделали бы
    // все локальные файлы «уже выгруженными»; сменился корень (сервер завёл папку новому
    // устройству, токен перевыпущен) — то же самое, только новая папка осталась бы пустой.
    //
    // Проверка по корню закрывает и случай базы от старого нативного клиента: у неё нет записи
    // о корне, зато есть device_id прежнего токена, и он не совпадёт с нынешним.
    final identity = '${api.serverUrl}|${me.login}';
    final wasAccount = await _store.meta(MirrorStore.keyAccount);
    final wasRoot = await _store.meta(MirrorStore.keyMirrorRoot);
    final wasDevice = await _store.meta(MirrorStore.keyDeviceId);
    final otherAccount = wasAccount != null && wasAccount != identity;
    final otherRoot =
        wasRoot != null && wasRoot.isNotEmpty && wasRoot != mirrorRootId;
    final otherDevice =
        wasDevice != null &&
        wasDevice.isNotEmpty &&
        me.deviceId != null &&
        wasDevice != me.deviceId;
    if (otherAccount || otherRoot || otherDevice) {
      await _store.wipe();
      _status.update(
        (s) => s.copyWith(
          inCloudFiles: 0,
          inCloudBytes: 0,
          waitingFiles: 0,
          waitingBytes: 0,
        ),
      );
    }
    await _store.setMeta(MirrorStore.keyAccount, identity);
    await _store.setMeta(MirrorStore.keyDeviceId, me.deviceId ?? '');
    await _store.setMeta(MirrorStore.keyMirrorRoot, mirrorRootId);

    final folders = MirrorFolders(api, _store);
    final roots = SelectionRules.scanRoots(_selection.paths(Section.files));
    // папку сняли с выбора: пару убираем, а строки выгруженного остаются — вернуть выбор
    // можно без повторной заливки и без удаления в облаке
    for (final gone in (await _store.roots()).keys.where(
      (r) => !roots.contains(r),
    )) {
      await _store.dropRoot(gone);
    }
    for (final root in roots) {
      if (isCancelled()) return _finish(report..stopped = true);
      final name = p.basename(root);
      try {
        await _store.putRoot(
          root,
          await folders.ensure(name, root, mirrorRootId),
          name,
        );
      } catch (e) {
        report.failed += 1;
      }
    }

    // 1) облако → телефон
    final pull = MirrorPull(
      api,
      _store,
      me.deviceId,
      onProgress,
      native: _native,
    );
    if (roots.isNotEmpty) {
      _status.update((s) => s.copyWith(phase: MirrorPhase.cloud));
      onProgress('догоняю облако…');
      await pull.catchUp();
    }
    _fill(report, pull);
    final fatal = pull.fatal;
    if (fatal != null) return _finish(report..error = fatal);

    // 2) телефон → облако
    if (roots.isNotEmpty) {
      await _pushLocal(
        roots: roots,
        folders: folders,
        mirrorRootId: mirrorRootId,
        api: api,
        pull: pull,
        report: report,
        onProgress: onProgress,
        isCancelled: isCancelled,
        startedAt: startedAt,
        budgetMs: budgetMs,
      );
    }

    return _finish(report);
  }

  /// Только облачная сторона: догнать журнал, не трогая диск. Так работает мгновенный режим:
  /// правка из веба приезжает за секунды, а полный обход папок ради этого не нужен — он
  /// остаётся за событиями файловой системы и периодическим проходом.
  Future<MirrorReport> catchUpCloud({
    void Function(String)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final progress = onProgress ?? (String _) {};
    final cancelled = isCancelled ?? () => false;
    if (_busy) return MirrorReport()..error = 'проход уже идёт';
    _busy = true;
    final report = MirrorReport();
    try {
      final SyncApi api;
      try {
        api = _api();
      } catch (e) {
        return report..error = 'нет доступа к синхронизации: $e';
      }
      MeInfo me;
      try {
        me = await api.meInfo();
      } catch (e) {
        return report..error = 'нет связи с сервером: $e';
      }
      await _store.setMeta(MirrorStore.keyDeviceId, me.deviceId ?? '');
      _status.update(
        (s) => s.copyWith(
          phase: MirrorPhase.cloud,
          startedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      final pull = MirrorPull(
        api,
        _store,
        me.deviceId,
        progress,
        native: _native,
      );
      await pull.catchUp();
      _fill(report, pull);
      report.error = pull.fatal;
      report.stopped = cancelled();
      return await _finish(report);
    } finally {
      _busy = false;
    }
  }

  /// Итог прохода: пишем отчёт в базу и гасим состояние. Одна точка выхода — иначе при любой
  /// новой ветке «рано вернулись» в интерфейсе навсегда осталось бы «выгружаю…».
  Future<MirrorReport> _finish(MirrorReport report) async {
    report.finishedAt = DateTime.now().millisecondsSinceEpoch;
    // подтверждение массового удаления живёт ровно один проход: если проход до разбора
    // удалений не дошёл, флаг всё равно должен сгореть, иначе он сработает в следующем —
    // уже на другом наборе файлов
    await _store.clearMeta(MirrorStore.keyConfirmed);
    await _store.setMeta(MirrorStore.keyReport, report.text());
    final inCloud = await _store.inCloud();
    final waiting = await _store.waitingTotals();
    _status.update(
      (s) => s.copyWith(
        phase: s.phase == MirrorPhase.paused
            ? MirrorPhase.paused
            : MirrorPhase.idle,
        clearCurrentName: true,
        currentSent: 0,
        currentTotal: 0,
        passUploadedFiles: report.uploaded,
        passDownloaded: report.downloaded,
        passFailed: report.failed,
        inCloudFiles: inCloud.files,
        inCloudBytes: inCloud.bytes,
        waitingFiles: waiting.files,
        waitingBytes: waiting.bytes,
        finishedAt: report.finishedAt,
        lastText: report.text(),
        error: report.error,
        clearError: report.error == null,
        blocked: report.blockedDeletes,
        blockedReason: report.blockedReason,
        clearBlockedReason: report.blockedReason == null,
      ),
    );
    return report;
  }

  /// Перенести счётчики облачного прохода в общий итог.
  void _fill(MirrorReport report, MirrorPull pull) {
    report.downloaded += pull.downloaded;
    report.deletedOnPhone += pull.deletedLocal;
    report.conflicts += pull.conflicts;
    report.renamed += pull.renamedLocal;
    report.failed += pull.failed;
    report.rescanned = report.rescanned || pull.rescanned;
  }

  Future<void> _pushLocal({
    required List<String> roots,
    required MirrorFolders folders,
    required String mirrorRootId,
    required SyncApi api,
    required MirrorPull pull,
    required MirrorReport report,
    required void Function(String) onProgress,
    required bool Function() isCancelled,
    required int startedAt,
    required int budgetMs,
  }) async {
    final snapshot = await MirrorScanner(native: _native)
        .snapshot(roots, onProgress: onProgress, isCancelled: isCancelled);
    report.unreadable = snapshot.unreadable;
    report.capped = snapshot.capped;
    // сколько всего лежит в выбранных папках: от этого считается доля выгруженного
    final localBytes = snapshot.files.fold<int>(0, (sum, f) => sum + f.size);
    await _store.setLocalTotals(snapshot.files.length, localBytes);
    _status.update(
      (s) => s.copyWith(
        phase: MirrorPhase.upload,
        localFiles: snapshot.files.length,
        localBytes: localBytes,
      ),
    );

    // структура в облаке повторяет структуру телефона, включая пустые папки
    for (final dir in snapshot.dirs) {
      if (isCancelled()) {
        report.stopped = true;
        return;
      }
      try {
        await folders.ensure(dir.relDir, dir.path, mirrorRootId);
      } catch (_) {
        report.failed += 1;
      }
    }

    final confirmed = await _store.meta(MirrorStore.keyConfirmed) == '1';
    final deletionsAllowed = MirrorRules.deletionsAllowed(snapshot);
    // строки, относящиеся к выбранным сейчас папкам, отсекаются признаком: копию таблицы
    // на большой библиотеке делать нельзя, а без отсечения сверка удалила бы содержимое
    // папки, снятой с выбора
    final known = await _store.files();
    final plan = MirrorRules.plan(
      local: snapshot.files,
      known: known,
      now: DateTime.now().millisecondsSinceEpoch,
      deletionsAllowed: deletionsAllowed,
      confirmed: confirmed,
      inScope: (path) => MirrorRules.underRoots(path, roots),
    );

    // отложенные файлы (ещё пишутся) не забываем: к ним вернёмся через окно стабильности
    if (plan.unstable > 0) {
      await _store.setMeta(
        MirrorStore.keyRetryAt,
        '${DateTime.now().millisecondsSinceEpoch + MirrorRules.stableMs}',
      );
    } else {
      await _store.clearMeta(MirrorStore.keyRetryAt);
    }
    final waitingBytes = plan.uploads.fold<int>(0, (sum, f) => sum + f.size);
    await _store.setWaitingTotals(plan.uploads.length, waitingBytes);
    _status.update(
      (s) => s.copyWith(
        waitingFiles: plan.uploads.length,
        waitingBytes: waitingBytes,
        blocked: plan.blockedCount,
        localFiles: snapshot.files.length,
        localBytes: localBytes,
      ),
    );

    if (plan.blocked) {
      final reason = deletionsAllowed
          ? 'одним проходом пропало слишком много файлов'
          : 'часть папок не читается или обход неполный';
      await _store.setMeta(
        MirrorStore.keyBlocked,
        '${plan.blockedCount}|$reason',
      );
      report.blockedDeletes = plan.blockedCount;
      report.blockedReason = reason;
    } else {
      await _store.clearMeta(MirrorStore.keyBlocked);
    }

    // переименования первыми: выгрузка изменившегося файла пойдёт уже по новому пути
    for (final (row, file) in plan.renames) {
      if (_outOfTime(startedAt, budgetMs) || isCancelled()) {
        report.stopped = true;
        return;
      }
      final folderId = await _store.dirId(file.dir) ?? row.cloudFolderId;
      try {
        await api.moveFile(row.entryId, folderId, file.name);
        final moved = MirrorRow(
          path: file.path,
          cloudFolderId: folderId,
          entryId: row.entryId,
          inode: file.inode,
          size: file.size,
          mtime: file.mtime,
          sha256: row.sha256,
        );
        known.remove(row.path);
        known[file.path] = moved;
        await _store.moveFile(row.path, moved);
        report.renamed += 1;
        onProgress('переименовано: ${file.name}');
      } catch (_) {
        report.failed += 1;
      }
    }

    for (final file in plan.uploads) {
      if (_outOfTime(startedAt, budgetMs) || isCancelled()) {
        report.stopped = true;
        return;
      }
      final folderId = await _store.dirId(file.dir);
      if (folderId == null) {
        report.failed += 1;
        continue;
      }
      try {
        await _upload(
          api: api,
          file: file,
          folderId: folderId,
          known: known,
          pull: pull,
          report: report,
          onProgress: onProgress,
        );
      } catch (e) {
        report.failed += 1;
        onProgress('не выгрузилось ${file.name}: $e');
      }
    }

    if (plan.deletes.isNotEmpty) {
      _status.update(
        (s) => s.copyWith(phase: MirrorPhase.delete, clearCurrentName: true),
      );
    }
    for (final row in plan.deletes) {
      if (_outOfTime(startedAt, budgetMs) || isCancelled()) {
        report.stopped = true;
        return;
      }
      try {
        await api.deleteFile(row.entryId);
        known.remove(row.path);
        await _store.dropFile(row.path);
        report.deletedInCloud += 1;
        _status.update(
          (s) => s.copyWith(
            inCloudFiles: s.inCloudFiles > 0 ? s.inCloudFiles - 1 : 0,
            inCloudBytes: s.inCloudBytes - row.size > 0
                ? s.inCloudBytes - row.size
                : 0,
          ),
        );
        onProgress('удалено в облаке: ${p.basename(row.path)}');
      } on SyncApiException catch (e) {
        // 404 — записи в облаке уже нет: строку всё равно убираем, иначе будем пытаться
        // удалить её в каждом проходе
        if (e.status == 404) {
          known.remove(row.path);
          await _store.dropFile(row.path);
        } else {
          report.failed += 1;
        }
      } catch (_) {
        report.failed += 1;
      }
    }

    // Хвост после переименований и удалений: папки, которые завело зеркало и которых больше
    // нет на телефоне. Убираем только пустые и только по полному снимку — папка с содержимым
    // не тронется ни при каких условиях.
    if (deletionsAllowed &&
        !isCancelled() &&
        !_outOfTime(startedAt, budgetMs)) {
      await _sweepEmptyFolders(
        api: api,
        roots: roots,
        snapshot: snapshot,
        report: report,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    }
  }

  /// Сколько пустых папок убираем за один проход. Папка уходит отдельным запросом, а после
  /// переименования большого дерева кандидатов бывает сотни: остальное доедет следующим разом.
  static const int _maxFolderSweep = 200;

  /// Убрать в облаке опустевшие папки, оставшиеся от переименований и удалений на телефоне.
  ///
  /// Зеркало удаляет в облаке только файлы, поэтому папка, из которой файлы перенесли,
  /// оставалась там навсегда. Здесь она уходит — но лишь при трёх условиях сразу: её завело
  /// зеркало, на телефоне её больше нет и она внутри выбранных папок. Плюс на момент удаления
  /// в ней должно быть пусто: если сверка ошиблась и содержимое осталось, папка останется тоже.
  Future<void> _sweepEmptyFolders({
    required SyncApi api,
    required List<String> roots,
    required LocalSnapshot snapshot,
    required MirrorReport report,
    required void Function(String) onProgress,
    required bool Function() isCancelled,
  }) async {
    final rootIds = {for (final r in (await _store.roots()).values) r.cloudId};
    final candidates = MirrorRules.emptyFolderCandidates(
      dirs: await _store.allDirs(),
      aliveLocally: {for (final d in snapshot.dirs) d.path},
      roots: roots,
      rootCloudIds: rootIds,
    );
    var removed = 0;
    for (final localPath in candidates) {
      if (removed >= _maxFolderSweep || isCancelled()) break;
      final cloudId = (await _store.dirId(localPath)) ?? '';
      if (cloudId.isEmpty) continue;
      try {
        final children = await api.children(cloudId);
        if (children.entries.isNotEmpty || children.folderIds.isNotEmpty) {
          continue;
        }
        await api.deleteFolder(cloudId);
        await _store.dropDir(cloudId);
        removed += 1;
      } catch (_) {
        // папку могли удалить в вебе или в неё что-то легло: следующий проход разберётся
      }
    }
    if (removed > 0) {
      report.removedFolders += removed;
      onProgress('убрано пустых папок: $removed');
    }
  }

  /// Выгрузка одного файла. Если сервер отвечает, что версия на его стороне другая или что имя
  /// занято, — это конфликт: содержимое обеих сторон сохраняется, каноническое имя занимает
  /// версия облака, локальная уезжает копией с пометкой. Молча затирать нельзя ни там, ни тут.
  Future<void> _upload({
    required SyncApi api,
    required LocalFile file,
    required String folderId,
    required Map<String, MirrorRow> known,
    required MirrorPull pull,
    required MirrorReport report,
    required void Function(String) onProgress,
  }) async {
    final local = File(file.path);
    if (!await local.exists()) return;
    final row = known[file.path];
    _status.update(
      (s) => s.copyWith(
        phase: MirrorPhase.upload,
        currentName: file.name,
        currentSent: 0,
        currentTotal: file.size,
      ),
    );
    final sha = await _hash(local);
    void progress(int sent, int total) {
      _status.update((s) => s.copyWith(currentSent: sent, currentTotal: total));
      onProgress('${file.name}: $sent из $total');
    }

    // Незавершённая выгрузка этого же содержимого — продолжаем с принятой части: заново лить
    // двухгигабайтное видео после каждой остановки нельзя, и прогресс не должен прыгать назад.
    // Хэш в слепке обязателен: если файл успели изменить, сессия не подходит.
    final session = await _store.uploadSession(file.path);
    final resumable =
        session != null &&
        session.folderId == folderId &&
        session.size == file.size &&
        session.mtime == file.mtime &&
        session.sha256 == sha;

    UploadResult result;
    try {
      if (resumable) {
        try {
          result = await Uploader(api).resume(
            uploadId: session.uploadId,
            file: local,
            sha256: sha,
            onProgress: progress,
          );
        } catch (_) {
          // сессия на сервере могла истечь — тогда только с начала
          await api.abort(session.uploadId);
          await _store.dropUploadSession(file.path);
          result = await _startUpload(
            api: api,
            file: file,
            folderId: folderId,
            local: local,
            sha: sha,
            row: row,
            progress: progress,
          );
        }
      } else {
        await _store.dropUploadSession(file.path);
        result = await _startUpload(
          api: api,
          file: file,
          folderId: folderId,
          local: local,
          sha: sha,
          row: row,
          progress: progress,
        );
      }
    } on SyncApiException catch (e) {
      if (e.code == 'stale_version' ||
          e.code == 'conflict' ||
          e.code == 'in_trash') {
        await _resolveConflict(
          api: api,
          file: file,
          folderId: folderId,
          known: known,
          pull: pull,
          report: report,
          onProgress: onProgress,
        );
        return;
      }
      rethrow;
    }

    // размер и дата берутся из снимка, по которому считался хэш: если файл успел измениться
    // во время выгрузки, строка останется несовпадающей и следующий проход выгрузит его снова
    final fresh = MirrorRow(
      path: file.path,
      cloudFolderId: folderId,
      entryId: result.entryId,
      inode: file.inode,
      size: file.size,
      mtime: file.mtime,
      sha256: sha,
    );
    known[file.path] = fresh;
    await _store.putFile(fresh);
    // выгрузка завершена: незавершённой сессии больше нет
    await _store.dropUploadSession(file.path);
    report.uploaded += 1;
    _status.update(
      (s) => s.copyWith(
        passUploadedFiles: s.passUploadedFiles + 1,
        passUploadedBytes: s.passUploadedBytes + file.size,
        inCloudFiles: s.inCloudFiles + 1,
        inCloudBytes: s.inCloudBytes + file.size,
      ),
    );
    onProgress('выгружено: ${file.name}');
  }

  /// Выгрузка с нуля: запоминаем сессию, чтобы после обрыва продолжить, а не начинать заново.
  Future<UploadResult> _startUpload({
    required SyncApi api,
    required LocalFile file,
    required String folderId,
    required File local,
    required String sha,
    required MirrorRow? row,
    required void Function(int, int) progress,
  }) => Uploader(api).upload(
    folderId: folderId,
    file: local,
    cloudName: file.name,
    mime: MediaRules.mimeOf(file.name),
    sha256: sha,
    replace: row != null,
    expectedSha256: row?.sha256,
    onSession: (uploadId) => _store.putUploadSession(
      UploadSessionRow(
        path: file.path,
        uploadId: uploadId,
        folderId: folderId,
        size: file.size,
        mtime: file.mtime,
        sha256: sha,
      ),
    ),
    onProgress: progress,
    // телефон — источник истины: если файл с таким именем лежит в корзине облака, это наша
    // же удалённая версия, и место под именем надо занять, а не ждать очистки корзины
    replaceTrashed: true,
  );

  /// Конфликт версий. Локальное содержимое сохраняется копией с пометкой, а по каноническому
  /// имени скачивается версия облака — так не теряется ни одна из сторон.
  ///
  /// Если записи с таким именем в облаке нет (имя занято записью из корзины), не делаем ничего
  /// и говорим об этом: воскрешать чужую корзину самостоятельно нельзя.
  Future<void> _resolveConflict({
    required SyncApi api,
    required LocalFile file,
    required String folderId,
    required Map<String, MirrorRow> known,
    required MirrorPull pull,
    required MirrorReport report,
    required void Function(String) onProgress,
  }) async {
    final local = File(file.path);
    List<RemoteEntry>? remote;
    try {
      remote = (await api.children(folderId)).entries;
    } catch (_) {
      remote = null;
    }
    if (remote == null) {
      report.failed += 1;
      onProgress(
        'конфликт по «${file.name}»: не удалось прочитать папку облака',
      );
      return;
    }
    RemoteEntry? cloudEntry;
    for (final entry in remote) {
      if (entry.name == file.name) {
        cloudEntry = entry;
        break;
      }
    }
    if (cloudEntry == null) {
      // записи с таким именем в облаке нет вовсе: строка устарела (её удалили в вебе или
      // с другого устройства). Снимаем её и даём следующему проходу выгрузить файл как новый —
      // иначе он не уедет никогда и в каждом проходе будет ошибка.
      known.remove(file.path);
      await _store.dropFile(file.path);
      onProgress('«${file.name}»: запись в облаке пропала — выгружу заново');
      return;
    }
    final taken = remote.map((e) => e.name).toSet();
    final copyName = UploadPlan.freeName(
      MirrorRules.conflictName(
        file.name,
        DateTime.now().millisecondsSinceEpoch,
      ),
      taken,
    );
    try {
      await Uploader(api).upload(
        folderId: folderId,
        file: local,
        cloudName: copyName,
        mime: MediaRules.mimeOf(file.name),
        sha256: await _hash(local),
        replace: false,
        onProgress: (_, _) {},
      );
    } catch (e) {
      report.failed += 1;
      onProgress('конфликтная копия «$copyName» не уехала: $e');
      return;
    }
    report.conflicts += 1;
    onProgress(
      'конфликт: «${file.name}» сохранён как «$copyName», по основному имени — версия облака',
    );
    known.remove(file.path);
    await _store.dropFile(file.path);
    final ok = await pull.downloadInto(
      cloudEntry.id,
      folderId,
      file.path,
      cloudEntry.sha256,
      cloudEntry.size,
      cloudEntry.clientMtime,
    );
    if (ok) {
      report.downloaded += 1;
    } else {
      report.failed += 1;
    }
  }

  Future<String> _hash(File file) async {
    final stat = await file.stat();
    final cached = _hashCache[file.path];
    if (cached != null &&
        cached.$2 == stat.size &&
        cached.$3 == stat.modified.millisecondsSinceEpoch) {
      return cached.$1;
    }
    final sha = await Hasher.sha256(file);
    _hashCache[file.path] = (
      sha,
      stat.size,
      stat.modified.millisecondsSinceEpoch,
    );
    return sha;
  }

  /// Хэш содержимого за проход считается один раз: файл может попасть и в план выгрузки,
  /// и в разбор конфликта.
  final Map<String, (String, int, int)> _hashCache = {};

  bool _outOfTime(int startedAt, int budgetMs) =>
      DateTime.now().millisecondsSinceEpoch - startedAt > budgetMs;
}
