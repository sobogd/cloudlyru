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
import 'gallery_index.dart';
import 'gallery_pages.dart';
import 'gallery_rows.dart';

/// Состояние галереи: полная сетка по локальному индексу, прокрутка и кадры строк.
///
/// ## Полный список вместо окна вокруг якоря
///
/// Прежняя галерея не знала, сколько всего кадров: список был окном вокруг якоря и достраивался
/// страницами в обе стороны. Отсюда следовало всё остальное — прыжок по шкале сбрасывал окно
/// и ждал страницу, окно чистилось по краям, а страница, добавленная сверху, требовала вёрстки
/// с `center`, чтобы не сдвинуть читаемое.
///
/// Теперь геометрия известна целиком и до кадров: разбивка по месяцам в локальном индексе
/// говорит, сколько кадров в каждом месяце, а заголовок и ряд клеток (число колонок —
/// от ширины экрана, см. `GalleryGrid.columnsFor`) дают строки
/// известной высоты ([GalleryIndex]). Поэтому:
///
///  * у списка есть точная длина на всю историю, и она не зависит от того, что успело
///    прочитаться, — под пальцем ничего не растёт и не переставляется;
///  * позиция прокрутки сама по себе осмысленна: ползунок обычного скроллбара (`GalleryScreen`)
///    стоит по доле кадров, а не по датам, и его можно тянуть через всю библиотеку;
///  * подпись месяца в шапке считается по верхней видимой СТРОКЕ, поэтому верна и там, где
///    кадры ещё не прочитаны.
///
/// ## Где берутся кадры
///
/// В локальном индексе ([GalleryStore]) — целиком, в память ([GalleryPages]): библиотека
/// читается один раз при открытии раздела и лежит в памяти месяцами, поэтому клетка на экране
/// всегда знает свой кадр и прокрутка в базу не ходит. Читается это после первого кадра
/// ([_loadAll]): пока кадры едут, сетка показывает заглушки того же размера, а приезд кадров
/// ничего не сдвигает. Наполняется индекс фоном ([GallerySync]): пока он наполнен не целиком,
/// сетка уже показывает всю историю месяцами (разбивку присылает сервер), а кадры в ней
/// появляются по мере чтения — по месяцу за раз, потому что месяц здесь и единица хранения.
class GalleryController extends ChangeNotifier {
  GalleryController({required this.sync, required this.apiOf}) : store = sync.store {
    pages = GalleryPages(
      store: store,
      tzOffsetMin: _tz,
      onLoaded: _onPagesLoaded,
      onError: _onPagesError,
    );
  }

  /// Синхронизация: ею наполняется и догоняется локальный индекс.
  final GallerySync sync;

  /// Локальный индекс — источник кадров.
  final GalleryStore store;

  /// Клиент API. Функцией, а не значением: адрес сервера и сессия меняются в рантайме
  /// (вход, выход, смена сервера), а контроллер пересоздавать из-за этого незачем.
  final CloudlyApi Function() apiOf;

  /// Кадры, прочитанные из индекса пачками.
  late final GalleryPages pages;

  /// Период опроса состояний превью, мс.
  static const int _statusPollMs = 5000;

  /// Предел попыток опроса на один кадр: 24 × 5 с — две минуты ожидания в открытом разделе.
  static const int _statusMaxTries = 24;

  /// Потолок списка id в одном запросе `/media/status` (серверный `MEDIA_STATUS_MAX = 500`).
  static const int _statusBatchMax = 500;

  /// Отступ сетки сверху — тот же, что у вёрстки (`GalleryGrid.gap`).
  ///
  /// Позиция прокрутки отсчитывается от начала содержимого, а строки — от начала списка:
  /// без этого отступа строка встала бы на зазор выше позиции. Величина берётся
  /// из общего с вёрсткой места, а не задаётся здесь числом: разойдясь, они развели бы
  /// прыжок и строку, к которой он ведёт.
  static const double topInset = GalleryGrid.gap;

  /// Прокрутка сетки. Владеет ею контроллер, а не виджет: по позиции прокрутки считаются
  /// подпись месяца в шапке, опрос превью и место чтения при пересборке геометрии.
  final ScrollController scroll = ScrollController();

  /// Сколько кадров во всей ленте — для просмотрщика: он листает по номерам и берёт отсюда
  /// границы листания. Значение меняется на месте (удаление кадра), и просмотрщик
  /// перестраивается без переоткрытия.
  final ValueNotifier<int> total = ValueNotifier(0);

