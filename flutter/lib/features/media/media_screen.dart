import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
// kDebugMode приходит из foundation: material его больше не реэкспортирует, а без него
// отладочную печать в проглатываемой ошибке пришлось бы либо печатать всегда, либо убрать.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'month_timeline.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../media/media_sync.dart';
import '../../media/thumb_image.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/download.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';

/// Сколько кадров минимум в строке сетки.
///
/// Четыре — выбранная плотность: клетка на экране 360 dp получается 88 dp (264 физических
/// пикселя на DPR 3), ровно под превью [kThumbSize]. На широких экранах колонок становится
/// больше по желаемой ширине клетки, но меньше этого числа — никогда.
const int _minColumns = 4;

/// Желаемая ширина клетки сетки и зазор между ними.
///
/// [_cell] — не фактический размер клетки, а то, из чего выводится число колонок: `GridView`
/// растягивает ячейки на всю ширину экрана, поэтому сторона клетки получается делением
/// (см. `_cellSide`). Число колонок — «сколько клеток по [_cell] влезает в строку».
///
/// Фактическая сторона клетки и шаг строки (`_rowStep`) — не только вёрстка: по ним считается,
/// какие кадры попадают в видимое окно (`_fetchVisible`) и какой месяц показан в заголовке
/// (`_updateMonth`). Захардкоженный шаг здесь — источник расхождения, которое копится с
/// глубиной прокрутки: при клетке 50 dp и зазоре 3 шаг брался 53 dp, а фактический на экране
/// 360 dp — 60.5 dp, и на 50 000 dp прокрутки окно уезжало от видимого на сотни кадров.
///
/// Числа — логические пиксели, а сеточное превью сервер отдаёт фиксированного размера
/// (`GRID_SIZE = 100 px`, src/media/media.service.ts) и выбирает его по `w` только как «сетка
/// или 1080» (`src/media/media.controller.ts`). На экране с DPR 3 клетка — это 150 физических
/// пикселей, то есть картинка растягивается в полтора раза: подобрать размер под DPR клиент
/// не может — нужного размера сервер не собирает.
/// 70 dp — это (360 dp экрана − 44 dp шкалы − зазоры) / 4 колонки; на DPR 3 выходит ~210
/// физических пикселей, то есть превью 256 px покрывает клетку с запасом, а на экранах с
/// повышенной плотностью апскейл остаётся незаметным.
const _cell = 70.0;
const _gap = 3.0;
const _row = _cell + _gap;

/// Фактическая сторона клетки и шаг строки, посчитанные в раскладке.
///
/// `ValueNotifier`, а не поля: пишутся из `LayoutBuilder`, а читаются и вне `build` — из
/// расчёта окна, из таймера дебаунса и из `ensure` просмотрщика. Слушателей у них нет:
/// перерисовку и так вызывает раскладка, а запись — обычное обновление числа для следующего
/// расчёта (та же причина, что у `_cols`).
final ValueNotifier<double> _cellSide = ValueNotifier(_cell);
final ValueNotifier<double> _rowStep = ValueNotifier(_cell + _gap);

/// Задержка перед загрузкой окна после последнего события скролла, мс (см. `_onScroll`).
const _fetchDebounceMs = 400;

/// Сколько строк сетки берётся в запас сверху и снизу от видимого окна (см. `_visibleRange`).
const _viewRowsMargin = 3;

/// Высота видимой части сетки до первой раскладки, px: у скролла ещё нет ни позиции, ни
/// размеров, а первый запрос окна должен уйти с правдоподобными числами, иначе он накроет
/// одну строку. 900 — типовой экран телефона, лишнее просто отсеется следующим расчётом.
const _fallbackViewport = 900.0;

/// Сколько кадров просить одной страницей `mediaRange`.
///
/// Половина серверного потолка одного запроса (`MEDIA_RANGE_MAX = 1000`,
/// src/media-feed/media-feed.service.ts): при клетке 53 px порция накрывает три-четыре экрана
/// сетки, поэтому одна остановка скролла обычно обходится одним запросом.
const _rangeChunk = 500;

/// Период опроса статусов неготовых превью, мс (см. `_pollStatuses`).
const _statusPollMs = 5000;

/// Предел попыток опроса на один кадр: 24 × 5 с — две минуты ожидания в открытом разделе.
const _statusMaxTries = 24;

/// Сколько кадров ленты держим в памяти.
///
/// Раньше кэш не ограничивался: пролистав ленту, приложение оставляло в куче десятки тысяч
/// объектов — это и есть «держим всё в памяти». Нужны же единицы: то, что на экране и рядом.
/// Две тысячи кадров — это ~35 экранов запаса, дальше кэш чистится по удалённости от окна.
const int _itemsLimit = 2000;

/// Потолок числа id в одном `/media/status` — серверный `MEDIA_STATUS_MAX = 500`
/// (src/media-feed/media-feed.service.ts): более длинный список сервер обрежет и только
/// предупредит об этом в логе, признака усечения в ответе нет.
const _statusBatchMax = 500;

/// Высота полосы метаданных в просмотрщике: одна строка значков и подписей.
const _footerH = 46.0;

/// Прозрачность подложки футера поверх кадра.
const _footerAlpha = 0.6;

/// Экран «Медиа»: сплошная сетка кадров зоны «Фото» (фото и видео вперемешку, от свежих
/// к старым) с заголовком-месяцем.
///
/// Сетка виртуальная, как и почтовый список: сервер знает только общее число (`mediaCount`)
/// и разбивку по месяцам (`mediaMonths`), а сами кадры приходят по абсолютному смещению
/// (`mediaRange`) — только для того, что попало в окно скролла. Весь расчёт высоты и индексов
/// держится на двух допущениях: все клетки одного размера и порядок кадров на сервере не
/// меняется, пока экран открыт.
///
/// Экран же служит источником кадров для `MediaViewer`: он открывает просмотрщик, отдаёт ему
/// свой кэш по индексам и сам переживает удаление кадра.
class MediaScreen extends ConsumerStatefulWidget {
  const MediaScreen({super.key});

  @override
  ConsumerState<MediaScreen> createState() => _MediaScreenState();
}

