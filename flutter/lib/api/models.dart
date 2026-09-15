/// Модели API — порт TS-интерфейсов из `web/src/api.ts`.
library;

/// Число из JSON, даже если сервер отдал его строкой (BIGINT из raw-SQL бывает строкой).
num? toNum(Object? v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v);
  return null;
}

bool _toBool(Object? v) => v == true || v == 'true';

extension JsonX on Map<String, dynamic> {
  String s(String k) => (this[k] as String?) ?? '';
  String? sN(String k) => this[k] as String?;
  int i(String k) => toNum(this[k])?.toInt() ?? 0;
  int? iN(String k) => toNum(this[k])?.toInt();
  double d(String k) => toNum(this[k])?.toDouble() ?? 0;
  double? dN(String k) => toNum(this[k])?.toDouble();
  bool b(String k) => _toBool(this[k]);
  bool? bN(String k) => (this[k] as bool?) ?? (_toBool(this[k]) ? true : null);
  Map<String, dynamic>? m(String k) => (this[k] as Map?)?.cast<String, dynamic>();
  List<dynamic>? l(String k) => this[k] as List?;
  List<Map<String, dynamic>> lm(String k) => ((this[k] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => e.cast<String, dynamic>())
      .toList();
  List<String> ls(String k) => ((this[k] as List?) ?? const []).whereType<String>().toList();
}

DateTime? _dt(String? iso) => (iso == null || iso.isEmpty) ? null : DateTime.tryParse(iso);

// ===== auth =====

class UserInfo {
  final String id;
  final String login;
  final String? rootFolderId;
  final String? photoFolderId;
  final String? phoneFolderId;
  final String? mirrorFolderId;
  final String? deviceId;

  UserInfo({
    required this.id,
    required this.login,
    this.rootFolderId,
    this.photoFolderId,
    this.phoneFolderId,
    this.mirrorFolderId,
    this.deviceId,
  });

  factory UserInfo.fromJson(Map<String, dynamic> j) => UserInfo(
        id: j.s('id'),
        login: j.s('login'),
        rootFolderId: j.sN('rootFolderId'),
        photoFolderId: j.sN('photoFolderId'),
        phoneFolderId: j.sN('phoneFolderId'),
        mirrorFolderId: j.sN('mirrorFolderId'),
        deviceId: j.sN('deviceId'),
      );
}

// ===== folders/files =====

class FolderEntry {
  final String id;
  final String name;
  final DateTime? createdAt;
  final int? size;
  final String? mime;

  FolderEntry({required this.id, required this.name, this.createdAt, this.size, this.mime});

  factory FolderEntry.fromJson(Map<String, dynamic> j) => FolderEntry(
        id: j.s('id'),
        name: j.s('name'),
        createdAt: _dt(j.sN('createdAt')),
        size: j.iN('size'),
        mime: j.sN('mime'),
      );
}

class FolderView {
  final String parentId;
  final List<FolderEntry> folders;
  final List<FolderEntry> entries;

  FolderView({required this.parentId, required this.folders, required this.entries});

  factory FolderView.fromJson(Map<String, dynamic> j) => FolderView(
        parentId: j.s('parentId'),
        folders: j.lm('folders').map(FolderEntry.fromJson).toList(),
        entries: j.lm('entries').map(FolderEntry.fromJson).toList(),
      );
}

class FileMedia {
  final String? capturedAt;
  final double? latitude;
  final double? longitude;
  final String? make;
  final String? model;
  final int? width;
  final int? height;
  final Map<String, dynamic>? raw;

  FileMedia({
    this.capturedAt,
    this.latitude,
    this.longitude,
    this.make,
    this.model,
    this.width,
    this.height,
    this.raw,
  });

  factory FileMedia.fromJson(Map<String, dynamic> j) => FileMedia(
        capturedAt: j.sN('capturedAt'),
        latitude: j.dN('latitude'),
        longitude: j.dN('longitude'),
        make: j.sN('make'),
        model: j.sN('model'),
        width: j.iN('width'),
        height: j.iN('height'),
        raw: j.m('raw'),
      );
}

class FileMailOrigin {
  final String id;
  final String? subject;
  final String? fromName;
  final String? fromAddr;
  final String? sortAt;
  final String? box;