  /// Сигнал просмотрщику, что кадры изменились и слайд можно перерисовать.
  final ValueNotifier<int> revision = ValueNotifier(0);

  /// Подпись месяца в шапке — месяц верхней видимой строки.
  ///
  /// Заменяет собой прежнюю шкалу месяцев: она показывала, куда человек едет, а обычный
  /// скроллбар возит сам список, и «где я во времени» остаётся видно по этой подписи.
  final ValueNotifier<String> barTitle = ValueNotifier('Медиа');

  /// Геометрия сетки на всю историю; `null` — ещё не собрана (не было раскладки или разбивки).
  GalleryIndex? index;

  /// Разбивка по месяцам, из которой собирается геометрия.
  List<MediaMonthBucket> _months = const [];

  /// Локальный индекс наполнен целиком: лента показана вся, догружать нечего.
  bool _complete = false;

  /// Первое открытие раздела ещё идёт (показываем спиннер, а не «здесь ничего нет»).
  bool _loading = true;

  /// Причина сбоя чтения из индекса — показывается в строке состояния; `null` — сбоя нет.
  String? error;

  /// Просмотрщик открыт.
  ///
  /// Пока он открыт, геометрия не пересобирается: просмотрщик листает по номерам ленты,
  /// а кадры, доехавшие сверху, сдвинули бы все номера — и он показал бы вместо открытого
  /// снимка соседний. Что пришло за это время, применяется после закрытия ([closeViewer]).
  bool _viewerOpen = false;

  /// Синхронизация изменила индекс, пока был открыт просмотрщик: пересобрать после закрытия.
  bool _dirty = false;

  /// Перерисовка уже заказана на этот кадр (см. [_onPagesLoaded]).
  bool _repaintScheduled = false;

  /// Приехало то, чего построенные строки ещё не видели (см. [_onPagesLoaded]).
  bool _pagesDirty = false;

  /// Срок перерисовки во время прокрутки; `null` — срока нет (см. [_scrollRepaintMs]).
  Timer? _repaintTimer;

  /// Через сколько показывать приехавшие кадры, пока список едет, мс.
  ///
  /// Четверть секунды — это уже не «заглушки до остановки» и всё ещё вчетверо реже кадра:
  /// под пальцем за это время сменяется десяток экранов, и увидеть в них одну приехавшую
  /// пачку всё равно нельзя, а остановившись человек получает её через кадр.
  static const int _scrollRepaintMs = 250;

  /// Проход наполнения уже замечен этим контроллером (см. [_onSyncProgress]).
  bool _filling = false;

  /// Ширина сетки: от неё считается сторона клетки, а по ней — высоты строк.
  double _gridWidth = 0;

  /// Сдвиг пояса устройства в минутах на восток — в нём считаются месяцы и их границы.
  int get _tz => DateTime.now().timeZoneOffset.inMinutes;

  /// Счётчик попыток опроса на кадр: `entryId` → сколько раз спрашивали состояние превью.
  final Map<String, int> _statusTries = {};

  /// Таймер опроса состояний превью; `null` — опрос не идёт.
  Timer? _statusTimer;

  /// Кэш миниатюр: плитки просят их отсюда.
  ThumbCache? thumbs;

  /// Контроллер уничтожен: отложенные обновления (после кадра, из фоновой загрузки)
  /// не должны трогать уничтоженные уведомители.
  bool _disposed = false;

  /// Сколько строк в сетке — по этому числу вёрстка их и спрашивает.
  int get rowCount => index?.rowCount ?? 0;

  /// Сколько кадров во всей ленте.
  int get itemCount => index?.itemCount ?? 0;

  /// Первое открытие ещё идёт.
  bool get loading => _loading;

  /// Кадров нет вовсе: показывать нечего.
  bool get isEmpty => index?.isEmpty ?? true;

  /// Наполнение индекса ещё идёт: в строке состояния видно, что кадры продолжают доезжать.
  bool get loadingHistory => !_complete || (sync.progress.value?.running ?? false);

  /// Сторона клетки сетки — по текущей раскладке.
  double get cellSide => GalleryGrid.cellSide(_gridWidth);

  /// Текст строки состояния в конце списка.
  ///
  /// Строка есть всегда, даже когда сказать нечего: её высота входит в геометрию, и появление
  /// или исчезновение текста не должно двигать список. При сбое чтения показывается причина —
  /// без неё «не загрузилось» неотличимо от «кадров больше нет», а это разные поводы что-то
  /// делать.
  String get footerNote {
    if (error != null) return error!;
    if (loadingHistory) return 'Загружаем историю…';
    return 'Это все кадры';
  }