/// Состояние ленты: счётчик, разбивка по месяцам, загруженные кадры и сигнал просмотрщику.
class _MediaScreenState extends ConsumerState<MediaScreen> {
  /// Ответ на `mediaCount` уже пришёл (до него показывается спиннер, а не «медиа нет»).
  bool _loaded = false;
  /// Сколько всего кадров в ленте. Меняется при удалении кадра: у сервера лента становится
  /// короче, у нас — тоже.
  ///
  /// Не `int`, а `ValueNotifier`, потому что это число — общий контракт с просмотрщиком:
  /// он берёт из него `itemCount` и границы листания (см. `total` у `MediaViewer`). Пока
  /// число лежало в поле, просмотрщик замораживал его на момент открытия и после удаления
  /// кадра оставался с лишней страницей-спиннером.
  final ValueNotifier<int> _total = ValueNotifier(0);
  /// Разбивка по месяцам от сервера: сколько кадров в каждом. Из неё считаются диапазоны
  /// индексов для поиска месяца по позиции скролла (`_monthCum`).
  List<MediaMonthBucket> _months = const [];
  /// Загруженные кадры по абсолютному индексу в ленте.
  final Map<int, MediaItem> _items = {};
  /// Сколько колонок в сетке. Считается во время раскладки (`LayoutBuilder`), а читается
  /// при расчёте окна загрузки и месяца: индексы кадров получаются из строк умножением
  /// на число колонок, и без него окно посчиталось бы по неправильным индексам.
  ///
  /// `ValueNotifier`, а не поле: писать его приходится из раскладки, а значение нужно уже
  /// в следующем кадре — из `addPostFrameCallback` и из таймера дебаунса. Слушателей у него
  /// нет (перерисовку и так вызывает `LayoutBuilder`), поэтому запись в раскладке никого
  /// не будит и остаётся обычным обновлением числа для следующего расчёта.
  final ValueNotifier<int> _cols = ValueNotifier(1);
  /// Подпись в заголовке: месяц, к которому относится верхняя видимая строка.
  ///
  /// Стартовое значение — общее «Медиа»: подпись месяца появляется сразу после первой загрузки
  /// (`_load` → `_updateMonth`), а до неё в шапке должно стоять хоть что-то осмысленное.
  String _month = 'Медиа';
  /// Скролл сетки: из его позиции считаются видимые строки.
  final ScrollController _sc = ScrollController();

  /// Положение прокрутки долей от 0 до 1 — для бегунка на шкале месяцев.
  ///
  /// `ValueNotifier`, а не `setState`: положение меняется на каждом кадре прокрутки, а
  /// перерисовывать из-за него весь экран (с сеткой) не нужно — слушает только шкала.
  final ValueNotifier<double> _scrollFrac = ValueNotifier(0);

  /// Кэш разбивки по месяцам в виде диапазонов индексов (см. `_monthCum`).
  ///
  /// Считается на каждое событие прокрутки (подпись месяца в шапке), а зависит только от
  /// `_months`: без кэша десятки раз в секунду строился бы список по всем месяцам ленты.
  List<({String month, int start, int end})>? _monthCumCache;
  /// Задержка перед загрузкой окна (см. `_onScroll`).
  Timer? _debounce;
  /// Запрос окна уже в полёте: без этого быстрый скролл порождал бы параллельные запросы
  /// одних и тех же индексов (`_fetchVisible` зовётся из дебаунса, из таймера статусов и из
  /// `ensure` просмотрщика).
  bool _fetching = false;
  /// Пока запрос был в полёте, окно успело сдвинуться: по завершении окно пересчитывается
  /// ещё раз, иначе последний сдвиг остался бы не загруженным до следующего скролла.
  bool _refetch = false;
  /// Опрос статусов неготовых превью (см. `_pollStatuses`); `null` — опрос не идёт.
  Timer? _statusTimer;
  /// Сколько раз статус каждого кадра уже спрашивали: `entryId` → число попыток.
  final Map<String, int> _statusTries = {};
  /// Локальный список ленты: из него читаются окна, а с сервером он сверяется журналом.
  ///
  /// `null` до первой загрузки: пока хранилище открывается (чтение каталога баз), лента
  /// показывает спиннер — как и раньше, пока не придёт `mediaCount`.
  MediaFeedSync? _feed;

  /// Синхронизация идёт прямо сейчас: по этому признаку в шапке показывается полоса прогрева
  /// (список наполняется с сервера — на первом запуске это десятки секунд).
  bool _syncing = false;

  /// Сигнал открытому просмотрщику, что кадры подгрузились.
  ///
  /// Контракт: инкрементит только владелец ленты — здесь после каждой страницы `mediaRange`
  /// (и в `map_screen` после догрузки кадра), слушает `MediaViewer` через `revision`
  /// и на каждое изменение перерисовывается. Так просмотрщик узнаёт, что серый слайд,
  /// который он показывает, теперь можно отрисовать.
  final ValueNotifier<int> _revision = ValueNotifier(0);

  @override
  /// Подписка на скролл и первая загрузка: счётчик, месяцы, видимое окно.
  void initState() {
    super.initState();
    _sc.addListener(_onScroll);
    _load();
  }

  @override
  /// Снимаем таймеры, контроллер скролла и общие с просмотрщиком сигналы.
  void dispose() {
    _debounce?.cancel();
    _statusTimer?.cancel();
    _sc.dispose();
    _revision.dispose();
    _total.dispose();
    _cols.dispose();
    _cellSide.dispose();
    _rowStep.dispose();
    _scrollFrac.dispose();
    super.dispose();
  }

  /// Читает счётчик и разбивку по месяцам, после чего просит видимое окно.
  ///
  /// Разбивка нужна не для красоты: по ней считается месяц в заголовке и, что важнее, она
  /// подтверждает порядок ленты — кадры идут от свежих к старым, и индекс в ней совпадает
  /// с индексом сетки.
  ///
  /// Запрос окна уходит после кадра (`addPostFrameCallback`): до первой раскладки неизвестно
  /// ни число колонок, ни позиция скролла. Там же обновляется подпись месяца — иначе в шапке
  /// до первого движения пальцем стояло бы пустое место.
  /// Ошибку показываем подсказкой — сетке без данных показать нечего, пустая она выглядела бы
  /// как «медиа нет».
  /// Побочно: `_loaded`, `_total`, `_months`, затем `_fetchVisible` и `_updateMonth`.
  Future<void> _load() async {
    final feed = await ref.read(mediaFeedProvider.future);
    if (!mounted) return;
    _feed = feed;
    try {
      // Список читается с диска: ни сети, ни ожидания — на экране сразу то, что уже есть
      // на телефоне. Пояс передаём свой: бакет месяца считается как `capturedAt + tz`, иначе
      // кадр, снятый вечером последнего числа, уезжает в следующий месяц. В подписи
      // просмотрщика при этом показывается пояс САМОГО снимка (`tzOffsetMin` кадра) — для фото
      // из другой поездки эти два пояса расходятся, и это осознанно: бакет один на всю ленту,
      // а подпись у каждого кадра своя.
      await _reloadFromStore();
      // После кадра: к этому моменту сетка уже посчитала колонки и привязала скролл.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _fetchVisible();
        _updateMonth();
      });
      unawaited(_syncWithServer(feed));
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  /// Перечитать счётчик, месяцы и уже загруженные кадры из локального списка.
  ///
  /// Нужен и после синхронизации: список на диске изменился (появились новые кадры, ушли
  /// удалённые), а на экране остались прежние числа и прежние кадры в кэше по индексам.
  Future<void> _reloadFromStore() async {
    final feed = _feed;
    if (feed == null) return;
    final n = await feed.store.count();
    final m = await feed.store.months(tzOffsetMin: DateTime.now().timeZoneOffset.inMinutes);
    if (!mounted) return;
    final changed = n != _total.value;
    // Разбивка по месяцам изменилась — кэш диапазонов больше не годится.
    _monthCumCache = null;
    setState(() {
      _total.value = n;
      _months = m;
      _loaded = true;
      // Кэш кадров НЕ сбрасывается: при смене числа кадров индексы сдвигаются, но перезагрузка
      // окна и так поправит то, что видно, — а сброс заставлял плитки мигнуть заглушками и
      // на пустом месте казался «лента не грузится». Сброшенные кадры дочитает `_fetchVisible`.
      if (changed) _fetchVisible();
    });
  }

