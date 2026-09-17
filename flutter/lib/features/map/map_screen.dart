import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PointMode;

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

/// Радиус точки в экранных пикселях.
///
/// Точка — не маркер-виджет, а кружок на канве слоя: фотографий бывают десятки тысяч, и
/// виджет на каждую карта не переживёт. Радиус маленький намеренно: при отдалении точки вдоль
/// маршрута съёмки складываются в пунктирную линию, а крупные кружки слились бы в пятно.
const _dotRadius = 3.0;

/// Сторона квадрата маркера-миниатюры.
const _thumbSide = 26.0;

/// Зум, с которого поверх точек показываются миниатюры.
///
/// Миниатюра — это виджет с картинкой на каждую фотографию, поэтому их число ограничено
/// (`_thumbMax`), и включаются они только вблизи, где кадры уже различимы. Точки при этом
/// никуда не деваются: фотография без миниатюры всё равно видна своим кружком.
const _thumbZoom = 15.0;

/// Потолок числа миниатюр в одном кадре.
///
/// `MarkerLayer` строит виджеты заново на каждое движение карты, а картинка каждой миниатюры
/// — это ещё и файл с диска. В плотном месте на 15-м зуме в кадр попадают тысячи кадров;
/// в разметку уходят только первые `_thumbMax`, а `_points` идут от свежих к старым — значит
/// остаются самые новые.
const _thumbMax = 500;

/// Насколько далеко от точки может попасть палец, чтобы тап по ней сработал, в пикселях.
///
/// Кружок в 3 px пальцем не накрыть, поэтому тап засчитывается ближайшей точке в этом радиусе.
const _tapRadius = 22.0;

/// Запас вокруг видимой части экрана при отборе и отрисовке точек, в пикселях.
///
/// Точка чуть за краем ещё рисуется и ещё попадает в список миниатюр: иначе кружки
/// появлялись бы с задержкой у края экрана при подтягивании карты.
const _viewPadPx = 160.0;

/// Троттлинг пересчёта вида во время жеста, мс.
///
/// Камера во время движения пальцем меняется каждый кадр, а пересчёт — это проход по всем
/// точкам (до `MEDIA_MAP_MAX = 50 000` на сервере). Кадровых пересчётов не нужно: 150 мс
/// незаметны на глаз, но снимают почти всю работу. Точный пересчёт — по концу движения
/// (см. `onMapEvent`). Сами точки от этого не зависят: их позицию слой считает каждый кадр
/// из заранее посчитанных координат (см. `_ensureWorld`), а троттлинг касается только
/// списка миниатюр.
const _viewThrottleMs = 150;

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

/// Слой точек: кружки на канве вместо маркеров-виджетов.
///
/// Координаты точек приходят уже спроецированными на нулевой зум (`world`), а буфер под
/// экранные позиции переиспользуется между кадрами (`scratch`): и то и другое считает
/// `_MapScreenState`, потому что переживает перестройку слоя на каждое движение камеры.
class _DotLayer extends StatelessWidget {
  /// Мировые координаты точек на нулевом зуме: пары x, y подряд.
  final Float64List world;
  /// Буфер под экранные координаты: тот же на все кадры.
  final Float32List scratch;

  const _DotLayer({required this.world, required this.scratch});

  @override
  Widget build(BuildContext context) {
    final cam = MapCamera.of(context);
    // `MobileLayerTransformer` — как у встроенных слоёв: он же поворачивает слой вместе
    // с картой (жест двумя пальцами), поэтому копировать поворот в painter'е не нужно.
    return MobileLayerTransformer(
      child: CustomPaint(
        size: cam.size,
        painter: _DotPainter(world: world, scratch: scratch, cam: cam),
      ),
    );
  }
}

/// Рисует все точки одной пачкой.
///
/// Экранная позиция точки — это её координата на нулевом зуме, умноженная на `2^zoom`
/// (у Меркатора пиксель масштабируется ровно так), минус начало координат камеры. Это та же
/// арифметика, что у `MapCamera.getOffsetFromOrigin`, но без проекции: проход по 50 000 точек
/// стоит доли миллисекунды, поэтому на карте помещаются все фотографии сразу, а не только
/// те, что влезли в потолок маркеров-виджетов.
class _DotPainter extends CustomPainter {
  /// Мировые координаты точек на нулевом зуме: пары x, y подряд.
  final Float64List world;
  /// Буфер под экранные координаты; заполняется заново на каждую отрисовку.
  final Float32List scratch;
  final MapCamera cam;

