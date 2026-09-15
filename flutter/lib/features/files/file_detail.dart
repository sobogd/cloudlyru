import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/download.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';

class FileDetailScreen extends ConsumerStatefulWidget {
  final String entryId;
  const FileDetailScreen({super.key, required this.entryId});

  @override
  ConsumerState<FileDetailScreen> createState() => _FileDetailScreenState();
}

class _FileDetailScreenState extends ConsumerState<FileDetailScreen> {
  FileMeta? _meta;
  String? _error;
  String? _notice;
  UnzipJob? _job;
  Timer? _unzipTimer;
  Timer? _pagesTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _loadUnzip();
  }

  @override
  void dispose() {
    _unzipTimer?.cancel();
    _pagesTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final m = await ref.read(appStateProvider).api.fileMeta(widget.entryId);
      if (mounted) setState(() {
        _meta = m;
        _error = null;
      });
      // PDF без pageCount — превью ещё собирается: переспрашиваем
      if (m.mime == 'application/pdf' && (m.pageCount ?? 0) == 0) {
        _pagesTimer?.cancel();
        _pagesTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
          try {
            final mm = await ref.read(appStateProvider).api.fileMeta(widget.entryId);
            if (mounted && (mm.pageCount ?? 0) > 0) {
              setState(() => _meta = mm);
              _pagesTimer?.cancel();
            }
          } catch (_) {}
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _loadUnzip() async {
    try {
      final j = await ref.read(appStateProvider).api.latestUnzip(widget.entryId);
      if (mounted && j != null && (j.state == 'pending' || j.state == 'processing' || j.state == 'done')) {
        setState(() => _job = j);
        _pollUnzip();
      }
    } catch (_) {}
  }

  void _pollUnzip() {
    _unzipTimer?.cancel();
    _unzipTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final j = _job;
      if (j == null) return;
      try {
        final s = await ref.read(appStateProvider).api.unzipStatus(j.id);
        if (mounted) {
          setState(() => _job = s);
          if (s.state != 'pending' && s.state != 'processing') _unzipTimer?.cancel();
        }
      } catch (_) {}
    });
  }

  bool get _isZip {
    final m = _meta;
    if (m == null) return false;
    return m.mime == 'application/zip' || m.name.toLowerCase().endsWith('.zip');
  }

  Future<void> _rename() async {
    final m = _meta;
    if (m == null) return;
    final next = await promptDialog(context, 'Новое имя файла', initial: m.name);
    if (next == null || next.trim().isEmpty || next == m.name) return;
    try {
      await ref.read(appStateProvider).api.renameFile(m.id, next.trim());
      setState(() {
        _meta = _meta;
        _notice = 'Имя изменено';
      });
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _toClip(String mode) async {
    final m = _meta;
    if (m == null) return;
    try {
      await ref.read(appStateProvider).api.setClipboard('file', m.id, mode);
      if (mounted) {
        snack(context, mode == 'copy'
            ? 'Скопировано. Откройте папку и нажмите «Вставить».'
            : 'Вырезано. Откройте папку и нажмите «Вставить».');
      }
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  Future<void> _delete() async {
    final m = _meta;
    if (m == null) return;
    final ok = await confirmDialog(context, 'Удалить «${m.name}»?', 'Файл уйдёт в корзину.', danger: true);
    if (!ok) return;
    try {
      await ref.read(appStateProvider).api.deleteFile(m.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  Future<void> _startUnzip() async {
    try {
      final j = await ref.read(appStateProvider).api.startUnzip(widget.entryId);
      if (mounted) {
        setState(() => _job = j);
        _pollUnzip();
      }
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  Future<void> _cancelUnzip() async {
    final j = _job;
    if (j == null) return;
    try {
      final s = await ref.read(appStateProvider).api.cancelUnzip(j.id);
      if (mounted) setState(() => _job = s);
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _meta;
    final api = ref.watch(appStateProvider).api;
    return Scaffold(
      backgroundColor: C.canvas,
      appBar: AppBar(
        backgroundColor: C.canvas,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: C.fg),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(m?.name ?? 'Файл', style: const TextStyle(color: C.fg, fontSize: 16)),
        actions: [
          if (m != null) ...[
            IconButton(tooltip: 'Переименовать', icon: const Icon(Icons.edit_outlined, color: C.fg), onPressed: _rename),
            IconButton(tooltip: 'Копировать', icon: const Icon(Icons.copy, color: C.fg), onPressed: () => _toClip('copy')),
            IconButton(tooltip: 'Вырезать', icon: const Icon(Icons.content_cut, color: C.fg), onPressed: () => _toClip('cut')),
            if (_isZip)
              IconButton(
                tooltip: 'Разархивировать рядом с архивом',
                icon: const Icon(Icons.inventory_2_outlined, color: C.fg),
                onPressed: (_job?.state == 'pending' || _job?.state == 'processing') ? null : _startUnzip,
              ),
            IconButton(
              tooltip: 'Скачать',
              icon: const Icon(Icons.download, color: C.fg),
              onPressed: () => downloadAndOpen(api, m.id, m.name),
            ),
            IconButton(tooltip: 'Удалить', icon: const Icon(Icons.delete_outline, color: C.danger), onPressed: _delete),
          ],
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: C.danger)),
          if (_notice != null) Text(_notice!, style: const TextStyle(color: C.ok)),
          if (_job != null) _unzipPanel(),
          if (m == null && _error == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else if (m != null) ...[
            if (m.mail != null) _mailOriginPanel(m),
            Panel(child: Column(children: _metaRows(m))),
            const SizedBox(height: 8),
            if (_previewKind(m) != null) _preview(api, m),
            if (_mediaRows(m.media?.raw).isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Все теги из файла (${_mediaRows(m.media?.raw).length})',
                    style: const TextStyle(color: C.fg3, fontSize: 13)),
                children: _mediaRows(m.media?.raw)
                    .map((r) => MetaRow(r.$1, r.$2))
                    .toList(),
              ),
          ],
        ],
      ),
    );
  }

  Widget _unzipPanel() {
    final j = _job!;
    final busy = j.state == 'pending' || j.state == 'processing';
    final statusText = j.state == 'done'
        ? 'готово'
        : j.state == 'failed'
            ? 'ошибка'
            : j.state == 'cancelled'
                ? 'отменено'
                : '${j.percent}%';
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.inventory_2_outlined, color: C.fg3, size: 18),
            const SizedBox(width: 6),
            const Text('Распаковка', style: TextStyle(color: C.fg, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(statusText, style: const TextStyle(color: C.fg3, fontSize: 13)),
            if (busy)
              IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 18), onPressed: _cancelUnzip),
          ]),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: (j.percent / 100).clamp(0, 1), minHeight: 4, color: j.state == 'done' ? C.ok : C.accent),
          const SizedBox(height: 4),
          Text('файлов: ${j.doneEntries} из ${j.totalEntries} · ${fmt(j.doneBytes)} из ${fmt(j.totalBytes)}',
              style: const TextStyle(color: C.fg3, fontSize: 12)),
          if (busy && j.currentName != null)
            Text('сейчас: ${j.currentName}', style: const TextStyle(color: C.fg3, fontSize: 12)),
          if (j.error != null) Text(j.error!, style: const TextStyle(color: C.danger, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _mailOriginPanel(FileMeta m) {
    final mail = m.mail!;
    return Panel(
      child: Row(children: [
        const Icon(Icons.mail_outline, color: C.fg3, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(mail.subject ?? '(без темы)', style: const TextStyle(color: C.fg, fontSize: 14)),
            Text('${[mail.fromName ?? mail.fromAddr, mail.sortAt == null ? '' : fmtLocal(mail.sortAt)].where((s) => (s ?? '').isNotEmpty).join(' · ')}',
                style: const TextStyle(color: C.fg3, fontSize: 12)),
          ]),
        ),
      ]),
    );
  }

  List<Widget> _metaRows(FileMeta m) {
    return [
      MetaRow('Имя', m.name),
      MetaRow('Тип', m.ext != null ? '${m.ext!.toUpperCase()} — ${m.mime}' : m.mime),
      MetaRow('Размер', fmt(m.size)),
      MetaRow('Расположение', m.path),
      if (m.createdAt != null) MetaRow('Создан', fmtLocal(m.createdAt) ?? m.createdAt!),
      if (m.media?.capturedAt != null)
        MetaRow('Дата съёмки', fmtExifDate(m.media!.capturedAt) ?? (fmtLocal(m.media!.capturedAt) ?? m.media!.capturedAt!)),
      if ((m.media?.make?.isNotEmpty ?? false) || (m.media?.model?.isNotEmpty ?? false))
        MetaRow('Камера', [m.media!.make, m.media!.model].where((s) => s != null && s.isNotEmpty).join(' ')),
      if ((m.media?.width != null) && (m.media?.height != null))
        MetaRow('Кадр', '${m.media!.width} × ${m.media!.height}'),
      if (m.media?.latitude != null && m.media?.longitude != null)
        MetaRow('Координаты', '${m.media!.latitude!.toStringAsFixed(6)}, ${m.media!.longitude!.toStringAsFixed(6)}'),
      MetaRow('SHA-256', m.sha256, mono: true),
    ];
  }

  String? _previewKind(FileMeta m) {
    if (m.mime.startsWith('image/')) return 'image';
    if (m.mime.startsWith('video/')) return 'video';
    if (m.mime == 'application/pdf' || m.name.toLowerCase().endsWith('.pdf')) return 'pdf';
    return null;
  }

  Widget _preview(CloudlyApi api, FileMeta m) {
    switch (_previewKind(m)) {
      case 'image':
        return ImagePreview(api: api, meta: m);
      case 'video':
        return VideoPreview(api: api, meta: m);
      case 'pdf':
        return PdfPreview(api: api, meta: m);
      default:
        return const SizedBox.shrink();
    }
  }

  List<(String, String)> _mediaRows(Map<String, dynamic>? raw) {
    final rows = <(String, String)>[];
    if (raw == null) return rows;
    void push(String k, Object? v) {
      if (v == null || v == '') return;
      if (rows.any((r) => r.$1 == k)) return;
      rows.add((k, v.toString()));
    }

    if (raw['kind'] == 'image') {
      push('Дата съёмки', fmtExifDate(raw['dateTimeOriginal']));
      push('Создан (EXIF)', fmtExifDate(raw['createDate']));
      push('Изменён (EXIF)', fmtExifDate(raw['modifyDate']));
      push('Часовой пояс', raw['offsetTime']);
      push('Камера', [raw['make'], raw['model']].whereType<String>().where((s) => s.isNotEmpty).join(' '));
      push('Объектив', raw['lens']);
      push('Выдержка', raw['exposureTime']);
      if (raw['fNumber'] is num) push('Диафрагма', 'f/${trimNum(raw['fNumber'] as num, 1)}');
      push('ISO', raw['iso']);
      if (raw['focalLength'] is num) push('Фокусное', '${trimNum(raw['focalLength'] as num, 1)} мм');
      if (raw['focalLength35'] is num) push('Фокусное (35 мм)', '${raw['focalLength35']} мм');
      push('Описание', raw['description']);
      push('Автор', raw['artist']);
      push('Copyright', raw['copyright']);
      push('ПО', raw['software']);
      if (raw['width'] != null && raw['height'] != null) push('Кадр', '${raw['width']} × ${raw['height']}');
    } else if (raw['kind'] == 'video') {
      if (raw['durationSec'] is num) push('Длительность', fmtDurationLong((raw['durationSec'] as num).toInt()));
      push('Контейнер', raw['container']);
      push('Видеокодек', raw['videoCodec']);
      push('Аудиокодек', raw['audioCodec']);
      if (raw['width'] != null && raw['height'] != null) push('Кадр', '${raw['width']} × ${raw['height']}');
      if (raw['fps'] is num) push('Кадров/с', (raw['fps'] as num).toStringAsFixed(2));
      push('Создан', fmtLocal(raw['createdAt']));
    }
    return rows;
  }
}

// ---------- превью ----------

Future<Uint8List> _fetchBytes(CloudlyApi api, String url) async {
  final dio = Dio();
  final res = await dio.get<List<int>>(url,
      options: Options(headers: api.authHeaders, responseType: ResponseType.bytes));
  return Uint8List.fromList(res.data!);
}

class ImagePreview extends StatefulWidget {
  final CloudlyApi api;
  final FileMeta meta;
  const ImagePreview({super.key, required this.api, required this.meta});
  @override
  State<ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<ImagePreview> {
  int _stage = 0; // 0 превью, 1 оригинал inline, 2 нечем
  Uint8List? _bytes;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _bytes = null;
      _loading = true;
    });
    final url = _stage == 0
        ? widget.api.previewUrl(widget.meta.sha256, w: 1080)
        : widget.api.fileInlineUrl(widget.meta.id);
    try {
      final b = await _fetchBytes(widget.api, url);
      if (mounted) setState(() {
        _bytes = b;
        _loading = false;
      });
    } catch (_) {
      if (_stage < 2) {
        setState(() => _stage++);
        _load();
      } else {
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(_bytes!, fit: BoxFit.contain, width: double.infinity),
        ),
      );
    }
    if (_stage >= 2) return _note();
    return const SizedBox(
      height: 180,
      child: Center(child: CircularProgressIndicator()),
    );
  }

  Widget _note() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        const Expanded(child: Text('Превью не собрано', style: TextStyle(color: C.fg3))),
        TextButton(onPressed: () => downloadAndOpen(widget.api, widget.meta.id, widget.meta.name),
            child: const Text('Скачать')),
      ]),
    );
  }
}