  /// Сверить список с сервером и показать это в шапке, если идёт полный проход.
  ///
  /// Догон журнала занимает мгновения и в интерфейсе не показывается; полный проход читает
  /// десятки страниц — на нём полоса прогрева уместна, иначе экран выглядел бы зависшим.
  Future<void> _syncWithServer(MediaFeedSync feed) async {
    feed.progress.addListener(_onSyncProgress);
    // Слушатель снимается до выхода из метода при любом исходе, но сам разбор результата —
    // уже за `try`: возврат из `finally` заглушил бы исключение синхронизации, а оно должно
    // быть видно в отладке (список при этом остаётся тем, что уже лежит на диске).
    try {
      await feed.sync();
    } finally {
      feed.progress.removeListener(_onSyncProgress);
    }
    if (!mounted) return;
    await _reloadFromStore();
    if (!mounted) return;
    setState(() => _syncing = false);
    _fetchVisible();
    _updateMonth();
  }

  /// Перерисовать полосу прогрева при изменении хода синхронизации.
  void _onSyncProgress() {
    final running = _feed?.progress.value?.running ?? false;
    if (mounted && running != _syncing) setState(() => _syncing = running);
  }

  /// Ставит задержку перед загрузкой окна и сразу обновляет месяц в заголовке.
  ///
  /// Событие приходит на каждый кадр прокрутки, поэтому загрузка откладывается и таймер
  /// перезапускается: `_fetchVisible` уходит один раз — через `_fetchDebounceMs` после
  /// остановки, когда инерция закончилась и окно уже не меняется. Меньше — запросы пошли бы
  /// пачками на каждое движение пальца, заметно больше — серые клетки висели бы на глазах.
  /// Месяц, в отличие от загрузки, обновляем сразу: подпись в заголовке должна идти за
  /// пальцем, а `_updateMonth` дёргает `setState` только при смене месяца.
  void _onScroll() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: _fetchDebounceMs), _fetchVisible);
    _updateMonth();
    // Положение ползунка шкалы: доля ПЕРВОГО ВИДИМОГО КАДРА, а не доля прокрутки
    // (`offset / maxScrollExtent`). Это важно: шкала переводит палец в индекс кадра, и если
    // ползунок считать по прокрутке, он встаёт не туда, где палец, — из-за того, что
    // максимальная прокрутка меньше полной высоты списка на высоту экрана. Считается без
    // `setState`: перерисовывается только шкала, а не сетка.
    if (_sc.hasClients && _total.value > 0) {
      final firstRow = (_sc.offset / _rowStep.value).floor();
      final firstIndex = firstRow * math.max(1, _cols.value);
      _scrollFrac.value = (firstIndex / _total.value).clamp(0.0, 1.0);
    }
  }

  /// Прыжок ленты к кадру с этим индексом (шкала месяцев).
  ///
  /// Прыжок мгновенный (`jumpTo`), а не анимированный: шкалу тянут именно для того, чтобы
  /// оказаться в другом месте сразу, и анимация через десятки тысяч кадров только мешала бы.
  void _jumpToFrame(int index) {
    if (!_sc.hasClients || !_loaded) return;
    final cols = math.max(1, _cols.value);
    final offset = (index / cols) * _rowStep.value;
    _sc.jumpTo(offset.clamp(0.0, _sc.position.maxScrollExtent));
    // Окно здесь НЕ просим: загрузка идёт по `onJumpEnd`, когда палец отпущен. Иначе при
    // перетаскивании шкалы окно запрашивалось бы на каждое движение пальца — список
    // перестраивался бы десятки раз в секунду, а плитки не жили и половины секунды, из-за
    // чего миниатюры вообще не запрашивались (и экран оставался серым).
  }

  /// Подпись месяца для кадра с этим индексом (что видно на шкале при перетаскивании).
  String _monthLabelAt(int index) {
    final key = _monthAt(index);
    if (key == null) return 'Медиа';
    return key == 'Без даты' ? key : monthLabel(key);
  }

  /// Выкинуть из кэша кадры, ушедшие далеко от видимого окна.
  ///
  /// Вызывается после подгрузки страниц: кэш ограничен [_itemsLimit] кадрами, и при
  /// пролистывании всей ленты старые вытесняются, а не копятся до конца сеанса.
  void _trimItems(int center) {
    if (_items.length <= _itemsLimit) return;
    final keys = _items.keys.toList()
      ..sort((a, b) => (a - center).abs().compareTo((b - center).abs()));
    for (final k in keys.skip(_itemsLimit)) {
      _items.remove(k);
    }
  }

  /// Обновляет подпись месяца в заголовке по верхней видимой строке.
  ///
  /// Позиция скролла переводится в индекс кадра (строки × колонки), а индекс — в месяц через
  /// диапазоны `_monthAt`. `setState` вызывается только когда подпись изменилась: скролл шлёт
  /// события десятками в секунду, и перерисовка на каждое была бы напрасной.
  void _updateMonth() {
    final t = _total.value;
    if (t == 0 || !_sc.hasClients) return;
    final idx = (_sc.offset ~/ _rowStep.value).clamp(0, 1 << 30) * _cols.value;
    final key = _monthAt(idx);
    final label = key == null ? 'Медиа' : key == 'Без даты' ? key : monthLabel(key);
    if (label != _month) setState(() => _month = label);
  }

  /// Месяц, которому принадлежит кадр с этим индексом, или `null`, если разбивка пуста.
  ///
  /// Бинарный поиск по кумулятивным диапазонам: месяцев в библиотеке бывают сотни, а вызывается
  /// это на каждом событии скролла, поэтому линейный проход по всем корзинам был бы заметен.
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

  /// Кумулятивные диапазоны индексов по месяцам: [start, end) для каждой непустой корзины.
  ///
  /// Сервер отдаёт только счётчики, поэтому границы накапливаются здесь: так индекс кадра
  /// превращается в месяц одним поиском. Пустые корзины пропускаются — иначе в диапазонах
  /// появились бы дырки, и часть кадров не нашла бы своего месяца.
  List<({String month, int start, int end})> _monthCum() {
    final cached = _monthCumCache;
    if (cached != null) return cached;
    final arr = <({String month, int start, int end})>[];
    var start = 0;
    for (final b in _months) {
      if (b.count <= 0) continue;
      arr.add((month: b.month == null ? 'Без даты' : b.month!, start: start, end: start + b.count));
      start += b.count;
    }
    _monthCumCache = arr;
    return arr;
  }

  /// Диапазон индексов кадров, попавших в видимое окно сетки (с запасом `_viewRowsMargin`
  /// строк сверху и снизу), или `null`, если считать нечего.
  ///
  /// Как считается: позиция скролла делится на высоту строки, к полученному диапазону строк
  /// добавляется запас — столько проскакивает инерция, пока идёт запрос, и столько же
  /// остаётся готовым, когда пользователь долистает. Строки переводятся в индексы кадров
  /// умножением на `_cols` — именно поэтому число колонок считается до этого места.
  ///
  /// До первой раскладки ни позиции скролла, ни его окна нет, поэтому берётся типовой экран
  /// телефона: первый запрос должен уйти, даже если сетка ещё не привязала контроллер.
  (int, int)? _visibleRange() {
    final t = _total.value;
    if (t == 0) return null;
    final top = _sc.hasClients ? _sc.offset : 0.0;
    final vh = _sc.hasClients ? _sc.position.viewportDimension : _fallbackViewport;
    final cols = _cols.value;
    // Шаг строки — фактический, из раскладки: захардкоженный (клетка + зазор) не совпадает
    // с тем, что видно на экране, потому что GridView растягивает ячейки на всю ширину.
    final step = _rowStep.value;
    final firstRow = math.max(0, (top / step).floor() - _viewRowsMargin);
    final lastRow = ((top + vh) / step).ceil() + _viewRowsMargin;
    final start = firstRow * cols;
    final end = math.min(t - 1, (lastRow + 1) * cols - 1);
    return start > end ? null : (start, end);
  }

  /// Загружает кадры, попавшие в видимое окно сетки.
  ///
  /// Окно считает `_visibleRange`; здесь из него берутся только непрерывные участки ещё не
  /// загруженных индексов (загруженное не перезапрашивается), и каждый участок режется на
  /// порции по `_rangeChunk` кадров.
  ///
  /// Параллельные просьбы не удваиваются: пока запрос в полёте, повторный вызов только
  /// помечает, что окно сдвинулось, и по завершении окно пересчитывается ещё раз. Без этого
  /// быстрый скролл слал бы пачками одни и те же индексы (дебаунс, таймер статусов и `ensure`
  /// просмотрщика зовут этот метод независимо).
  ///
  /// Слоты, которые ещё не пришли, остаются плейсхолдерами: `_cellWidget` рисует для них серую
  /// клетку на месте кадра. Это не заглушка «на время» — по такому слоту уже можно тапнуть
  /// и открыть просмотрщик: он покажет спиннер и дождётся кадра через `_revision`.
  /// Побочно: `setState` с новыми кадрами, `_revision.value++` после каждой страницы и запуск
  /// опроса статусов превью (`_pollStatuses`).
  Future<void> _fetchVisible() async {
    if (_fetching) {
      _refetch = true;
      return;
    }
    final range = _visibleRange();
    if (range == null) return;
    final feed = _feed;
    if (feed == null) return;
    final (start, end) = range;
    _fetching = true;
    try {
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
        for (var off = s; off <= e; off += _rangeChunk) {
          final len = math.min(_rangeChunk, e - off + 1);
          try {
            // Окно читается из локального списка: это запрос к SQLite, а не к серверу,
            // поэтому прокрутка не зависит от сети (данные догоняются синхронизацией).
            final page = await feed.store.range(off, len);
            if (!mounted) return;
            // В базе строк меньше, чем считает лента: список изменился из-под нас (идёт полный
            // проход синхронизации или он оборвался). Перечитываем счётчик и месяцы, иначе
            // внизу останутся пустые клетки, а ползунок будет врать.
            if (page.isEmpty && off < _total.value) {
              await _reloadFromStore();
              return;
            }
            // Миниатюры всего загруженного окна — в фоновую очередь: пока человек смотрит на
            // текущий экран, соседние кадры уже скачиваются, и листание идёт без серых плиток.
            // Запросы дедуплицируются по sha, поэтому повторный вызов для уже скачанного
            // кадра ничего не стоит.
            // Устаревший прогрев не нужен: кадры этого окна уже уехали с экрана, а их загрузки
            // занимали канал и потоки — видимые плитки из-за этого оставались серыми.
            // Миниатюры просят сами плитки: то, что видно, грузится первым (высокий приоритет).
            ref.read(thumbCacheProvider).value?.dropBackground();
            setState(() {
              // Ключ — абсолютный индекс кадра в ленте, а не порядок прихода: страницы могут
              // приехать вразнобой, а по индексу они ложатся на свои клетки.
              for (var j = 0; j < page.length; j++) {
                _items[off + j] = page[j];
              }
              _trimItems((start + end) ~/ 2);
            });
            // Просмотрщик (если он открыт) узнаёт, что серые слайды можно отрисовать.
            _revision.value++;
          } catch (e) {
            // Неудачу глотаем: следующий скролл спросит эти же индексы снова, а падать из-за
            // одного запроса лента не должна. Печать — только в отладке: в релизе сообщать
            // об этом некуда.
            if (kDebugMode) debugPrint('media range error: $e');
          }
        }
      }
    } finally {
      _fetching = false;
    }
    if (!mounted) return;
    // Пока грузили, окно могло уехать: догружаем его, а не ждём следующего скролла.
    if (_refetch) {
      _refetch = false;
      unawaited(_fetchVisible());
      return;
    }
    _scheduleStatusPoll();
  }

  /// Запускает опрос статусов превью, если он ещё не идёт.
  ///
  /// Опрос разовый: `_pollStatuses` сам решит, продолжать ли (см. его описание).
  void _scheduleStatusPoll() {
    _statusTimer ??= Timer(const Duration(milliseconds: _statusPollMs), _pollStatuses);
  }

  /// Переспрашивает у сервера состояние превью тех видимых кадров, которые ещё не готовы.
  ///
  /// Зачем это нужно, хотя `previewState` уже приходит вместе с кадром: в момент, когда лента
  /// отдана, превью часто ещё только собирается в очереди, и без перезапроса клетка остаётся
  /// серой до перезахода на экран. Ответ несёт только состояние — картинка по нему уже есть
  /// в самом кадре: `sha256` сервер отдаёт и для несобранного превью
  /// (src/media-feed/media-feed.service.ts, `range`).
  ///
  /// Опрос прекращается сам: когда среди видимых неготовых кадров не осталось либо когда
  /// каждый из них спрашивали `_statusMaxTries` раз (превью может собираться долго, а очередь
  /// стоять — ждать бесконечно на открытом экране незачем). Запускается он только из
  /// `_fetchVisible`, то есть после каждой подгрузки окна.
  ///
  /// Побочно: `_items` с обновлёнными состояниями, `_statusTries`, перезапуск таймера.
  Future<void> _pollStatuses() async {
    _statusTimer = null;
    if (!mounted) return;
    final range = _visibleRange();
    if (range == null) return;
    final (s, e) = range;
    final ids = <String>[];
    /// `entryId` → индекс кадра в ленте: по нему найденный статус ложится в свой слот,
    /// без повторного прохода по всему окну на каждый id.
    final at = <String, int>{};
    for (var i = s; i <= e && ids.length < _statusBatchMax; i++) {
      final it = _items[i];
      if (it == null) continue;
      // 'impossible' — превью не будет вовсе (файл больше лимита, тип не поддержан): ждать
      // нечего, и опрашивать такие кадры незачем.
      if (it.previewState == 'done' || it.previewState == 'impossible') continue;
      if ((_statusTries[it.entryId] ?? 0) >= _statusMaxTries) continue;
      if (at.containsKey(it.entryId)) continue;
      at[it.entryId] = i;
      ids.add(it.entryId);
    }
    if (ids.isEmpty) return;
    var unresolved = false;
    try {
      final states = await ref.read(appStateProvider).api.mediaStatus(ids);
      if (!mounted) return;
      final by = {for (final st in states) st.entryId: st};
      // Изменения пишутся и в локальный список: иначе после перезапуска приложения плитки
      // снова показывали бы «превью не готово» там, где оно уже собрано на сервере.
      final persist = <String, String>{};
      setState(() {
        for (final id in ids) {
          _statusTries[id] = (_statusTries[id] ?? 0) + 1;
          final st = by[id];
          if (st == null) continue;
          if (st.previewState != 'done' && st.previewState != 'impossible') unresolved = true;
          final i = at[id]!;
          final it = _items[i];
          if (it == null || it.entryId != id) continue;
          if (it.previewState != st.previewState) {
            _items[i] = _withPreviewState(it, st);
            persist[id] = st.previewState;
          }
        }
      });
      if (persist.isNotEmpty) await _feed?.store.setPreviewStates(persist);
    } catch (e) {
      // Как и у страниц ленты: неудачный опрос — не повод падать, следующий скролл запустит
      // его снова.
      if (kDebugMode) debugPrint('media status error: $e');
      return;
    }
    if (unresolved) _scheduleStatusPoll();
  }

  /// Копия кадра с новым состоянием превью.
  ///
  /// Копия собирается вручную, потому что `MediaItem` неизменяем, а `copyWith` у модели нет
  /// (`api/models.dart` — файл не этого экрана, см. отчёт ревью): поля те же, меняется одно.
  MediaItem _withPreviewState(MediaItem it, MediaStatusItem st) => MediaItem(
        entryId: it.entryId,
        name: it.name,
        capturedAt: it.capturedAt,
        mime: it.mime,
        sha256: it.sha256,
        previewState: st.previewState,
        jobState: st.jobState,
        size: it.size,
        tzOffsetMin: it.tzOffsetMin,
      );

  /// Открывает просмотрщик на кадре `idx`, передав ему доступ к своему кэшу.
  ///
  /// Что важно в этом контракте:
  /// * `_total` отдаётся просмотрщику как общий `ValueNotifier`, а не как число: список и
  ///   просмотрщик смотрят на один счётчик, поэтому после удаления кадра просмотрщик сразу
  ///   видит новое число страниц, а не держит замороженное (см. `total` у `MediaViewer`);
  /// * удаление кадра обрабатывает лента, а не просмотрщик: `onDelete` сдвигает индексы кэша
  ///   и уменьшает `_total`, потому что просмотрщик только листает, а данные живут в ленте;
  /// * `revision` отдаётся наружу, чтобы просмотрщик сам узнавал о подгруженных кадрах.
  ///
  /// Побочно: маршрут просмотрщика (`fullscreenDialog` — он открывается поверх, а не как
  /// обычный экран стека).
  void _open(int idx) {
    Navigator.push(context, MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => MediaViewer(
        api: ref.read(appStateProvider).api,
        total: _total,
        initialIndex: idx,
        getItem: (i) => _items[i],
        ensure: (s, e) {
          // Аргументы здесь намеренно игнорируются: окно загрузки у ленты одно и считается
          // от позиции её собственного скролла, а не от индекса, который показывает просмотрщик.
          // Запрос просмотрщика только будит ленту — грузится окно ленты. Ленте этого хватает:
          // просмотрщик открывают из неё же, и он листает рядом с открытым кадром (у карты
          // `ensure`, наоборот, точечный: там кадров в памяти нет вовсе, см. map_screen.dart).
          // Грузим именно запрошенный просмотрщиком диапазон, а не видимое окно сетки:
          // открыть кадр можно и там, где сетка не стоит (прыжок шкалой, листание внутри
          // просмотрщика), и тогда «разбудить ленту» было бесполезно — она тянула своё окно,
          // а кадр оставался незагруженным: бесконечный спиннер.
          _ensureRange(s, e);
        },
        onDelete: (i) => _handleDelete(i),
        revision: _revision,
      ),
    ));
  }

  /// Догрузить кадры по просьбе просмотрщика — ровно этот диапазон индексов.
  ///
  /// Диапазон берётся из локального списка, поэтому запрос дешёвый. Недостающие кадры
  /// запрашиваются одним сплошным куском: просмотрщик листает по одному, и городить запрос
  /// на каждый индекс было бы расточительно.
  ///
  /// Побочно: `_items` пополняется, `_revision` будит просмотрщик, чтобы он перерисовал слайд.
  Future<void> _ensureRange(int start, int end) async {
    final feed = _feed;
    if (feed == null || _total.value == 0) return;
    final from = math.max(0, start);
    final to = math.min(_total.value - 1, end);
    if (to < from) return;
    var firstMissing = -1;
    var lastMissing = -1;
    for (var i = from; i <= to; i++) {
      if (_items.containsKey(i)) continue;
      if (firstMissing < 0) firstMissing = i;
      lastMissing = i;
    }
    if (firstMissing < 0) return;
    try {
      final page = await feed.store.range(firstMissing, lastMissing - firstMissing + 1);
      if (!mounted || page.isEmpty) return;
      setState(() {
        for (var j = 0; j < page.length; j++) {
          _items[firstMissing + j] = page[j];
        }
      });
      _revision.value++;
    } catch (e) {
      if (kDebugMode) debugPrint('media ensure error: $e');
    }
  }

  /// Убирает удалённый кадр из кэша ленты, сдвигает индексы остальных и уменьшает счётчик.
  ///
  /// Это и есть та работа, которую просмотрщик за ленту не делает: он лишь сообщает номер
  /// удалённого кадра (`onDelete`), а кэш живёт здесь и хранится по индексам. Удалённый
  /// выкидывается, все, кто был правее, сдвигаются на единицу — так индексы снова совпадают
  /// с порядком ленты на сервере.
  ///
  /// Кэш и счётчик меняются одной транзакцией `setState`: между сдвигом индексов и новым
  /// `_total` сетка не должна успеть отрисоваться (в кадре с новым числом клеток, но старым
  /// кэшем последняя клетка осталась бы без кадра).
  ///
  /// Побочно: `_items`, `_total` (через него — `itemCount` у сетки и у просмотрщика).
  void _handleDelete(int index) {
    if (!mounted) return;
    final t = _total.value;
    if (t == 0) return;
    // Из локального списка кадр убираем сразу: иначе он вернулся бы на своё место после
    // следующей синхронизации (и занял бы чужой индекс, сдвинув остальные).
    final removed = _items[index];
    if (removed != null) unawaited(_feed?.store.removeEntries([removed.entryId]) ?? Future.value());
    setState(() {
      // сдвиг индексов: удалённый уходит, следующие смещаются на единицу
      final next = <int, MediaItem>{};
      _items.forEach((k, v) {
        if (k == index) return;
        next[k > index ? k - 1 : k] = v;
      });
      _items
        ..clear()
        ..addAll(next);
      _total.value = t - 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.canvas,
      appBar: AppBar(
        title: Text(_month, style: const TextStyle(color: C.fg, fontSize: 17)),
        // Полоса прогрева появляется только на полном проходе (первый запуск, сброс журнала,
        // переносы): догон журнала мгновенный, и мигающая полоса на нём только мешала бы.
        bottom: _syncing
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(
                  value: _feed?.progress.value?.fraction,
                  backgroundColor: C.surface3,
                  color: C.accent,
                  minHeight: 3,
                ),
              )
            : null,
      ),
      body: LayoutBuilder(builder: (context, c) {
        // Число колонок считается прямо в раскладке: от него зависят индексы кадров, поэтому
        // оно должно быть известно до первого расчёта видимого окна (см. `_fetchVisible`).
        // Пишется в `ValueNotifier`, а не в обычное поле: слушателей у него нет, поэтому
        // запись в раскладке никого не будит, а следующий расчёт (из post-frame колбэка или
        // таймера дебаунса) читает уже новое число.
        // Число колонок — из желаемой ширины клетки, а фактическая сторона ячейки получается
        // делением ширины: GridView растягивает ячейки на всю строку, поэтому сторона не равна
        // `_cell`. Именно она (и шаг строки) нужна расчёту видимого окна.
        final cols = math.max(_minColumns, ((c.maxWidth + _gap) / _row).floor());
        _cols.value = cols;
        _cellSide.value = (c.maxWidth - (cols - 1) * _gap) / cols;
        _rowStep.value = _cellSide.value + _gap;
        if (!_loaded) return const Center(child: CircularProgressIndicator());
        final t = _total.value;
        if (t == 0) {
          // Пусто при идущей синхронизации — это ещё не «медиа нет»: список наполняется
          // с сервера, и спиннер честнее надписи про пустой раздел.
          if (_syncing) return const Center(child: CircularProgressIndicator());
          return const Center(child: Text('Здесь появятся фото и видео из раздела «Фото»', style: TextStyle(color: C.fg3)));
        }
        return Stack(children: [
          GridView.builder(
            controller: _sc,
            // Справа отступ шире: там живёт шкала месяцев, и плитки не должны уходить под неё.
            padding: const EdgeInsets.fromLTRB(_gap, _gap, _gap + MonthTimeline.width, _gap),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _cols.value,
              mainAxisSpacing: _gap,
              crossAxisSpacing: _gap,
            ),
            itemCount: t,
            itemBuilder: (context, i) => _cellWidget(i),
          ),
          // Шкала месяцев у правого края: перетаскивание — быстрый переход к нужному периоду,
          // без проматывания десятков тысяч кадров.
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: MonthTimeline(
              months: _months,
              total: t,
              position: _scrollFrac,
              labelAt: _monthLabelAt,
              onJump: _jumpToFrame,
              // Окно грузится один раз — когда палец отпустили: во время перетаскивания оно
              // всё равно меняется на каждом кадре, и запросы уходили бы впустую.
              onJumpEnd: _fetchVisible,
            ),
          ),
        ]);
      }),
    );
  }

  /// Клетка сетки: картинка, а пока кадра нет или превью не собрано — серая клетка с иконкой
  /// по типу файла.
  ///
  /// Плейсхолдер сделан тапаемым намеренно: просмотрщик умеет ждать кадр (через `revision`),
  /// поэтому нажатие по ещё не загруженной клетке открывает его, а не пропадает впустую.
  /// Видео и фото отличаются только иконкой — миниатюру для обоих отдаёт сервер.
  ///
  /// `previewState = 'impossible'` (файл больше лимита, тип не поддержан) показывается
  /// намеренно другой иконкой: «превью не будет никогда» и «превью ещё собирается» — разные
  /// вещи, и по одинаковому значку пользователь не понимает, ждать ему или нет.
  ///
  /// Готовый кадр рисует [ThumbImage]: миниатюра берётся с диска, если она уже скачана
  /// (в том числе прогревом всей библиотеки), иначе качается через очередь приложения.
  /// Сетевой загрузки «по виджету» здесь больше нет — иначе один и тот же кадр тянулся бы
  /// в обход хранилища, и офлайн-галерея показывала бы заглушки вместо того, что уже лежит
  /// на телефоне.
  Widget _cellWidget(int i) {
    final item = _items[i];
    if (item == null) {
      // Плейсхолдер тапаемый: просмотрщик умеет ждать кадр (см. `revision`), поэтому нажатие
      // по ещё не загруженной клетке открывает его, а не пропадает впустую. Раньше эта ветка
      // возвращала клетку без обработчика, и по пустому окну нельзя было нажать вообще ничего.
      return GestureDetector(
        onTap: () => _open(i),
        child: Container(color: C.surface3),
      );
    }
    final isVideo = item.mime.startsWith('video/');
    final ready = item.previewState == 'done' && (item.sha256?.isNotEmpty ?? false);
    if (!ready) {
      final IconData icon;
      if (item.previewState == 'impossible') {
        icon = isVideo ? Icons.videocam_off_outlined : Icons.hide_image_outlined;
      } else {
        icon = isVideo ? Icons.movie_outlined : Icons.image_outlined;
      }
      return GestureDetector(
        onTap: () => _open(i),
        child: Container(
          color: C.surface3,
          child: Icon(icon, color: C.fg3, size: 22),
        ),
      );
    }
    return GestureDetector(
      onTap: () => _open(i),
      child: ThumbImage(
        sha: item.sha256!,
        // Сторона — фактическая ячейка, а не желаемая ширина: иначе картинка окажется меньше
        // клетки и по краям останется полоса фона.
        size: _cellSide.value,
        // Без скругления: клетка сетки была квадратной и до появления локального хранилища,
        // менять вид списка эта правка не должна.
        radius: 0,
        fallback: Container(
          color: C.surface3,
          child: Icon(isVideo ? Icons.movie_outlined : Icons.image_outlined, color: C.fg3),
        ),
      ),
    );
  }
}