  FileMailOrigin({
    required this.id,
    this.subject,
    this.fromName,
    this.fromAddr,
    this.sortAt,
    this.box,
  });

  factory FileMailOrigin.fromJson(Map<String, dynamic> j) => FileMailOrigin(
        id: j.s('id'),
        subject: j.sN('subject'),
        fromName: j.sN('fromName'),
        fromAddr: j.sN('fromAddr'),
        sortAt: j.sN('sortAt'),
        box: j.sN('box'),
      );
}

class FileMeta {
  final String id;
  final String name;
  final String? createdAt;
  final String? folderId;
  final String zone;
  final String path;
  final FileMailOrigin? mail;
  final int size;
  final String mime;
  final String? ext;
  final String sha256;
  final int? pageCount;
  final FileMedia? media;

  FileMeta({
    required this.id,
    required this.name,
    this.createdAt,
    this.folderId,
    required this.zone,
    required this.path,
    this.mail,
    required this.size,
    required this.mime,
    this.ext,
    required this.sha256,
    this.pageCount,
    this.media,
  });

  factory FileMeta.fromJson(Map<String, dynamic> j) => FileMeta(
        id: j.s('id'),
        name: j.s('name'),
        createdAt: j.sN('createdAt'),
        folderId: j.sN('folderId'),
        zone: j.s('zone'),
        path: j.s('path'),
        mail: j.m('mail') == null ? null : FileMailOrigin.fromJson(j.m('mail')!),
        size: j.i('size'),
        mime: j.s('mime'),
        ext: j.sN('ext'),
        sha256: j.s('sha256'),
        pageCount: j.iN('pageCount'),
        media: j.m('media') == null ? null : FileMedia.fromJson(j.m('media')!),
      );
}

// ===== буфер копирования/вырезания =====

class ClipboardView {
  final String kind; // file | folder
  final String mode; // copy | cut
  final String id;
  final String name;
  final bool available;
  final String? at;

  ClipboardView({
    required this.kind,
    required this.mode,
    required this.id,
    required this.name,
    required this.available,
    this.at,
  });

  factory ClipboardView.fromJson(Map<String, dynamic> j) => ClipboardView(
        kind: j.s('kind'),
        mode: j.s('mode'),
        id: j.s('id'),
        name: j.s('name'),
        available: j.b('available'),
        at: j.sN('at'),
      );
}

class FolderMeta {
  final String id;
  final String name;
  final String zone;
  final String path;
  final int folders;
  final int entries;
  final String? createdAt;
  final String? updatedAt;

  FolderMeta({
    required this.id,
    required this.name,
    required this.zone,
    required this.path,
    required this.folders,
    required this.entries,
    this.createdAt,
    this.updatedAt,
  });

  factory FolderMeta.fromJson(Map<String, dynamic> j) => FolderMeta(
        id: j.s('id'),
        name: j.s('name'),
        zone: j.s('zone'),
        path: j.s('path'),
        folders: j.i('folders'),
        entries: j.i('entries'),
        createdAt: j.sN('createdAt'),
        updatedAt: j.sN('updatedAt'),
      );
}

// ===== trash =====

class TrashItem {
  final String id;
  final String name;
  final String? deletedAt;
  final String kind; // folder | file
  final int? size;

  TrashItem({required this.id, required this.name, this.deletedAt, required this.kind, this.size});

  factory TrashItem.fromJson(Map<String, dynamic> j) => TrashItem(
        id: j.s('id'),
        name: j.s('name'),
        deletedAt: j.sN('deletedAt'),
        kind: j.s('kind'),
        size: j.iN('size'),
      );
}

class TrashView {
  final List<TrashItem> folders;
  final List<TrashItem> entries;

  TrashView({required this.folders, required this.entries});

  factory TrashView.fromJson(Map<String, dynamic> j) => TrashView(
        folders: j.lm('folders').map(TrashItem.fromJson).toList(),
        entries: j.lm('entries').map(TrashItem.fromJson).toList(),
      );
}

// ===== app-токены =====

class ApiTokenRow {
  final String id;
  final String label;
  final String scope;
  final String? lastUsedAt;
  final String? createdAt;

  ApiTokenRow({required this.id, required this.label, required this.scope, this.lastUsedAt, this.createdAt});