class VideoPreview extends StatefulWidget {
  final CloudlyApi api;
  final FileMeta meta;
  const VideoPreview({super.key, required this.api, required this.meta});
  @override
  State<VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<VideoPreview> {
  int _stage = 0;
  VideoPlayerController? _c;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _c?.removeListener(_onEvent);
    _c?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final url = _stage == 0
        ? widget.api.videoPreviewUrl(widget.meta.sha256)
        : widget.api.videoPreviewUrl(widget.meta.sha256, original: true);
    final c = VideoPlayerController.networkUrl(Uri.parse(url), httpHeaders: widget.api.authHeaders);
    _c = c;
    c.addListener(_onEvent);
    try {
      await c.initialize();
      if (mounted) {
        setState(() {});
        await c.play();
      }
    } catch (_) {
      _fallback();
    }
  }

  void _onEvent() {
    if (_c?.value.hasError ?? false) _fallback();
  }

  void _fallback() {
    _c?.removeListener(_onEvent);
    _c?.dispose();
    _c = null;
    if (_stage < 1) {
      setState(() => _stage++);
      _init();
    } else {
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          const Expanded(child: Text('Видео не проигрывается на этом устройстве', style: TextStyle(color: C.fg3))),
          TextButton(onPressed: () => downloadAndOpen(widget.api, widget.meta.id, widget.meta.name),
              child: const Text('Скачать')),
        ]),
      );
    }
    final c = _c;
    if (c != null && c.value.isInitialized) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: c.value.aspectRatio,
            child: Stack(alignment: Alignment.center, children: [
              VideoPlayer(c),
              _PlayPause(c),
            ]),
          ),
        ),
      );
    }
    return const SizedBox(height: 180, child: Center(child: CircularProgressIndicator()));
  }
}

