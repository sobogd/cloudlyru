/// REST-клиент облака — порт `web/src/api.ts` + токен-вход как у нативного клиента.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'models.dart';

class ApiException implements Exception {
  final int status;
  final String code;
  final String message;
  ApiException(this.status, this.code, this.message);
  @override
  String toString() => message;
}

class DirectUnavailable implements Exception {
  final String message;
  DirectUnavailable(this.message);
  @override
  String toString() => message;
}

class UploadResult {
  final String entryId;
  final bool deduped;
  UploadResult(this.entryId, this.deduped);
}

class UploadInit {
  final String? uploadId;
  final bool deduped;
  final bool direct;
  final int partSize;
  final String? entryId;

  UploadInit({this.uploadId, required this.deduped, required this.direct, required this.partSize, this.entryId});
}

/// Ловит итоговый [Digest] стримингового хеширования.
class _DigestSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest d) => digest = d;
  @override
  void close() {}
}

class CloudlyApi {
  String serverUrl;

  /// Cookie веб-сессии (`cl_session=…`). Приложение — порт веб-клиента, поэтому ходит
  /// той же сессией: ручки с @SessionOnly (почта: accounts/sync/status/send) принимают
  /// только её, device-токену они отвечают 403.
  String? session;

  late final Dio _http;
  late final Dio _session;
  late final Dio _s3;

