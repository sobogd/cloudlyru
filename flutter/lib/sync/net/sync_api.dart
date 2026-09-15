import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../device/hasher.dart';

/// Ошибка сервера с кодом из тела ответа (409 stale_version, 429 и т.п.).
class SyncApiException implements Exception {
  const SyncApiException(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Прямой путь до хранилища не работает: presigned-ссылка не отвечает (сеть, VPN,
/// блокировщик) или сервер их вовсе не выдаёт.
///
/// Наследник [IOException] намеренно: для вызывающих это «попробовать иначе» (релеем через
/// сервер), а не «сервер сказал „нет“, повторять бессмысленно». Смешать эти случаи нельзя —
/// иначе либо лишний релей на каждую ошибку, либо вечное упрямство с мёртвым хостом.
class SyncDirectUnavailable implements IOException {
  const SyncDirectUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Запись в облаке в том виде, в каком её видит зеркало.
class RemoteEntry {
  const RemoteEntry({
    required this.id,
    required this.name,
    required this.size,
    required this.mime,
    required this.sha256,
    this.clientMtime,
    this.folderId,
  });

  final String id;
  final String name;
  final int size;
  final String mime;
  final String sha256;
  final int? clientMtime;

  /// Папка, в которой лежит запись — нужна для сопоставления при зеркале вниз.
  final String? folderId;
}

/// Содержимое папки: подпапки (имя → id) и записи.
class FolderChildren {
  const FolderChildren(this.folderIds, this.entries);

  final Map<String, String> folderIds;
  final List<RemoteEntry> entries;
}

/// Строка журнала изменений. Журнал append-only: клиент держит курсор по `seq` и применяет
/// строки по порядку, а снимок в строке избавляет от запросов за деталями.
class CloudChange {
  const CloudChange({
    required this.seq,
    required this.target,
    required this.op,
    required this.targetId,
    required this.name,
    required this.size,
    this.folderId,
    this.sha256,
    this.mime,
    this.clientMtime,
    this.deviceId,
  });

  final int seq;

  /// entry | folder
  final String target;

  /// create | update | move | delete | restore (в старых строках встречается pin)
  final String op;
  final String targetId;

  /// родительская папка цели на момент события: по ней правка находится в зеркале
  final String? folderId;
  final String name;
  final String? sha256;
  final int size;
  final String? mime;
  final int? clientMtime;

  /// какое устройство сделало изменение; null — изменение из веба или от сервера
  final String? deviceId;
}

/// Страница журнала: `hasMore` — догонять сразу, не дожидаясь следующего прохода.
class ChangesPage {
  const ChangesPage({
    required this.nextSeq,
    required this.hasMore,
    required this.resetRequired,
    required this.changes,
  });

  final int nextSeq;
  final bool hasMore;

  /// Курсор старше журнала (или впереди него): нужен полный проход по содержимому папки.
  final bool resetRequired;
  final List<CloudChange> changes;
}

/// Свои данные и системные папки: зеркалу нужен корень этого устройства и его id в журнале.
class MeInfo {
  const MeInfo({
    required this.login,
    this.photoFolderId,
    this.phoneFolderId,
    this.mirrorFolderId,
    this.deviceId,
  });

  final String login;
  final String? photoFolderId;
  final String? phoneFolderId;
  final String? mirrorFolderId;
  final String? deviceId;
}

/// Что вернул сервер на попытку начать загрузку.
class SyncUploadInit {
  const SyncUploadInit({
    this.entryId = '',
    this.uploadId,
    this.deduped = false,
    this.direct = false,
    this.partSize = 16 * 1024 * 1024,
    this.nextPart = 1,
    this.stale = false,
    this.inTrash = false,
    this.nameTaken = false,
  });

  final String entryId;
  final String? uploadId;
  final bool deduped;
  final bool direct;
  final int partSize;
  final int nextPart;

  /// 409 stale_version: на сервере другая версия — клиент делает конфликтную копию.
  final bool stale;

  /// 409 in_trash: имя занято записью из корзины — сами не воскрешаем.
  final bool inTrash;

  /// 409 «имя уже существует»: запись есть, движок сверит хэш и решит.
  final bool nameTaken;
}

/// Ответ GET /uploads/:id — с какой части продолжать и каким способом лить дальше.
class SyncUploadStatus {
  const SyncUploadStatus(this.nextPart, this.partSize, this.direct);

  final int nextPart;
  final int partSize;
  final bool direct;
}

/// Клиент REST API облака для синхронизации. Авторизация — device-токен в Bearer: корень
/// зеркала сервер заводит именно устройству, а веб-сессия его не получает вовсе.
///
/// Отдельный клиент, а не общий [CloudlyApi], намеренно: сессионная cookie в запросе
/// перебивает токен (гард проверяет её первой), и вместе с ней `deviceId` в ответе был бы
/// пустым — зеркало осталось бы без своего корня.
class SyncApi {
  SyncApi({required String serverUrl, required this.token})
    : serverUrl = _normalize(serverUrl) {
    // Пустой адрес — не «странный URL» от Dio, а понятная причина: синхронизации некуда ходить
    if (this.serverUrl.isEmpty) {
      throw StateError('не задан адрес сервера');
    }
    // Подстановка именно через `${…}`: `$this.serverUrl` Dart читает как «объект целиком»,
    // и адресом становится «Instance of 'SyncApi'.serverUrl» — Dio такое отвергает.
    _http = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 60),
        sendTimeout: const Duration(seconds: 120),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      ),
    );
    // Свой клиент без Authorization: ссылка уже подписана, лишние заголовки ломают подпись
    _s3 = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 300),
        sendTimeout: const Duration(seconds: 300),
      ),
    );
  }

  final String serverUrl;
  final String token;

  late final Dio _http;
  late final Dio _s3;

  /// Базовый адрес API: один на все запросы. Вынесен в поле, чтобы его можно было проверить
  /// тестом — ошибка в нём роняет всю синхронизацию разом, а видно её только на телефоне.
  String get baseUrl => '$serverUrl/api/v1';

  static String _normalize(String u) => u.trim().replaceAll(RegExp(r'/+$'), '');

  /// Проверка токена и адреса сервера: заодно отдаёт корень зеркала этого устройства.
  Future<MeInfo> meInfo() async {
    final o = _m(await _req('/auth/me'));
    return MeInfo(
      login: '${o['login'] ?? ''}',
      photoFolderId: _sOrNull(o['photoFolderId']),
      phoneFolderId: _sOrNull(o['phoneFolderId']),
      mirrorFolderId: _sOrNull(o['mirrorFolderId']),
      deviceId: _sOrNull(o['deviceId']),
    );
  }

  /// Только системные папки: очередь наполняется и без корня зеркала.
  Future<MeInfo> systemFolders() => meInfo();

  /// Отозвать токен, которым пришёл запрос. Нужно при выходе: без этого серверный токен
  /// остаётся живым до истечения срока и даёт полный доступ к облаку.
  Future<void> revokeOwnToken() => _req('/auth/me/token', method: 'DELETE');

  /// Текущая голова журнала. Нужна, чтобы включить зеркало «с этого момента».
  Future<int> syncHead() async => _toInt(_m(await _req('/sync/head'))['seq']);

  /// Изменения дерева после курсора: клиент применяет их по порядку и двигает курсор.
  Future<ChangesPage> changes(int since, {int limit = 200}) async {
    final o = _m(await _req('/sync/changes?since=$since&limit=$limit'));
    final raw = (o['changes'] as List?) ?? const [];
    return ChangesPage(
      nextSeq: _toInt(o['nextSeq'], fallback: since),
      hasMore: o['hasMore'] == true,
      resetRequired: o['resetRequired'] == true,
      changes: raw.whereType<Map>().map((c) {
        final m = c.cast<String, dynamic>();
        return CloudChange(
          seq: _toInt(m['seq']),
          target: '${m['target'] ?? ''}',
          op: '${m['op'] ?? ''}',
          targetId: '${m['targetId'] ?? ''}',
          folderId: _sOrNull(m['folderId']),
          name: '${m['name'] ?? ''}',
          sha256: _sOrNull(m['sha256']),
          size: _toInt(m['size']),
          mime: _sOrNull(m['mime']),
          clientMtime: _isoOrNull(m['clientMtime']),
          deviceId: _sOrNull(m['deviceId']),
        );
      }).toList(),
    );
  }

  /// Идемпотентный mkdir: возвращает id папки по пути от корня.
  Future<String> ensurePath(String path, String? parentId) async {
    final j = _m(
      await _req(
        '/folders/ensure-path',
        method: 'POST',
        body: {'path': path, 'parentId': ?parentId},
      ),
    );
    return '${j['id'] ?? ''}';
  }

  /// Метаданные папки: имя.
  Future<String> folderMeta(String folderId) async =>
      '${_m(await _req('/folders/$folderId/meta'))['name'] ?? ''}';

  /// Содержимое папки одной страницей: сервер отдаёт порциями по 1000 записей.
  Future<(FolderChildren, String?)> _childrenPage(
    String folderId,
    String? after,
  ) async {
    final suffix = (after == null || after.isEmpty)
        ? ''
        : '?after=${Uri.encodeQueryComponent(after)}';
    final o = _m(await _req('/folders/$folderId/children$suffix'));
    final folders = <String, String>{};
    for (final f in ((o['folders'] as List?) ?? const []).whereType<Map>()) {
      folders['${f['name']}'] = '${f['id']}';
    }
    final entries = ((o['entries'] as List?) ?? const []).whereType<Map>().map((
      e,
    ) {
      return RemoteEntry(
        id: '${e['id']}',
        name: '${e['name']}',
        size: _toInt(e['size']),
        mime: '${e['mime'] ?? ''}',
        sha256: '${e['sha256'] ?? ''}',
        clientMtime: _isoOrNull(e['clientMtime']),
      );
    }).toList();
    final next = o['hasMore'] == true ? _sOrNull(o['nextAfter']) : null;
    return (FolderChildren(folders, entries), next);
  }

  /// Всё содержимое папки, с обходом страниц: большая папка приходит порциями,
  /// и без этого зеркало видело бы только первую тысячу записей.
  Future<FolderChildren> children(String folderId) async {
    final folders = <String, String>{};
    final entries = <RemoteEntry>[];
    String? after;
    var guard = 0;
    while (guard++ < 1000) {
      final (page, next) = await _childrenPage(folderId, after);
      folders.addAll(page.folderIds);
      entries.addAll(page.entries);
      if (next == null) break;
      after = next;
    }
    return FolderChildren(folders, entries);
  }

  /// Метаданные файла: имя, размер, тип, хэш.
  Future<RemoteEntry> entryMeta(String entryId) async {
    final e = _m(await _req('/files/$entryId'));
    return RemoteEntry(
      id: '${e['id']}',
      name: '${e['name']}',
      size: _toInt(e['size']),
      mime: '${e['mime'] ?? ''}',
      sha256: '${e['sha256'] ?? ''}',
      clientMtime: _isoOrNull(e['clientMtime']),
      folderId: _sOrNull(e['folderId']),
    );
  }

  /// Начать загрузку. `expectedSha256` — оптимистичная блокировка: сервер откажет (409
  /// stale_version), если на его стороне уже другая версия файла.
  Future<SyncUploadInit> initUpload({
    required String folderId,
    required String name,
    required int size,
    required String mime,
    required String? sha256,
    required bool replace,
    required int clientMtime,
    String? expectedSha256,
    String mode = 'direct',
    bool replaceTrashed = false,
  }) async {
    final body = <String, dynamic>{
      'folderId': folderId,
      'name': name,
      'size': size,
      'mime': mime,
      'mode': mode,
      'replace': replace,
      'clientMtime': isoOf(clientMtime),
      'sha256': ?sha256,
      if (replace && expectedSha256 != null) 'expectedSha256': expectedSha256,
      if (replaceTrashed) 'replaceTrashed': true,
    };
    try {
      final o = _m(await _req('/uploads', method: 'POST', body: body));
      return SyncUploadInit(
        entryId: _sOrNull((o['entry'] as Map?)?['id']) ?? '',
        uploadId: _sOrNull(o['uploadId']),
        deduped: o['deduped'] == true,
        direct: o['direct'] == true,
        partSize: _toInt(o['partSize'], fallback: 16 * 1024 * 1024),
        nextPart: _toInt(o['nextPart'], fallback: 1),
      );
    } on SyncApiException catch (e) {
      if (e.status != 409) rethrow;
      // 409 бывает трёх видов: расхождение версий, имя в корзине, имя просто занято
      return SyncUploadInit(
        stale: e.code == 'stale_version',
        inTrash: e.code == 'in_trash',
        nameTaken: e.code != 'stale_version' && e.code != 'in_trash',
      );
    }
  }

  /// Состояние сессии: с какой части продолжать после обрыва и каким способом лить.
  Future<SyncUploadStatus> uploadStatus(String uploadId) async {
    final o = _m(await _req('/uploads/$uploadId'));
    return SyncUploadStatus(
      _toInt(o['nextPart'], fallback: 1),
      _toInt(o['partSize'], fallback: 16 * 1024 * 1024),
      o['direct'] != false,
    );
  }

  Future<String> partUrl(String uploadId, int part) async {
    try {
      final url =
          '${_m(await _req('/uploads/$uploadId/url/$part'))['url'] ?? ''}';
      if (url.isEmpty) {
        throw const SyncDirectUnavailable('сервер не выдал ссылку на часть');
      }
      return url;
    } on SyncApiException catch (e) {
      if (e.status == 404 || e.status == 405) {
        throw const SyncDirectUnavailable(
          'сервер не поддерживает прямую загрузку',
        );
      }
      rethrow;
    }
  }

  Future<void> registerPart(String uploadId, int part, String etag, int size) =>
      _req(
        '/uploads/$uploadId/parts/$part',
        method: 'PUT',
        body: {'etag': etag, 'size': size},
      );

  /// Заливка части через сервер: нужно, когда хранилище с телефона недоступно.
  Future<void> relayChunk(String uploadId, int part, Uint8List bytes) async {
    try {
      await _http.put(
        '/uploads/$uploadId/chunks/$part',
        data: bytes,
        options: Options(
          contentType: 'application/octet-stream',
          responseType: ResponseType.plain,
        ),
      );
    } on DioException catch (e) {
      throw _toException(e);
    }
  }

  Future<String> complete(String uploadId, String sha256) async {
    final o = _m(
      await _req(
        '/uploads/$uploadId/complete',
        method: 'POST',
        body: {'sha256': sha256},
      ),
    );
    return _sOrNull((o['entry'] as Map?)?['id']) ?? '';
  }

  Future<void> abort(String uploadId) async {
    try {
      await _http.delete('/uploads/$uploadId');
    } catch (_) {}
  }

  /// Заливка одной части напрямую в хранилище по presigned-ссылке.
  Future<String> putPartToS3(String presignedUrl, Uint8List bytes) async {
    final host = Uri.tryParse(presignedUrl)?.host ?? 'S3';
    try {
      final res = await _s3.put<List<int>>(
        presignedUrl,
        data: bytes,
        options: Options(
          contentType: 'application/octet-stream',
          responseType: ResponseType.plain,
        ),
      );
      final etag = res.headers.value('etag');
      if (etag == null || etag.isEmpty) {
        throw SyncDirectUnavailable('$host не отдал ETag');
      }
      return etag.replaceAll('"', '');
    } on DioException catch (e) {
      // в сообщении должно быть видно, какой именно хост не отвечает
      throw SyncDirectUnavailable('$host: ${e.message ?? 'ошибка сети'}');
    }
  }

  Future<void> deleteFile(String entryId) =>
      _req('/files/$entryId', method: 'DELETE');

  Future<void> moveFile(String entryId, String folderId, String name) => _req(
    '/files/$entryId',
    method: 'PATCH',
    body: {'folderId': folderId, 'name': name},
  );

  /// Переименование без переноса: сервер считает это отдельной операцией.
  Future<void> renameFile(String entryId, String name) =>
      _req('/files/$entryId', method: 'PATCH', body: {'name': name});

  Future<void> deleteFolder(String folderId) =>
      _req('/folders/$folderId', method: 'DELETE');

  Future<void> renameFolder(String folderId, String name) =>
      _req('/folders/$folderId', method: 'PATCH', body: {'name': name});

  /// Скачивание записи в файл с докачкой: оборвавшийся на середине файл не начинается заново.
  /// Пишем во временное имя рядом и переименовываем только после успеха — иначе сканирование
  /// подхватило бы недописанный файл. `expectedSha256` приходит из журнала: если содержимое
  /// не сошлось, файл не оставляем.
  Future<void> downloadToFile(
    String entryId,
    File dest, {
    String? expectedSha256,
  }) async {
    final tmp = File(
      p.join(dest.parent.path, '.${p.basename(dest.path)}.cloudly-tmp'),
    );
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final from = await tmp.exists() ? await tmp.length() : 0;
        await _downloadInto(entryId, tmp, from);
        if (expectedSha256 != null && expectedSha256.isNotEmpty) {
          final have = await Hasher.sha256(tmp);
          if (have.toLowerCase() != expectedSha256.toLowerCase()) {
            // огрызок с чужим содержимым копить нельзя: следующая попытка начнётся с нуля,
            // иначе к нему приклеится ещё кусок и файл так и останется испорченным
            await tmp.delete();
            throw const FileSystemException(
              'содержимое не сошлось с хэшем из журнала',
            );
          }
        }
        // прежний файл не удаляем, а уводим в сторону: если переименование не удастся,
        // на месте останется рабочая версия, а не пустота (иначе зеркало сочло бы файл
        // удалённым и унесло бы облачную копию в корзину)
        final backup = File(
          p.join(dest.parent.path, '${p.basename(dest.path)}.cloudly-old'),
        );
        if (await dest.exists()) {
          if (await backup.exists()) await backup.delete();
          await dest.rename(backup.path);
        }
        try {
          await tmp.rename(dest.path);
        } catch (_) {
          if (await backup.exists()) await backup.rename(dest.path);
          rethrow;
        }
        if (await backup.exists()) await backup.delete();
        return;
      } catch (e) {
        lastError = e;
        if (e is SyncApiException && e.status < 500) break;
        await Future<void>.delayed(Duration(milliseconds: 700 * (attempt + 1)));
      }
    }
    if (await tmp.exists()) {
      try {
        await tmp.delete();
      } catch (_) {}
    }
    throw lastError ?? const FileSystemException('скачивание не удалось');
  }

  /// Скачивание с докачкой: `from` — с какого байта продолжать (сервер умеет Range).
  Future<void> _downloadInto(String entryId, File target, int from) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(minutes: 5);
    try {
      final req = await client.getUrl(
        Uri.parse('$serverUrl/api/v1/files/$entryId/content'),
      );
      req.headers.set('Authorization', 'Bearer $token');
      req.headers.set('Accept-Encoding', 'identity');
      if (from > 0) req.headers.set('Range', 'bytes=$from-');
      final res = await req.close();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw SyncApiException(res.statusCode, '', 'HTTP ${res.statusCode}');
      }
      // 206 — сервер продолжил с запрошенного места. Если он ответил 200, значит Range
      // проигнорирован и пришло всё содержимое: дописывать его к огрызку нельзя, пишем заново.
      final resumed = from > 0 && res.statusCode == 206;
      final sink = target.openWrite(
        mode: resumed ? FileMode.append : FileMode.write,
      );
      try {
        await res.forEach(sink.add);
      } finally {
        await sink.flush();
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
  }

  // ---------- внутреннее ----------

  Future<dynamic> _req(
    String path, {
    String method = 'GET',
    Object? body,
  }) async {
    try {
      final res = await _http.request<dynamic>(
        path,
        data: body,
        options: Options(method: method),
      );
      return res.data;
    } on DioException catch (e) {
      throw _toException(e);
    }
  }

  SyncApiException _toException(DioException e) {
    final status = e.response?.statusCode ?? 0;
    var code = '';
    var message = 'HTTP $status';
    final data = e.response?.data;
    if (data is Map) {
      message = '${data['message'] ?? message}';
      code = '${data['code'] ?? ''}';
    } else if (data is String && data.isNotEmpty) {
      try {
        final obj = json.decode(data);
        if (obj is Map) {
          message = '${obj['message'] ?? message}';
          code = '${obj['code'] ?? ''}';
        }
      } catch (_) {
        message = data;
      }
    }
    if (e.response == null) {
      message = switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => 'не дождался ответа сервера',
        DioExceptionType.connectionError => 'нет соединения с сервером',
        _ => e.message ?? 'ошибка сети',
      };
    }
    return SyncApiException(status, code, message);
  }

  static Map<String, dynamic> _m(dynamic d) =>
      d is Map ? d.cast<String, dynamic>() : <String, dynamic>{};

  /// В JSON null и пустая строка значат одно и то же: id нет.
  static String? _sOrNull(dynamic v) {
    if (v == null) return null;
    final s = '$v';
    return s.isEmpty || s == 'null' ? null : s;
  }

  /// `seq` сервер отдаёт строкой: без приведения курсор молча сделался бы нулём.
  static int _toInt(dynamic v, {int fallback = 0}) {
    if (v == null) return fallback;
    if (v is int) return v;
    return int.tryParse('$v') ?? fallback;
  }

  /// ISO-8601 из сервера → миллисекунды (для сравнения с локальным mtime).
  static int? _isoOrNull(dynamic v) {
    final s = _sOrNull(v);
    if (s == null) return null;
    return DateTime.tryParse(s)?.millisecondsSinceEpoch;
  }
}

/// ISO-8601 из миллисекунд: сервер ждёт дату файла в этом виде.
String isoOf(int millis) =>
    DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toIso8601String();