// ---------- просмотрщик кадра (общий для «Медиа» и «Карты») ----------

/// Полноэкранный просмотрщик кадра — общий для «Медиа» и «Карты».
///
/// Кадров у него нет: он листает по индексам и спрашивает их у вызывающего экрана через
/// `getItem`, а догрузку просит через `ensure`. Такая развязка нужна потому, что источники
/// разные: у ленты «Медиа» это кэш, заполняемый окнами по скроллу, у карты — кадры, которые
/// приезжают по одному уже после открытия просмотрщика.
///
/// Контракт по удалению (и главная тонкость класса): `total` — не снимок, а общий с владельцем
/// кадров `ValueListenable`. Он задаёт `itemCount` и границы листания, и его же владелец
/// уменьшает в своём `onDelete`; просмотрщик перестраивается на новое число сам, поэтому
/// лишней страницы-спиннера после удаления не остаётся. Значит удаление переживает не
/// просмотрщик, а вызвавший его экран: он сдвигает свои индексы (`onDelete`) и уменьшает своё
/// число кадров, а просмотрщик только переставляет указатель на новый текущий кадр.
class MediaViewer extends StatefulWidget {
  final CloudlyApi api;
  /// Число кадров у владельца: тот же счётчик, что показывает список. См. контракт в описании
  /// класса — значение живое, а не зафиксированное на момент открытия.
  final ValueListenable<int> total;
  /// С какого кадра открылись: он же стартовая страница `PageView`.
  final int initialIndex;
  /// Кадр по индексу или `null`, если он ещё не загружен (тогда показывается спиннер).
  final MediaItem? Function(int) getItem;
  /// Просьба подгрузить кадры в диапазоне индексов. Вызывается на каждой отрисовке слайда,
  /// поэтому реализация обязана быть дешёвой и сама решать, что именно грузить.
  final void Function(int start, int end) ensure;
  /// Сообщение вызывающему экрану, что кадр удалён: индекс в его нумерации. Сдвиг индексов
  /// и пересчёт числа кадров — забота вызывающего (см. контракт класса).
  final void Function(int index) onDelete;