  /// Подключить очередь миниатюр. Отдельным вызовом, потому что она открывается асинхронно
  /// (чтение каталога данных), а сетка к этому моменту уже может быть на экране.
  ///
  /// Пауза ставится сразу по текущему состоянию прокрутки: очередь могла подключиться как раз
  /// на ходу, и качать в этот момент ей нечего (см. [_onScrollingChanged]).
  void attachThumbs(ThumbCache cache) {
    thumbs = cache;
    cache.paused = isScrolling.value;
    notifyListeners();
  }

  /// Показывать ли превью в сетке.
  ///
  /// `false` — режим без картинок: плитки не просят миниатюры и не декодируют их, а рисуют
  /// значок по типу файла. Включается кнопкой в шапке раздела и переживает перезапуск
  /// (`UiStateStore.galleryPreviews`): выбор хранит экран, а контроллер применяет его к сетке
  /// и к опросу состояний превью (см. [_scheduleStatusPoll]).
  final ValueNotifier<bool> showPreviews = ValueNotifier(true);

  /// Переключить показ превью (см. [showPreviews]).
  ///
  /// Побочно: будит слушателей — живые плитки перерисовываются в новом режиме, — и заводит
  /// опрос состояний, если превью вернули: пока режим был выключен, спрашивать было нечего.
  void setShowPreviews(bool value) {
    if (showPreviews.value == value) return;
    showPreviews.value = value;
    if (value) _scheduleStatusPoll();
    notifyListeners();
  }

  /// Просмотрщик открыт: до его закрытия геометрия не пересобирается (см. [_viewerOpen]).
  void openViewer() => _viewerOpen = true;

  /// Просмотрщик закрыт: применить то, что принесла синхронизация за время его работы.
  void closeViewer() {
    _viewerOpen = false;
    if (!_dirty) return;
    _dirty = false;
    unawaited(_reloadMonths(keepPlace: true));
  }

  /// Первый показ раздела: разбивка, геометрия, затем синхронизация в фоне.
  ///
  /// Синхронизация не ждётся: сетка показывает то, что уже лежит в индексе, а сервер догоняет
  /// список следом. Ждать её значило бы держать спиннер на каждом открытии раздела.
  Future<void> open() async {
    sync.progress.addListener(_onSyncProgress);
    await _reloadMonths(keepPlace: false);
    _complete = await store.meta(GalleryStore.keyBackboneDone) == '1';
    if (kDebugMode) {
      debugPrint('cloudly-gallery: открытие — кадров ${await store.count()}, '
          'месяцев ${_months.length}, индекс полон: $_complete');
    }
    _loading = false;
    _publishCounters();
    _refreshTopFromScroll();
    notifyListeners();
    // Кадры читаются после первого кадра, а не до него: пятьдесят шесть тысяч строк идут
    // с диска заметное время, и ждать их, показывая спиннер, значит открывать раздел секундами.
    unawaited(_loadAll());
    _scheduleStatusPoll();
    unawaited(_syncInBackground());
  }

  /// Прочитать все кадры индекса в память — фоном, сразу после первого кадра сетки.
  ///
  /// Пока это идёт, сетка стоит на заглушках известного размера, а кадры встают в свои клетки
  /// месяц за месяцем. Чтение уступает прокрутке (см. `GalleryPages.paused`): человек, который
  /// сразу после открытия раздела потянул список, не должен ждать, пока разберут всю библиотеку.
  ///
  /// Побочно: `pages`, счётчики и уведомление слушателей.
  Future<void> _loadAll() async {
    await pages.loadAll();
    if (_disposed) return;
    _publishCounters();
    notifyListeners();
  }

  /// Раскладка изменилась (поворот экрана, другая ширина): пересчитать геометрию.
  ///
  /// Зовётся из `LayoutBuilder`, то есть во время сборки, поэтому уведомления и прокрутка —
  /// после кадра: будить слушателей и двигать позицию во время чужой сборки нельзя. Сама
  /// геометрия пересчитывается сразу: тот же кадр уже рисует строки по новым высотам.
  void setLayout(double gridWidth) {
    if ((gridWidth - _gridWidth).abs() < 0.5) return;
    final anchor = _topPlace();
    _gridWidth = gridWidth;
    _rebuild();
    _afterFrame(() {
      _restorePlace(anchor);
      _publishCounters();
      _refreshTopFromScroll();
      // Позиция прокрутки появляется вместе с первой раскладкой: до неё следить за состоянием
      // прокрутки не за чем (см. [_watchScrolling]).
      _watchScrolling();
      notifyListeners();
    });
  }

