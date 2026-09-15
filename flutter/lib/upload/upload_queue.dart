import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../api/cloudly_api.dart';

class UploadRow {
  final int key;
  final String path;
  final String name;
  final int size;
  final String? folderId;
  String state; // queued | uploading | done | failed
  int pct;
  String? phase;
  String? note;
  String? error;

  UploadRow({
    required this.key,
    required this.path,
    required this.name,
    required this.size,
    this.folderId,
    this.state = 'queued',
    this.pct = 0,
    this.phase,
    this.note,
    this.error,
  });
}

/// Общая очередь загрузки (порт `useBulkUpload`): живёт в AppState и переживает
/// переключение вкладок.
class UploadQueue extends ChangeNotifier {
  final CloudlyApi Function() api;
  UploadQueue(this.api);

  final List<UploadRow> _rows = [];
  List<UploadRow> get rows => List.unmodifiable(_rows);

  bool _running = false;
  bool _stopped = false;
  int _seq = 0;

  bool get busy => _rows.any((r) => r.state == 'queued' || r.state == 'uploading');

  Future<void> addFiles(List<PlatformFile> files, String? folderId) async {
    if (files.isEmpty || _running) return;
    _rows.removeWhere((r) => r.state == 'done');
    for (final f in files) {
      final p = f.path;
      if (p == null || p.isEmpty) continue;
      _rows.add(UploadRow(
        key: ++_seq,
        path: p,
        name: f.name,
        size: f.lengthSync() ?? 0,
        folderId: folderId,
      ));
    }
    notifyListeners();
    unawaited(_start());
  }

  Future<void> _start() async {
    if (_running) return;
    _running = true;
    _stopped = false;
    try {
      for (;;) {
        final i = _rows.indexWhere((r) => r.state == 'queued');
        if (i < 0 || _stopped) break;
        final row = _rows[i];
        row.state = 'uploading';
        row.pct = 0;
        row.note = null;
        notifyListeners();
        try {
          await api().uploadFile(
            row.path,
            folderId: row.folderId,
            name: row.name,
            onProgress: (pct, phase, note) {
              row.pct = pct;
              row.phase = phase;
              row.note = note;
              notifyListeners();
            },
          );
          row.state = 'done';
          row.pct = 100;
        } catch (e) {
          if (_stopped) {
            _rows.removeAt(i);
          } else {
            row.state = 'failed';
            row.error = e.toString();
          }
        }
        notifyListeners();
      }
    } finally {
      _running = false;
      if (_stopped) {
        _stopped = false;
        _rows.removeWhere((r) => r.state != 'done');
        notifyListeners();
      }
    }
  }

  void cancel() {
    _stopped = true;
    notifyListeners();
  }

  void retryFailed() {
    for (final r in _rows) {
      if (r.state == 'failed') {
        r.state = 'queued';
        r.pct = 0;
        r.error = null;
      }
    }
    notifyListeners();
    unawaited(_start());
  }

  void dismissFailed() {
    _rows.removeWhere((r) => r.state == 'failed');
    notifyListeners();
  }
}