  _DotPainter({required this.world, required this.scratch, required this.cam});

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.pow(2, cam.zoom).toDouble();
    final origin = cam.pixelOrigin;
    final left = -_viewPadPx;
    final top = -_viewPadPx;
    final right = size.width + _viewPadPx;
    final bottom = size.height + _viewPadPx;
    var n = 0;
    for (var i = 0; i < world.length; i += 2) {
      final x = world[i] * scale - origin.dx;
      final y = world[i + 1] * scale - origin.dy;
      // Точки за краем кадра в пачку не попадают: канва их всё равно отсечёт, но платить
      // за них на каждой отрисовке незачем.
      if (x < left || x > right || y < top || y > bottom) continue;
      scratch[n++] = x;
      scratch[n++] = y;
    }
    if (n == 0) return;
    // Один вызов на все точки: `drawRawPoints` рисует по координатам из буфера, поэтому
    // на кадр не выделяется ни одного объекта на точку.
    canvas.drawRawPoints(
      PointMode.points,
      Float32List.sublistView(scratch, 0, n),
      Paint()
        ..color = C.accent
        // Кружок радиуса r у `PointMode.points` — это штрих толщиной 2r с круглым концом.
        ..strokeWidth = _dotRadius * 2
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_DotPainter old) =>
      old.cam.zoom != cam.zoom ||
      old.cam.pixelOrigin != cam.pixelOrigin ||
      old.cam.rotation != cam.rotation ||
      !identical(old.world, world);
}

/// Экран «Карта»: все фотографии с геометками на подложке OpenStreetMap.
///
/// Ни кластеров, ни счётчиков: каждая фотография — своя точка на своём месте, и нарисованы
/// они все сразу, на любом зуме. С отдалением точки вдоль маршрута съёмки выстраиваются
/// в пунктирные линии, и по ним видно, где человек ходил и ездил; кадры, снятые в одном
/// месте, при этом ложатся друг на друга — на экране они и есть одна точка, потому что
/// между ними доли пикселя.
///
/// С `_thumbZoom` поверх точек показываются миниатюры кадров (не больше `_thumbMax` в кадре):
/// вблизи нужно отличать кадры друг от друга, а картинка на каждую фотографию — это виджет
/// и файл с диска.
///
/// Данные приходят одним запросом целиком (`mediaMap`): сервер отдаёт только `entryId`
/// и координаты — ни имён, ни размеров, потому что карте они не нужны (миниатюра берётся
/// по `entryId`, детали кадра подтягиваются при открытии). Потолок — 50 000 точек
/// (`MEDIA_MAP_MAX` в src/media-feed/media-feed.service.ts), о превышении говорит `truncated`.
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

/// Состояние карты: точки, их мировые координаты, миниатюры текущего вида и кэш кадров
/// для просмотрщика.
class _MapScreenState extends ConsumerState<MapScreen> {
  /// Точки с геометками — всё, что отдал сервер (до 50 000 штук, от свежих к старым).
  List<MapPoint> _points = const [];
  /// Сколько геометок есть на сервере всего: может быть больше, чем пришло в `_points`.
  int _total = 0;
  /// Библиотека не влезла в потолок сервера — в заголовке показываем «N из M».
  bool _truncated = false;
  String? _error;

  /// Мировые координаты точек на нулевом зуме: пары x, y подряд, в порядке `_points`.
  ///
  /// Проекция (у Меркатора это логарифм и тангенс) — самая дорогая часть отрисовки, а нужна
  /// она каждой точке один раз: дальше позиция на экране — умножение на `2^zoom`. Поэтому
  /// кэш живёт в состоянии, а не считается в painter'е на каждый кадр (см. `_ensureWorld`).
  Float64List? _world;
  /// Сколько точек лежит в `_world`: по нему видно, что кэш устарел (загрузка, удаление).
  int _worldCount = -1;
  /// Буфер под экранные координаты для отрисовки: переиспользуется, чтобы на каждый кадр
  /// не выделять память под десятки тысяч точек.
  Float32List? _scratch;

  /// Индексы точек в `_points`, которым сейчас полагается миниатюра (не больше `_thumbMax`).
  List<int> _thumbs = const [];
  /// Зум, на котором посчитаны `_thumbs`.
  ///
  /// Хранится рядом с ними, а не читается из камеры в `build`: от зума зависит, показывать ли
  /// миниатюры, а камера меняется каждый кадр жеста — читай её в `build`, и перерисовка пошла
  /// бы на движение пальца. Здесь снимок зума делается там же, где считается список, то есть
  /// не чаще троттлинга.
  double _zoom = _worldZoom;