  /// Обработать событие прокрутки: подпись месяца в шапке и опрос превью.
  ///
  /// Кадры при этом никто не догружает — они уже в памяти (`GalleryPages`), — и читать на ходу
  /// нечего: приостановлены только редкие просьбы месяцев, которых в памяти нет вовсе
  /// (см. [_onScrollingChanged]).
  void onScroll() {
    _watchScrolling();
    _refreshTopFromScroll();
    _scheduleStatusPoll();
  }

  /// Строка сетки для вёрстки: заголовок месяца, ряд кадров или строка состояния.
  ///
  /// Клетки ряда могут быть `null` — кадр этого места ещё не прочитан из индекса (первые секунды
  /// после открытия раздела, пока идёт чтение всей библиотеки, или месяц, который перечитывается
  /// после синхронизации). Так и надо: строка известной высоты уже на месте, и приезд кадров
  /// ничего не сдвигает.
  GalleryRow rowAt(int row) {
    final idx = index;
    if (idx == null || idx.rowCount == 0) {
      return GalleryRow.note(footerNote, GalleryGrid.noteHeight);
    }
    final spec = idx.specAt(row);
    if (spec.note) return GalleryRow.note(footerNote, GalleryGrid.noteHeight);
    if (spec.header) {
      return GalleryRow.header(
        spec.month.isEmpty ? 'Без даты' : monthLabel(spec.month),
        spec.height,
      );
    }
    return GalleryRow.items(
      [for (var i = 0; i < spec.cells; i++) pages.itemAt(spec.month, spec.monthOffset + i)],
      spec.firstItem,
      spec.height,
    );
  }

  /// Высота строки [row] — ею вёрстка считает полную высоту списка; `null` — такой строки нет.
  double? rowHeight(int row) {
    final idx = index;
    if (idx == null || row < 0 || row >= idx.rowCount) return null;
    return idx.heightOfRow(row);
  }

  /// Кадр по номеру во всей ленте: так его берёт просмотрщик.
  ///
  /// `null` — кадр ещё не прочитан из индекса: просмотрщик показывает спиннер, а пачка
  /// запрашивается тут же ([ensureRange] зовётся им на каждой странице).
  MediaItem? itemAt(int item) {
    final idx = index;
    if (idx == null) return null;
    final at = idx.locateItem(item);
    return at == null ? null : pages.itemAt(at.month, at.offset);
  }

  /// Попросить кадры для диапазона номеров — просьба просмотрщика.
  ///
  /// Смотрятся края диапазона: кадр в его середине — тот, который просмотрщик и показывает,
  /// и его пачку он уже запросил сам. Края же — это соседи, до которых он долистает следом.
  void ensureRange(int start, int end) {
    final idx = index;
    if (idx == null) return;
    for (final item in [start, end]) {
      final at = idx.locateItem(item);
      if (at != null) pages.itemAt(at.month, at.offset);
    }
  }

  /// Убрать кадр из ленты: его удалил просмотрщик.
  ///
  /// Разбивка месяца уменьшается сразу за кадром, а не при следующей синхронизации: по ней
  /// посчитана геометрия, и разошедшись, они оставили бы под удалённым кадром пустую клетку.
  /// Номера кадров после удалённого сдвигаются — просмотрщик об этом знает и переставляет
  /// указатель сам (см. `MediaViewer`).
  void deleteAt(int item) {
    final idx = index;
    if (idx == null) return;
    final at = idx.locateItem(item);
    if (at == null) return;
    final removed = pages.loadedAt(at.month, at.offset);
    // Строка в индексе снимается, если кадр в руках: просмотрщик показывает именно его, но
    // кадра могло не быть в памяти, и тогда снять строку нечем. Разбивка при этом уменьшается
    // в любом случае — иначе номер, по которому листает просмотрщик, остался бы за концом ленты.
    unawaited(_forgetFrame(at.month, removed?.entryId));
    _months = [
      for (final m in _months)
        if ((m.month ?? '') == at.month)
          MediaMonthBucket(month: m.month, count: math.max(0, m.count - 1))
        else
          m,
    ];
    _rebuild();
    _publishCounters();
    _refreshTopFromScroll();
    notifyListeners();
  }