  /// Родитель дёргает этот Listenable, когда его кэш кадров пополнился: без этого
  /// просмотрщик оставался бы со спиннером (у карты кадры приходят уже после открытия).
  ///
  /// Кто инкрементит: владелец кэша (`MediaScreen` после каждой страницы `mediaRange`,
  /// `MapScreen` после догрузки одного кадра). Кто слушает: этот виджет — подписка ставится
  /// в `initState` и снимается в `dispose`, поэтому сигнал не переживает просмотрщик.
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

/// Состояние просмотрщика: текущая страница и метаданные кадра для футера.
class _MediaViewerState extends State<MediaViewer> {
  /// Контроллер листания; создаётся на стартовом кадре и живёт до закрытия просмотрщика.
  late final PageController _pc = PageController(initialPage: widget.initialIndex);
  /// Номер текущего кадра. Держится отдельно от контроллера, потому что нужен там, где
  /// страница не менялась: удаление, обновление метаданных, футер.
  late int _idx = widget.initialIndex;
  /// Метаданные текущего кадра для футера; `null` — ещё грузятся (или кадра нет).
  MediaInfo? _info;
  /// Номер запроса метаданных: ответ применяется, только если он всё ещё последний.
  ///
  /// Без этого футер показывал бы EXIF прошлого кадра: при быстром листании запросы уходят
  /// на каждый кадр, а отвечают не по порядку — медленный ответ на кадр №3 перетирал бы
  /// метаданные уже открытого №4.
  int _infoGen = 0;

