import 'dart:async';
import 'dart:math' as math;

// `CupertinoPageRoute` берём точечно: это маршрут с горизонтальным слайдом и пальцевым
// возвратом от края на всех платформах, а из всего `cupertino.dart` здесь нужен он один.
import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';

import '../theme.dart';
import 'widgets.dart';

/// Пункт раскладки «список — деталка»: строка списка слева и то, что открывается по её выбору.
class MasterDetailEntry {
  const MasterDetailEntry({
    required this.id,
    required this.title,
    required this.icon,
    required this.body,
  });

  /// Ключ пункта. По нему держится выбранная строка и узнаётся уже построенное тело, поэтому
  /// у двух пунктов он не должен совпадать — иначе выбор и память ширины перепутаются.
  final String id;

  /// Подпись в списке. Она же — заголовок отдельного экрана на телефоне.
  final String title;

  /// Значок строки.
  final IconData icon;

  /// Содержимое правой панели. Строится один раз при первом открытии пункта и дальше живёт
  /// (см. [_MasterDetailState._built]).
  final Widget body;
}

/// Раскладка «список слева, деталка справа» для разделов приложения.
///
/// Один виджет на все разделы, которые заходят списком: «Проекты», «Настройки» и те, что
/// появятся дальше. На широком экране список и выбранный пункт лежат двумя карточками на
/// чёрном фоне (`C.canvas`), а границу между карточками можно тянуть пальцем или мышкой;
/// на узком список занимает всю ширину,
/// а пункт открывается отдельным экраном с кнопкой «назад».
///
/// Какой вид показать, решает ширина самого раздела ([twoPaneMin], по умолчанию 720):
/// `LayoutBuilder` отдаёт уже урезанные границы (без бара разделов и разделителя оболочки),
/// поэтому порог один и тот же на всех платформах, и подгонять его под чужие виджеты не нужно.
/// `MediaQuery` дал бы ширину окна и сломался бы на маке и iPad, где окно меняется на лету.
///
/// Ширину колонки раскладка не хранит сама: её читает и записывает вызывающий
/// ([initialWidth], [onWidthChanged]) — так общий виджет не зависит от хранилища настроек,
/// а у каждого раздела остаётся своя запомненная ширина.
class MasterDetail extends StatefulWidget {
  const MasterDetail({
    super.key,
    required this.title,
    required this.entries,
    this.headerActions = const [],
    this.initialWidth,
    this.onWidthChanged,
    this.twoPaneMin = 720,
    this.sidebarMin = 240,
    this.sidebarMax = 560,
    this.sidebarDefaultMax = 380,
    this.detailScrollable = true,
  });

  /// Заголовок колонки со списком (название раздела). На телефоне он заменяет `AppBar`.
  final String title;

  /// Пункты списка: порядок здесь — порядок строк на экране.
  final List<MasterDetailEntry> entries;

  /// Значки в шапке списка справа (вкладки раздела). Пусто — шапка только с заголовком.
  final List<Widget> headerActions;

  /// Запомненная ширина колонки со списком или `null` — «по умолчанию». Значение из диапазона
  /// всё равно приводится к текущей ширине раздела ([sidebarMin]…[sidebarMax]).
  final double? initialWidth;

  /// Куда сообщать о новой ширине после перетаскивания границы или её сброса двойным тапом.
  final ValueChanged<double>? onWidthChanged;

  /// Минимальная ширина раздела, начиная с которой список и деталка показываются рядом.
  final double twoPaneMin;

  /// Пределы ширины колонки со списком. Ниже минимума строки не читаются, выше максимума
  /// список забрал бы у деталки больше половины экрана.
  final double sidebarMin;
  final double sidebarMax;

  /// Ширина по умолчанию для широкого экрана: доля от ширины раздела, но не больше этой
  /// величины. Отсюда видно, зачем нужен третий предел помимо [sidebarMax]: на большом
  /// мониторе список сам по себе никогда не должен занимать половину экрана.
  final double sidebarDefaultMax;

  /// Оборачивать ли тело пункта в прокрутку. Панели настроек — обычные колонки карточек,
  /// и прокрутка нужна им самим; экраны со своей прокруткой (переписка агента) передают
  /// `false`, чтобы список не оказался внутри списка.
  final bool detailScrollable;

