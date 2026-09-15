import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../net/sync_api.dart';

/// Итог заливки одного файла.
class UploadResult {
  const UploadResult({
    required this.entryId,
    required this.sha256,
    required this.deduped,
  });

  final String entryId;
  final String sha256;

  /// Содержимое уже было в облаке: байты не передавались вовсе.
  final bool deduped;
}

/// Заливка одного файла: части идут прямо в хранилище по presigned-ссылкам (сервер видит
/// только ETag'и), а если хранилище с телефона недоступно — через сервер.
///
/// Части читаются из файла случайным доступом и льются параллельно: память ≈ параллелизм ×
/// размер части.
class Uploader {
  Uploader(this._api);

  final SyncApi _api;

  /// Сколько частей льём одновременно: память ≈ parallelism × partSize.
  static const int _parallelism = 3;

  /// @param expectedSha256 версия файла на сервере, которую клиент считает актуальной
  ///        (обязательна при перезаписи: сервер откажет, если там уже другое содержимое)
  Future<UploadResult> upload({
    required String folderId,
    required File file,
    required String cloudName,
    required String mime,
    required String sha256,
    required bool replace,
    String? expectedSha256,
    void Function(String uploadId)? onSession,
    void Function(int sent, int total)? onProgress,
    bool forceRelay = false,
    bool replaceTrashed = false,
  }) async {
    final size = await file.length();
    final mtime = (await file.stat()).modified.millisecondsSinceEpoch;
    final init = await _api.initUpload(
      folderId: folderId,
      name: cloudName,
      size: size,
      mime: mime,
      sha256: sha256,
      replace: replace,
      clientMtime: mtime,
      expectedSha256: expectedSha256,
      mode: forceRelay ? 'relay' : 'direct',
      replaceTrashed: replaceTrashed,
    );
    if (init.stale || init.inTrash || init.nameTaken) {
      // имя занято или версия на сервере другая — решает вызывающий: свободное имя или отказ,
      // чтобы не затереть чужое. Коды разные намеренно: «версия на сервере другая» и «имя
      // занято» — разные случаи, и зеркало разбирает их по-разному.
      final code = init.inTrash
          ? 'in_trash'
          : init.stale
              ? 'stale_version'
              : 'conflict';
      throw SyncApiException(409, code, init.inTrash ? 'name in trash' : 'name taken');
    }
    if (init.deduped || init.uploadId == null) {
      // содержимое уже в облаке: запись создана, байты не передавались
      return UploadResult(entryId: init.entryId, sha256: sha256, deduped: true);
    }
    onSession?.call(init.uploadId!);
    return _sendParts(
      uploadId: init.uploadId!,
      direct: init.direct,
      partSize: init.partSize,
      file: file,
      sha256: sha256,
      onProgress: onProgress,
    );
  }

  /// Продолжить начатую выгрузку: сервер помнит, какие части уже приняты.
  ///
  /// Нужно для больших файлов: без этого видео на гигабайт после каждого обрыва, перезапуска
  /// приложения или остановки системой начиналось бы с нуля, а прогресс прыгал бы назад.
  /// Содержимое сверяется по хэшу: если файл изменился, сессия не подходит.
  Future<UploadResult> resume({
    required String uploadId,
    required File file,
    required String sha256,
    void Function(int sent, int total)? onProgress,
  }) async {
    final status = await _api.uploadStatus(uploadId);
    return _sendParts(
      uploadId: uploadId,
      direct: status.direct,
      partSize: status.partSize,
      file: file,
      sha256: sha256,
      onProgress: onProgress,
      fromPart: status.nextPart,
    );
  }

  Future<UploadResult> _sendParts({
    required String uploadId,
    required bool direct,
    required int partSize,
    required File file,
    required String sha256,
    void Function(int sent, int total)? onProgress,
    int fromPart = 1,
  }) async {
    final total = await file.length();
    // Пустой файл: частей нет вовсе. Сервер умеет записать пустой объект одним запросом,
    // поэтому просто завершаем сессию.
    if (total == 0) {
      onProgress?.call(0, 0);
      final entryId = await _api.complete(uploadId, sha256);
      return UploadResult(entryId: entryId, sha256: sha256, deduped: false);
    }
    final parts = math.max(1, ((total + partSize - 1) ~/ partSize));
    final first = fromPart.clamp(1, parts + 1);
    // уже принятые части считаются отправленными: прогресс продолжается, а не начинается заново
    var sent = math.min(total, (first - 1) * partSize);
    onProgress?.call(sent, total);
    // релей-режим (байты идут через сервер) требует строгого порядка частей; на очень больших
    // файлах ужимаем параллелизм: буферы частей держатся в памяти целиком
    final width = !direct
        ? 1
        : total > 1024 * 1024 * 1024
            ? 2
            : _parallelism;

    final raf = await file.open();
    try {
      var part = first;
      while (part <= parts) {
        final batchEnd = math.min(parts, part + width - 1);
        // Сначала читаем части пачки подряд: у одного RandomAccessFile позиция общая, и
        // параллельное чтение из него перемешало бы куски. Память ≈ ширина × размер части —
        // ровно как в нативном клиенте.
        final batch = <(int, Uint8List)>[];
        for (var number = part; number <= batchEnd; number++) {
          final offset = (number - 1) * partSize;
          final length = math.min(partSize, total - offset);
          await raf.setPosition(offset);
          batch.add((number, Uint8List.fromList(await raf.read(length))));
        }
        // …а льём их параллельно: сеть ждёт, и три части уходят одновременно
        final lengths = await Future.wait(batch.map((item) async {
          final (number, bytes) = item;
          if (direct) {
            final url = await _api.partUrl(uploadId, number);
            final etag = await _api.putPartToS3(url, bytes);
            await _api.registerPart(uploadId, number, etag, bytes.length);
          } else {
            await _api.relayChunk(uploadId, number, bytes);
          }
          return bytes.length;
        }));
        for (final length in lengths) {
          sent += length;
          onProgress?.call(sent, total);
        }
        part = batchEnd + 1;
      }
    } finally {
      await raf.close();
    }
    final entryId = await _api.complete(uploadId, sha256);
    return UploadResult(entryId: entryId, sha256: sha256, deduped: false);
  }
}