  @override
  /// Подписка на сигнал родителя и метаданные кадра, с которого открылись.
  void initState() {
    super.initState();
    widget.revision?.addListener(_onRevision);
    _loadInfo(_idx);
  }

  /// Реакция на сигнал «в кэше родителя появились кадры».
  ///
  /// Кадр мог подгрузиться уже после открытия просмотрщика (это обычный случай для карты),
  /// поэтому по сигналу достаточно перерисоваться — `build` сам перечитает кадр через
  /// `getItem`. Метаданные футера при этом дотягиваются отдельно: за них отвечает другое
  /// поле, и без повторного запроса футер остался бы пустым.
  void _onRevision() {
    if (!mounted) return;
    setState(() {});
    // Кадр подгрузился уже после открытия — метаданные футера тоже надо дотянуть.
    if (_info == null) _loadInfo(_idx);
  }

  @override
  /// Отписка от сигнала и уничтожение контроллера листания.
  void dispose() {
    widget.revision?.removeListener(_onRevision);
    _pc.dispose();
    super.dispose();
  }

  /// Читает метаданные кадра для футера (параметры съёмки, размер, координаты).
  ///
  /// Кадр берётся у родителя: если он ещё не загружен, запрашивать нечего — выход без запроса,
  /// метаданные подтянутся по сигналу `_onRevision`. Пока идёт запрос, `_info` сбрасывается,
  /// чтобы футер не показывал данные прошлого кадра. Ошибку глотаем: без футера просмотр
  /// кадра не ломается.
  ///
  /// Ответ применяется только если за время запроса не ушёл следующий (`_infoGen`): иначе
  /// футер показывал бы EXIF того кадра, который уже пролистали.
  /// Побочно: `_info` (сначала пусто, потом метаданные кадра), `_infoGen`.
  Future<void> _loadInfo(int i) async {
    final gen = ++_infoGen;
    final item = widget.getItem(i);
    if (item == null) return;
    if (mounted) setState(() => _info = null);
    try {
      final info = await widget.api.mediaInfo(item.entryId);
      if (mounted && gen == _infoGen) setState(() => _info = info);
    } catch (_) {}
  }