  final MapController _mc = MapController();
  /// Карта готова (`onMapReady`): до этого у камеры нет ни размеров, ни матрицы перевода
  /// координат, поэтому ни мировые координаты, ни подгонку вида считать нельзя.
  bool _ready = false;
  /// Отложенный пересчёт миниатюр во время жеста (см. `_scheduleView`).
  Timer? _viewTimer;

  // источник кадров для просмотрщика
  /// Догруженные кадры по `entryId` точки: просмотрщику нужны имя, mime, размер и sha256,
  /// а карте с сервера приходят только координаты.
  final Map<String, MediaItem> _itemCache = {};
  /// `entryId` кадров, запрос по которым уже в полёте: `ensure` вызывается на каждой отрисовке
  /// слайда, и без этого списка в полёте были бы десятки одинаковых запросов.
  final Set<String> _pending = {};
  /// Число кадров для просмотрщика — общий с ним счётчик.
  ///
  /// Нумерация просмотрщика — это нумерация `_points`: тап открывает кадр по его номеру,
  /// листать можно по всей карте от свежих к старым (тот же порядок, что у ленты «Медиа»),
  /// а удаление выкидывает точку из `_points` и уменьшает это число. Не `int`, а
  /// `ValueNotifier`, по той же причине, что и в ленте: удаление меняет число страниц на
  /// месте, и просмотрщик должен узнать об этом сразу (см. `total` у `MediaViewer`).
  final ValueNotifier<int> _count = ValueNotifier(0);
  /// У карты нет ленты кадров — просмотрщик получает их по мере догрузки,
  /// поэтому его надо будить этим сигналом (иначе первый тап висит на спиннере).
  ///
  /// Инкрементит только `_ensureItem` (после успешной догрузки кадра), слушает `MediaViewer`.
  final ValueNotifier<int> _revision = ValueNotifier(0);

  @override
  /// Старт: читаем точки. Всё остальное (вид, миниатюры) — только после `onMapReady`.
  void initState() {
    super.initState();
    _load();
  }

  @override
  /// Уходим с карты — уничтожаем сигналы, которые слушал просмотрщик, и снимаем таймер.
  void dispose() {
    _viewTimer?.cancel();
    _revision.dispose();
    _count.dispose();
    super.dispose();
  }