  /// Снять удалённый кадр из индекса и перечитать его месяц.
  ///
  /// Месяц перечитывается только ПОСЛЕ записи в базу ([pages.dropMonth] читает сразу, не
  /// дожидаясь остановки списка): чтение, начатое раньше удаления, вернуло бы удалённый кадр
  /// обратно в память — и он остался бы в сетке до следующей синхронизации.
  ///
  /// Побочно: строки и счётчик месяца в локальном индексе, кадры месяца в памяти.
  Future<void> _forgetFrame(String month, String? entryId) async {
    if (entryId != null) await store.removeEntries([entryId]);
    await store.decrementMonth(month);
    pages.dropMonth(month);
  }

  /// Повторить чтение — кнопкой в строке состояния.
  ///
  /// Непрочитанный месяц в памяти и не задерживался, поэтому достаточно снять причину и
  /// перерисовать: построенные строки попросят его снова (см. `GalleryPages.itemAt`).
  void retry() {
    error = null;
    notifyListeners();
  }

  /// Перечитать разбивку по месяцам и пересобрать геометрию.
  ///
  /// [keepPlace] — сохранить место чтения: синхронизация в фоне меняет разбивку (сверху доехали
  /// кадры, снизу удалились), и без переноса позиции человек оказался бы в другом месте ленты.
  Future<void> _reloadMonths({required bool keepPlace}) async {
    final months = await store.months();
    if (_disposed) return;
    final anchor = keepPlace ? _topPlace() : null;
    // Число кадров в месяце изменилось — значит, внутри месяца что-то появилось или пропало,
    // и его кадры в памяти устарели: номера внутри месяца сдвинулись. У месяцев с прежним
    // числом кадров меняться нечему, и перечитывать их незачем.
    pages.refreshChanged(months);
    _months = months;
    _rebuild();
    _restorePlace(anchor);
    _publishCounters();
    notifyListeners();
  }

  /// Пересобрать геометрию сетки по текущей разбивке и раскладке.
  ///
  /// Никого не уведомляет и прокрутку не двигает: зовётся и во время сборки (`setLayout`),
  /// где будить слушателей нельзя, и из асинхронных обновлений, которые публикуют счётчики сами.
  void _rebuild() {
    if (_gridWidth <= 0) return;
    index = GalleryIndex(months: _months, width: _gridWidth, hasNote: true);
  }

  /// Место чтения — месяц верхней видимой строки и её номер внутри месяца.
  ///
  /// Именно место, а не номер строки: номера сдвигаются от каждой загрузки сверху (и меняют
  /// высоты при смене раскладки), а «месяц и место в нём» переживает и то и другое
  /// (см. `GalleryIndex.topOfPlace`). `null` — сетки нет или видна строка состояния.
  ({String month, int rowInBlock})? _topPlace() {
    final idx = index;
    if (idx == null || idx.isEmpty || !scroll.hasClients) return null;
    final row = idx.rowAtOffset(scroll.offset - topInset);
    if (row < 0) return null;
    final spec = idx.specAt(row);
    if (spec.note) return null;
    return (month: spec.month, rowInBlock: spec.rowInBlock);
  }

  /// Вернуть список на место [anchor] после пересборки геометрии.
  void _restorePlace(({String month, int rowInBlock})? anchor) {
    final idx = index;
    if (anchor == null || idx == null || !scroll.hasClients) return;
    scroll.jumpTo(_clampOffset(topInset + idx.topOfPlace(anchor.month, anchor.rowInBlock)));
  }

  /// Предел прокрутки известен точно: высота списка, отступы сетки и высота окна.
  ///
  /// Без этого прыжок в самый низ списка (или на строку, оказавшуюся за концом после удаления)
  /// дал бы позицию за концом содержимого, и вёрстка поехала бы назад анимацией.
  double _clampOffset(double offset) {
    final idx = index;
    if (idx == null || !scroll.hasClients) return offset;
    final max = math.max(
      0.0,
      idx.height + topInset + GalleryGrid.gap - scroll.position.viewportDimension,
    );
    return offset.clamp(0.0, max);
  }

  /// Обновить счётчики, за которыми следят снаружи (просмотрщик и вёрстка).
  void _publishCounters() {
    final items = index?.itemCount ?? 0;
    if (total.value != items) total.value = items;
    revision.value++;
  }

