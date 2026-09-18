import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'gallery_index.dart';

/// Слайвер сетки галереи: строки известной высоты и точная геометрия всего списка.
///
/// ## Зачем свой слайвер, а не `SliverVariedExtentList`
///
/// У списка переменной высоты Flutter переводит «смещение прокрутки → строка» и «строка → её
/// смещение» сложением высот с начала списка. `SliverVariedExtentList` рендерится
/// `RenderSliverVariedExtentList` — наследником `RenderSliverFixedExtentBoxAdaptor`, — и когда
/// задан `itemExtentBuilder`, у него `indexToLayoutOffset` крутит цикл от НУЛЕВОЙ строки (и зовётся
/// на каждого уложенного ребёнка), `_getChildIndexForScrollOffset` идёт по строкам от начала,
/// а `computeMaxScrollOffset` суммирует высоты всех строк. На ленте в восемнадцать тысяч строк это
/// сотни тысяч вызовов за кадр, и стоит это тем дороже, чем дальше от начала списка уехала
/// прокрутка: вверху списка гладко, после резкого пролива в дальний год — рывками.
///
/// Оба перевода делает индекс ([GalleryIndex]): он знает блоки месяцев, поэтому строку по смещению
/// находит двоичным поиском, а смещение строки — арифметикой внутри блока. Стоимость не зависит
/// от места прокрутки.
///
/// ## Почему полная длина известна точно
///
/// Высоту содержимого вёрстка берёт у делегата, а `SliverChildBuilderDelegate` умеет её только
/// ОЦЕНИТЬ: «средняя высота построенных детей × сколько осталось» (`_extrapolateMaxScrollOffset`).
/// Построенные дети — смесь заголовков месяцев по 34 и рядов кадров по ~87, поэтому оценка меньше
/// настоящей высоты, и список живёт с двумя разными длинами: ползунок скроллбара считает долю
/// по оценке, а `GalleryController` ограничивает прыжок по точной высоте. Расхождение и видно как
/// «далеко и резко — глючит». Индекс знает высоту целиком, поэтому [estimateMaxScrollOffset]
/// отдаёт её точно — этот метод `SliverMultiBoxAdaptorWidget` для того и объявлен.
class GalleryRowsSliver extends SliverVariedExtentList {
  const GalleryRowsSliver({
    super.key,
    required super.delegate,
    required super.itemExtentBuilder,
    required this.index,
  });

  /// Индекс сетки: по нему считаются и места строк, и полная высота содержимого.
  final GalleryIndex index;

  @override
  RenderSliverVariedExtentList createRenderObject(BuildContext context) {
    return _RenderGalleryRows(
      index,
      childManager: context as SliverMultiBoxAdaptorElement,
      itemExtentBuilder: itemExtentBuilder,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderSliverVariedExtentList renderObject) {
    // Приведение безопасно: этот рендер-объект создан здесь же (`createRenderObject`), а вёрстка
    // передаёт сюда ровно его.
    (renderObject as _RenderGalleryRows)
      ..itemExtentBuilder = itemExtentBuilder
      ..index = index;
  }

  /// Точная высота всех строк — вместо оценки по построенным детям.
  ///
  /// Список конечный и полностью известный, поэтому догадываться о его длине не нужно:
  /// `null` (и вместе с ним оценка делегата) здесь не возвращается никогда.
  @override
  double? estimateMaxScrollOffset(
    SliverConstraints? constraints,
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) =>
      index.height;
}

/// Рендер-объект сетки: переводы «смещение ↔ строка» берутся у индекса, а не обходом списка.
///
/// Переопределяются ровно те методы родителя, которые обходят список от нулевого ребёнка;
/// остальное — раскладка детей, сборка мусора, отрисовка — остаётся родительским: строки у нас
/// такие же дети фиксированной высоты, только высоты эти ему сообщают, а не считает он сам.
class _RenderGalleryRows extends RenderSliverVariedExtentList {
  /// [index] — геометрия строк; остальное — как у родителя.
  ///
  /// Первым позиционным параметром, а не именованным: именованный параметр не может быть
  /// приватным, и поле пришлось бы присваивать в теле вместо инициализирующей формы.
  _RenderGalleryRows(
    this._index, {
    required super.childManager,
    required super.itemExtentBuilder,
  });

  GalleryIndex _index;

  /// Индекс сетки. Смена геометрии (другая ширина экрана, другое число кадров в месяцах)
  /// обязывает переложить список: у строк меняются и высоты, и места, и полная длина.
  GalleryIndex get index => _index;
  set index(GalleryIndex value) {
    if (identical(_index, value)) return;
    _index = value;
    markNeedsLayout();
  }

  /// Смещение начала строки [index] — там вёрстка её и ставит.
  @override
  double indexToLayoutOffset(double itemExtent, int index) => _index.topOfRow(index);

  /// Первая строка, попадающая в смещение [scrollOffset]: с неё начинается раскладка.
  @override
  int getMinChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _index.rowAtOffset(scrollOffset);

  /// Последняя строка, попадающая в смещение [scrollOffset].
  ///
  /// Как и у родителя, это строка, накрывающая смещение: её конец — граница, за которой строки
  /// уже не нужны. Смещение за концом списка даёт последнюю строку, поэтому доведённая до края
  /// прокрутка раскладывает ровно то, что есть.
  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _index.rowAtOffset(scrollOffset);

  /// Точная высота содержимого: сумма высот всех строк известна индексу без обхода.
  @override
  double computeMaxScrollOffset(SliverConstraints constraints, double itemExtent) => _index.height;
}
