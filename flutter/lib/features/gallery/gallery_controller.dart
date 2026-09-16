import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../media/thumb_cache.dart';
import '../../util/format.dart';
import 'data/gallery_store.dart';
import 'data/gallery_sync.dart';
import 'gallery_calendar.dart';
import 'gallery_rows.dart';

/// Состояние галереи: окно кадров вокруг якоря, страницы, шкала таймлайна и прокрутка.
///
/// ## Как устроено окно
///
/// Галерея не знает, сколько всего кадров: у ленты нет ни конца, ни начала, которые можно
/// было бы заранее посчитать. Вместо этого она держит **окно** — кадры вокруг **якоря**,
/// кадра, с которого окно началось (начало ленты при открытии раздела, самый свежий кадр
/// месяца при прыжке по шкале). Окно растёт в обе стороны: вниз — к старым кадрам, вверх —
/// к новым, и в обе стороны страницами по [pageSize] кадров.
///
/// Растёт оно в `CustomScrollView` с `center`: якорь — это нулевая позиция прокрутки, выше него
/// лежит «верхнее плечо» (новые кадры), ниже — «нижнее» (якорь и старые). Слоты обоих плеч
/// отсчитываются от якоря наружу, поэтому добавление страницы вверх ничего не сдвигает на
/// экране: у обычного списка пришлось бы вручную править позицию прокрутки, и она бы дёргалась.
///
/// Идентификатором кадра служит он сам (`MediaCursor` — пара «время съёмки, id»), а не номер:
/// библиотека живая, приложение выгружает фото с телефона, и номер кадра врёт уже через
/// секунду после запроса. Пара «время, id» не врёт никогда.
///
/// ## Где берутся кадры
///
/// Сначала в локальном индексе ([GalleryStore]) — он читается мгновенно и работает без сети.
/// Пока индекс неполон (идёт первое наполнение, см. [GallerySync]), страницы берутся с сервера
/// и попутно кладутся в индекс: следующее листание того же места сети уже не требует.
///
/// ## Что грузится, а что нет
///
/// Пока человек тянет ползунок шкалы, не грузится ничего: ни кадров, ни миниатюр — известно
/// только, какой месяц он выбирает. Страница запрашивается один раз, когда ползунок отпущен
/// ([jumpToMonth]), а плитки просят миниатюры сами, когда окно уже стоит на месте
/// (см. `GalleryTile`).
class GalleryController extends ChangeNotifier {
  GalleryController({required this.sync, required this.apiOf}) : store = sync.store;

  /// Синхронизация: ею наполняется и догоняется локальный индекс.
  final GallerySync sync;

  /// Локальный индекс — источник страниц, пока он полон.
  final GalleryStore store;

  /// Клиент API. Функцией, а не значением: адрес сервера и сессия меняются в рантайме
  /// (вход, выход, смена сервера), а контроллер пересоздавать из-за этого незачем.
  final CloudlyApi Function() apiOf;

  /// Сколько кадров берём одной страницей окна.
  ///
  /// Двести — примерно пять экранов сетки: страница накрывает экран с запасом на инерцию,
  /// поэтому листание обычно обходится одним запросом на «остановку».
  static const int pageSize = 200;

  /// Сколько кадров держим в окне. Дальше от видимого места кадры выбрасываются: без этого
  /// пролистывание всей библиотеки оставило бы в памяти десятки тысяч кадров.
  static const int windowMax = 2500;

  /// Период опроса состояний превью, мс.
  static const int _statusPollMs = 5000;

  /// Предел попыток опроса на один кадр: 24 × 5 с — две минуты ожидания в открытом разделе.
  static const int _statusMaxTries = 24;

  /// Потолок списка id в одном запросе `/media/status` (серверный `MEDIA_STATUS_MAX = 500`).
  static const int _statusBatchMax = 500;

  /// Прокрутка сетки. Владеет ею контроллер, а не виджет: по позиции прокрутки считаются
  /// видимый кадр, подпись месяца и ползунок, а при прыжке по шкале контроллер сам ставит
  /// список на якорь.
  final ScrollController scroll = ScrollController();

