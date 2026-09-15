import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/download.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';

const _cell = 50.0;
const _gap = 3.0;
const _row = _cell + _gap;

class MediaScreen extends ConsumerStatefulWidget {
  const MediaScreen({super.key});

  @override
  ConsumerState<MediaScreen> createState() => _MediaScreenState();
}

class _MediaScreenState extends ConsumerState<MediaScreen> {
  int? _total;
  List<MediaMonthBucket> _months = const [];
  final Map<int, MediaItem> _items = {};
  int _cols = 1;
  String _month = '';
  final ScrollController _sc = ScrollController();
  Timer? _debounce;
  /// Сигнал открытому просмотрщику, что кадры подгрузились.
  final ValueNotifier<int> _revision = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _sc.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sc.dispose();
    _revision.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = ref.read(appStateProvider).api;
    try {
      final n = await api.mediaCount();
      final m = await api.mediaMonths();
      if (mounted) setState(() {
        _total = n;
        _months = m;
      });
      // После кадра: к этому моменту сетка уже посчитала колонки и привязала скролл.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fetchVisible();
      });
    } catch (e) {
      debugPrint('media load error: $e');
      if (mounted) snack(context, e.toString());
    }
  }

  void _onScroll() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _fetchVisible);
    _updateMonth();
  }

  void _updateMonth() {
    final t = _total;
    if (t == null || t == 0 || !_sc.hasClients) return;
    final idx = (_sc.offset ~/ _row).clamp(0, 1 << 30) * _cols;
    final key = _monthAt(idx);
    final label = key == null ? 'Медиа' : key == 'Без даты' ? key : monthLabel(key);
    if (label != _month) setState(() => _month = label);
  }

  String? _monthAt(int index) {
    final cum = _monthCum();
    if (cum.isEmpty) return null;
    var lo = 0, hi = cum.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final b = cum[mid];
      if (index < b.start) {
        hi = mid - 1;
      } else if (index >= b.end) {
        lo = mid + 1;
      } else {
        return b.month;
      }
    }
    return null;
  }

  List<({String month, int start, int end})> _monthCum() {
    final arr = <({String month, int start, int end})>[];
    var start = 0;
    for (final b in _months) {
      if (b.count <= 0) continue;
      arr.add((month: b.month == null ? 'Без даты' : b.month!, start: start, end: start + b.count));
      start += b.count;
    }
    return arr;
  }

  Future<void> _fetchVisible() async {
    final t = _total;
    if (t == null || t == 0) return;
    final api = ref.read(appStateProvider).api;
    // Первый экран надо забрать ещё до того, как сетка привяжет скролл-контроллер:
    // иначе до первого движения пальцем лента стоит пустой.
    final top = _sc.hasClients ? _sc.offset : 0.0;
    final vh = _sc.hasClients ? _sc.position.viewportDimension : 900.0;
    final firstRow = math.max(0, (top / _row).floor() - 3);
    final lastRow = ((top + vh) / _row).ceil() + 3;
    final start = firstRow * _cols;
    final end = math.min(t - 1, (lastRow + 1) * _cols - 1);
    if (start > end) return;
    // догрузить только недостающие куски
    final spans = <(int, int)>[];
    var a = -1;
    for (var i = start; i <= end; i++) {
      if (!_items.containsKey(i)) {
        if (a == -1) a = i;
      } else if (a != -1) {
        spans.add((a, i - 1));
        a = -1;
      }
    }
    if (a != -1) spans.add((a, end));
    for (final (s, e) in spans) {
      for (var off = s; off <= e; off += 500) {
        final len = math.min(500, e - off + 1);
        try {
          final page = await api.mediaRange(off, len);
          if (!mounted) return;
          setState(() {
            for (var j = 0; j < page.length; j++) {
              _items[off + j] = page[j];
            }
          });
          _revision.value++;
          debugPrint('media fetched: off=$off len=${page.length}');
        } catch (e) {
          debugPrint('media range error: $e');
        }
      }
    }
  }

  void _open(int idx) {
    Navigator.push(context, MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => MediaViewer(
        api: ref.read(appStateProvider).api,
        total: _total ?? 0,
        initialIndex: idx,
        getItem: (i) => _items[i],
        ensure: (s, e) {
          if (!_items.containsKey(s) || !_items.containsKey(e)) _fetchVisible();
        },
        onDelete: (i) => _handleDelete(i),
        revision: _revision,
      ),
    ));
  }

  void _handleDelete(int index) {
    final t = _total;
    if (t == null) return;
    // сдвиг индексов: удалённый уходит, следующие смещаются на единицу
    final next = <int, MediaItem>{};
    _items.forEach((k, v) {
      if (k == index) return;
      next[k > index ? k - 1 : k] = v;
    });
    _items
      ..clear()
      ..addAll(next);
    setState(() => _total = t - 1);
  }

  @override
  Widget build(BuildContext context) {
    final t = _total;
    return Scaffold(
      backgroundColor: C.canvas,
      appBar: AppBar(
        backgroundColor: C.canvas,
        title: Text(_month, style: const TextStyle(color: C.fg, fontSize: 17)),
      ),
      body: LayoutBuilder(builder: (context, c) {
        _cols = math.max(1, ((c.maxWidth + _gap) / _row).floor());
        if (t == null) return const Center(child: CircularProgressIndicator());
        if (t == 0) {
          return const Center(child: Text('Здесь появятся фото и видео из раздела «Фото»', style: TextStyle(color: C.fg3)));
        }
        return GridView.builder(
          controller: _sc,
          padding: const EdgeInsets.all(3),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _cols,
            mainAxisSpacing: _gap,
            crossAxisSpacing: _gap,
          ),
          itemCount: t,
          itemBuilder: (context, i) => _cellWidget(i),
        );
      }),
    );
  }

  Widget _cellWidget(int i) {
    final item = _items[i];
    if (item == null) {
      return Container(color: C.surface3);
    }
    final ready = item.previewState == 'done' && (item.sha256?.isNotEmpty ?? false);
    final api = ref.read(appStateProvider).api;
    if (!ready) {
      return GestureDetector(
        onTap: () => _open(i),
        child: Container(
          color: C.surface3,
          child: Icon(item.mime.startsWith('video/') ? Icons.movie_outlined : Icons.image_outlined,
              color: C.fg3, size: 22),
        ),
      );
    }
    return GestureDetector(
      onTap: () => _open(i),
      child: CachedNetworkImage(
        imageUrl: api.previewUrl(item.sha256!),
        httpHeaders: api.authHeaders,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(color: C.surface3),
        errorWidget: (_, __, ___) => Container(
          color: C.surface3,
          child: Icon(item.mime.startsWith('video/') ? Icons.movie_outlined : Icons.image_outlined, color: C.fg3),
        ),
      ),
    );
  }
}

