import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/widgets.dart';
import '../media/media_viewer.dart';

/// Размер клетки кластеризации в экранных пикселях.
///
/// Клетка — единица схлопывания: точки, попавшие в одну клетку, дают один маркер. Она чуть
/// больше самого маркера (`_clusterSide`), чтобы соседние миниатюры не соприкасались вплотную:
/// при клетке, равной маркеру, они бы сливались в сплошное пятно. Тем же числом задаётся запас
/// вокруг видимой части экрана — точка чуть за краем ещё считается видимой, чтобы маркер не
/// мигал при подтягивании карты.
const _clusterPx = 36.0;
/// Сторона квадрата маркера-миниатюры.
const _clusterSide = 26.0;
/// Потолок числа маркеров в одном кадре.
///
/// Кластеры сортируются по числу кадров, и в разметку уходят только первые 600. На телефоне
/// в видимую часть попадает около трёхсот клеток, так что запас есть; на планшете или при
/// сильном отдалении клеток бывают тысячи, а `MarkerLayer` строит виджет на каждый маркер
/// заново на каждое движение карты — без потолка это заметные рывки.
const _clusterMax = 600;

/// Троттлинг пересчёта кластеров во время жеста, мс.
///
/// Камера во время движения пальцем меняется каждый кадр, а пересчёт — это проход по точкам
/// (до `MEDIA_MAP_MAX = 50 000` на сервере) плюс перестройка до `_clusterMax` маркеров с
/// картинками. Кадровых пересчётов не нужно: 150 мс незаметны на глаз, но снимают почти всю
/// работу. Точный пересчёт делается по концу движения (см. `onMapEvent`).
const _clusterThrottleMs = 150;

/// Ширина мира в пикселях на нулевом зуме — из неё считается «сколько градусов в пикселе»
/// при отсечке точек по видимой части (см. `_paddedViewBounds`).
const _worldPxAtZoom0 = 256.0;

/// Границы зума карты: ниже виден весь мир одной картинкой, выше — квартал.
const _minZoom = 2.0;
const _maxZoom = 19.0;
/// Вид «весь мир»: с него открывается карта и на него откатывается `_fitFirst`, когда
/// геометок нет вовсе.
const _worldCenter = LatLng(20, 10);
const _worldZoom = 2.0;

/// Сторона клетки грубого подсчёта в `_fitFirst`, в градусах.
///
/// Клетка не квадрат на местности: 0.05° — это ≈5.5 км по широте и ≈2.7 км по долготе на
/// 60-й параллели (и ещё уже ближе к полюсу). Для выбора «где больше всего кадров» это
/// не важно: важно, что счёт не размазывается по всему городу.
const _fitCellDeg = 0.05;
/// Отступ и потолок зума для подгонки вида: «показать все точки» и стартовый вид.
const _fitAllPad = 40.0;
const _fitFirstPad = 60.0;
const _fitAllMaxZoom = 15.0;
const _fitFirstMaxZoom = 16.0;

/// Клетка грубого подсчёта в `_fitFirst`: сколько в ней кадров и где её границы.
typedef _FitCell = ({int count, double south, double north, double west, double east});

/// Кластер: накопитель для точек, попавших в одну экранную клетку.
///
/// Координаты суммируются, а не усредняются на ходу: маркер ставится в среднее место клетки
/// (деление на `n` — уже при отрисовке), поэтому до конца обхода нужны и сумма, и счётчик.
/// `ids` — индексы точек в `_points`: это и есть группа кадров, которую открывает просмотрщик.
class _Cluster {
  double lat;
  double lon;
  int n;
  final List<int> ids;
  _Cluster(this.lat, this.lon, this.n, this.ids);
}

/// Экран «Карта»: точки с геометками на подложке OpenStreetMap, сгруппированные в кластеры.
///
/// Данные приходят одним запросом целиком (`mediaMap`): сервер отдаёт только `entryId`
/// и координаты — ни имён, ни размеров, потому что карте они не нужны (миниатюра берётся
/// по `entryId`, детали кадра подтягиваются при открытии). Потолок — 50 000 точек
/// (`MEDIA_MAP_MAX` в src/media-feed/media-feed.service.ts), о превышении говорит `truncated`.
///
/// Вся группировка считается на клиенте: она зависит от зума и размера экрана, то есть от того,
/// чего сервер не знает. Обратная сторона — пересчёт на движение камеры, поэтому он делается
/// не на каждое её изменение: во время жеста — не чаще `_clusterThrottleMs`, точно — по концу
/// движения (`onMapEvent`), а точки сначала отсекаются по видимой части (`_computeClusters`).
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