  /// Выполнить после текущего кадра: во время сборки будить слушателей нельзя.
  ///
  /// Кадр при этом просится явно: отложенное обновление приходит из асинхронного чтения, когда
  /// рисовать вроде бы и нечего, а `addPostFrameCallback` сам по себе кадр не заказывает —
  /// без `scheduleFrame` уведомление ждало бы следующей причины перерисоваться, и сетка
  /// осталась бы с заглушками там, где кадры уже приехали.
  void _afterFrame(VoidCallback action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) action();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// Синхронизация в фоне, а после неё — новая разбивка и новая геометрия.
  ///
  /// Разбивка перечитывается, только если индекс изменился: сверху доехали кадры или из журнала
  /// ушли удалённые. Место чтения при этом сохраняется.
  Future<void> _syncInBackground() async {
    final changed = await sync.sync();
    if (_disposed) return;
    _complete = await store.meta(GalleryStore.keyBackboneDone) == '1';
    if (!changed) {
      notifyListeners();
      return;
    }
    // Просмотрщик открыт — геометрия ждёт его закрытия (см. [_viewerOpen]).
    if (_viewerOpen) {
      _dirty = true;
      notifyListeners();
      return;
    }
    await _reloadMonths(keepPlace: true);
  }

  /// Полоса наполнения индекса: пока проход идёт, видно, что кадры продолжают доезжать.
  ///
  /// Начало прохода — отдельный повод перечитать разбивку: серверную разбивку проход записывает
  /// первым делом, и по ней сетка сразу становится полной на всю историю, а кадры в ней
  /// появляются по месяцу за раз (см. `GalleryPages`).
  ///
  /// Перерисовку заказывает только СМЕНА состояния прохода, а не каждый его шаг. Сам ход виден
  /// полосой в шапке — у неё свой слушатель, — а кадры приезжают пачками и уведомляют сами
  /// (с ограничением частоты, см. [_onPagesLoaded]). Наполнение индекса читает страницы по тысяче
  /// кадров подряд, и перерисовка на каждой из них означала бы пересборку всех живых строк десятки
  /// раз в секунду всё время прохода: прокрутка в это время захлёбывается ровно тогда, когда
  /// человеку и хочется полистать библиотеку.
  void _onSyncProgress() {
    if (_disposed) return;
    final running = sync.progress.value?.running ?? false;
    // Прочитана очередная страница ленты: месяц, который лента дочитывает сейчас, подрос —
    // его надо перечитать, иначе низ месяца останется заглушками.
    if (running) pages.refreshChanged(_months);
    if (running == _filling) return;
    if (running) {
      _filling = true;
      unawaited(_reloadMonths(keepPlace: true));
    } else {
      _filling = false;
    }
    notifyListeners();
  }

  /// Кадры приехали из индекса: перерисовать строки, которые их ждали.
  ///
  /// Перерисовка — не чаще одного раза в кадр, а во время прокрутки — не чаще [_scrollRepaintMs].
  /// Месяц, прочитанный до начала движения, может вернуться уже на ходу, а пересборка списка
  /// стоит как пересборка всех живых строк — делегат строк объявляет себя изменившимся всегда
  /// (`SliverChildBuilderDelegate.shouldRebuild`). Под пальцем клетки всё равно мелькают, и делать
  /// это шестьдесят раз в секунду незачем.
  ///
  /// Приехавшее при этом не теряется: каждое чтение либо попадает в перерисовку по сроку таймера,
  /// либо, если прокрутка к тому времени уже встала, перерисовывается кадром — путь есть у любого.
  void _onPagesLoaded() {
    if (_disposed) return;
    _scheduleStatusPoll();
    _pagesDirty = true;
    if (isScrolling.value) {
      _repaintTimer ??= Timer(const Duration(milliseconds: _scrollRepaintMs), _onScrollRepaintDue);
      return;
    }
    _scheduleFrameRepaint();
  }

  /// Прокрутка идёт прямо сейчас.
  ///
  /// Наружу — плиткам: пока список едет, миниатюры не просятся (см. `GalleryTile`).
  final ValueNotifier<bool> isScrolling = ValueNotifier(false);

  /// Позиция прокрутки, за состоянием которой мы следим; `null` — ещё не подключились.
  ///
  /// Держится ссылкой, а не берётся из контроллера на каждом шаге: к моменту уничтожения экрана
  /// позиция уже может быть отцеплена, и `scroll.position` бросил бы исключение прямо в `dispose`.
  ScrollPosition? _watched;