  factory ApiTokenRow.fromJson(Map<String, dynamic> j) => ApiTokenRow(
        id: j.s('id'),
        label: j.s('label'),
        scope: j.s('scope'),
        lastUsedAt: j.sN('lastUsedAt'),
        createdAt: j.sN('createdAt'),
      );
}

// ===== медиа =====

class MediaItem {
  final String entryId;
  final String name;
  final String? capturedAt;
  final String mime;
  final String? sha256;
  final String previewState;
  final String? jobState;
  final int size;

  MediaItem({
    required this.entryId,
    required this.name,
    this.capturedAt,
    required this.mime,
    this.sha256,
    required this.previewState,
    this.jobState,
    required this.size,
  });

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
        entryId: j.s('entryId'),
        name: j.s('name'),
        capturedAt: j.sN('capturedAt'),
        mime: j.s('mime'),
        sha256: j.sN('sha256'),
        previewState: j.s('previewState'),
        jobState: j.sN('jobState'),
        size: j.i('size'),
      );
}

class MediaMonthBucket {
  final String? month;
  final int count;

  MediaMonthBucket({this.month, required this.count});

  factory MediaMonthBucket.fromJson(Map<String, dynamic> j) =>
      MediaMonthBucket(month: j.sN('month'), count: j.i('count'));
}

class MediaStatusItem {
  final String entryId;
  final String previewState;
  final String? jobState;

  MediaStatusItem({required this.entryId, required this.previewState, this.jobState});

  factory MediaStatusItem.fromJson(Map<String, dynamic> j) => MediaStatusItem(
        entryId: j.s('entryId'),
        previewState: j.s('previewState'),
        jobState: j.sN('jobState'),
      );
}

class MediaInfo {
  final String entryId;
  final String name;
  final String mime;
  final int size;
  final String sha256;
  final String? capturedAt;
  final int? width;
  final int? height;
  final String? make;
  final String? model;
  final double? latitude;
  final double? longitude;
  final String? lens;
  final double? fNumber;
  final String? exposureTime;
  final int? iso;
  final double? focalLength;
  final double? focalLength35;
  final int? durationSec;
  final double? fps;
  final String? videoCodec;

  MediaInfo({
    required this.entryId,
    required this.name,
    required this.mime,
    required this.size,
    required this.sha256,
    this.capturedAt,
    this.width,
    this.height,
    this.make,
    this.model,
    this.latitude,
    this.longitude,
    this.lens,
    this.fNumber,
    this.exposureTime,
    this.iso,
    this.focalLength,
    this.focalLength35,
    this.durationSec,
    this.fps,
    this.videoCodec,
  });

  factory MediaInfo.fromJson(Map<String, dynamic> j) => MediaInfo(
        entryId: j.s('entryId'),
        name: j.s('name'),
        mime: j.s('mime'),
        size: j.i('size'),
        sha256: j.s('sha256'),
        capturedAt: j.sN('capturedAt'),
        width: j.iN('width'),
        height: j.iN('height'),
        make: j.sN('make'),
        model: j.sN('model'),
        latitude: j.dN('latitude'),
        longitude: j.dN('longitude'),
        lens: j.sN('lens'),
        fNumber: j.dN('fNumber'),
        exposureTime: j.sN('exposureTime'),
        iso: j.iN('iso'),
        focalLength: j.dN('focalLength'),
        focalLength35: j.dN('focalLength35'),
        durationSec: j.iN('durationSec'),
        fps: j.dN('fps'),
        videoCodec: j.sN('videoCodec'),
      );
}

class MapPoint {
  final String entryId;
  final double lat;
  final double lon;

  MapPoint({required this.entryId, required this.lat, required this.lon});

  factory MapPoint.fromJson(Map<String, dynamic> j) =>
      MapPoint(entryId: j.s('entryId'), lat: j.d('lat'), lon: j.d('lon'));
}

// ===== альбомы =====

class AlbumInfo {
  final String id;
  final String name;
  final String? createdAt;
  final int count;

  AlbumInfo({required this.id, required this.name, this.createdAt, required this.count});

  factory AlbumInfo.fromJson(Map<String, dynamic> j) =>
      AlbumInfo(id: j.s('id'), name: j.s('name'), createdAt: j.sN('createdAt'), count: j.i('count'));
}

class AlbumItem {
  final String entryId;
  final String name;
  final int size;
  final String mime;
  final String? capturedAt;