  /// Удаляет текущий кадр: файл уходит в корзину на сервере, кэш и счётчик сдвигает родитель.
  ///
  /// Арифметика перехода опирается на число кадров **до** удаления, — и это не ошибка:
  /// удалённый кадр в этом числе ещё есть. Если удалили последний кадр, встаём на
  /// предпоследний (после сдвига он стал последним), иначе остаёмся на своём номере —
  /// на него въехал следующий кадр. `clamp` не даёт выйти за границы. Если кадр был
  /// единственным, просмотрщик закрывается: показывать нечего.
  ///
  /// Число кадров после удаления берётся из общего с родителем счётчика (`widget.total`),
  /// который тот уменьшает внутри `onDelete`. Поэтому `itemCount` у `PageView` схлопывается
  /// сразу, а контроллер переставляется на новый номер вручную — иначе листание осталось бы
  /// на странице, которой в новом списке уже нет.
  ///
  /// Побочно: `widget.onDelete(_idx)` — родитель сдвигает индексы и уменьшает счётчик;
  /// `_idx` и метаданные футера пересчитываются под новый кадр.
  Future<void> _delete() async {
    final item = widget.getItem(_idx);
    if (item == null) return;
    final ok = await confirmDialog(context, 'Удалить «${item.name}»?', 'Файл уйдёт в корзину.', danger: true);
    if (!ok) return;
    try {
      await widget.api.deleteFile(item.entryId);
      if (!mounted) return;
      // Родитель сдвигает свои индексы и уменьшает общий счётчик — из него и берётся число
      // кадров после удаления.
      widget.onDelete(_idx);
      final after = widget.total.value;
      if (after <= 0) {
        Navigator.pop(context);
        return;
      }
      // Удалили последний кадр — встаём на предыдущий; иначе номер тот же: на него въехал
      // следующий кадр.
      setState(() => _idx = (_idx >= after ? after - 1 : _idx).clamp(0, after - 1));
      // Список страниц уже укоротился, но `PageView` мог остаться на прежнем номере:
      // переставляем контроллер на кадр, который показываем.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pc.hasClients) _pc.jumpToPage(_idx);
      });
      _loadInfo(_idx);
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    // `itemCount` и границы листания живут в счётчике родителя: удаление кадра меняет их
    // на месте, и просмотрщик перестраивается без переоткрытия (см. контракт класса).
    return ValueListenableBuilder<int>(
      valueListenable: widget.total,
      builder: (context, total, _) => _body(total),
    );
  }