  @override
  State<MasterDetail> createState() => _MasterDetailState();
}

/// Состояние раскладки: выбранный пункт, ширина колонки и уже построенные тела пунктов.
class _MasterDetailState extends State<MasterDetail> {
  /// Минимальная ширина деталки при перетаскивании границы: уже неё правая панель перестаёт
  /// быть рабочей областью, и тянуть дальше некуда.
  static const _minDetail = 320.0;

  /// Поле вокруг карточек: между ними и краем раздела просвечивает фон приложения.
  static const _paneGap = kPaneGutter;

  /// Ширина невидимой границы между карточками — она же промежуток между ними. Два поля
  /// сетки ([kPaneGutter]) — ровно то расстояние, что отделяет иконки бара от первой карточки
  /// (боковое поле бара плюс поле раздела), поэтому и бар, и карточки стоят на одной сетке.
  /// Палец шире одной линии, поэтому это полоса, а не штрих: по ней попадают и на планшете,
  /// и мышкой.
  static const _handleWidth = 2 * kPaneGutter;

  /// Сколько ширины раздела занимают не список и не деталка: поля и полоса между карточками.
  /// Вычитается из ширины, когда считается предел колонки со списком.
  static const _chrome = 2 * _paneGap + _handleWidth;

  /// Выбранный пункт; `null` — «первый из списка» (см. [_selected]).
  String? _selectedId;

  /// Ширина колонки со списком: `null` — ещё не тянули, ширину считает [_sidebarWidth].
  double? _width;

  /// Ширина раздела на последнем построении. Нужна обработчику перетаскивания: жест приходит
  /// между кадрами, когда `LayoutBuilder` уже отработал, и взять её больше негде.
  double _paneWidth = 0;

  /// Тела пунктов, построенные при первом открытии и дальше живущие в `IndexedStack`.
  ///
  /// В этом весь смысл: у «Обновления» в теле идёт скачивание, а его `dispose` рвёт запрос, —
  /// переключение на другой пункт не должно обрывать начатое. По той же причине здесь лежит
  /// уже собранный виджет, а не строится заново: новый экземпляр сбросил бы состояние панели.
  ///
  /// Плата за это — тело строится по тем данным, что были при первом открытии. Тела пунктов
  /// самодостаточны (панели настроек сами ходят на сервер), поэтому устареть им нечем.
  final Map<String, Widget> _built = {};

  @override
  void initState() {
    super.initState();
    _width = widget.initialWidth;
  }

  /// Пункт, который показан справа: выбранный, а если его нет в списке — первый.
  ///
  /// Первый, а не «ничего»: на широком экране пустая правая панель при открытии раздела
  /// выглядит как поломка, а показать один из пунктов сразу — то же, что сделал бы человек.
  MasterDetailEntry? get _selected {
    if (widget.entries.isEmpty) return null;
    final id = _selectedId;
    for (final e in widget.entries) {
      if (e.id == id) return e;
    }
    return widget.entries.first;
  }

  /// Ширина колонки со списком для раздела шириной [paneWidth].
  ///
  /// По умолчанию — доля от ширины раздела (треть), но не больше [sidebarDefaultMax]. Затем
  /// значение ужимается так, чтобы деталке осталось хотя бы [_minDetail]: на узком двухпанельном
  /// экране запомненная ширина иначе съела бы правую панель целиком.
  double _sidebarWidth(double paneWidth) {
    final limit = math.max(
      widget.sidebarMin,
      math.min(widget.sidebarMax, paneWidth - _chrome - _minDetail),
    );
    final base =
        _width ?? (paneWidth * 0.34).clamp(widget.sidebarMin, widget.sidebarDefaultMax);
    return base.clamp(widget.sidebarMin, limit);
  }

  /// Тянет границу: к текущей ширине прибавляется сдвиг пальца за кадр.
  void _drag(double delta) {
    if (_paneWidth <= 0) return;
    final limit = math.max(
      widget.sidebarMin,
      math.min(widget.sidebarMax, _paneWidth - _chrome - _minDetail),
    );
    final next = (_sidebarWidth(_paneWidth) + delta).clamp(widget.sidebarMin, limit);
    setState(() => _width = next);
  }