  /// Читает все точки карты одним запросом.
  ///
  /// Разбирает ответ в `_points`, а `total`/`truncated` запоминает отдельно: точки приходят
  /// с потолком в 50 000, и если библиотека больше, в заголовке честно показывается «N из M»
  /// вместо тихого усечения.
  ///
  /// Побочно: `_points`, `_count` (общий с просмотрщиком), `_total`, `_truncated`, снятие
  /// ошибки и пересчёт вида — но только если карта уже готова: до `onMapReady` у камеры нет
  /// размеров, и считать нечего. Мировые координаты пересоберёт `_syncView` — по `_worldCount`
  /// он увидит, что точек стало другое число.
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
        _count.value = _points.length;
      }
      if (_ready) _syncView();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Показать все точки сразу (кнопка «Показать все фото»).
  ///
  /// `fitCamera` подбирает масштаб так, чтобы прямоугольник вокруг всех точек попал в экран,
  /// с отступом `_fitAllPad` — иначе крайние точки липли бы к рамке. `maxZoom` ограничивает
  /// зум сверху: когда все геометки в одном месте, без ограничения камера подошла бы так
  /// близко, что показала бы одну улицу.
  ///
  /// Список миниатюр пересчитывается здесь явно: программные движения камеры в
  /// `onPositionChanged` намеренно игнорируются, поэтому «само пересчитается» не работает.
  /// Побочно: двигает камеру и пересчитывает вид.
  void _fitAll() {
    if (!_ready || _points.isEmpty) return;
    _mc.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(_points.map((p) => LatLng(p.lat, p.lon)).toList()),
      padding: const EdgeInsets.all(_fitAllPad),
      maxZoom: _fitAllMaxZoom,
    ));
    _syncView();
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
  /// Побочно: двигает камеру (и пересчитывает вид — программные движения в
  /// `onPositionChanged` не обрабатываются). Пустые точки — вид на мир целиком.
  void _fitFirst() {
    if (!_ready) return;
    if (_points.isEmpty) {
      _mc.move(_worldCenter, _worldZoom);
      _syncView();
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
    _syncView();
  }

  /// Откладывает пересчёт вида: во время жеста он идёт не чаще, чем раз в `_viewThrottleMs`,
  /// а последнее положение камеры обрабатывается точно и сразу — по концу движения
  /// (`onMapEvent`).
  void _scheduleView() {
    if (_viewTimer?.isActive ?? false) return;
    _viewTimer = Timer(const Duration(milliseconds: _viewThrottleMs), () {
      _viewTimer = null;
      _syncView();
    });
  }

  /// Видимая часть карты, расширенная на `_viewPadPx` экранных пикселей по каждому краю.
  ///
  /// Нужна как дешёвый фильтр до проекции: `contains` — четыре сравнения, а проекция точки
  /// заметно дороже, и при 50 000 точках вне экрана почти всегда большинство. Запас в градусах
  /// считается из размера мира: при зуме z в мире `256 · 2^z` пикселей на 360° долготы. По
  /// широте он берётся с избытком (у Меркатора градус широты на пиксель пропорционален cos φ)
  /// — это безопасно, лишние точки отсеет точная проверка после проекции.
  LatLngBounds _paddedViewBounds(MapCamera cam) {
    final b = cam.visibleBounds;
    final pad = 360.0 / (_worldPxAtZoom0 * math.pow(2, cam.zoom)) * _viewPadPx;
    return LatLngBounds.worldSafe(
      north: math.min(LatLngBounds.maxLatitude, b.north + pad),
      south: math.max(LatLngBounds.minLatitude, b.south - pad),
      longitudeCenter: b.longitudeCenter,
      longitudeWidth: math.min(360.0, b.longitudeWidth + 2 * pad),
    );
  }

  /// Пересобирает мировые координаты точек, если они устарели.
  ///
  /// Считает проекцию каждой точки на нулевом зуме (`latLngToOffset(latLng, 0)`) и заводит
  /// буфер под экранные позиции. Это единственное место, где вообще считается проекция:
  /// у Меркатора мировой пиксель на зуме z — это пиксель на нулевом зуме, умноженный на `2^z`,
  /// поэтому отрисовка обходится умножением и вычитанием (см. `_DotPainter`).
  ///
  /// Вызывается перед каждым пересчётом вида, но пересобирает кэш только когда число точек
  /// изменилось — то есть после загрузки и после удаления кадра. Проекция 50 000 точек — это
  /// несколько десятков миллисекунд, и платить их на каждое движение карты нельзя.
  ///
  /// Побочно: `_world`, `_worldCount`, `_scratch`.
  void _ensureWorld(MapCamera cam) {
    if (_world != null && _worldCount == _points.length) return;
    final crs = cam.crs;
    final world = Float64List(_points.length * 2);
    for (var i = 0; i < _points.length; i++) {
      final p = _points[i];
      final o = crs.latLngToOffset(LatLng(p.lat, p.lon), 0);
      world[i * 2] = o.dx;
      world[i * 2 + 1] = o.dy;
    }
    _world = world;
    _worldCount = _points.length;
    _scratch = Float32List(_points.length * 2);
  }

  /// Пересчитывает вид и кладёт его в состояние.
  ///
  /// Точки слой рисует сам и всегда — от зума зависит только список миниатюр, поэтому здесь
  /// считаются мировые координаты (если кэш устарел) и номера кадров под миниатюры.
  ///
  /// Побочно: `setState` со списком миниатюр и снимком зума. Запросов здесь нет: считаем только
  /// по тому, что уже в памяти. Вызывать из `setState` нельзя — этот метод делает свой
  /// (см. `_handleDelete`).
  void _syncView() {
    if (!_ready || !mounted) return;
    final cam = _mc.camera;
    _ensureWorld(cam);
    final thumbs = _computeThumbs(cam);
    setState(() {
      _thumbs = thumbs;
      _zoom = cam.zoom;
    });
  }

  /// Набирает номера кадров под миниатюры для текущего положения камеры.
  ///
  /// Нужен только вблизи (`_thumbZoom`): дальше миниатюры не показываются, и список пуст.
  /// Точка отсекается по расширенной видимой части (`_paddedViewBounds`) — четыре сравнения
  /// вместо проекции. Порядок обхода — порядок `_points`, от свежих к старым, поэтому
  /// в потолок `_thumbMax` упирается хвост старых кадров, а не свежие.
  ///
  /// Побочных эффектов нет: только чтение точек и положения камеры.
  List<int> _computeThumbs(MapCamera cam) {
    final size = cam.nonRotatedSize;
    if (size.width <= 0 || size.height <= 0) return const [];
    if (cam.zoom < _thumbZoom) return const [];
    final view = _paddedViewBounds(cam);
    final thumbs = <int>[];
    for (var i = 0; i < _points.length; i++) {
      final p = _points[i];
      if (!view.contains(LatLng(p.lat, p.lon))) continue;
      thumbs.add(i);
      if (thumbs.length >= _thumbMax) break;
    }
    return thumbs;
  }

  // ---------- источник кадров для просмотрщика ----------

  /// Кадр для просмотрщика по номеру точки в `_points`.
  ///
  /// Кадры лежат в `_itemCache` по `entryId`: пока кадр не догружен, возвращается `null`,
  /// и просмотрщик показывает спиннер до сигнала `_revision`. Границы проверяются по
  /// `_points`: после удаления нумерация сдвинулась, а просмотрщик может спросить номер
  /// из прежней. Побочных эффектов нет.
  MediaItem? _itemAt(int i) {
    if (i < 0 || i >= _points.length) return null;
    return _itemCache[_points[i].entryId];
  }

  /// Догружает кадр по номеру точки: у карты в памяти только координаты, а просмотрщику нужны
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
  void _ensureItem(int i) {
    if (i < 0 || i >= _points.length) return;
    final p = _points[i];
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

  /// Открывает просмотрщик на кадре с номером `index` в `_points`.
  ///
  /// Нумерация просмотрщика — та же, что у `_points`, поэтому листать можно по всей карте
  /// от свежих к старым, а начальный кадр — тот, по которому тапнули.
  ///
  /// `ensure` здесь точечный, в отличие от ленты «Медиа»: кадров в памяти нет, поэтому
  /// запрашиваются ровно те номера, которые просит просмотрщик (соседние — заранее, чтобы
  /// следующий слайд был готов до свайпа).
  ///
  /// Побочно: `_count` (общий с просмотрщиком счётчик) и маршрут просмотрщика.
  void _openAt(int index) {
    if (index < 0 || index >= _points.length) return;
    _count.value = _points.length;
    Navigator.push(context, MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => MediaViewer(
        api: ref.read(appStateProvider).api,
        total: _count,
        initialIndex: index,
        getItem: _itemAt,
        ensure: (s, e) {
          for (var i = s; i <= e; i++) {
            _ensureItem(i);
          }
        },
        onDelete: _handleDelete,
        revision: _revision,
      ),
    ));
  }

  /// Открывает кадр по тапу в карту: точка ближе всех к пальцу в радиусе `_tapRadius`.
  ///
  /// Тапа по самому кружку нет — точки рисует слой на канве, а не виджеты, и попасть пальцем
  /// в кружок в 3 px нельзя. Поэтому тап переводится в экранные координаты, и выбирается
  /// ближайшая точка. Считается та же арифметика, что в `_DotPainter` (мировая координата на
  /// `2^zoom` минус начало координат камеры), поэтому тап не разъезжается с картинкой.
  ///
  /// Побочно: открывает просмотрщик (`_openAt`). Тап мимо всех точек — ничего не делает.
  void _tapDot(LatLng at) {
    final world = _world;
    if (world == null || world.isEmpty) return;
    final cam = _mc.camera;
    final tap = cam.getOffsetFromOrigin(at);
    final scale = math.pow(2, cam.zoom).toDouble();
    final origin = cam.pixelOrigin;
    var best = -1;
    var bestDist = _tapRadius * _tapRadius;
    for (var i = 0; i < world.length; i += 2) {
      final dx = world[i] * scale - origin.dx - tap.dx;
      final dy = world[i + 1] * scale - origin.dy - tap.dy;
      final dist = dx * dx + dy * dy;
      // Строго меньше: при равном расстоянии остаётся первая из совпавших точек, то есть
      // самая свежая — `_points` идут от свежих к старым.
      if (dist < bestDist) {
        bestDist = dist;
        best = i ~/ 2;
      }
    }
    if (best >= 0) _openAt(best);
  }

  /// Убирает удалённый кадр с карты.
  ///
  /// Нумерация просмотрщика — та же, что у `_points`, поэтому удаление сводится к выкидыванию
  /// точки по её номеру и уменьшению общего счётчика: индексы всех, что были правее, съезжают
  /// на единицу сами, и просмотрщик листает по сдвинутым номерам (см. контракт `MediaViewer`).
  ///
  /// Пересчёт вида идёт после `setState`, а не внутри него: `_syncView` делает свой `setState`,
  /// и вложенный вызов означал бы лишнюю перерисовку на каждый удалённый кадр. Мировые
  /// координаты пересоберутся там же — по `_worldCount` видно, что точек стало меньше.
  ///
  /// Побочно: `_points`, `_count` (общий с просмотрщиком) и пересчёт вида — точка исчезает
  /// с карты.
  void _handleDelete(int index) {
    if (!mounted) return;
    if (index < 0 || index >= _points.length) return;
    setState(() {
      _points = List<MapPoint>.from(_points)..removeAt(index);
    });
    _count.value = _points.length;
    _syncView();
  }

  @override
  Widget build(BuildContext context) {
    final count = _points.length;
    final api = ref.read(appStateProvider).api;
    final world = _world;
    final scratch = _scratch;
    final thumbs = _zoom >= _thumbZoom;
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
              // теперь можно считать мировые координаты и выбирать стартовый вид. `_fitFirst`
              // пересчитает вид сам — программные движения камеры сюда больше не приходят.
              _ready = true;
              _fitFirst();
            },
            // Тап открывает ближайший кадр. Мимо маркеров-миниатюр он доходит сюда, потому что
            // их ловит собственный обработчик — вложенный распознаватель жестов выигрывает
            // у карты.
            onTap: (tapPosition, point) => _tapDot(point),
            // Камера меняется и на программные движения (`_fitAll`, `_fitFirst`, инерция),
            // поэтому пересчёт идёт только на жест — и то не чаще, чем раз в
            // `_viewThrottleMs`: во время движения пальцем пересчитывать список миниатюр
            // каждый кадр незачем, а стартовый перелёт к «самой фотографируемой» клетке
            // проходил бы через десятки промежуточных положений. Точки от троттлинга
            // не зависят: слой считает их позиции сам, каждый кадр.
            onPositionChanged: (camera, hasGesture) {
              if (hasGesture) _scheduleView();
            },
            // Конец жеста, инерции, двойного тапа и изменение размера карты: последнее
            // положение камеры, на котором миниатюры обязаны совпасть с картой. Троттлинг мог
            // отстать на 150 мс, здесь счёт идёт точно и сразу.
            onMapEvent: (e) {
              if (e is MapEventMoveEnd ||
                  e is MapEventFlingAnimationEnd ||
                  e is MapEventDoubleTapZoomEnd ||
                  e is MapEventNonRotatedSizeChange) {
                _syncView();
              } else if (e is MapEventScrollWheelZoom) {
                // Колесо/тачпад шлёт поток событий без «конца» — используем тот же троттлинг.
                _scheduleView();
              }
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'ru.cloudly.cloudly_flutter',
              maxZoom: _maxZoom,
            ),
            // Все точки и на всех зумах: слой рисует их одной пачкой на канве, поэтому
            // на экране помещаются все фотографии сразу, без потолка и без схлопывания.
            if (world != null && scratch != null && world.isNotEmpty)
              _DotLayer(world: world, scratch: scratch),
            // Вблизи поверх точек — миниатюры, чтобы отличать кадры друг от друга. Их потолок
            // `_thumbMax`, но фотография без миниатюры всё равно видна своим кружком.
            if (thumbs)
              MarkerLayer(
                markers: _thumbs
                    .map((i) => Marker(
                          point: LatLng(_points[i].lat, _points[i].lon),
                          width: _thumbSide,
                          height: _thumbSide,
                          child: GestureDetector(
                            onTap: () => _openAt(i),
                            child: _thumb(_points[i].entryId, api),
                          ),
                        ))
                    .toList(),
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

  /// Маркер-миниатюра: один кадр — один маркер, показывается с зума `_thumbZoom` и выше.
  ///
  /// Картинку отдаёт сервер (`thumbUrl`), при неудаче остаётся иконка на сером фоне: маркер
  /// должен оставаться видимым и тапаемым даже без картинки.
  ///
  /// `api` приходит из `build`, а не читается из провайдера здесь: маркеров в кадре до
  /// `_thumbMax`, и на каждое движение карты они строятся заново.
  Widget _thumb(String entryId, CloudlyApi api) {
    return AuthThumb(
      api: api,
      url: api.thumbUrl(entryId),
      size: _thumbSide,
      radius: 5,
      fallback: const Icon(Icons.image_outlined, size: 14, color: C.fg3),
    );
  }
}