/// Состояние карты: точки, кластеры и кэш кадров для просмотрщика.
class _MapScreenState extends ConsumerState<MapScreen> {
  /// Точки с геометками — всё, что отдал сервер (до 50 000 штук, от свежих к старым).
  List<MapPoint> _points = const [];
  /// Сколько геометок есть на сервере всего: может быть больше, чем пришло в `_points`.
  int _total = 0;
  /// Библиотека не влезла в потолок сервера — в заголовке показываем «N из M».
  bool _truncated = false;
  String? _error;
  /// Кластеры текущего вида; пересчитываются из `_points` и положения камеры.
  List<_Cluster> _clusters = const [];
  final MapController _mc = MapController();
  /// Карта готова (`onMapReady`): до этого у камеры нет ни размеров, ни матрицы перевода
  /// координат, поэтому ни кластеры, ни подгонку вида считать нельзя.
  bool _ready = false;
  /// Отложенный пересчёт кластеров во время жеста (см. `_scheduleClusters`).
  Timer? _clusterTimer;

  // источник кадров для просмотрщика
  /// Догруженные кадры по `entryId` точки: просмотрщику нужны имя, mime, размер и sha256,
  /// а карте с сервера приходят только координаты.
  final Map<String, MediaItem> _itemCache = {};
  /// `entryId` кадров, запрос по которым уже в полёте: `ensure` вызывается на каждой отрисовке
  /// слайда, и без этого списка в полёте были бы десятки одинаковых запросов.
  final Set<String> _pending = {};
  /// Группа открытого маркера — индексы точек в `_points`; `null`, когда просмотрщик закрыт.
  /// Живёт, пока он открыт: `getItem` и `ensure` работают по номерам внутри группы.
  List<int>? _group;
  /// Сколько кадров в открытой группе — общий с просмотрщиком счётчик.
  ///
  /// Не `int`, а `ValueNotifier`, по той же причине, что и в ленте «Медиа»: удаление кадра
  /// уменьшает группу, и просмотрщик должен узнать об этом сразу, а не держать зафиксированное
  /// на момент открытия число страниц (см. `total` у `MediaViewer`).
  final ValueNotifier<int> _groupTotal = ValueNotifier(0);
  /// У карты нет ленты кадров — просмотрщик получает их по мере догрузки,
  /// поэтому его надо будить этим сигналом (иначе первый тап висит на спиннере).
  ///
  /// Инкрементит только `_ensureItem` (после успешной догрузки кадра), слушает `MediaViewer`.
  final ValueNotifier<int> _revision = ValueNotifier(0);

  @override
  /// Старт: читаем точки. Всё остальное (вид, кластеры) — только после `onMapReady`.
  void initState() {
    super.initState();
    _load();
  }

  @override
  /// Уходим с карты — уничтожаем сигнал, который слушал просмотрщик, и снимаем таймер.
  void dispose() {
    _clusterTimer?.cancel();
    _revision.dispose();
    _groupTotal.dispose();
    super.dispose();
  }