  CloudlyApi({required this.serverUrl, this.session}) {
    final base = '${_normalize(serverUrl)}/api/v1';
    _http = Dio(BaseOptions(
      baseUrl: base,
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 120),
    ));
    _http.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      final s = session;
      if (s != null && s.isNotEmpty) o.headers['Cookie'] = s;
      o.headers['Accept'] = 'application/json';
      h.next(o);
    }));
    _session = Dio(BaseOptions(
      baseUrl: base,
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30),
    ));
    _s3 = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 300),
      receiveTimeout: const Duration(seconds: 300),
    ));
  }

  static String _normalize(String u) => u.trim().replaceAll(RegExp(r'/+$'), '');

  Map<String, String> get authHeaders {
    final s = session;
    return (s != null && s.isNotEmpty) ? {'Cookie': s} : const {};
  }

  /// Абсолютный URL для картинок/видео (превью требуют авторизации).
  String url(String path) => '${_normalize(serverUrl)}/api/v1$path';

  String get baseUrl => '${_normalize(serverUrl)}/api/v1';

  // ---------- базовые запросы ----------

  Future<dynamic> _req(String path, {String method = 'GET', Object? body}) async {
    try {
      final res = await _http.request<dynamic>(path, data: body, options: Options(method: method));
      return res.data;
    } on DioException catch (e) {
      throw _toException(e);
    }
  }

  ApiException _toException(DioException e) {
    final status = e.response?.statusCode ?? 0;
    var code = '';
    var message = 'HTTP $status';
    final data = e.response?.data;
    if (data is Map) {
      message = (data['message'] as String?) ?? message;
      code = (data['code'] as String?) ?? '';
    } else if (data is String) {
      try {
        final obj = json.decode(data);
        if (obj is Map) {
          message = (obj['message'] as String?) ?? message;
          code = (obj['code'] as String?) ?? '';
        }
      } catch (_) {
        if (data.isNotEmpty) message = data;
      }
    }
    if (e.response == null) {
      message = _netMessage(e);
    }
    return ApiException(status, code, message);
  }

  String _netMessage(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'не дождался ответа сервера';
      case DioExceptionType.connectionError:
        return 'нет соединения с сервером (${e.message ?? ''})';
      default:
        return e.message ?? 'ошибка сети';
    }
  }

  static Map<String, dynamic> _m(dynamic d) =>
      d is Map ? d.cast<String, dynamic>() : <String, dynamic>{};
  static List<Map<String, dynamic>> _lm(dynamic d) => d is List
      ? d.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
      : <Map<String, dynamic>>[];

  // ---------- авторизация ----------

  /// Вход логином/паролем. Возвращает cookie веб-сессии — дальше приложение ходит ею,
  /// как веб-клиент (ручки с @SessionOnly иначе отвечают 403). Пароль не сохраняется.
  Future<String> login(String login, String password) async {
    final res = await _session.post('/auth/login',
        data: {'login': login, 'password': password},
        options: Options(responseType: ResponseType.plain));
    final cookie = (res.headers['set-cookie'] ?? const <String>[])
        .map((c) => c.split(';').first)
        .where((c) => c.isNotEmpty)
        .join('; ');
    if (cookie.isEmpty) throw ApiException(0, '', 'сервер не выдал сессию');
    return cookie;
  }

  Future<UserInfo> me() async => UserInfo.fromJson(_m(await _req('/auth/me')));

  /// Выход: гасит веб-сессию на сервере.
  Future<void> logout() async {
    await _req('/auth/logout', method: 'POST');
  }

  /// Последняя опубликованная сборка (ручка без авторизации — обновление должно
  /// работать и с отозванным токеном).
  Future<AppRelease> latestApp() async =>
      AppRelease.fromJson(_m(await _req('/app/android')));

  Future<List<ApiTokenRow>> listTokens() async =>
      _lm(await _req('/auth/tokens')).map(ApiTokenRow.fromJson).toList();

  Future<Map<String, dynamic>> createToken(String label) async =>
      _m(await _req('/auth/tokens', method: 'POST', body: {'label': label}));

  Future<void> revokeToken(String id) async {
    await _req('/auth/tokens/$id', method: 'DELETE');
  }

  // ---------- папки/файлы ----------

  Future<FolderView> listFolder(String? parentId) async => FolderView.fromJson(_m(
      await _req(parentId == null ? '/folders' : '/folders/$parentId/children')));

  Future<String> mkdir(String name, String? parentId) async {
    final j = _m(await _req('/folders',
        method: 'POST', body: {'name': name, if (parentId != null) 'parentId': parentId}));
    return j['id'] as String? ?? '';
  }

  Future<void> renameFolder(String id, String name) async {
    await _req('/folders/$id', method: 'PATCH', body: {'name': name});
  }

  Future<void> renameFile(String id, String name) async {
    await _req('/files/$id', method: 'PATCH', body: {'name': name});
  }

  Future<void> deleteFolder(String id) async => _req('/folders/$id', method: 'DELETE');

  Future<void> deleteFile(String id) async => _req('/files/$id', method: 'DELETE');

  Future<FileMeta> fileMeta(String id) async =>
      FileMeta.fromJson(_m(await _req('/files/$id')));

  Future<FolderMeta> folderMeta(String id) async =>
      FolderMeta.fromJson(_m(await _req('/folders/$id/meta')));

  // ---------- буфер ----------

  Future<ClipboardView?> clipboard() async {
    final d = await _req('/clipboard');
    if (d == null) return null;
    return ClipboardView.fromJson(_m(d));
  }

  Future<void> setClipboard(String kind, String id, String mode) async {
    await _req('/clipboard', method: 'POST', body: {'kind': kind, 'id': id, 'mode': mode});
  }

  Future<void> clearClipboard() async => _req('/clipboard', method: 'DELETE');

  Future<Map<String, dynamic>> pasteClipboard(String folderId) async =>
      _m(await _req('/clipboard/paste', method: 'POST', body: {'folderId': folderId}));

  // ---------- корзина ----------

  Future<TrashView> trash() async => TrashView.fromJson(_m(await _req('/trash')));

  Future<void> restoreItem(String kind, String id) async =>
      _req('/trash/restore', method: 'POST', body: {'type': kind, 'id': id});

  Future<void> purgeTrash() async => _req('/trash/purge', method: 'POST', body: {});

  // ---------- медиа ----------

  Future<int> mediaCount() async => toNum(await _req('/media/count'))?.toInt() ?? 0;

  Future<List<MediaItem>> mediaRange(int offset, int limit) async =>
      _lm(await _req('/media/range?offset=$offset&limit=$limit')).map(MediaItem.fromJson).toList();

  Future<List<MediaMonthBucket>> mediaMonths() async =>
      _lm(await _req('/media/months')).map(MediaMonthBucket.fromJson).toList();

  Future<List<MediaStatusItem>> mediaStatus(List<String> entryIds) async =>
      _lm(await _req('/media/status', method: 'POST', body: {'entryIds': entryIds}))
          .map(MediaStatusItem.fromJson)
          .toList();

  Future<MediaInfo> mediaInfo(String entryId) async =>
      MediaInfo.fromJson(_m(await _req('/media/${Uri.encodeComponent(entryId)}')));

  Future<Map<String, dynamic>> mediaMap() async => _m(await _req('/media/map'));

  // ---------- альбомы ----------

  Future<List<AlbumInfo>> listAlbums() async =>
      _lm(await _req('/albums')).map(AlbumInfo.fromJson).toList();

  Future<AlbumView> getAlbum(String id) async =>
      AlbumView.fromJson(_m(await _req('/albums/$id')));

  Future<AlbumInfo> createAlbum(String name) async =>
      AlbumInfo.fromJson(_m(await _req('/albums', method: 'POST', body: {'name': name})));

  Future<void> deleteAlbum(String id) async => _req('/albums/$id', method: 'DELETE');

  // ---------- очередь превью ----------

  Future<QueueStatus> queueStatus() async =>
      QueueStatus.fromJson(_m(await _req('/queue/status')));

  Future<void> retryPreview(String entryId) async =>
      _req('/queue/retry', method: 'POST', body: {'entryId': entryId});

  Future<Map<String, dynamic>> rebuildPreviews() async =>
      _m(await _req('/queue/rebuild', method: 'POST', body: {}));

  Future<Map<String, dynamic>> clearQueue() async =>
      _m(await _req('/queue/clear', method: 'POST', body: {}));

  Future<void> setQueuePaused(bool paused) async =>
      _req('/queue/pause', method: 'POST', body: {'paused': paused});

  Future<Map<String, dynamic>> queueErrors({int limit = 50, int offset = 0}) async =>
      _m(await _req('/queue/errors?limit=$limit&offset=$offset'));

  Future<Map<String, dynamic>> retryQueueErrors() async =>
      _m(await _req('/queue/errors/retry', method: 'POST', body: {}));

  // ---------- разархивирование ----------

  Future<UnzipJob> startUnzip(String entryId) async =>
      UnzipJob.fromJson(_m(await _req('/unzip', method: 'POST', body: {'entryId': entryId})));

  Future<UnzipJob> unzipStatus(String id) async =>
      UnzipJob.fromJson(_m(await _req('/unzip/$id')));

  Future<UnzipJob?> latestUnzip(String entryId) async {
    final d = await _req('/unzip?entryId=${Uri.encodeComponent(entryId)}');
    if (d == null) return null;
    return UnzipJob.fromJson(_m(d));
  }

  Future<UnzipJob> cancelUnzip(String id) async =>
      UnzipJob.fromJson(_m(await _req('/unzip/$id/cancel', method: 'POST')));

  // ---------- почта ----------

  Future<List<MailAccountRow>> mailAccounts() async =>
      _lm(await _req('/mail/accounts')).map(MailAccountRow.fromJson).toList();

  Future<Map<String, dynamic>> mailSync() async =>
      _m(await _req('/mail/sync', method: 'POST'));

  Future<MailStatusView> mailStatus() async =>
      MailStatusView.fromJson(_m(await _req('/mail/status')));

  Future<int> mailCount(String box, {String? account}) async {
    final a = (account == null || account.isEmpty) ? '' : '&account=$account';
    return toNum(await _req('/mail/count?box=$box$a'))?.toInt() ?? 0;
  }

  Future<List<MailListItem>> mailRange(String box, int offset, int limit, {String? account}) async {
    final a = (account == null || account.isEmpty) ? '' : '&account=$account';
    return _lm(await _req('/mail/range?box=$box&offset=$offset&limit=$limit$a'))
        .map(MailListItem.fromJson)
        .toList();
  }

  Future<List<MailMonthBucket>> mailMonths(String box, {String? account}) async {
    final a = (account == null || account.isEmpty) ? '' : '&account=$account';
    return _lm(await _req('/mail/months?box=$box$a')).map(MailMonthBucket.fromJson).toList();
  }

  Future<MailMessageView> mailMessage(String id) async =>
      MailMessageView.fromJson(_m(await _req('/mail/messages/$id')));

  Future<Map<String, dynamic>> mailBody(String id, bool images) async =>
      _m(await _req('/mail/messages/$id/body${images ? '?images=1' : ''}'));

  Future<void> mailSetSeen(String id, bool seen) async =>
      _req('/mail/messages/$id/seen', method: 'POST', body: {'seen': seen});

  Future<void> mailDelete(String id) async => _req('/mail/messages/$id', method: 'DELETE');

  Future<Map<String, dynamic>> mailSend(Map<String, dynamic> body) async =>
      _m(await _req('/mail/send', method: 'POST', body: body));

  Future<MailReplyContext> mailReplyContext(String id, String mode) async =>
      MailReplyContext.fromJson(_m(await _req('/mail/messages/$id/reply-context?mode=$mode')));

  Future<void> mailRestore(String id) async =>
      _req('/mail/messages/$id/restore', method: 'POST', body: {});

  Future<void> mailPurgeMessage(String id) async =>
      _req('/mail/messages/$id/purge', method: 'POST', body: {});

  Future<Map<String, dynamic>> mailPurgeTrash() async =>
      _m(await _req('/mail/trash/purge', method: 'POST', body: {}));

  // ---------- URL превью/скачивания ----------

  String fileUrl(String id) => '${baseUrl}/files/$id/content';
  String fileInlineUrl(String id) => '${baseUrl}/files/$id/inline';
  String thumbUrl(String entryId) => '${baseUrl}/files/$entryId/thumb';
  String previewUrl(String sha, {int w = 512}) => '${baseUrl}/previews/$sha?w=$w';
  String pdfPageUrl(String sha, int page) => '${baseUrl}/previews/$sha?page=$page';
  String videoPreviewUrl(String sha, {bool original = false}) =>
      '${baseUrl}/video-preview/$sha${original ? '?src=original' : ''}';
  String faviconUrl(String domain) =>
      '${baseUrl}/mail/favicon?domain=${Uri.encodeComponent(domain)}';
  String mailRawUrl(String id) => '${baseUrl}/mail/messages/$id/raw';

  // ---------- загрузка ----------

  static const int _chunkBytes = 5 * 1024 * 1024;
  static const int _hashChunkBytes = 8 * 1024 * 1024;
  static const int _partAttempts = 3;

  String guessMime(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const map = {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif',
      'webp': 'image/webp', 'heic': 'image/heic', 'heif': 'image/heif', 'tif': 'image/tiff',
      'tiff': 'image/tiff', 'mp4': 'video/mp4', 'mov': 'video/quicktime', 'm4v': 'video/x-m4v',
      'webm': 'video/webm', 'mkv': 'video/x-matroska', 'avi': 'video/avi', '3gp': 'video/3gpp',
      'ogv': 'video/ogg', 'pdf': 'application/pdf', 'txt': 'text/plain', 'zip': 'application/zip',
    };
    return map[ext] ?? 'application/octet-stream';
  }

  Future<String> hashFile(String path, {void Function(int pct)? onProgress}) async {
    final f = File(path);
    final len = await f.length();
    final raf = await f.open();
    final out = _DigestSink();
    final sink = sha256.startChunkedConversion(out);
    try {
      var off = 0;
      while (off < len) {
        final want = math.min(_hashChunkBytes, len - off);
        await raf.setPosition(off);
        final bytes = await raf.read(want);
        if (bytes.isEmpty) break;
        sink.add(bytes);
        off += bytes.length;
        onProgress?.call((off * 100 / len).round());
      }
      sink.close();
      return out.digest?.toString() ?? '';
    } finally {
      await raf.close();
    }
  }

  Future<UploadInit> _initUpload(String name, int size, String mime, String sha256, String mode,
      {String? folderId}) async {
    final d = await _req('/uploads', method: 'POST', body: {
      'name': name,
      'size': size,
      'mime': mime,
      'sha256': sha256,
      'mode': mode,
      if (folderId != null) 'folderId': folderId,
    });
    final j = _m(d);
    final deduped = j['deduped'] == true;
    return UploadInit(
      uploadId: j['uploadId'] as String?,
      deduped: deduped,
      direct: j['direct'] == true,
      partSize: toNum(j['partSize'])?.toInt() ?? 16 * 1024 * 1024,
      entryId: _m(j['entry'] ?? const {})['id'] as String?,
    );
  }

  Future<void> _abortUpload(String uploadId) async {
    try {
      await _http.delete('/uploads/$uploadId');
    } catch (_) {}
  }

  Future<String> _presignPart(String uploadId, int part) async {
    try {
      final j = _m(await _req('/uploads/$uploadId/url/$part'));
      return j['url'] as String? ?? '';
    } on ApiException catch (e) {
      if (e.status == 404 || e.status == 405) {
        throw DirectUnavailable('сервер не поддерживает прямую загрузку в S3');
      }
      rethrow;
    }
  }

  Future<String> _putPartDirect(String url, Uint8List bytes,
      {void Function(int loaded)? onBytes}) async {
    try {
      final res = await _s3.put<List<int>>(url, data: bytes,
          options: Options(
            contentType: 'application/octet-stream',
            responseType: ResponseType.plain,
          ),
          onSendProgress: (sent, total) => onBytes?.call(sent));
      final etag = res.headers.value('etag');
      if (etag == null || etag.isEmpty) throw DirectUnavailable('S3 не отдал ETag');
      return etag.replaceAll('"', '');
    } on DirectUnavailable {
      rethrow;
    } on DioException catch (e) {
      throw DirectUnavailable('сеть до S3: ${e.message}');
    } catch (_) {
      throw DirectUnavailable('прямая загрузка в S3 не удалась');
    }
  }

  Future<void> _registerPart(String uploadId, int part, String etag, int size) async {
    await _req('/uploads/$uploadId/parts/$part', method: 'PUT', body: {'etag': etag, 'size': size});
  }

  Future<void> _relayChunk(String uploadId, int part, Uint8List bytes) async {
    try {
      await _http.put('/uploads/$uploadId/chunks/$part',
          data: bytes,
          options: Options(contentType: 'application/octet-stream', responseType: ResponseType.plain));
    } on DioException catch (e) {
      throw _toException(e);
    }
  }

  Future<UploadResult> _complete(String uploadId, String sha256) async {
    final j = _m(await _req('/uploads/$uploadId/complete', method: 'POST', body: {'sha256': sha256}));
    final entry = _m(j['entry'] ?? const {});
    return UploadResult(entry['id'] as String? ?? '', j['deduped'] == true);
  }

  Future<Uint8List> _readRange(String path, int start, int end) async {
    final raf = await File(path).open();
    try {
      await raf.setPosition(start);
      final bytes = await raf.read(end - start);
      return Uint8List.fromList(bytes);
    } finally {
      await raf.close();
    }
  }

  Future<UploadResult> uploadFile(
    String path, {
    String? folderId,
    String? name,
    void Function(int pct, String phase, String? note)? onProgress,
  }) async {
    final fileName = name ?? path.split('/').last;
    final mime = guessMime(fileName);
    final f = File(path);
    final size = await f.length();

    final sha256hex = await hashFile(path, onProgress: (p) => onProgress?.call(p, 'hash', null));
    onProgress?.call(0, 'upload', null);

    var init = await _initUpload(fileName, size, mime, sha256hex, 'direct', folderId: folderId);
    if (init.deduped && init.entryId != null) {
      return UploadResult(init.entryId!, true);
    }
    var uploadId = init.uploadId!;

    try {
      if (init.direct) {
        try {
          await _uploadDirect(path, uploadId, init.partSize, size, onProgress);
        } on DirectUnavailable catch (e) {
          await _abortUpload(uploadId);
          init = await _initUpload(fileName, size, mime, sha256hex, 'relay', folderId: folderId);
          if (init.deduped && init.entryId != null) return UploadResult(init.entryId!, true);
          uploadId = init.uploadId!;
          onProgress?.call(0, 'relay', e.message);
          await _uploadRelay(path, uploadId, size, onProgress);
        }
      } else {
        await _uploadRelay(path, uploadId, size, onProgress);
      }
      onProgress?.call(100, 'verify', null);
      return await _complete(uploadId, sha256hex);
    } catch (e) {
      await _abortUpload(uploadId);
      rethrow;
    }
  }

  Future<void> _uploadDirect(String path, String uploadId, int partSize, int size,
      void Function(int pct, String phase, String? note)? onProgress) async {
    final total = math.max(1, (size / partSize).ceil());
    final loaded = List<int>.filled(total + 1, 0);
    void report(String? note) {
      var sum = 0;
      for (final n in loaded) {
        sum += n;
      }
      onProgress?.call(math.min(100, (sum * 100 / size).floor()), 'upload', note);
    }

    for (var part = 1; part <= total; part++) {
      final start = (part - 1) * partSize;
      final end = math.min(size, start + partSize);
      report('часть $part из $total');
      final url = await _presignPart(uploadId, part);
      final bytes = await _readRange(path, start, end);
      var lastErr = '';
      var ok = false;
      for (var attempt = 1; attempt <= _partAttempts; attempt++) {
        try {
          final etag = await _putPartDirect(url, bytes, onBytes: (n) {
            loaded[part] = n;
            report('часть $part из $total');
          });
          await _registerPart(uploadId, part, etag, bytes.length);
          loaded[part] = bytes.length;
          report('часть $part из $total');
          ok = true;
          break;
        } on DirectUnavailable catch (e) {
          lastErr = e.message;
          if (attempt < _partAttempts) {
            report('$lastErr — повторяю (попытка ${attempt + 1})');
            await Future.delayed(Duration(milliseconds: 700 * attempt));
          }
        }
      }
      if (!ok) throw DirectUnavailable(lastErr.isEmpty ? 'часть $part не загрузилась' : lastErr);
    }
  }

  Future<void> _uploadRelay(String path, String uploadId, int size,
      void Function(int pct, String phase, String? note)? onProgress) async {
    final parts = math.max(1, (size / _chunkBytes).ceil());
    for (var part = 1; part <= parts; part++) {
      final start = (part - 1) * _chunkBytes;
      final end = math.min(size, start + _chunkBytes);
      final bytes = await _readRange(path, start, end);
      await _relayChunk(uploadId, part, bytes);
      onProgress?.call(((part / parts) * 100).round(), 'relay', 'часть $part из $parts');
    }
  }
}