  /// Запоминает ширину после перетаскивания: писать в настройки на каждый кадр незачем.
  void _persistWidth() {
    final w = _width;
    if (w != null) widget.onWidthChanged?.call(w);
  }

  /// Возвращает ширину по умолчанию по двойному тапу на границе.
  ///
  /// `setState` выполняет колбэк сразу, поэтому [_sidebarWidth] после сброса `_width` успевает
  /// посчитать именно ширину по умолчанию — её и записываем как новую настройку.
  void _resetWidth() {
    if (_paneWidth <= 0) return;
    setState(() => _width = null);
    widget.onWidthChanged?.call(_sidebarWidth(_paneWidth));
  }

  /// Строку нажали: на широком экране это выбор пункта, на телефоне — открытие отдельным экраном.
  void _select(MasterDetailEntry e, {required bool wide}) {
    if (wide) {
      if (_selected?.id == e.id) return;
      setState(() => _selectedId = e.id);
      return;
    }
    // не ждём закрытия экрана: строка списка ничего не должна делать после возврата
    unawaited(_push(e));
  }

  /// Открывает пункт отдельным экраном (телефон) — с шапкой и кнопкой «назад».
  Future<void> _push(MasterDetailEntry e) async {
    await Navigator.of(context).push(
      // `CupertinoPageRoute`, а не `MaterialPageRoute`: горизонтальный слайд и пальцевый
      // возврат от края одинаковы на Android и iOS, как и в разделе «Проекты».
      CupertinoPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text(e.title, style: const TextStyle(color: C.fg, fontSize: 18)),
          ),
          // на телефоне тело живёт только на этом экране и никуда не переключается:
          // кэшировать его незачем
          body: _paneBody(e),
        ),
      ),
    );
  }

  /// Тело пункта в правой панели: ранее построенное, а если его ещё не открывали — строим.
  Widget _body(MasterDetailEntry e) => _built.putIfAbsent(e.id, () => _paneBody(e));

  /// Содержимое пункта как оно лежит в панели: с прокруткой, если она ему нужна.
  ///
  /// Нижний отступ включает высоту полосы навигации Android: у списка настроек свой `padding`,
  /// и без этого последняя карточка уезжала бы под полосу жестов.
  Widget _paneBody(MasterDetailEntry e) => widget.detailScrollable
      ? ListView(
          padding: EdgeInsets.only(bottom: navBarInset(context) + 24),
          children: [e.body],
        )
      : e.body;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _paneWidth = c.maxWidth;
        final wide = c.maxWidth >= widget.twoPaneMin;
        return wide ? _twoPane(c.maxWidth) : _singlePane();
      },
    );
  }

  /// Однопанельный вид: список карточкой во всю ширину, пункт открывается экраном поверх.
  ///
  /// Карточка здесь та же, что и на широком экране, а не полноэкранный список как раньше:
  /// раздел выглядит одинаково на любой ширине, и переход между телефоном и планшетом ничего
  /// не меняет в том, как список устроен.
  Widget _singlePane() => Scaffold(
    backgroundColor: C.canvas,
    body: Padding(
      padding: const EdgeInsets.all(_paneGap),
      child: _card(child: _master(wide: false)),
    ),
  );

  /// Двухпанельный вид: список и выбранный пункт — двумя карточками на чёрном фоне.
  Widget _twoPane(double paneWidth) {
    return Scaffold(
      // фон раздела — `canvas`: карточки лежат на нём, и промежутки между ними чёрные
      backgroundColor: C.canvas,
      body: Padding(
        padding: const EdgeInsets.all(_paneGap),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _card(width: _sidebarWidth(paneWidth), child: _master(wide: true)),
            _ResizeHandle(
              width: _handleWidth,
              onDrag: _drag,
              onDragEnd: _persistWidth,
              onReset: _resetWidth,
            ),
            Expanded(child: _card(child: _detail())),
          ],
        ),
      ),
    );
  }

  /// Карточка раскладки: фон `surface` на чёрном фоне раздела и скруглённые углы.
  ///
  /// `Material`, а не `Container`: он же даёт подложку всплескам от нажатия в строках списка.
  /// `clipBehavior` нужен, чтобы подсветка выбранной строки не выходила за скруглённый угол.
  Widget _card({double? width, required Widget child}) => Material(
    color: C.surface,
    borderRadius: BorderRadius.circular(16),
    clipBehavior: Clip.antiAlias,
    child: SizedBox(width: width, child: child),
  );

  /// Правая панель: тело выбранного пункта, а если ничего не выбрано — пусто.
  ///
  /// Тела живут в `IndexedStack`: он держит в дереве все уже открытые и показывает только
  /// выбранное. Прокрутка и набранный текст в невидимых панелях при этом не сбрасываются,
  /// а скачивание в «Обновлении» не обрывается переключением на соседний пункт.
  Widget _detail() {
    final selected = _selected;
    if (selected == null) return const SizedBox.shrink();
    _body(selected);
    final built = [for (final e in widget.entries) if (_built.containsKey(e.id)) e];
    return IndexedStack(
      // размер по панели, а не по самому крупному ребёнку: иначе `IndexedStack` растянул бы
      // правую панель под него и сломал раскладку
      sizing: StackFit.expand,
      index: built.indexWhere((e) => e.id == selected.id),
      children: [for (final e in built) _built[e.id]!],
    );
  }

  /// Колонка со списком: шапка и строки пунктов. Фон даёт карточка, в которую её кладут.
  Widget _master({required bool wide}) => Column(
    children: [
      _masterHeader(),
      Expanded(
        child: ListView.builder(
          padding: EdgeInsets.only(bottom: navBarInset(context) + 24),
          itemCount: widget.entries.length,
          itemBuilder: (context, i) => _entryTile(widget.entries[i], wide: wide),
        ),
      ),
    ],
  );

  /// Шапка списка: название раздела и значки-вкладки.
  ///
  /// Высота 56 — как у шапки открытого раздела в «Проектах»: обе шапки стоят на одной линии
  /// и читаются одной полосой. Отступы по краям — как у строк списка, чтобы заголовок был
  /// с ними на одной вертикали.
  Widget _masterHeader() => SizedBox(
    height: 56,
    child: Padding(
      padding: const EdgeInsets.only(left: 16, right: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.title,
              style: const TextStyle(color: C.fg, fontSize: 18),
            ),
          ),
          ...widget.headerActions,
        ],
      ),
    ),
  );

  /// Строка списка: значок и подпись.
  ///
  /// Высота и отступы — как у строк левого бара и списка разговоров: списки разделов читаются
  /// одним ритмом. Выбранную строку подсвечивает [Material] под [InkWell], чтобы всплеск от
  /// нажатия ложился поверх подсветки, а не под неё.
  Widget _entryTile(MasterDetailEntry e, {required bool wide}) {
    final selected = wide && e.id == _selected?.id;
    return Material(
      color: selected ? C.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: () => _select(e, wide: wide),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(
            children: [
              Icon(e.icon, size: 22, color: selected ? C.accent : C.fg3),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  e.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: selected ? C.accent : C.fg, fontSize: 15),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Перетаскиваемая граница между карточками списка и деталки.
///
/// Границы не видно и подсказки у неё нет: между карточками чёрный фон, и трогать надо пустоту.
/// Единственное, что выдаёт ручку, — курсор «тянуть влево-вправо» на маке. Двойной тап
/// возвращает ширину по умолчанию: иначе, затащив список в неудобное состояние, вернуть его
/// было бы нечем.
///
/// Ширина — полоса, а не штрих: палец шире точки, по полосе попадают и на планшете, и мышкой.
class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    required this.width,
    required this.onDrag,
    required this.onDragEnd,
    required this.onReset,
  });

  /// Ширина полосы между карточками.
  final double width;

  /// Сдвиг за кадр во время перетаскивания (в логических пикселях).
  final ValueChanged<double> onDrag;

  /// Перетаскивание закончилось — пора запомнить ширину.
  final VoidCallback onDragEnd;

  /// Двойной тап — вернуть ширину по умолчанию.
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        // `opaque`: полоса прозрачная, и без этого жесты мимо иконки не доходили бы до неё
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) => onDragEnd(),
        onDoubleTap: onReset,
        child: SizedBox(
          width: width,
          // пустая полоса: рисовать в ней нечего, а тянуть можно по всей высоте раздела
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