  /// Читает все точки карты одним запросом.
  ///
  /// Разбирает ответ в `_points`, а `total`/`truncated` запоминает отдельно: точки приходят
  /// с потолком в 50 000, и если библиотека больше, в заголовке честно показывается «N из M»
  /// вместо тихого усечения.
  ///
  /// Побочно: `_points`, `_total`, `_truncated`, снятие ошибки и пересчёт кластеров — но только
  /// если карта уже готова: до `onMapReady` у камеры нет размеров, и считать нечего.
  Future<void> _load() async {
    try {
      final r = await ref.read(appStateProvider).api.mediaMap();
      if (mounted) {
        setState(() {
          _points = (r['points'] as List? ?? const [])
              .whereType<Map>()
              .map((e) => MapPoint.fromJson(e.cast<String, dynamic>()))
              .toList();
          _total = toNum(r['total'])?.toInt() ?? 0;
          _truncated = r['truncated'] == true;
          _error = null;
        });
      }
      if (_ready) _syncClusters();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Показать все точки сразу (кнопка «Показать все фото»).
  ///
  /// `fitCamera` подбирает масштаб так, чтобы прямоугольник вокруг всех точек попал в экран,
  /// с отступом `_fitAllPad` — иначе крайние маркеры липли бы к рамке. `maxZoom` ограничивает
  /// зум сверху: когда все геометки в одном месте, без ограничения камера подошла бы так
  /// близко, что показала бы одну улицу.
  ///
  /// Кластеры пересчитываются здесь явно: программные движения камеры в `onPositionChanged`
  /// намеренно игнорируются (см. `onMapEvent`), поэтому «само пересчитается» больше не работает.
  /// Побочно: двигает камеру и пересчитывает кластеры.
  void _fitAll() {
    if (!_ready || _points.isEmpty) return;
    _mc.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(_points.map((p) => LatLng(p.lat, p.lon)).toList()),
      padding: const EdgeInsets.all(_fitAllPad),
      maxZoom: _fitAllMaxZoom,
    ));
    _syncClusters();
  }