  /// Сколько кадров в окне — для просмотрщика: он листает по номерам внутри окна и должен
  /// видеть, как это число меняется, когда подгружается очередная страница.
  final ValueNotifier<int> total = ValueNotifier(0);

  /// Сигнал просмотрщику, что кадры в окне изменились и слайд можно перерисовать.
  final ValueNotifier<int> revision = ValueNotifier(0);

  /// Положение ползунка шкалы.
  final ValueNotifier<GalleryRailPosition> rail = ValueNotifier(GalleryRailPosition.start);

  /// Подпись месяца в шапке — месяц верхнего видимого кадра.
  final ValueNotifier<String> barTitle = ValueNotifier('Медиа');

  /// Ползунок шкалы в пальце: пока true, плитки не просят миниатюры.
  final ValueNotifier<bool> scrubbing = ValueNotifier(false);

  /// Окно кадров в порядке ленты (свежие → старые).
  List<MediaItem> _items = const [];

  /// Сколько кадров окна лежит ВЫШЕ якоря. Остальные — сам якорь и всё, что ниже него.
  ///
  /// Это не «сколько загружено сверху», а точка разреза окна на два плеча: она задаёт, что
  /// считается якорем при пересборке слотов.
  int _newerCount = 0;

  /// Есть ли кадры выше и ниже того, что уже в окне. `false` — направление исчерпано.
  bool _hasNewer = false;
  bool _hasOlder = false;

  /// Хвост без даты уже запрошен: он дочитывается один раз, когда кончилась датированная лента.
  bool _tailDone = false;

  /// Курсор следующей страницы ВВЕРХ, когда он не выводится из первого кадра окна.
  ///
  /// Так бывает на стыке хвоста без даты с датированной лентой: кадры хвоста упорядочены по id,
  /// и «новее последнего кадра хвоста» — это уже не хвост, а самые старые датированные кадры
  /// (курсор `{at: null, id: ''}`).
  MediaCursor? _newerCursorOverride;

  /// Страница вверх или вниз уже запрашивается: без этого быстрый скролл порождал бы
  /// параллельные запросы одних и тех же кадров.
  bool _loadingNewer = false;
  bool _loadingOlder = false;

  /// Номер поколения окна. Растёт на каждом прыжке: ответы прежнего окна, пришедшие после
  /// него, отбрасываются — иначе они вставили бы кадры не туда, где человек уже стоит.
  int _generation = 0;

  /// Локальный индекс наполнен целиком: страницы можно читать из него, не ходя в сеть.
  bool _indexComplete = false;

  /// Первое окно ещё грузится (показываем спиннер, а не «здесь ничего нет»).
  bool _loading = true;

  /// Идёт прыжок по шкале: окно сброшено и ждёт страницу.
  bool _jumping = false;

  /// Разбивка по месяцам от сервера или из индекса. `null` — ещё не приехала.
  List<MediaMonthBucket> _months = const [];

  /// Шкала таймлайна, посчитанная по [_months].
  GalleryCalendar? calendar;

  /// Ошибка последней загрузки — показывается подсказкой; окно при этом остаётся как было.
  String? error;

  /// Плечи окна: слоты выше и ниже якоря вместе с их геометрией.
  GalleryArm newerArm = GalleryArm.empty;
  GalleryArm olderArm = GalleryArm.empty;

  /// Ширина сетки: от неё считается сторона клетки, а по ней — геометрия плеч.
  double _gridWidth = 0;

  /// Контроллер уничтожен: отложенные обновления (после кадра, из фоновой синхронизации)
  /// не должны трогать уничтоженные уведомители.
  bool _disposed = false;

  /// Просмотрщик открыт.
  ///
  /// Пока он открыт, окно не растёт вверх и не чистится по краям. Причина одна: просмотрщик
  /// листает по номерам внутри окна, а кадры, добавленные выше якоря, сдвинули бы все номера —
  /// и он показал бы вместо текущего снимка соседний. Вниз окно расти может: там номера
  /// не меняются.
  bool _viewerOpen = false;