  /// Обработать смену состояния прокрутки: началась — приостановить загрузки, кончилась —
  /// показать то, что видно.
  ///
  /// Это граница двух режимов раздела. Пока список едет, не качается ни одна миниатюра
  /// (`ThumbCache.paused`) и не читается ни один месяц, которого нет в памяти
  /// (`GalleryPages.paused`), а клетки, у которых картинки ещё нет, показывают заглушки
  /// (см. `GalleryTile`): декодирование миниатюр — это работа на каждый новый кадр прокрутки,
  /// и именно она видна как «клюёт, когда пытается загрузить». Уже показанные картинки движение
  /// не отбирает — они остаются на клетках до остановки. Кадры при этом на месте — библиотека
  /// лежит в памяти целиком (`GalleryPages`), — поэтому «границы подгруженного», на которой
  /// раньше начинался рывок, больше нет: читать на ходу просто нечего.
  ///
  /// По остановке ничего не происходит СРАЗУ: у плиток пауза в двести миллисекунд, у
  /// `GalleryPages` — в секунду (свой `_settle` у каждого, см. `GalleryTile`). Палец замирает
  /// между движениями, и работа, начатая по первой же остановке, приходится на кадр следующего
  /// движения; плиткам хватает короткой паузы, потому что показанное они не теряют,
  /// а чтение месяцев — работа главного изолята, и ей нужен срок понадёжнее.
  ///
  /// Побочно: `isScrolling`, пауза чтения месяцев и очереди миниатюр, перерисовка по остановке.
  void _onScrollingChanged() {
    if (_disposed) return;
    final moving = _watched?.isScrollingNotifier.value ?? false;
    if (isScrolling.value != moving) isScrolling.value = moving;
    pages.paused = moving;
    thumbs?.paused = moving;
    // Начало движения — это и есть вся работа: паузы поставлены, качать и читать нечего.
    if (moving) return;
    // Список встал: перерисовать построенные строки — они попросят недостающие месяцы,
    // а плитки миниатюры. Заодно возобновляется опрос состояний: во время движения он не шёл.
    _repaintNow();
    _scheduleStatusPoll();
  }

  /// Подключиться к состоянию прокрутки, как только у контроллера появится позиция.
  ///
  /// Позиция возникает при первой раскладке списка, поэтому зовётся и с прокрутки, и после кадра
  /// (см. `setLayout`): до этого момента `isScrollingNotifier` просто не существует.
  void _watchScrolling() {
    if (_watched != null || !scroll.hasClients) return;
    _watched = scroll.position;
    _watched!.isScrollingNotifier.addListener(_onScrollingChanged);
    _onScrollingChanged();
  }

  /// Срок таймера прокрутки: показать приехавшее, не дожидаясь остановки.
  ///
  /// Пачка, которую ждали, успевает вернуться на ходу — например, её просили ещё до начала
  /// движения, — и держать её до остановки незачем: четверть секунды успевает пройти между
  /// заметными движениями пальца, а перерисовка стоит четыре раза в секунду, а не шестьдесят.
  void _onScrollRepaintDue() {
    _repaintTimer = null;
    if (_disposed || !_pagesDirty) return;
    _repaintNow();
  }

  /// Перерисовать сетку после кадра — когда список стоит.
  void _scheduleFrameRepaint() {
    if (_repaintScheduled) return;
    _repaintScheduled = true;
    _afterFrame(() {
      _repaintScheduled = false;
      if (_pagesDirty) _repaintNow();
    });
  }

  /// Показать приехавшие кадры: их ждут построенные строки и открытый просмотрщик.
  void _repaintNow() {
    _pagesDirty = false;
    revision.value++;
    notifyListeners();
  }

  /// Пачка не прочиталась: причина показывается в строке состояния, повтор — кнопкой.
  void _onPagesError(Object e) {
    if (_disposed) return;
    error = e.toString();
    notifyListeners();
  }

  /// Запустить опрос состояний превью, если он ещё не идёт.
  ///
  /// Во время прокрутки опрос не начинается: это запрос к серверу, а список на ходу не платит
  /// ни за сеть, ни за разбор ответа. Остановка возобновляет его сама (см. [_onScrollingChanged]).
  void _scheduleStatusPoll() {
    if (isScrolling.value || !showPreviews.value) return;
    _statusTimer ??= Timer(const Duration(milliseconds: _statusPollMs), _pollStatuses);
  }