  /// Тело просмотрщика для текущего числа кадров `total`.
  Widget _body(int total) {
    final item = widget.getItem(_idx);
    final geo = (_info?.latitude != null && _info?.longitude != null) ? _info : null;
    // В шапке — дата съёмки, а если её нет, имя файла. Пояс снимка сервер отдаёт отдельным
    // полем (`tzOffsetMin` у кадра): `capturedAt` — уже пересчитанный UTC-момент, поэтому без
    // поправки цифры ISO-строки врут на пояс съёмки. Если пояса в тегах не было, `tzOffsetMin`
    // пуст и подпись выходит в UTC — сервер в этом случае не знает, где снимали.
    final date = fmtMediaDate(item?.capturedAt, tzOffsetMin: item?.tzOffsetMin);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        PageView.builder(
          controller: _pc,
          itemCount: total,
          onPageChanged: (i) {
            setState(() => _idx = i);
            _loadInfo(i);
          },
          itemBuilder: (context, i) {
            // Просим кадр и соседей: соседние слайды PageView строит заранее, и без этой
            // просьбы они оставались бы спиннерами до следующего движения пальцем.
            widget.ensure(math.max(0, i - 1), math.min(total - 1, i + 1));
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
                  date.isNotEmpty ? date : (item?.name ?? ''),
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

  /// Один слайд: фото, видео или спиннер, пока кадр не доехал.
  ///
  /// Спиннер вместо пустоты — потому что кадры приходят по индексам, и «нет данных» здесь
  /// штатная ситуация, а не ошибка: `ensure` уже попросил их у родителя.
  Widget _slide(MediaItem? item) {
    if (item == null) return const Center(child: CircularProgressIndicator());
    final isVideo = item.mime.startsWith('video/');
    if (isVideo) return _video(item);
    return _image(item);
  }

  /// Фото: превью 1080 px в `InteractiveViewer`, чтобы можно было приблизить пальцами.
  ///
  /// Именно превью, а не оригинал: в ленте кадры листают десятками, и тянуть полноразмерные
  /// файлы ради просмотра на телефоне смысла нет. Оригинал доступен кнопкой «Скачать».
  /// Если sha256 у кадра нет, кадр брать неоткуда — про это честно сообщаем.
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
          placeholder: (_, _) => const CircularProgressIndicator(color: Colors.white),
          errorWidget: (_, _, _) => const Center(child: Text('Превью не открылось — файл мог быть удалён', style: TextStyle(color: Colors.white70))),
        ),
      ),
    );
  }

  /// Видео: серверное превью в отдельном виджете `_Vid` со своим контроллером.
  ///
  /// Превью — не единственный источник: часть старых роликов собрана в AV1, который
  /// декодируют не все устройства (Safari/iOS < 17), поэтому `_Vid` при отказе сам переходит
  /// на оригинал (`?src=original`) — так же, как это сделано в деталке файла.
  Widget _video(MediaItem item) {
    final sha = item.sha256;
    if (sha == null || sha.isEmpty) return const SizedBox();
    return Center(child: _Vid(api: widget.api, sha: sha));
  }

  /// Футер с параметрами кадра: размер, кадр, камера, объектив, выдержка, ISO, координаты.
  ///
  /// Данные — из метаданных кадра (`_info`), а размер берётся из ленты, когда кадр под рукой:
  /// он там уже есть и не требует отдельного поля. Строки показываются по наличию значения,
  /// поэтому у фото и видео набор разный. Футер горизонтально прокручивается: параметров
  /// много, а место занимает одну строку.
  Widget _footer() {
    final info = _info!;
    final item = widget.getItem(_idx);
    final metas = <(IconData, String, String)>[
      (Icons.sd_storage_outlined, 'Размер', fmt(item?.size ?? info.size)),
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
      color: Colors.black.withValues(alpha: _footerAlpha),
      height: _footerH,
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

  /// Открывает точку съёмки на OpenStreetMap в браузере.
  ///
  /// Ссылка ведёт не на просмотрщик карты, а на osm.org: полноценной карты внутри приложения
  /// для одного кадра не нужно, а браузер даёт зум, слои и поиск. `#map=16` — уровень зума,
  /// на котором видно квартал.
  void _openOsm(MediaInfo geo) {
    launchUrl(Uri.parse(
        'https://www.openstreetmap.org/?mlat=${geo.latitude}&mlon=${geo.longitude}#map=16/${geo.latitude}/${geo.longitude}'));
  }

  /// Скачивает оригинал кадра и открывает его системным просмотрщиком (`downloadAndOpen`).
  void _download(MediaItem item) {
    downloadAndOpen(widget.api, item.entryId, item.name);
  }
}

/// Проигрыватель видео для просмотрщика: свой контроллер на слайд.
///
/// Отдельный виджет, а не код внутри `MediaViewer`, чтобы контроллер жил ровно столько,
/// сколько слайд на экране: `PageView` уничтожает ушедшие страницы, и вместе с ними
/// освобождается декодер. Иначе при листании десятков роликов они копились бы в памяти.
///
/// Адреса строятся здесь, а не приходят готовой строкой: их два — превью и оригинал, и
/// выбираются они по ходу (см. `_stage`).
class _Vid extends StatefulWidget {
  final CloudlyApi api;
  /// sha256 кадра: из него собираются и превью, и оригинал.
  final String sha;
  const _Vid({required this.api, required this.sha});
  @override
  State<_Vid> createState() => _VidState();
}

/// Состояние плеера: контроллер, стадия и признак «не заиграло совсем».
class _VidState extends State<_Vid> {
  /// 0 — серверное превью, 1 — оригинал кадра (`?src=original`), 2 — пробовать больше нечего.
  int _stage = 0;
  VideoPlayerController? _c;
  bool _err = false;

  @override
  /// Сразу поднимаем плеер для этого слайда.
  void initState() {
    super.initState();
    _init();
  }

  @override
  /// Слайд ушёл с экрана — снимаем подписку и освобождаем декодер.
  void dispose() {
    _c?.removeListener(_onEvent);
    _c?.dispose();
    super.dispose();
  }

  /// Создаёт контроллер текущей стадии и инициализирует поток.
  ///
  /// Автовоспроизведения нет (в отличие от деталки файла): в ленте может открыться страница
  /// с видео, которое пользователь не просил включать. Ошибка ловится и из `initialize`,
  /// и из событий контроллера — поток может не открыться уже после успешной инициализации.
  /// Побочно: `_c`, подписка на события, перерисовка; при неудаче — `_fallback`.
  Future<void> _init() async {
    final url = _stage == 0
        ? widget.api.videoPreviewUrl(widget.sha)
        : widget.api.videoPreviewUrl(widget.sha, original: true);
    final c = VideoPlayerController.networkUrl(Uri.parse(url), httpHeaders: widget.api.authHeaders);
    _c = c;
    c.addListener(_onEvent);
    try {
      await c.initialize();
      if (mounted) setState(() {});
    } catch (_) {
      _fallback();
    }
  }

  /// Ловит ошибку, пришедшую уже после `initialize`.
  void _onEvent() {
    if (_c?.value.hasError ?? false) _fallback();
  }

  /// Откат к следующей стадии, а если их больше нет — к надписи «Видео не проигрывается».
  ///
  /// Первая стадия — превью 1080: часть старых роликов сервер собрал в AV1, и на устройствах
  /// без его декодера (Safari/iOS < 17) такое превью не играет вовсе, хотя сам файл
  /// проигрывается. Вторая стадия — оригинал (`?src=original`): он отдаётся в исходном
  /// формате, который эти устройства понимают. Тянуть оригинал всегда нельзя (гигабайты
  /// ради листания), поэтому он только запасной вариант — как в деталке файла.
  ///
  /// Побочно: старый контроллер уничтожается (иначе он держал бы декодер и поток), при
  /// `_stage < 1` стадия растёт и `_init` пробует оригинал, иначе ставится `_err`.
  void _fallback() {
    if (!mounted) return;
    _c?.removeListener(_onEvent);
    _c?.dispose();
    _c = null;
    if (_stage < 1) {
      setState(() => _stage++);
      _init();
    } else {
      setState(() => _err = true);
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
