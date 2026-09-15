import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../media/media_screen.dart';

const _clusterPx = 36.0;
const _clusterSide = 26.0;
const _clusterMax = 600;

class _Cluster {
  double lat;
  double lon;
  int n;
  final List<int> ids;
  _Cluster(this.lat, this.lon, this.n, this.ids);
}

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  List<MapPoint> _points = const [];
  int _total = 0;
  bool _truncated = false;
  String? _error;
  List<_Cluster> _clusters = const [];
  final MapController _mc = MapController();
  bool _ready = false;
  bool _fitted = false;

  // источник кадров для просмотрщика
  final Map<String, MediaItem> _itemCache = {};
  final Set<String> _pending = {};
  List<int>? _group;
  int _groupAt = 0;
  /// У карты нет ленты кадров — просмотрщик получает их по мере догрузки,
  /// поэтому его надо будить этим сигналом (иначе первый тап висит на спиннере).
  final ValueNotifier<int> _revision = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _revision.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await ref.read(appStateProvider).api.mediaMap();
      if (mounted) setState(() {
        _points = (r['points'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => MapPoint.fromJson(e.cast<String, dynamic>()))
            .toList();
        _total = toNum(r['total'])?.toInt() ?? 0;
        _truncated = r['truncated'] == true;
        _error = null;
      });
      if (_ready) _syncClusters();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _fitAll() {
    if (!_ready || _points.isEmpty) return;
    _mc.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(_points.map((p) => LatLng(p.lat, p.lon)).toList()),
      padding: const EdgeInsets.all(40),
      maxZoom: 15,
    ));
  }

  void _fitFirst() {
    if (!_ready) return;
    if (_points.isEmpty) {
      _mc.move(const LatLng(20, 10), 2);
      return;
    }
    // самая «фотографируемая» клетка ~5 км
    const cell = 0.05;
    final counts = <String, int>{};
    for (final p in _points) {
      final k = '${(p.lat / cell).round()}:${(p.lon / cell).round()}';
      counts[k] = (counts[k] ?? 0) + 1;
    }
    String best = '';
    var bestN = 0;
    counts.forEach((k, v) {
      if (v > bestN) {
        best = k;
        bestN = v;
      }
    });
    final near = _points.where((p) => '${(p.lat / cell).round()}:${(p.lon / cell).round()}' == best).toList();
    if (near.isEmpty) {
      _fitAll();
      return;
    }
    _mc.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(near.map((p) => LatLng(p.lat, p.lon)).toList()),
      padding: const EdgeInsets.all(60),
      maxZoom: 16,
    ));
  }

  void _syncClusters() {
    if (!_ready) return;
    final cam = _mc.camera;
    final size = cam.nonRotatedSize;
    if (size.width <= 0 || size.height <= 0) return;
    final cells = <String, _Cluster>{};
    for (var i = 0; i < _points.length; i++) {
      final p = _points[i];
      final off = cam.latLngToScreenOffset(LatLng(p.lat, p.lon));
      if (off.dx < -_clusterPx || off.dy < -_clusterPx ||
          off.dx > size.width + _clusterPx || off.dy > size.height + _clusterPx) {
        continue;
      }
      final key = '${off.dx ~/ _clusterPx}:${off.dy ~/ _clusterPx}';
      final c = cells[key];
      if (c == null) {
        cells[key] = _Cluster(p.lat, p.lon, 1, [i]);
      } else {
        c.lat += p.lat;
        c.lon += p.lon;
        c.n++;
        c.ids.add(i);
      }
    }
    final list = cells.values.toList()..sort((a, b) => b.n.compareTo(a.n));
    setState(() => _clusters = list.take(_clusterMax).toList());
  }

  // ---------- источник кадров для просмотрщика ----------

  MediaItem? _groupItem(int gi) {
    final group = _group;
    if (group == null || gi < 0 || gi >= group.length) return null;
    final idx = group[gi];
    if (idx < 0 || idx >= _points.length) return null;
    return _itemCache[_points[idx].entryId];
  }

  void _ensureItem(int gi) {
    final group = _group;
    if (group == null || gi < 0 || gi >= group.length) return;
    final p = _points[group[gi]];
    if (_itemCache.containsKey(p.entryId) || _pending.contains(p.entryId)) return;
    _pending.add(p.entryId);
    ref.read(appStateProvider).api.mediaInfo(p.entryId).then((d) {
      _itemCache[p.entryId] = MediaItem(
        entryId: p.entryId,
        name: d.name,
        mime: d.mime,
        sha256: d.sha256,
        capturedAt: d.capturedAt,
        size: d.size,
        previewState: 'done',
        jobState: null,
      );
      debugPrint('map item loaded: ${p.entryId}');
      if (mounted) _revision.value++;
    }).catchError((_) {}).whenComplete(() => _pending.remove(p.entryId));
  }

  void _openGroup(_Cluster c) {
    setState(() {
      _group = c.ids;
      _groupAt = 0;
    });
    Navigator.push(context, MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => MediaViewer(
        api: ref.read(appStateProvider).api,
        total: c.ids.length,
        initialIndex: 0,
        getItem: _groupItem,
        ensure: (s, e) {
          for (var i = s; i <= e; i++) {
            _ensureItem(i);
          }
        },
        onDelete: _handleDelete,
        revision: _revision,
      ),
    )).then((_) {
      if (mounted) setState(() => _group = null);
    });
  }

  void _handleDelete(int pos) {
    final group = _group;
    if (group == null) return;
    final gi = group[pos];
    final nextPoints = List<MapPoint>.from(_points)..removeAt(gi);
    final nextGroup = <int>[];
    for (var i = 0; i < group.length; i++) {
      if (i == pos) continue;
      nextGroup.add(group[i] > gi ? group[i] - 1 : group[i]);
    }
    setState(() {
      _points = nextPoints;
      _group = nextGroup.isEmpty ? null : nextGroup;
      _groupAt = math.max(0, math.min(pos, nextGroup.length - 1));
      _syncClusters();
    });
  }

  @override
  Widget build(BuildContext context) {
    final count = _points.length;
    return Scaffold(
      backgroundColor: C.canvas,
      appBar: AppBar(
        backgroundColor: C.canvas,
        title: Text(
          _error != null
              ? 'Карта'
              : count == 0
                  ? 'Нет фото с геоданными'
                  : '$count фото на карте${_truncated ? ' из $_total' : ''}',
          style: const TextStyle(color: C.fg, fontSize: 16),
        ),
        actions: [
          IconButton(
            tooltip: 'Показать все фото',
            icon: const Icon(Icons.my_location, color: C.fg),
            onPressed: count == 0 ? null : _fitAll,
          ),
        ],
      ),
      body: Stack(children: [
        FlutterMap(
          mapController: _mc,
          options: MapOptions(
            initialCenter: const LatLng(20, 10),
            initialZoom: 2,
            minZoom: 2,
            maxZoom: 19,
            onMapReady: () {
              _ready = true;
              _fitted = true;
              _fitFirst();
              _syncClusters();
            },
            onPositionChanged: (camera, hasGesture) => _syncClusters(),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'ru.cloudly.cloudly_flutter',
              maxZoom: 19,
            ),
            MarkerLayer(
              markers: _clusters.map((c) => Marker(
                point: LatLng(c.lat / c.n, c.lon / c.n),
                width: _clusterSide,
                height: _clusterSide,
                child: GestureDetector(
                  onTap: () => _openGroup(c),
                  child: _clusterMarker(c),
                ),
              )).toList(),
            ),
          ],
        ),
        Positioned(
          right: 8,
          top: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.55),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text('© OpenStreetMap contributors',
                style: TextStyle(color: Colors.white, fontSize: 10)),
          ),
        ),
        if (_error != null)
          Positioned(left: 12, top: 8, child: _pill(_error!, C.danger)),
        if (_points.isEmpty && _error == null)
          Positioned(left: 12, top: 8, child: _pill('Загружаю метки…', C.surface2)),
      ]),
    );
  }

  Widget _pill(String text, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: const TextStyle(color: C.fg, fontSize: 12)),
    );
  }

  Widget _clusterMarker(_Cluster c) {
    final api = ref.read(appStateProvider).api;
    final entryId = _points[c.ids.first].entryId;
    return Stack(alignment: Alignment.center, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: CachedNetworkImage(
          imageUrl: api.thumbUrl(entryId),
          httpHeaders: api.authHeaders,
          width: _clusterSide,
          height: _clusterSide,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => Container(
            width: _clusterSide,
            height: _clusterSide,
            color: C.surface3,
            child: const Icon(Icons.image_outlined, size: 14, color: C.fg3),
          ),
        ),
      ),
      if (c.n > 1)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          decoration: BoxDecoration(
            color: C.accent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text('${c.n}', style: const TextStyle(color: Colors.white, fontSize: 9)),
        ),
    ]);
  }
}