class _PlayPause extends StatelessWidget {
  final VideoPlayerController c;
  const _PlayPause(this.c);
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => c.value.isPlaying ? c.pause() : c.play(),
      child: Icon(c.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
          size: 48, color: Colors.white.withOpacity(0.85)),
    );
  }
}

class PdfPreview extends StatefulWidget {
  final CloudlyApi api;
  final FileMeta meta;
  const PdfPreview({super.key, required this.api, required this.meta});
  @override
  State<PdfPreview> createState() => _PdfPreviewState();
}

class _PdfPreviewState extends State<PdfPreview> {
  int _page = 1;
  Uint8List? _bytes;
  bool _failed = false;

  int get _pages => widget.meta.pageCount ?? 0;

  @override
  void initState() {
    super.initState();
    if (_pages > 0) _load();
  }

  @override
  void didUpdateWidget(covariant PdfPreview old) {
    super.didUpdateWidget(old);
    if ((old.meta.pageCount ?? 0) == 0 && _pages > 0) _load();
  }

  Future<void> _load() async {
    setState(() {
      _bytes = null;
      _failed = false;
    });
    try {
      final b = await _fetchBytes(widget.api, widget.api.pdfPageUrl(widget.meta.sha256, _page));
      if (mounted) setState(() => _bytes = b);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_pages == 0) {
      return const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()));
    }
    return Column(children: [
      if (_bytes != null)
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(_bytes!, fit: BoxFit.contain, width: double.infinity),
        )
      else if (_failed)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            const Expanded(child: Text('Превью страницы не собралось', style: TextStyle(color: C.fg3))),
            TextButton(onPressed: () => downloadAndOpen(widget.api, widget.meta.id, widget.meta.name),
                child: const Text('Скачать')),
          ]),
        )
      else
        const SizedBox(height: 160, child: Center(child: CircularProgressIndicator())),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(
          icon: const Icon(Icons.chevron_left, color: C.fg),
          onPressed: _page <= 1 ? null : () { setState(() => _page--); _load(); },
        ),
        Text('$_page / $_pages', style: const TextStyle(color: C.fg3)),
        IconButton(
          icon: const Icon(Icons.chevron_right, color: C.fg),
          onPressed: _page >= _pages ? null : () { setState(() => _page++); _load(); },
        ),
      ]),
    ]);
  }
}
