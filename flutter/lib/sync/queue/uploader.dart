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

  /// id записи в облаке: под ним файл виден в дереве, по нему же берутся метаданные.
  final String entryId;

  /// Хэш содержимого, которое уехало: тот же, что передан серверу на завершении сессии.
  final String sha256;

  /// Содержимое уже было в облаке: байты не передавались вовсе.
  final bool deduped;
}

/// Заливка одного файла: части идут прямо в хранилище по presigned-ссылкам (сервер видит
/// только ETag'и), а если хранилище с телефона недоступно — через сервер.
///
/// Части читаются из файла случайным доступом и льются параллельно: память ≈ параллелизм ×
/// размер части.
///
/// Пользуются: [UploadRunner] (очередь) и `MirrorEngine` (зеркало). Продолжение прерванной
/// выгрузки через [resume] есть у обоих: сессию хранит вызывающий — зеркало в таблице
/// `uploads` (`MirrorStore`), очередь в `queue_uploads` (`QueueStore`).
/// Своего состояния между вызовами нет: всё, что нужно помнить, помнит сервер (сессия
/// и принятые части) либо вызывающий.
///
/// Файл только читается — ничего не пишется ни в файловую систему, ни в базы. Всё, что класс
/// делает наружу, — сетевые запросы; про состояние строк очереди и зеркала заботится вызывающий.
class Uploader {
  Uploader(this._api);

  final SyncApi _api;

  /// Сколько частей льём одновременно: память ≈ parallelism × partSize.
  ///
  /// Три — компромисс между скоростью и памятью: буферы частей держатся в памяти целиком,
  /// а размер части назначает сервер (по умолчанию 16 МБ — см. [SyncUploadInit.partSize]),
  /// то есть на телефоне это десятки мегабайт одновременно.
  static const int _parallelism = 3;