  /// Якорь окна — первый кадр месяца (так бывает после прыжка по шкале).
  ///
  /// Нужно для заголовка: у первого кадра окна подпись ставится, только когда известно, что
  /// месяц с него и начинается. При открытии раздела это значит «выше кадров нет», а после
  /// прыжка по шкале — «месяц начинается именно здесь» (см. [_startsMonth]).
  bool _anchorAtMonthStart = false;

  /// Счётчик попыток опроса на кадр: `entryId` → сколько раз спрашивали состояние превью.
  final Map<String, int> _statusTries = {};

  /// Таймер опроса состояний превью; `null` — опрос не идёт.
  Timer? _statusTimer;

  /// Кэш миниатюр: плитки просят их отсюда.
  ThumbCache? thumbs;

  /// Первое окно ещё грузится.
  bool get loading => _loading;

  /// Прыжок по шкале идёт: сетка на это время приглушается.
  bool get jumping => _jumping;

  /// Сколько кадров в окне.
  int get itemCount => _items.length;

  /// Окно пусто — показывать нечего (при этом [loading] может быть `true`).
  bool get isEmpty => _items.isEmpty;

  /// Кадр окна по номеру: так его берёт просмотрщик.
  MediaItem? itemAt(int index) => index < 0 || index >= _items.length ? null : _items[index];