  AlbumItem({required this.entryId, required this.name, required this.size, required this.mime, this.capturedAt});

  factory AlbumItem.fromJson(Map<String, dynamic> j) => AlbumItem(
        entryId: j.s('entryId'),
        name: j.s('name'),
        size: j.i('size'),
        mime: j.s('mime'),
        capturedAt: j.sN('capturedAt'),
      );
}

class AlbumView {
  final String id;
  final String name;
  final int count;
  final List<AlbumItem> items;

  AlbumView({required this.id, required this.name, required this.count, required this.items});

  factory AlbumView.fromJson(Map<String, dynamic> j) => AlbumView(
        id: j.s('id'),
        name: j.s('name'),
        count: j.i('count'),
        items: j.lm('items').map(AlbumItem.fromJson).toList(),
      );
}

// ===== очередь превью =====

class QueueStatus {
  final bool paused;
  final int remaining;
  final int processing;
  final int errors;
  final Map<String, int> remainingByKind;
  final int? diskFree;
  final bool? diskLow;

  QueueStatus({
    required this.paused,
    required this.remaining,
    required this.processing,
    required this.errors,
    required this.remainingByKind,
    this.diskFree,
    this.diskLow,
  });

  factory QueueStatus.fromJson(Map<String, dynamic> j) => QueueStatus(
        paused: j.b('paused'),
        remaining: j.i('remaining'),
        processing: j.i('processing'),
        errors: j.i('errors'),
        remainingByKind: (j.m('remainingByKind') ?? const {})
            .map((k, v) => MapEntry(k, toNum(v)?.toInt() ?? 0)),
        diskFree: j.iN('diskFree'),
        diskLow: j.bN('diskLow'),
      );
}

class QueueErrorRow {
  final String id;
  final String kind;
  final String error;
  final int attempts;
  final String? finishedAt;
  final String? entryId;
  final String? name;

  QueueErrorRow({
    required this.id,
    required this.kind,
    required this.error,
    required this.attempts,
    this.finishedAt,
    this.entryId,
    this.name,
  });

  factory QueueErrorRow.fromJson(Map<String, dynamic> j) => QueueErrorRow(
        id: j.s('id'),
        kind: j.s('kind'),
        error: j.s('error'),
        attempts: j.i('attempts'),
        finishedAt: j.sN('finishedAt'),
        entryId: j.sN('entryId'),
        name: j.sN('name'),
      );
}

// ===== разархивирование =====

class UnzipJob {
  final String id;
  final String entryId;
  final String state;
  final int totalEntries;
  final int doneEntries;
  final int totalBytes;
  final int doneBytes;
  final int skippedEntries;
  final String? currentName;
  final String? error;
  final String? targetFolderId;
  final int percent;
  final String? createdAt;
  final String? startedAt;
  final String? finishedAt;

  UnzipJob({
    required this.id,
    required this.entryId,
    required this.state,
    required this.totalEntries,
    required this.doneEntries,
    required this.totalBytes,
    required this.doneBytes,
    required this.skippedEntries,
    this.currentName,
    this.error,
    this.targetFolderId,
    required this.percent,
    this.createdAt,
    this.startedAt,
    this.finishedAt,
  });

  factory UnzipJob.fromJson(Map<String, dynamic> j) => UnzipJob(
        id: j.s('id'),
        entryId: j.s('entryId'),
        state: j.s('state'),
        totalEntries: j.i('totalEntries'),
        doneEntries: j.i('doneEntries'),
        totalBytes: j.i('totalBytes'),
        doneBytes: j.i('doneBytes'),
        skippedEntries: j.i('skippedEntries'),
        currentName: j.sN('currentName'),
        error: j.sN('error'),
        targetFolderId: j.sN('targetFolderId'),
        percent: j.i('percent'),
        createdAt: j.sN('createdAt'),
        startedAt: j.sN('startedAt'),
        finishedAt: j.sN('finishedAt'),
      );
}

// ===== почта =====

class MailCounts {
  final int inbox;
  final int sent;
  MailCounts({required this.inbox, required this.sent});
  factory MailCounts.fromJson(Map<String, dynamic> j) =>
      MailCounts(inbox: j.i('inbox'), sent: j.i('sent'));
}

class MailAccountRow {
  final String id;
  final String kind;
  final String label;
  final String email;
  final bool enabled;
  final String status;
  final String? statusError;
  final String? lastSyncAt;
  final String? createdAt;
  final MailCounts counts;