  /// Переспросить у сервера состояние превью у видимых кадров, которые ещё не готовы.
  ///
  /// Нужно потому, что к моменту показа кадра превью часто только в очереди: без перезапроса
  /// клетка осталась бы серой до перезахода в раздел. Опрос прекращается сам — когда неготовых
  /// не осталось или когда каждого спрашивали [_statusMaxTries] раз (превью может собираться
  /// долго, а очередь стоять, и ждать этого на открытом экране незачем).
  Future<void> _pollStatuses() async {
    _statusTimer = null;
    // Превью не показываются: состояние картинок, которые не появятся на экране, спрашивать
    // незачем — опрос заведётся сам, когда режим вернут (см. [setShowPreviews]).
    if (!showPreviews.value) return;
    final unready = _visibleUnready();
    if (unready.isEmpty) return;
    try {
      final states = await apiOf().mediaStatus(unready.keys.toList());
      final by = {for (final st in states) st.entryId: st};
      final persist = <String, String>{};
      var unresolved = false;
      unready.forEach((id, place) {
        _statusTries[id] = (_statusTries[id] ?? 0) + 1;
        final st = by[id];
        if (st == null) return;
        if (st.previewState != 'done' && st.previewState != 'impossible') unresolved = true;
        final item = pages.loadedAt(place.month, place.offset);
        if (item == null || item.entryId != id || item.previewState == st.previewState) return;
        final updated = item.copyWith(previewState: st.previewState, jobState: st.jobState);
        // Замена может не найти своё место: пачка успела вытесниться — тогда новое состояние
        // приедет вместе с кадром при следующем чтении.
        if (pages.replace(place.month, place.offset, updated)) persist[id] = st.previewState;
      });
      if (persist.isNotEmpty) {
        await store.setPreviewStates(persist);
        revision.value++;
        notifyListeners();
      }
      if (unresolved) _scheduleStatusPoll();
    } catch (e) {
      // Неудачный опрос — не повод падать: следующий запустится после следующей прокрутки.
      if (kDebugMode) debugPrint('gallery status error: $e');
    }
  }

  /// Видимые кадры без готового превью: id → место кадра в индексе (месяц и номер в нём).
  ///
  /// Только видимые: опрос — это запрос каждые пять секунд, и спрашивать про всю библиотеку
  /// значило бы занимать канал тем, чего человек не видит.
  Map<String, ({String month, int offset})> _visibleUnready() {
    final idx = index;
    if (idx == null || !scroll.hasClients) return const {};
    final offset = scroll.offset - topInset;
    final first = idx.rowAtOffset(offset);
    final last = idx.rowAtOffset(offset + scroll.position.viewportDimension);
    final out = <String, ({String month, int offset})>{};
    for (var row = first < 0 ? 0 : first; row <= last && out.length < _statusBatchMax; row++) {
      final spec = idx.specAt(row);
      for (var i = 0; i < spec.cells; i++) {
        final at = spec.monthOffset + i;
        final item = pages.loadedAt(spec.month, at);
        if (item == null) continue;
        if (item.previewState == 'done' || item.previewState == 'impossible') continue;
        if ((_statusTries[item.entryId] ?? 0) >= _statusMaxTries) continue;
        out[item.entryId] = (month: spec.month, offset: at);
      }
    }
    return out;
  }

  /// Подпись месяца в шапке по текущей позиции прокрутки.
  void _refreshTopFromScroll() => _refreshTop((scroll.hasClients ? scroll.offset : 0.0) - topInset);

  /// Подпись месяца для смещения [offset] от начала списка.
  ///
  /// Считается по верхней видимой строке, а не по кадру: строка знает свой месяц из геометрии,
  /// поэтому подпись верна и там, где кадры ещё не прочитаны, — а именно это и остаётся
  /// единственным ответом на «где я во времени», пока человек тянет ползунок скроллбара.
  void _refreshTop(double offset) {
    final idx = index;
    if (idx == null || idx.isEmpty) return;
    final row = idx.rowAtOffset(offset);
    if (row < 0) return;
    final spec = idx.specAt(row);
    if (spec.note) return;
    barTitle.value = spec.month.isEmpty ? 'Без даты' : monthLabel(spec.month);
  }

  @override
  void dispose() {
    _disposed = true;
    _statusTimer?.cancel();
    _repaintTimer?.cancel();
    _watched?.isScrollingNotifier.removeListener(_onScrollingChanged);
    sync.progress.removeListener(_onSyncProgress);
    scroll.dispose();
    total.dispose();
    revision.dispose();
    barTitle.dispose();
    isScrolling.dispose();
    showPreviews.dispose();
    super.dispose();
  }
}