  /// Номер кадра в окне по id записи; `-1` — кадра в окне нет.
  ///
  /// Нужен плитке: она знает кадр, а не его номер, а просмотрщику нужен именно номер — по нему
  /// он листает и просит догрузку.
  int indexOf(String entryId) {
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].entryId == entryId) return i;
    }
    return -1;
  }

  /// Сторона клетки сетки — по текущей раскладке.
  double get cellSide => GalleryGrid.cellSide(_gridWidth);

  /// Подключить очередь миниатюр. Отдельным вызовом, потому что она открывается асинхронно
  /// (чтение каталога данных), а окно к этому моменту уже может быть на экране.
  void attachThumbs(ThumbCache cache) {
    thumbs = cache;
    notifyListeners();
  }

  /// Просмотрщик открыт: до его закрытия номера кадров в окне не меняются (см. [_viewerOpen]).
  void openViewer() => _viewerOpen = true;

  /// Просмотрщик закрыт: окно снова может расти вверх и чиститься.
  void closeViewer() => _viewerOpen = false;

  /// Первый показ раздела: месяцы, окно, затем синхронизация в фоне.
  ///
  /// Синхронизация не ждётся: окно показывает то, что уже лежит в индексе, а сервер догоняет
  /// список следом. Ждать её значило бы держать спиннер на каждом открытии раздела.
  Future<void> open() async {
    await _loadCalendar();
    _indexComplete = await store.meta(GalleryStore.keyBackboneDone) == '1';
    await loadFirstWindow();
    // Шкала — единственный способ попасть в нужный год, и ждать её до конца наполнения индекса
    // (десятки страниц) нельзя: один запрос отдаёт все месяцы сразу.
    if (calendar == null || calendar!.isEmpty) await _loadRemoteMonths();
    unawaited(_syncInBackground());
  }

  /// Первое окно — начало ленты.
  Future<void> loadFirstWindow() async {
    _loading = true;
    error = null;
    _publish();
    try {
      final page = await _headPage(pageSize);
      _items = page.items;
      _hasOlder = page.hasMore;
      // Датированных кадров нет вовсе — вся медиатека ещё без дат (метаданные не разобраны).
      // Тогда лента начинается с хвоста: иначе раздел выглядел бы пустым при непустой библиотеке.
      if (_items.isEmpty) {
        final tail = await _olderPage(const MediaCursor(at: null, id: ''), pageSize);
        _items = tail.items;
        _hasOlder = tail.hasMore;
        _tailDone = true;
      }
      _newerCount = 0;
      _hasNewer = false;
      _anchorAtMonthStart = true;
    } catch (e) {
      error = e.toString();
    }
    _loading = false;
    _rebuildArms();
    _refreshTopFromScroll();
    _publish();
  }

  /// Показать окно, начинающееся с месяца [month] (прыжок по шкале).
  ///
  /// Якорь — граница начала месяца, и это ключевой момент: страница запрашивается «старше
  /// начала следующего месяца», то есть первым в ней идёт самый свежий кадр выбранного месяца.
  /// Ни номер кадра, ни id первого кадра месяца для этого не нужны.
  Future<void> jumpToMonth(String month) async {
    final cal = calendar;
    if (cal == null || cal.isEmpty) return;
    final boundary = cal.monthBoundaryUtc(cal.nextMonth(month));
    // Якорь — начало месяца: страница начнётся с его первого кадра, и у него будет заголовок.
    _anchorAtMonthStart = true;
    await _reanchor(MediaCursor(at: boundary.toIso8601String(), id: ''));
  }

  /// Показать окно, начинающееся с кадров без даты (зона под шкалой).
  Future<void> jumpToTail() {
    _anchorAtMonthStart = false;
    _tailDone = true;
    return _reanchor(const MediaCursor(at: null, id: ''));
  }

  /// Ползунок взяли в палец.
  void setScrubbing(bool value) {
    if (scrubbing.value == value) return;
    scrubbing.value = value;
  }

  /// Раскладка изменилась (поворот экрана, другая ширина): пересчитать слоты.
  ///
  /// Зовётся из `LayoutBuilder`, то есть во время сборки, поэтому слушателей здесь не будим:
  /// новые плечи нужны тому же кадру, который их и пересчитывает.
  void setLayout(double gridWidth) {
    if ((gridWidth - _gridWidth).abs() < 0.5) return;
    _gridWidth = gridWidth;
    _rebuildArms();
    // Подпись месяца и ползунок считаются по видимому кадру, а он известен только после
    // раскладки: до неё у плеч нет геометрии. Обновляем после кадра — будить слушателей
    // во время чужой сборки нельзя.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) _refreshTopFromScroll();
    });
  }

  /// Обработать событие прокрутки: подпись месяца, ползунок и подгрузка у краёв окна.
  ///
  /// Всё это считается из одной величины — позиции прокрутки. В `CustomScrollView` с `center`
  /// нулевая позиция — это якорь, поэтому расстояние от якоря равно `offset`: положительное
  /// уходит в нижнее плечо (к старым), отрицательное — в верхнее (к новым).
  void onScroll() {
    if (!scroll.hasClients) return;
    final pos = scroll.position;
    _refreshTop(pos.pixels);
    _maybeLoad(pos);
  }

  /// Догрузить страницу вниз (к старым кадрам).
  Future<void> loadOlder() async {
    if (_loadingOlder || !_hasOlder || _items.isEmpty) return;
    _loadingOlder = true;
    final gen = _generation;
    try {
      final page = await _olderPage(MediaCursor.of(_items.last), pageSize);
      if (gen != _generation) return;
      if (page.items.isNotEmpty) _items = [..._items, ...page.items];
      _hasOlder = page.hasMore;
      // Датированная лента кончилась — ниже идёт хвост кадров без даты. Он запрашивается
      // отдельной страницей: датированный курсор хвост не захватывает (см. `/media/feed`).
      // Последний кадр берётся из окна, а не из страницы: страница могла прийти пустой, когда
      // в индексе кончились датированные кадры, а хвост ещё нет.
      if (!_hasOlder && !_tailDone && _items.last.capturedAt != null) {
        _tailDone = true;
        final tail = await _olderPage(const MediaCursor(at: null, id: ''), pageSize);
        if (gen != _generation) return;
        if (tail.items.isNotEmpty) {
          _items = [..._items, ...tail.items];
          _hasOlder = tail.hasMore;
        }
      }
    } catch (e) {
      // Неудачная страница — не повод ронять окно: то, что загружено, остаётся, а следующий
      // скролл попробует снова.
      error = e.toString();
    } finally {
      _loadingOlder = false;
    }
    if (gen != _generation) return;
    _trimWindow();
    _rebuildArms();
    _publish();
    _scheduleStatusPoll();
  }

  /// Догрузить страницу вверх (к новым кадрам).
  ///
  /// Позицию прокрутки править не нужно: окно растёт в `CustomScrollView` с `center`, и кадры,
  /// добавленные выше якоря, ложатся в отрицательные смещения — то, что человек видит, стоит
  /// на месте. У обычного списка здесь пришлось бы пересчитывать позицию, и она бы дёрнулась.
  Future<void> loadNewer() async {
    // Просмотрщик открыт — номера кадров трогать нельзя (см. [_viewerOpen]).
    if (_viewerOpen) return;
    if (_loadingNewer || !_hasNewer || _items.isEmpty) return;
    _loadingNewer = true;
    final gen = _generation;
    try {
      final cursor = _newerCursorOverride ?? MediaCursor.of(_items.first);
      final page = await _newerPage(cursor, pageSize);
      if (gen != _generation) return;
      if (page.items.isEmpty) {
        _hasNewer = false;
        _newerCursorOverride = null;
        return;
      }
      _items = [...page.items, ..._items];
      _newerCount += page.items.length;
      _anchorAtMonthStart = false;
      // Хвост без даты дочитан: выше него начинается датированная лента, и продолжение берётся
      // уже курсором «к самым старым датированным кадрам».
      final tailExhausted = !page.hasMore && cursor.at == null && cursor.id.isNotEmpty;
      _newerCursorOverride = tailExhausted ? const MediaCursor(at: null, id: '') : null;
      _hasNewer = page.hasMore || tailExhausted;
    } catch (e) {
      error = e.toString();
    } finally {
      _loadingNewer = false;
    }
    if (gen != _generation) return;
    _trimWindow();
    _rebuildArms();
    _publish();
    _scheduleStatusPoll();
  }

  /// Подгрузить кадры по просьбе просмотрщика: диапазон номеров в окне.
  ///
  /// Просмотрщик листает по номерам окна, поэтому у его краёв просьба означает «дай ещё» —
  /// именно это здесь и делается. Кадры в середине окна всегда на месте.
  void ensureRange(int start, int end) {
    if (_items.isEmpty) return;
    if (end >= _items.length - 2) unawaited(loadOlder());
    if (!_viewerOpen && start <= 1) unawaited(loadNewer());
  }

  /// Убрать кадр из окна: его удалил просмотрщик.
  ///
  /// Нумерация окна сдвигается, поэтому меняются и номера, по которым просмотрщик листает:
  /// он перестраивается сам, а сюда приходит один раз — сообщить, какой номер выпал.
  void deleteAt(int index) {
    if (index < 0 || index >= _items.length) return;
    final removed = _items[index];
    unawaited(store.removeEntries([removed.entryId]));
    _items = [..._items]..removeAt(index);
    if (index < _newerCount) _newerCount--;
    _rebuildArms();
    _refreshTopFromScroll();
    _publish();
  }

  /// Сбросить окно на новом якоре и загрузить первую страницу.
  ///
  /// Поколение растёт до запроса: страницы прежнего окна, приехавшие позже, не должны попасть
  /// в новое — они про другое место ленты.
  Future<void> _reanchor(MediaCursor cursor) async {
    _generation++;
    final gen = _generation;
    _items = const [];
    _newerCount = 0;
    // Якорь почти всегда в середине ленты: выше наверняка что-то есть. Если нет (прыжок
    // в самый свежий месяц), первая же страница вверх это покажет.
    _hasNewer = true;
    _hasOlder = true;
    _tailDone = false;
    _newerCursorOverride = null;
    _jumping = true;
    _rebuildArms();
    if (scroll.hasClients) scroll.jumpTo(0);
    _publish();
    try {
      final page = await _olderPage(cursor, pageSize);
      if (gen != _generation) return;
      _items = page.items;
      _hasOlder = page.hasMore;
    } catch (e) {
      if (gen == _generation) error = e.toString();
    } finally {
      if (gen == _generation) {
        _jumping = false;
        _rebuildArms();
        _refreshTopFromScroll();
        _publish();
        _scheduleStatusPoll();
      }
    }
  }

  /// Прочитать разбивку по месяцам из локального индекса и собрать шкалу.
  Future<void> _loadCalendar() async {
    _months = await store.months();
    calendar = GalleryCalendar(months: _months, tzOffsetMin: _tz);
  }

  /// Забрать разбивку по месяцам с сервера — когда локальный индекс ещё пуст.
  ///
  /// Побочно: разбивка кладётся в индекс (следующее открытие раздела обойдётся без запроса),
  /// шкала пересобирается.
  Future<void> _loadRemoteMonths() async {
    try {
      final months = await apiOf().mediaMonths(tzOffsetMin: _tz);
      if (_disposed) return;
      await store.writeMonths(months);
      _months = months;
      calendar = GalleryCalendar(months: months, tzOffsetMin: _tz);
      notifyListeners();
    } catch (e) {
      // Без разбивки раздел работает: сетка листается, шкалы просто нет, пока её не принесёт
      // синхронизация.
      if (kDebugMode) debugPrint('gallery months error: $e');
    }
  }

  /// Синхронизация в фоне, а после неё — месяцы и тихое обновление верхушки окна.
  Future<void> _syncInBackground() async {
    final changed = await sync.sync();
    if (_disposed) return;
    if (changed) {
      await _loadCalendar();
      _indexComplete = await store.meta(GalleryStore.keyBackboneDone) == '1';
      await _silentHeadRefresh();
    }
    if (!_disposed) notifyListeners();
  }

  /// Показать новые загрузки, не трогая прокрутку.
  ///
  /// Только если человек стоит на верхушке окна: подсунуть кадры в середину того, что он
  /// читает, — хуже, чем показать их при следующем открытии раздела.
  Future<void> _silentHeadRefresh() async {
    if (_items.isEmpty) return;
    if (_hasNewer || (scroll.hasClients && scroll.offset > 1)) return;
    final page = await store.head(pageSize);
    if (page.items.isEmpty) return;
    final known = {for (final it in _items) it.entryId};
    final fresh = page.items.where((it) => !known.contains(it.entryId)).toList();
    if (fresh.isEmpty) return;
    _items = [...fresh, ..._items];
    _rebuildArms();
    _publish();
  }

  /// Первая страница: из индекса, а если индекс пуст — с сервера (и сразу в индекс).
  Future<MediaFeedPage> _headPage(int limit) async {
    final local = await store.head(limit);
    if (local.items.isNotEmpty) return local;
    final page = await apiOf().mediaFeed(limit: limit);
    await store.upsertAll(page.items);
    return page;
  }

  /// Страница вниз от курсора.
  ///
  /// Полный индекс отвечает сам: это чтение из SQLite, то есть без сети и мгновенно. Неполный
  /// (идёт первое наполнение) берёт страницу с сервера и кладёт её в индекс — так следующие
  /// заходы в это же место обходятся без сети. Если сети нет, но локально что-то есть, отдаём
  /// локальное: офлайн-галерея важнее свежести.
  Future<MediaFeedPage> _olderPage(MediaCursor cursor, int limit) async {
    if (_indexComplete) return store.older(cursor, limit);
    try {
      final page = await apiOf().mediaFeed(before: cursor, limit: limit);
      await store.upsertAll(page.items);
      return page;
    } catch (e) {
      final local = await store.older(cursor, limit);
      if (local.items.isNotEmpty) return local;
      rethrow;
    }
  }

  /// Страница вверх от курсора — тем же правилом, что и [_olderPage].
  Future<MediaFeedPage> _newerPage(MediaCursor cursor, int limit) async {
    if (_indexComplete) return store.newer(cursor, limit);
    try {
      final page = await apiOf().mediaFeed(after: cursor, limit: limit);
      await store.upsertAll(page.items);
      return page;
    } catch (e) {
      final local = await store.newer(cursor, limit);
      if (local.items.isNotEmpty) return local;
      rethrow;
    }
  }

  /// Пересобрать плечи окна по текущим кадрам и раскладке.
  void _rebuildArms() {
    if (_items.isEmpty || _gridWidth <= 0) {
      newerArm = GalleryArm.empty;
      olderArm = GalleryArm.empty;
      return;
    }
    final tz = _tz;
    final flags = _startsMonth(tz);
    final newerRows = buildGalleryRows(
      items: _items.sublist(0, _newerCount),
      startsMonth: flags.sublist(0, _newerCount),
      width: _gridWidth,
      tzOffsetMin: tz,
    );
    final olderRows = buildGalleryRows(
      items: _items.sublist(_newerCount),
      startsMonth: flags.sublist(_newerCount),
      width: _gridWidth,
      tzOffsetMin: tz,
    );
    // Плечо выше якоря собирается «наружу» переворотом строк: слот, примыкающий к якорю, —
    // последний в визуальном порядке (см. `GalleryArm.of`).
    newerArm = GalleryArm.of(newerRows, up: true);
    olderArm = GalleryArm.of(olderRows, up: false);
  }

  /// С какого кадра начинается новый месяц — по флагу на каждый кадр окна.
  ///
  /// У первого кадра окна заголовок ставится, только если выше кадров нет вовсе: иначе
  /// неизвестно, тот же это месяц, что у кадра за окном, и подпись могла бы соврать. Сверху
  /// в этом случае месяц показывает шапка.
  List<bool> _startsMonth(int tz) {
    final flags = List<bool>.filled(_items.length, false);
    String? prev;
    for (var i = 0; i < _items.length; i++) {
      final at = _items[i].capturedAt;
      final dt = at == null ? null : DateTime.tryParse(at);
      final key = dt == null ? '' : GalleryGrid.monthKey(dt, tz);
      // Первый кадр окна: подпись ставится, только если месяц с него и начинается — то есть
      // выше кадров нет вовсе либо окно началось с начала месяца (прыжок по шкале).
      final anchor = _newerCount == 0 && (_anchorAtMonthStart || !_hasNewer);
      flags[i] = i == 0 ? anchor : key != prev;
      prev = key;
    }
    return flags;
  }

  /// Выбросить из окна кадры, ушедшие далеко от видимого места.
  ///
  /// Удаляются только заведомо невидимые (половина окна в каждую сторону), поэтому прокрутка
  /// от чистки не дёргается: положение якоря и примыкающих к нему строк не меняется.
  void _trimWindow() {
    // При открытом просмотрщике окно не чистится: он может стоять далеко от того места,
    // которое видно в сетке, и выброшенный кадр оказался бы тем самым, который он показывает.
    if (_viewerOpen) return;
    if (_items.length <= windowMax) return;
    final visible = _visibleItemIndex();
    final half = windowMax ~/ 2;
    var from = math.max(0, visible - half);
    final to = math.min(_items.length, from + windowMax);
    from = math.max(0, to - windowMax);
    if (from == 0 && to == _items.length) return;
    if (from > 0) _hasNewer = true;
    if (to < _items.length) _hasOlder = true;
    _items = _items.sublist(from, to);
    _newerCount = math.max(0, _newerCount - from);
  }

  /// Номер верхнего видимого кадра в окне.
  int _visibleItemIndex() {
    final offset = scroll.hasClients ? scroll.offset : 0.0;
    final arm = offset >= 0 ? olderArm : newerArm;
    final row = arm.rowAt(offset.abs());
    if (row < 0) return _newerCount;
    // Заголовок месяца кадров не несёт: первый видимый кадр — в следующей строке плеча.
    for (var i = row; i < arm.rows.length; i++) {
      final items = arm.rows[i].items;
      if (items.isNotEmpty) {
        final item = items.first;
        final index = indexOf(item.entryId);
        if (index >= 0) return index;
        break;
      }
    }
    return _newerCount;
  }

  /// Обновить подпись месяца и ползунок по позиции прокрутки.
  void _refreshTopFromScroll() => _refreshTop(scroll.hasClients ? scroll.offset : 0.0);

  /// Подпись месяца и ползунок для позиции прокрутки [offset].
  ///
  /// Считается по верхнему видимому кадру, а не по доле прокрутки: у окна нет ни начала, ни
  /// конца, и «доля прокрутки» в нём ничего не значит. Кадр же честно говорит, какой сейчас
  /// месяц, — по нему и подпись, и положение ползунка.
  void _refreshTop(double offset) {
    final arm = offset >= 0 ? olderArm : newerArm;
    final row = arm.rowAt(offset.abs());
    MediaItem? item;
    if (row >= 0) {
      for (var i = row; i < arm.rows.length; i++) {
        if (arm.rows[i].items.isNotEmpty) {
          item = arm.rows[i].items.first;
          break;
        }
      }
    }
    if (item == null) return;
    final cal = calendar;
    final at = item.capturedAt;
    if (at == null) {
      rail.value = const GalleryRailPosition(1, tail: true);
      barTitle.value = 'Без даты';
      return;
    }
    final dt = DateTime.tryParse(at);
    if (dt == null || cal == null || cal.isEmpty) return;
    final fraction = cal.fractionOf(dt);
    if (rail.value.tail || (rail.value.fraction - fraction).abs() > 1e-4) {
      rail.value = GalleryRailPosition(fraction);
    }
    barTitle.value = monthLabel(GalleryGrid.monthKey(dt, _tz));
  }

  /// Догрузить страницу, если до края окна осталось меньше двух экранов.
  ///
  /// Порог в два экрана — чтобы страница успела приехать до того, как человек доедет до края:
  /// иначе на быстром пролистывании у края появлялись бы пустые места.
  void _maybeLoad(ScrollPosition pos) {
    final threshold = math.max(600.0, pos.viewportDimension * 2);
    if (_hasOlder && pos.pixels >= pos.maxScrollExtent - threshold) unawaited(loadOlder());
    if (_hasNewer && pos.pixels <= pos.minScrollExtent + threshold) unawaited(loadNewer());
  }

  /// Запустить опрос состояний превью, если он ещё не идёт.
  void _scheduleStatusPoll() {
    _statusTimer ??= Timer(const Duration(milliseconds: _statusPollMs), _pollStatuses);
  }

  /// Переспросить у сервера состояние превью у кадров окна, которые ещё не готовы.
  ///
  /// Нужно потому, что к моменту показа кадра превью часто только в очереди: без перезапроса
  /// клетка осталась бы серой до перезахода в раздел. Опрос прекращается сам — когда неготовых
  /// не осталось или когда каждого спрашивали [_statusMaxTries] раз (превью может собираться
  /// долго, а очередь стоять, и ждать этого на открытом экране незачем).
  Future<void> _pollStatuses() async {
    _statusTimer = null;
    final ids = <String>[];
    final at = <String, int>{};
    for (var i = 0; i < _items.length && ids.length < _statusBatchMax; i++) {
      final it = _items[i];
      if (it.previewState == 'done' || it.previewState == 'impossible') continue;
      if ((_statusTries[it.entryId] ?? 0) >= _statusMaxTries) continue;
      ids.add(it.entryId);
      at[it.entryId] = i;
    }
    if (ids.isEmpty) return;
    try {
      final states = await apiOf().mediaStatus(ids);
      final by = {for (final st in states) st.entryId: st};
      final persist = <String, String>{};
      var unresolved = false;
      for (final id in ids) {
        _statusTries[id] = (_statusTries[id] ?? 0) + 1;
        final st = by[id];
        if (st == null) continue;
        if (st.previewState != 'done' && st.previewState != 'impossible') unresolved = true;
        final i = at[id];
        if (i == null || i >= _items.length) continue;
        final it = _items[i];
        if (it.entryId != id || it.previewState == st.previewState) continue;
        _items[i] = it.copyWith(previewState: st.previewState, jobState: st.jobState);
        persist[id] = st.previewState;
      }
      if (persist.isNotEmpty) {
        await store.setPreviewStates(persist);
        revision.value++;
        notifyListeners();
      }
      if (unresolved) _scheduleStatusPoll();
    } catch (e) {
      // Неудачный опрос — не повод падать: следующий запустится после подгрузки страницы.
      if (kDebugMode) debugPrint('gallery status error: $e');
    }
  }

  /// Отдать наружу текущее окно: счётчик для просмотрщика и сигнал перерисовки.
  void _publish() {
    total.value = _items.length;
    revision.value++;
    notifyListeners();
  }

  /// Сдвиг пояса устройства в минутах на восток — в нём считаются месяцы и их границы.
  int get _tz => DateTime.now().timeZoneOffset.inMinutes;

  @override
  void dispose() {
    _disposed = true;
    _statusTimer?.cancel();
    scroll.dispose();
    total.dispose();
    revision.dispose();
    rail.dispose();
    barTitle.dispose();
    scrubbing.dispose();
    super.dispose();
  }
}