  MailAccountRow({
    required this.id,
    required this.kind,
    required this.label,
    required this.email,
    required this.enabled,
    required this.status,
    this.statusError,
    this.lastSyncAt,
    this.createdAt,
    required this.counts,
  });

  factory MailAccountRow.fromJson(Map<String, dynamic> j) => MailAccountRow(
        id: j.s('id'),
        kind: j.s('kind'),
        label: j.s('label'),
        email: j.s('email'),
        enabled: j.b('enabled'),
        status: j.s('status'),
        statusError: j.sN('statusError'),
        lastSyncAt: j.sN('lastSyncAt'),
        createdAt: j.sN('createdAt'),
        counts: MailCounts.fromJson(j.m('counts') ?? const {}),
      );
}

class MailStatusView {
  final Map<String, int> unread;
  final List<MailAccountRow> accounts;

  MailStatusView({required this.unread, required this.accounts});

  factory MailStatusView.fromJson(Map<String, dynamic> j) => MailStatusView(
        unread: (j.m('unread') ?? const {}).map((k, v) => MapEntry(k, toNum(v)?.toInt() ?? 0)),
        accounts: j.lm('accounts').map(MailAccountRow.fromJson).toList(),
      );
}

class MailListItem {
  final String id;
  final String box;
  final String accountId;
  final String accountEmail;
  final String? subject;
  final String? fromName;
  final String? fromAddr;
  final String preview;
  final String? sortAt;
  final bool seen;
  final bool hasAttachments;
  final int size;
  final int threadCount;

  MailListItem({
    required this.id,
    required this.box,
    required this.accountId,
    required this.accountEmail,
    this.subject,
    this.fromName,
    this.fromAddr,
    required this.preview,
    this.sortAt,
    required this.seen,
    required this.hasAttachments,
    required this.size,
    required this.threadCount,
  });

  factory MailListItem.fromJson(Map<String, dynamic> j) => MailListItem(
        id: j.s('id'),
        box: j.s('box'),
        accountId: j.s('accountId'),
        accountEmail: j.s('accountEmail'),
        subject: j.sN('subject'),
        fromName: j.sN('fromName'),
        fromAddr: j.sN('fromAddr'),
        preview: j.s('preview'),
        sortAt: j.sN('sortAt'),
        seen: j.b('seen'),
        hasAttachments: j.b('hasAttachments'),
        size: j.i('size'),
        threadCount: j.i('threadCount'),
      );
}

class MailAttachment {
  final String id;
  final String entryId;
  final String filename;
  final String name;
  final String mime;
  final int size;
  final bool inline;
  final String? contentId;

  MailAttachment({
    required this.id,
    required this.entryId,
    required this.filename,
    required this.name,
    required this.mime,
    required this.size,
    required this.inline,
    this.contentId,
  });

  factory MailAttachment.fromJson(Map<String, dynamic> j) => MailAttachment(
        id: j.s('id'),
        entryId: j.s('entryId'),
        filename: j.s('filename'),
        name: j.s('name'),
        mime: j.s('mime'),
        size: j.i('size'),
        inline: j.b('inline'),
        contentId: j.sN('contentId'),
      );
}

class MailMessageView {
  final String id;
  final String box;
  final String accountId;
  final String accountEmail;
  final String? subject;
  final String? fromName;
  final String? fromAddr;
  final String? sortAt;
  final bool seen;
  final bool hasAttachments;
  final int size;
  final int threadCount;
  final List<String> toAddrs;
  final List<String> ccAddrs;
  final String? replyTo;
  final String? messageId;
  final String? inReplyTo;
  final List<String> refs;
  final String? sentAt;
  final String? receivedAt;
  final String? bodyText;
  final List<MailAttachment> attachments;

  MailMessageView({
    required this.id,
    required this.box,
    required this.accountId,
    required this.accountEmail,
    this.subject,
    this.fromName,
    this.fromAddr,
    this.sortAt,
    required this.seen,
    required this.hasAttachments,
    required this.size,
    required this.threadCount,
    required this.toAddrs,
    required this.ccAddrs,
    this.replyTo,
    this.messageId,
    this.inReplyTo,
    required this.refs,
    this.sentAt,
    this.receivedAt,
    this.bodyText,
    required this.attachments,
  });