  /// Залить один файл в облако.
  ///
  /// [folderId] — папка получателя, [file] — файл на диске, [cloudName] — имя, под которым
  /// запись появится в облаке, [mime] — тип содержимого для метаданных, [sha256] — хэш файла.
  /// [replace] — заменяем ли существующую запись с этим именем.
  ///
  /// @param expectedSha256 версия файла на сервере, которую клиент считает актуальной
  ///        (обязательна при перезаписи: сервер откажет, если там уже другое содержимое)
  ///
  /// [onSession] — открытая сессия загрузки: её запоминают, чтобы после обрыва продолжить
  /// через [resume]; вызывается только когда сессия действительно начата.
  /// [onProgress] — сколько байт передано; у дедупа не вызывается ни разу.
  /// [forceRelay] — лить сразу через сервер, не пробуя хранилище напрямую.
  /// [replaceTrashed] — занять имя, даже если оно у записи из корзины (нужно и зеркалу,
  /// и очереди: телефон считает себя источником истины, а без этого файл с таким именем
  /// не уехал бы в облако, пока корзину не почистят руками).
  ///
  /// Возвращает [UploadResult] с id записи: ответ без id — отказ, а не успех (см. [_done]).
  /// Ошибки: `SyncApiException` с кодом `stale_version`,
  /// `in_trash` или `conflict` (409) — решение за вызывающим (свободное имя, конфликтная копия,
  /// отказ); `SyncDirectUnavailable` (реализует [IOException]) — хранилище недоступно напрямую,
  /// надо повторить релеем; прочие ошибки сети и чтения файла — как есть.
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
    // размер и дата уходят серверу как метаданные записи, а не как решение о заливке:
    // решение давно принято вызывающим, здесь только исполнение
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
      // Порядок проверок — от частного к общему: сначала корзина, затем расхождение версий,
      // и только потом просто занятое имя.
      final code = init.inTrash
          ? 'in_trash'
          : init.stale
              ? 'stale_version'
              : 'conflict';
      throw SyncApiException(409, code, init.inTrash ? 'name in trash' : 'name taken');
    }
    if (init.deduped || init.uploadId == null) {
      // содержимое уже в облаке: запись создана, байты не передавались.
      // uploadId сервер не выдал — продолжать нечего, и вызывающему нечего запоминать
      return _done(init.entryId, sha256, deduped: true);
    }
    // сессия открыта: только теперь её есть смысл запоминать — до этой строки продолжать
    // на сервере нечего
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
  ///
  /// [uploadId] — сессия, начатая раньше (её хранит вызывающий: зеркало — таблица `uploads`
  /// в `MirrorStore`, очередь — `queue_uploads` в `QueueStore`); [file] и [sha256] — текущий
  /// файл и его хэш: сверку «то же ли это содержимое» делает вызывающий, иначе принятые части
  /// смешались бы с чужими.
  /// [onProgress] вызывается по байтам, начиная с уже принятого.
  ///
  /// Возвращает итог заливки. Сеть: состояние сессии, ссылки на части, заливка, завершение.
  /// Исключение уходит вызывающему: продолжать нечем — он прерывает сессию и начинает заново.
  Future<UploadResult> resume({
    required String uploadId,
    required File file,
    required String sha256,
    void Function(int sent, int total)? onProgress,
  }) async {
    // способ заливки и размер части берём из ответа сервера, а не из своих настроек: сессию
    // мог открыть другой проход, и его partSize — истина для уже принятых частей
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

  /// Отправить части и завершить сессию.
  ///
  /// [uploadId] — открытая сессия; [direct] — лить прямо в хранилище, иначе через сервер;
  /// [partSize] — размер части, назначенный сервером; [file] — файл на диске (только чтение);
  /// [sha256] — хэш содержимого, уходит на завершении; [onProgress] — байты; [fromPart] —
  /// с какой части продолжать (уже принятые сервер повторно не отдаёт).
  ///
  /// Возвращает итог с id записи. Сеть: ссылки на части и PUT в хранилище с регистрацией
  /// ETag'ов (либо заливка частей через сервер) и завершение сессии. Исключение наружу —
  /// незавершённая выгрузка: сессия на сервере остаётся живой, её можно продолжить [resume].
  Future<UploadResult> _sendParts({
    required String uploadId,
    required bool direct,
    required int partSize,
    required File file,
    required String sha256,
    void Function(int sent, int total)? onProgress,
    int fromPart = 1,
  }) async {
    // длину файла спрашиваем с диска: по ней считаются границы всех частей
    final total = await file.length();
    // Пустой файл: частей нет вовсе. Сервер умеет записать пустой объект одним запросом,
    // поэтому просто завершаем сессию.
    if (total == 0) {
      onProgress?.call(0, 0);
      return _done(await _api.complete(uploadId, sha256), sha256, deduped: false);
    }
    // частей — округление вверх, минимум одна: пустой файл сюда не доходит, но формула
    // должна оставаться безопасной при любом partSize
    final parts = math.max(1, ((total + partSize - 1) ~/ partSize));
    // fromPart приходит от сервера и может оказаться больше числа частей: тогда отправлять
    // нечего и сессия просто завершается
    final first = fromPart.clamp(1, parts + 1);
    // уже принятые части считаются отправленными: прогресс продолжается, а не начинается заново
    var sent = math.min(total, (first - 1) * partSize);
    onProgress?.call(sent, total);
    // релей-режим (байты идут через сервер) требует строгого порядка частей, поэтому ширина 1;
    // на очень больших файлах параллелизм ужимаем до 2: буферы частей держатся в памяти целиком,
    // и три части подряд на гигабайтном файле — лишний риск для памяти телефона
    final width = !direct
        ? 1
        : total > 1024 * 1024 * 1024
            ? 2
            : _parallelism;

    // один дескриптор на файл: части читаются из него по смещению, поэтому файл не
    // перечитывается от начала до нужной части
    final raf = await file.open();
    try {
      var part = first;
      while (part <= parts) {
        // пачка — столько частей, сколько уйдёт одновременно; последняя бывает короче
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
        // …а льём их параллельно: пока сеть ждёт ответа на одну часть, уходят остальные
        final lengths = await Future.wait(batch.map((item) async {
          final (number, bytes) = item;
          if (direct) {
            // прямая заливка: ссылка на часть → PUT в хранилище → регистрация ETag'а.
            // Сервер узнаёт о части только из регистрации, поэтому пропустить её нельзя
            final url = await _api.partUrl(uploadId, number);
            final etag = await _api.putPartToS3(url, bytes);
            await _api.registerPart(uploadId, number, etag, bytes.length);
          } else {
            // релей: часть целиком уходит на сервер, а в хранилище её кладёт он сам
            await _api.relayChunk(uploadId, number, bytes);
          }
          return bytes.length;
        }));
        // прогресс двигаем после всей пачки: части уходят параллельно, и честно сказать,
        // сколько отправлено, можно только когда пачка закрыта
        for (final length in lengths) {
          sent += length;
          onProgress?.call(sent, total);
        }
        part = batchEnd + 1;
      }
    } finally {
      // дескриптор закрываем всегда: выгрузку прерывают исключением, и брошенный файл
      // остался бы открытым до конца процесса
      await raf.close();
    }
    // завершение: сервер собирает объект из частей и отдаёт id записи
    return _done(await _api.complete(uploadId, sha256), sha256, deduped: false);
  }

  /// Итог заливки с проверкой id записи.
  ///
  /// Пустой id — это не «выгружено»: по id вызывающий берёт метаданные записи, применяет
  /// правки из веба и отличает «уже в облаке» от «надо выгрузить». Строка состояния,
  /// записанная по пустому id, означала бы файл, которого в облаке не найти, и потерялась бы
  /// навсегда. Такой ответ сервера — отказ, а не успех.
  UploadResult _done(String entryId, String sha256, {required bool deduped}) {
    if (entryId.isEmpty) {
      throw const SyncApiException(
        0,
        '',
        'сервер не назвал запись в облаке, хотя выгрузка завершена',
      );
    }
    return UploadResult(entryId: entryId, sha256: sha256, deduped: deduped);
  }
}
