import 'dart:io';

import '../data/queue_store.dart';
import '../device/hasher.dart';
import '../device/media_rules.dart';
import '../net/sync_api.dart';
import '../section.dart';
import 'queue_planner.dart';
import 'upload_plan.dart';
import 'uploader.dart';

/// Что происходит прямо сейчас: имя файла и сколько байт ушло.
class UploadProgress {
  const UploadProgress({
    required this.id,
    required this.name,
    required this.sent,
    required this.total,
  });

  final int id;
  final String name;
  final int sent;
  final int total;

  int get percent => total > 0 ? (sent * 100) ~/ total : 0;
}

/// Выгрузка одного файла из очереди. Запускается вручную — кнопкой на строке, — и строго
/// по одному: пока идёт выгрузка, остальные кнопки неактивны.
///
/// Порядок работы:
///   1. файл на месте? если исчез — строка помечается ошибкой и ждёт следующего прохода;
///   2. SHA-256 содержимого (из кэша, если файл не менялся) — им сервер отличает дубли;
///   3. что уже лежит в облаке по этому имени: тот же хэш → выгрузка не нужна вовсе,
///      другой → перезапись с проверкой версии (сервер откажет, если там уже чужое);
///   4. папка получателя: для «Фото» — медиатека (плоско), для «Файлов» — структура папок;
///   5. заливка частями прямо в хранилище, при его недоступности — через сервер.
class UploadRunner {
  UploadRunner(this._api, this._store);

  final SyncApi _api;
  final QueueStore _store;

  /// Папки получателя по относительному пути: первый проход заводит их десятками.
  final Map<String, String> _folders = {};

  Future<void> run(int itemId, {void Function(UploadProgress)? onProgress}) async {
    final item = await _store.item(itemId);
    if (item == null) return;
    final file = File(item.path);
    if (!await file.exists()) {
      await _store.markFailed(itemId, 'файла больше нет на телефоне', item.attempts + 1);
      return;
    }

    final size = await file.length();
    final mtime = (await file.stat()).modified.millisecondsSinceEpoch;
    await _store.markRunning(itemId);
    onProgress?.call(UploadProgress(id: itemId, name: item.name, sent: 0, total: size));

    try {
      final sha = await _shaOf(item, file, size, mtime);
      final alreadyUploaded = (await _store.uploaded())[UploadedKey(item.path, item.target)];
      // что лежит на сервере сейчас: этим же отличается «уже там» от «надо перезаписать»
      String? serverSha;
      if (alreadyUploaded != null) {
        try {
          serverSha = (await _api.entryMeta(alreadyUploaded.entryId)).sha256;
        } catch (_) {
          // запись могли удалить из веба: тогда файл уедет как новый
          serverSha = null;
        }
      }

      switch (UploadPlan.decide(sha, serverSha)) {
        case UploadAction.skip:
          final entryId = alreadyUploaded?.entryId;
          if (entryId == null) return;
          await _store.markSkipped(itemId, entryId);
          await _store.markUploaded(item.path, item.target, entryId, size, mtime);
          return;
        case UploadAction.create:
        case UploadAction.replace:
          final replace = serverSha != null;
          final folderId = await _resolveFolder(item);
          final result = await _send(
            item: item,
            folderId: folderId,
            file: file,
            sha: sha,
            replace: replace,
            expectedSha256: replace ? serverSha : null,
            onProgress: onProgress,
          );
          if (result.deduped) {
            await _store.markSkipped(itemId, result.entryId);
          } else {
            await _store.markDone(itemId, result.entryId);
          }
          // Слепок берётся ДО выгрузки: в строке записано, что именно лежит в облаке.
          // Если файл дописался во время выгрузки, размер и дата разойдутся — и следующий
          // проход честно поставит его в очередь снова.
          await _store.markUploaded(
            item.path,
            item.target,
            result.entryId,
            size,
            mtime,
            sha256: sha,
          );
      }
    } catch (e) {
      final fresh = await _store.item(itemId);
      await _store.markFailed(itemId, '$e', (fresh?.attempts ?? 0) + 1);
      rethrow;
    }
  }

  /// Хэш содержимого: из кэша строки, если размер и дата не менялись с прошлой попытки.
  Future<String> _shaOf(QueueItem item, File file, int size, int mtime) async {
    final cached = item.sha256;
    if (cached != null && cached.isNotEmpty && item.size == size && item.mtime == mtime) {
      return cached;
    }
    final sha = await Hasher.sha256(file);
    await _store.setSha(item.id, sha);
    return sha;
  }

  /// Заливка с откатом на сервер: прямое подключение к хранилищу может не работать (DNS,
  /// блокировщик, VPN). Внятный ответ сервера (4xx) — не повод менять способ: режим запомнился
  /// бы навсегда и спрятал настоящую причину.
  Future<UploadResult> _send({
    required QueueItem item,
    required String folderId,
    required File file,
    required String sha,
    required bool replace,
    required String? expectedSha256,
    void Function(UploadProgress)? onProgress,
  }) async {
    final mime = MediaRules.mimeOf(item.name);
    void progress(int sent, int total) =>
        onProgress?.call(UploadProgress(id: item.id, name: item.name, sent: sent, total: total));

    Future<UploadResult> attempt(String cloudName, bool viaRelay) => Uploader(_api).upload(
          folderId: folderId,
          file: file,
          cloudName: cloudName,
          mime: mime,
          sha256: sha,
          replace: replace,
          expectedSha256: expectedSha256,
          onProgress: progress,
          forceRelay: viaRelay,
        );

    try {
      return await attempt(item.name, false);
    } catch (first) {
      if (first is SyncApiException &&
          (first.code == 'conflict' || first.code == 'stale_version')) {
        // в облаке чужой файл с таким именем: не затираем, кладём рядом под свободным именем
        var taken = <String>{};
        try {
          taken = (await _api.children(folderId)).entries.map((e) => e.name).toSet();
        } catch (_) {}
        final free = UploadPlan.freeName(item.name, taken);
        return attempt(free, false);
      }
      if (first is SyncApiException && first.status < 500) rethrow;
      if (first is! SyncApiException && first is! IOException) rethrow;

      // разовый обрыв не повод считать хранилище мёртвым: вторая попытка стоит секунд
      try {
        return await attempt(item.name, false);
      } catch (_) {
        return attempt(item.name, true);
      }
    }
  }

  /// Папка получателя: у «Фото» — медиатека (плоско), у «Файлов» — структура папок телефона.
  Future<String> _resolveFolder(QueueItem item) async {
    if (item.section != Section.files || item.relDir.isEmpty) return item.target;
    final cached = _folders[item.relDir];
    if (cached != null) return cached;
    final id = await _ensurePath(item.relDir, item.target);
    _folders[item.relDir] = id;
    return id;
  }

  /// Сервер ограничивает частоту запросов (429). Первый проход по дереву заводит папки
  /// десятками, и упереться в лимит на середине — значит уронить выгрузку на ровном месте.
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