  factory MailMessageView.fromJson(Map<String, dynamic> j) => MailMessageView(
        id: j.s('id'),
        box: j.s('box'),
        accountId: j.s('accountId'),
        accountEmail: j.s('accountEmail'),
        subject: j.sN('subject'),
        fromName: j.sN('fromName'),
        fromAddr: j.sN('fromAddr'),
        sortAt: j.sN('sortAt'),
        seen: j.b('seen'),
        hasAttachments: j.b('hasAttachments'),
        size: j.i('size'),
        threadCount: j.i('threadCount'),
        toAddrs: j.ls('toAddrs'),
        ccAddrs: j.ls('ccAddrs'),
        replyTo: j.sN('replyTo'),
        messageId: j.sN('messageId'),
        inReplyTo: j.sN('inReplyTo'),
        refs: j.ls('refs'),
        sentAt: j.sN('sentAt'),
        receivedAt: j.sN('receivedAt'),
        bodyText: j.sN('bodyText'),
        attachments: j.lm('attachments').map(MailAttachment.fromJson).toList(),
      );
}

class MailMonthBucket {
  final String month;
  final int count;

  MailMonthBucket({required this.month, required this.count});

  factory MailMonthBucket.fromJson(Map<String, dynamic> j) =>
      MailMonthBucket(month: j.s('month'), count: j.i('count'));
}

class MailReplyAttachment {
  final String entryId;
  final String filename;
  final int size;

  MailReplyAttachment({required this.entryId, required this.filename, required this.size});

  factory MailReplyAttachment.fromJson(Map<String, dynamic> j) => MailReplyAttachment(
        entryId: j.s('entryId'),
        filename: j.s('filename'),
        size: j.i('size'),
      );
}

class MailReplyContext {
  final String accountId;
  final String to;
  final String cc;
  final String subject;
  final String body;
  final String? inReplyToId;
  final List<MailReplyAttachment> attachments;

  MailReplyContext({
    required this.accountId,
    required this.to,
    required this.cc,
    required this.subject,
    required this.body,
    this.inReplyToId,
    required this.attachments,
  });

  factory MailReplyContext.fromJson(Map<String, dynamic> j) => MailReplyContext(
        accountId: j.s('accountId'),
        to: j.s('to'),
        cc: j.s('cc'),
        subject: j.s('subject'),
        body: j.s('body'),
        inReplyToId: j.sN('inReplyToId'),
        attachments: j.lm('attachments').map(MailReplyAttachment.fromJson).toList(),
      );
}

// ===== shares =====

class ShareInfo {
  final String token;
  final String url;
  final String kind;
  final String capability;
  final String targetId;
  final bool hasPassword;
  final String? expiresAt;
  final String? createdAt;

  ShareInfo({
    required this.token,
    required this.url,
    required this.kind,
    required this.capability,
    required this.targetId,
    required this.hasPassword,
    this.expiresAt,
    this.createdAt,
  });

  factory ShareInfo.fromJson(Map<String, dynamic> j) => ShareInfo(
        token: j.s('token'),
        url: j.s('url'),
        kind: j.s('kind'),
        capability: j.s('capability'),
        targetId: j.s('targetId'),
        hasPassword: j.b('hasPassword'),
        expiresAt: j.sN('expiresAt'),
        createdAt: j.sN('createdAt'),
      );
}

// ===== релиз приложения (обновление по кнопке) =====

class AppRelease {
  final String applicationId;
  final int versionCode;
  final String versionName;
  final int size;
  final String sha256;
  final int minSdk;
  final String? builtAt;
  final String url;

  AppRelease({
    required this.applicationId,
    required this.versionCode,
    required this.versionName,
    required this.size,
    required this.sha256,
    required this.minSdk,
    this.builtAt,
    required this.url,
  });

  factory AppRelease.fromJson(Map<String, dynamic> j) => AppRelease(
        applicationId: j.s('applicationId'),
        versionCode: toNum(j['versionCode'])?.toInt() ?? 0,
        versionName: j.s('versionName'),
        size: toNum(j['size'])?.toInt() ?? 0,
        sha256: j.s('sha256'),
        minSdk: toNum(j['minSdk'])?.toInt() ?? 0,
        builtAt: j.sN('builtAt'),
        url: j.s('url'),
      );
}