  /// Стартовый вид карты: не весь мир, а самая «фотографируемая» клетка.
  ///
  /// У личной библиотеки обычно есть одно основное место (дом), и открывать карту на плане
  /// мира с одинокой точкой посередине бессмысленно. Клетка выбирается грубым подсчётом по
  /// сетке `_fitCellDeg`: расстояния не считаются вовсе, задача — угадать, куда смотреть.
  ///
  /// Проход один: в каждой клетке сразу копятся и счётчик, и границы — по ним строится
  /// прямоугольник для `fitCamera`, второй проход по точкам не нужен.
  ///
  /// Побочно: двигает камеру (и пересчитывает кластеры — программные движения в
  /// `onPositionChanged` не обрабатываются). Пустые точки — вид на мир целиком.
  void _fitFirst() {
    if (!_ready) return;
    if (_points.isEmpty) {
      _mc.move(_worldCenter, _worldZoom);
      _syncClusters();
      return;
    }
    final cells = <String, _FitCell>{};
    for (final p in _points) {
      // Ключ — «округлённые» координаты: точки одной клетки дают один ключ.
      final k = '${(p.lat / _fitCellDeg).round()}:${(p.lon / _fitCellDeg).round()}';
      final c = cells[k];
      cells[k] = c == null
          ? (count: 1, south: p.lat, north: p.lat, west: p.lon, east: p.lon)
          : (
              count: c.count + 1,
              south: math.min(c.south, p.lat),
              north: math.max(c.north, p.lat),
              west: math.min(c.west, p.lon),
              east: math.max(c.east, p.lon),
            );
    }
    // Строго больше: при равенстве остаётся клетка, встретившаяся раньше, а точки идут
    // от свежих к старым — значит побеждает то место, где снимали последний раз.
    var best = cells.values.first;
    for (final c in cells.values) {
      if (c.count > best.count) best = c;
    }
    _mc.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds(LatLng(best.south, best.west), LatLng(best.north, best.east)),
      padding: const EdgeInsets.all(_fitFirstPad),
      maxZoom: _fitFirstMaxZoom,
    ));
    _syncClusters();
  }

  /// Откладывает пересчёт кластеров: во время жеста он идёт не чаще, чем раз в
  /// `_clusterThrottleMs`, а последнее положение камеры обрабатывается точно и сразу — по
  /// концу движения (`onMapEvent`).
  void _scheduleClusters() {
    if (_clusterTimer?.isActive ?? false) return;
    _clusterTimer = Timer(const Duration(milliseconds: _clusterThrottleMs), () {
      _clusterTimer = null;
      _syncClusters();
    });
  }

  /// Видимая часть карты, расширенная на `_clusterPx` экранных пикселей по каждому краю.
  ///
  /// Нужна как дешёвый фильтр до проекции: `contains` — четыре сравнения, а проекция точки
  /// (`latLngToScreenOffset`) заметно дороже, и при 50 000 точках вне экрана почти всегда
  /// большинство. Запас в градусах считается из размера мира: при зуме z в мире `256 · 2^z`
  /// пикселей на 360° долготы. По широте он берётся с избытком (у Меркатора градус широты на
  /// пиксель пропорционален cos φ) — это безопасно, лишние точки отсеет точная проверка после
  /// проекции.
  LatLngBounds _paddedViewBounds(MapCamera cam) {
    final b = cam.visibleBounds;
    final pad = 360.0 / (_worldPxAtZoom0 * math.pow(2, cam.zoom)) * _clusterPx;
    return LatLngBounds.worldSafe(
      north: math.min(LatLngBounds.maxLatitude, b.north + pad),
      south: math.max(LatLngBounds.minLatitude, b.south - pad),
      longitudeCenter: b.longitudeCenter,
      longitudeWidth: math.min(360.0, b.longitudeWidth + 2 * pad),
    );
  }

  /// Пересчитывает кластеры под текущее положение камеры.
  ///
  /// Точки сначала отсекаются по расширенной видимой части (`_paddedViewBounds`), и только
  /// оставшиеся проецируются в экранные координаты и раскладываются по клеткам сетки
  /// `_clusterPx`. Клетка и есть кластер: в ней копятся сумма координат, счётчик и индексы —
  /// так вместо десятков наложенных миниатюр на экране остаётся один маркер.
  ///
  /// Отбор по видимой части — не оптимизация ради оптимизации: точек бывает 50 000, а виджет
  /// маркера строится на каждый, и всё это перестраивается при движении карты. Поэтому
  /// сортировка по числу кадров и потолок `_clusterMax` — тоже часть этой экономии.
  ///
  /// Побочно: `setState` с новыми кластерами. Запросов здесь нет: считаем только по тому,
  /// что уже в памяти. Вызывать из `setState` нельзя — этот метод делает свой (см.
  /// `_handleDelete`).
  void _syncClusters() {
    if (!_ready || !mounted) return;
    final list = _computeClusters();
    setState(() => _clusters = list);
  }

  /// Считает кластеры для текущего положения камеры; пустой список — считать нечего.
  List<_Cluster> _computeClusters() {
    final cam = _mc.camera;
    final size = cam.nonRotatedSize;
    if (size.width <= 0 || size.height <= 0) return const [];
    final view = _paddedViewBounds(cam);
    final cells = <String, _Cluster>{};
    for (var i = 0; i < _points.length; i++) {
      final p = _points[i];
      if (!view.contains(LatLng(p.lat, p.lon))) continue;
      final off = cam.latLngToScreenOffset(LatLng(p.lat, p.lon));
      // Запас вокруг видимой части: точка чуть за краем ещё участвует — так маркер не исчезает
      // на полпути при подтягивании карты и появляется заранее при отдалении.
      if (off.dx < -_clusterPx || off.dy < -_clusterPx ||
          off.dx > size.width + _clusterPx || off.dy > size.height + _clusterPx) {
        continue;
      }
      // Ключ — номер клетки в экранной сетке: он и группирует точки.
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
    // Сверху — самые населённые клетки: если в кадр их не помещается больше потолка, обрезается
    // именно хвост с одиночными точками, а не то, ради чего на карту смотрят.
    final list = cells.values.toList()..sort((a, b) => b.n.compareTo(a.n));
    return list.take(_clusterMax).toList();
  }

  // ---------- источник кадров для просмотрщика ----------

  /// Кадр для просмотрщика по номеру внутри открытой группы.
  ///
  /// Группа хранит индексы точек, а кадры лежат в `_itemCache` по `entryId`: пока кадр не
  /// догружен, возвращается `null`, и просмотрщик показывает спиннер до сигнала `_revision`.
  /// Границы проверяются дважды — и по группе, и по точкам: после удаления группа уже
  /// сдвинута, а просмотрщик может спросить номер из прежней нумерации.
  MediaItem? _groupItem(int gi) {
    final group = _group;
    if (group == null || gi < 0 || gi >= group.length) return null;
    final idx = group[gi];
    if (idx < 0 || idx >= _points.length) return null;
    return _itemCache[_points[idx].entryId];
  }

  /// Догружает кадр по точке группы: у карты в памяти только координаты, а просмотрщику нужны
  /// имя, mime, размер и sha256.
  ///
  /// Запрашивается одна запись (`mediaInfo`), а не кусок ленты: на карте кадры открывают
  /// точечно, и грузить ради одного тапа соседей по ленте незачем. Повторные просьбы отсекаются
  /// по `_pending`, потому что `ensure` вызывается на каждой отрисовке слайда. Оттуда же
  /// `_pending` и снимается — в `whenComplete`, то есть и при ошибке: иначе кадр после сбоя
  /// нельзя было бы запросить повторно.
  ///
  /// Побочно: `_itemCache` и `_revision.value++` — сигнал просмотрщику, что слайд можно рисовать.
  /// Ошибку глотаем: без кадра слайд останется спиннером, но карта из-за этого падать не должна.
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
        tzOffsetMin: d.tzOffsetMin,
        size: d.size,
        // Готовность превью не проверяем намеренно: сервер отдаёт на карту только кадры
        // с собранным превью (фильтр `previewState = 'done'` в mapPoints), так что здесь
        // он всегда готов.
        previewState: 'done',
      );
      if (mounted) _revision.value++;
    }).catchError((_) {}).whenComplete(() => _pending.remove(p.entryId));
  }

  /// Открывает просмотрщик на группе маркера: листать можно по кадрам, из которых он собран.
  ///
  /// `_group` — индексы точек в `_points`; группа живёт, пока открыт просмотрщик, потому что
  /// `getItem` и `ensure` работают по номерам внутри неё. Число кадров для просмотрщика —
  /// размер группы, а не всей карты: листать имеет смысл по тому, что было в маркере, а не по
  /// всем кадрам библиотеки. Отдаётся он общим счётчиком `_groupTotal`, а не числом: при
  /// удалении кадра группа становится короче, и просмотрщик должен узнать об этом сразу.
  ///
  /// `ensure` здесь точечный, в отличие от ленты «Медиа»: кадров в памяти нет, поэтому
  /// запрашиваются ровно те номера, которые просит просмотрщик.
  ///
  /// Побочно: `_group`, `_groupTotal` и маршрут просмотрщика; после закрытия группа
  /// сбрасывается — иначе `getItem` отвечал бы по индексам, которых уже нет.
  void _openGroup(_Cluster c) {
    setState(() {
      _group = c.ids;
      _groupTotal.value = c.ids.length;
    });
    Navigator.push(context, MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => MediaViewer(
        api: ref.read(appStateProvider).api,
        total: _groupTotal,
        initialIndex: 0,
        getItem: _groupItem,
        ensure: (s, e) {
          // Диапазон используется как есть: соседние кадры нужны просмотрщику заранее,
          // чтобы следующий слайд был готов до свайпа.
          for (var i = s; i <= e; i++) {
            _ensureItem(i);
          }
        },
        onDelete: _handleDelete,
        revision: _revision,
      ),
    )).then((_) {
      if (mounted) {
        setState(() {
          _group = null;
          _groupTotal.value = 0;
        });
      }
    });
  }

  /// Убирает удалённый кадр из карты и сдвигает нумерацию группы.
  ///
  /// Удаление затрагивает две нумерации сразу. Точки: удалённая выкидывается из `_points`,
  /// и индексы всех, что были правее, уменьшаются на единицу — поэтому остальные индексы группы
  /// тоже пересчитываются (кто был правее удалённой точки, тот сдвинулся). Позиция внутри группы
  /// остаётся прежней, а если удалили последний кадр — берётся последний из оставшихся:
  /// просмотрщик после этого листает по сдвинутым номерам.
  ///
  /// Пересчёт кластеров идёт после `setState`, а не внутри него: `_syncClusters` делает свой
  /// `setState`, и вложенный вызов означал бы лишнюю перерисовку на каждый удалённый кадр.
  ///
  /// Побочно: `_points`, `_group`, `_groupTotal` (общий с просмотрщиком) и пересчёт кластеров —
  /// маркер стал меньше на один кадр, а если кадр был единственным, маркер исчезает совсем.
  void _handleDelete(int pos) {
    if (!mounted) return;
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
      _groupTotal.value = nextGroup.length;
    });
    _syncClusters();
  }

  @override
  Widget build(BuildContext context) {
    final count = _points.length;
    final api = ref.read(appStateProvider).api;
    return Scaffold(
      backgroundColor: C.canvas,
      // `backgroundColor` не задаём: подложка шапки уже в `appBarTheme` (theme.dart),
      // дублировать её здесь незачем.
      appBar: AppBar(
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
            initialCenter: _worldCenter,
            initialZoom: _worldZoom,
            minZoom: _minZoom,
            maxZoom: _maxZoom,
            onMapReady: () {
              // С этого момента у камеры есть размеры и матрица перевода координат: только
              // теперь можно считать кластеры и выбирать стартовый вид. `_fitFirst` пересчитает
              // кластеры сам — программные движения камеры сюда больше не приходят.
              _ready = true;
              _fitFirst();
            },
            // Камера меняется и на программные движения (`_fitAll`, `_fitFirst`, инерция),
            // поэтому пересчёт идёт только на жест — и то не чаще, чем раз в
            // `_clusterThrottleMs`: во время движения пальцем пересчитывать кластеры каждый
            // кадр незачем, а стартовый перелёт к «самой фотографируемой» клетке проходил бы
            // через десятки промежуточных положений.
            onPositionChanged: (camera, hasGesture) {
              if (hasGesture) _scheduleClusters();
            },
            // Конец жеста, инерции, двойного тапа и изменение размера карты: последнее
            // положение камеры, на котором маркеры обязаны совпасть с картой. Троттлинг мог
            // отстать на 150 мс, здесь счёт идёт точно и сразу.
            onMapEvent: (e) {
              if (e is MapEventMoveEnd ||
                  e is MapEventFlingAnimationEnd ||
                  e is MapEventDoubleTapZoomEnd ||
                  e is MapEventNonRotatedSizeChange) {
                _syncClusters();
              } else if (e is MapEventScrollWheelZoom) {
                // Колесо/тачпад шлёт поток событий без «конца» — используем тот же троттлинг.
                _scheduleClusters();
              }
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'ru.cloudly.cloudly_flutter',
              maxZoom: _maxZoom,
            ),
            MarkerLayer(
              markers: _clusters.map((c) => Marker(
                // Маркер ставится в среднее место клетки — отсюда деление суммы на счётчик.
                point: LatLng(c.lat / c.n, c.lon / c.n),
                width: _clusterSide,
                height: _clusterSide,
                child: GestureDetector(
                  onTap: () => _openGroup(c),
                  child: _clusterMarker(c, api),
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
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text('© OpenStreetMap contributors',
                style: TextStyle(color: Colors.white, fontSize: 10)),
          ),
        ),
        if (_error != null)
          Positioned(left: 12, top: 8, child: _pill(_error!, C.danger)),
        // Плашка означает «точек нет, ошибки нет» — под это условие попадают оба случая:
        // ответ ещё не пришёл и ответ пришёл пустым. Различить их по состоянию нельзя,
        // поэтому в обоих говорится нейтральное «Загружаю метки…», а не «фото нет».
        if (_points.isEmpty && _error == null)
          Positioned(left: 12, top: 8, child: _pill('Загружаю метки…', C.surface2)),
      ]),
    );
  }

  /// Плашка поверх карты: ошибка загрузки или «метки ещё не пришли».
  Widget _pill(String text, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: const TextStyle(color: C.fg, fontSize: 12)),
    );
  }

  /// Маркер кластера: миниатюра кадра и, если кадров больше одного, счётчик поверх неё.
  ///
  /// Миниатюра берётся по первой точке кластера (`ids.first`) — а `ids` заполняются в порядке
  /// `_points`, то есть от свежих к старым, поэтому маркер показывает самый свежий кадр клетки.
  /// Картинку отдаёт сервер (`thumbUrl`), при неудаче остаётся иконка на сером фоне: маркер
  /// должен оставаться видимым и тапаемым даже без картинки.
  ///
  /// `api` приходит из `build`, а не читается из провайдера здесь: маркеров в кадре до
  /// `_clusterMax`, и на каждое движение карты они строятся заново.
  Widget _clusterMarker(_Cluster c, CloudlyApi api) {
    final entryId = _points[c.ids.first].entryId;
    return Stack(alignment: Alignment.center, children: [
      // Миниатюра первого кадра клетки: ручка закрыта сессией, поэтому картинку строит
      // [AuthThumb] — он же подставляет заглушку, если превью ещё не собрано.
      AuthThumb(
        api: api,
        url: api.thumbUrl(entryId),
        size: _clusterSide,
        radius: 5,
        fallback: const Icon(Icons.image_outlined, size: 14, color: C.fg3),
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