// ---------- просмотрщик кадра (общий для «Медиа» и «Карты») ----------

class MediaViewer extends StatefulWidget {
  final CloudlyApi api;
  final int total;
  final int initialIndex;
  final MediaItem? Function(int) getItem;
  final void Function(int start, int end) ensure;
  final void Function(int index) onDelete;

  /// Родитель дёргает этот Listenable, когда его кэш кадров пополнился: без этого
  /// просмотрщик оставался бы со спиннером (у карты кадры приходят уже после открытия).
  final Listenable? revision;

  const MediaViewer({
    super.key,
    required this.api,
    required this.total,
    required this.initialIndex,
    required this.getItem,
    required this.ensure,
    required this.onDelete,
    this.revision,
  });

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> {
  late final PageController _pc = PageController(initialPage: widget.initialIndex);
  late int _idx = widget.initialIndex;
  MediaInfo? _info;

  @override
  void initState() {
    super.initState();
    widget.revision?.addListener(_onRevision);
    _loadInfo(_idx);
  }

  void _onRevision() {
    if (!mounted) return;
    debugPrint('viewer revision: idx=$_idx hasItem=${widget.getItem(_idx) != null}');
    setState(() {});
    // Кадр подгрузился уже после открытия — метаданные футера тоже надо дотянуть.
    if (_info == null) _loadInfo(_idx);
  }

  @override
  void dispose() {
    widget.revision?.removeListener(_onRevision);
    _pc.dispose();
    super.dispose();
  }

  Future<void> _loadInfo(int i) async {
    final item = widget.getItem(i);
    if (item == null) return;
    setState(() => _info = null);
    try {
      final info = await widget.api.mediaInfo(item.entryId);
      if (mounted) setState(() => _info = info);
    } catch (_) {}
  }

  Future<void> _delete() async {
    final item = widget.getItem(_idx);
    if (item == null) return;
    final ok = await confirmDialog(context, 'Удалить «${item.name}»?', 'Файл уйдёт в корзину.', danger: true);
    if (!ok) return;
    try {
      await widget.api.deleteFile(item.entryId);
      if (mounted) widget.onDelete(_idx);
      if (mounted) {
        setState(() {
          if (_idx >= widget.total - 1 && widget.total > 1) _idx = widget.total - 2;
          _idx = _idx.clamp(0, math.max(0, widget.total - 2));
        });
        if (widget.total <= 1) Navigator.pop(context);
        else _loadInfo(_idx);
      }
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.getItem(_idx);
    final geo = (_info?.latitude != null && _info?.longitude != null) ? _info : null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        PageView.builder(
          controller: _pc,
          itemCount: widget.total,
          onPageChanged: (i) {
            setState(() => _idx = i);
            _loadInfo(i);
          },
          itemBuilder: (context, i) {
            widget.ensure(math.max(0, i - 1), math.min(widget.total - 1, i + 1));
            return _slide(widget.getItem(i));
          },
        ),
        SafeArea(
          child: Column(children: [
            Row(children: [
              const SizedBox(width: 4),
              IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
              Expanded(
                child: Text(
                  fmtMediaDate(item?.capturedAt).isNotEmpty ? fmtMediaDate(item?.capturedAt) : (item?.name ?? ''),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (geo != null)
                IconButton(
                  icon: const Icon(Icons.map_outlined, color: Colors.white),
                  onPressed: () => _openOsm(geo),
                ),
              IconButton(
                icon: const Icon(Icons.download, color: Colors.white),
                onPressed: item == null ? null : () => _download(item),
              ),
              IconButton(icon: const Icon(Icons.delete_outline, color: Colors.white), onPressed: item == null ? null : _delete),
            ]),
            const Spacer(),
            if (_info != null) _footer(),
          ]),
        ),
      ]),
    );
  }

  Widget _slide(MediaItem? item) {
    if (item == null) return const Center(child: CircularProgressIndicator());
    final isVideo = item.mime.startsWith('video/');
    if (isVideo) return _video(item);
    return _image(item);
  }

  Widget _image(MediaItem item) {
    final sha = item.sha256;
    if (sha == null || sha.isEmpty) {
      return const Center(child: Text('Превью не открылось', style: TextStyle(color: Colors.white70)));
    }
    return InteractiveViewer(
      minScale: 1,
      maxScale: 8,
      child: Center(
        child: CachedNetworkImage(
          imageUrl: widget.api.previewUrl(sha, w: 1080),
          httpHeaders: widget.api.authHeaders,
          fit: BoxFit.contain,
          placeholder: (_, __) => const CircularProgressIndicator(color: Colors.white),
          errorWidget: (_, __, ___) => const Center(child: Text('Превью не открылось — файл мог быть удалён', style: TextStyle(color: Colors.white70))),
        ),
      ),
    );
  }

  Widget _video(MediaItem item) {
    final sha = item.sha256;
    if (sha == null || sha.isEmpty) return const SizedBox();
    return Center(child: _Vid(api: widget.api, url: widget.api.videoPreviewUrl(sha)));
  }

  Widget _footer() {
    final info = _info!;
    final item = widget.getItem(_idx);
    final metas = <(IconData, String, String)>[
      (Icons.sd_storage_outlined, 'Размер', fmtSize(item?.size ?? info.size)),
      if (info.width != null && info.height != null) (Icons.aspect_ratio, 'Кадр', '${info.width} × ${info.height}'),
      if ((info.make?.isNotEmpty ?? false) || (info.model?.isNotEmpty ?? false))
        (Icons.camera_alt_outlined, 'Камера', [info.make, info.model].where((s) => s != null && s.isNotEmpty).join(' ')),
      if (info.lens != null) (Icons.center_focus_strong, 'Объектив', info.lens!),
      if (info.fNumber != null) (Icons.camera, 'Диафрагма', 'f/${trimNum(info.fNumber!, 1)}'),
      if (info.exposureTime != null) (Icons.timer_outlined, 'Выдержка', info.exposureTime!),
      if (info.iso != null) (Icons.speed, 'ISO', '${info.iso}'),
      if (info.focalLength != null) (Icons.straighten, 'Фокусное', '${trimNum(info.focalLength!, 1)} мм'),
      if (info.durationSec != null) (Icons.schedule, 'Длительность', fmtDuration(info.durationSec!)),
      if (info.fps != null) (Icons.speed, 'Кадров/с', '${trimNum(info.fps!, 2)} к/с'),
      if (info.videoCodec != null) (Icons.videocam_outlined, 'Кодек', info.videoCodec!),
      if (item != null) (Icons.notes, 'Тип', item.mime),
      if (info.latitude != null && info.longitude != null)
        (Icons.place_outlined, 'Координаты', '${info.latitude!.toStringAsFixed(6)}, ${info.longitude!.toStringAsFixed(6)}'),
    ];
    return Container(
      color: Colors.black.withOpacity(0.6),
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: metas
            .map((m) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(children: [
                    Icon(m.$1, color: Colors.white70, size: 15),
                    const SizedBox(width: 4),
                    Text(m.$3, style: const TextStyle(color: Colors.white, fontSize: 13)),
                  ]),
                ))
            .toList(),
      ),
    );
  }

  void _openOsm(MediaInfo geo) {
    launchUrl(Uri.parse(
        'https://www.openstreetmap.org/?mlat=${geo.latitude}&mlon=${geo.longitude}#map=16/${geo.latitude}/${geo.longitude}'));
  }

  void _download(MediaItem item) {
    downloadAndOpen(widget.api, item.entryId, item.name);
  }
}

class _Vid extends StatefulWidget {
  final CloudlyApi api;
  final String url;
  const _Vid({required this.api, required this.url});
  @override
  State<_Vid> createState() => _VidState();
}

class _VidState extends State<_Vid> {
  VideoPlayerController? _c;
  bool _err = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.url), httpHeaders: widget.api.authHeaders);
    _c = c;
    c.addListener(() {
      if (c.value.hasError && mounted) setState(() => _err = true);
    });
    try {
      await c.initialize();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _err = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_err) {
      return const Center(child: Text('Видео не проигрывается', style: TextStyle(color: Colors.white70)));
    }
    final c = _c;
    if (c != null && c.value.isInitialized) {
      return AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c));
    }
    return const CircularProgressIndicator(color: Colors.white);
  }
}
