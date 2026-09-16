import '../../api/models.dart';
import '../../util/format.dart';

/// Строка сетки галереи: либо заголовок месяца, либо ряд кадров.
///
/// Списком строк, а не одной плиткой на кадр, сетка собирается ради заголовков месяцев:
/// заголовок — такая же строка, и он не может разорвать ряд из четырёх кадров.
class GalleryRow {
  /// Подпись заголовка («Май 2021»); у ряда кадров — `null`.
  final String? header;

  /// Кадры ряда: у заголовка пусто, у ряда — от одного до [GalleryGrid.columns] штук.
  final List<MediaItem> items;

  /// Высота строки: у заголовка своя ([GalleryGrid.headerHeight]), у ряда кадров — шаг ряда
  /// (сторона клетки плюс зазор). Фиксированные высоты здесь принципиальны: по ним считается,
  /// что видно в окне, и куда встать после прыжка по шкале.
  final double height;

  /// Текст строки состояния внизу окна («Загружаем…», причина сбоя) — `null` у остальных строк.
  final String? note;

  const GalleryRow.header(String this.header, this.height)
      : items = const [],
        note = null;
  const GalleryRow.items(this.items, this.height)
      : header = null,
        note = null;
  const GalleryRow.note(String this.note, this.height)
      : header = null,
        items = const [];

  /// Заголовок ли это (у ряда кадров подписи нет).
  bool get isHeader => header != null;

  /// Строка состояния ли это.
  bool get isNote => note != null;
}

/// Геометрия сетки: сколько кадров в ряду и какие у рядов высоты.
///
/// Числа одни на весь раздел: их видят и вёрстка, и расчёт видимого окна, и прыжок по шкале.
/// Разъехавшись, они дали бы окно, посчитанное по одной геометрии и нарисованное по другой, —
/// а это ровно тот «скролл уезжает», из-за которого раздел и переписывается.
class GalleryGrid {
  const GalleryGrid._();

  /// Кадров в ряду. Четыре — не только плотность: сервер собирает превью сетки квадратом
  /// `GRID_SIZE = 256` (src/media/media.service.ts), и на экране 360 dp при четырёх колонках
  /// клетка выходит ~75 dp, то есть ~225 физических пикселей на DPR 3 — превью покрывает её
  /// целиком. Пять колонок потребовали бы превью 512, которого сервер не собирает.
  static const int columns = 4;

  /// Зазор между клетками и по краям сетки.
  static const double gap = 3.0;

  /// Высота строки-заголовка месяца вместе с отступом.
  static const double headerHeight = 34.0;

  /// Высота строки состояния внизу окна (загрузка или сбой).
  static const double noteHeight = 52.0;

  /// Сторона клетки при ширине сетки [width]: экран минус шкала и зазоры, поделённый на колонки.
  static double cellSide(double width) => (width - (columns + 1) * gap) / columns;

  /// Шаг ряда: сторона клетки плюс зазор. По нему считается высота ряда кадров.
  static double rowStep(double width) => cellSide(width) + gap;

  /// Ключ месяца «ГГГГ-ММ» для момента съёмки в поясе зрителя.
  ///
  /// Один на весь раздел: по нему и подписи заголовков, и бакеты шкалы таймлайна, и границы
  /// месяцев для прыжка. Разные пояса в этих трёх местах развели бы шкалу, заголовки и кадр,
  /// к которому прыгнули.
  static String monthKey(DateTime at, int tzOffsetMin) {
    final shifted = at.toUtc().add(Duration(minutes: tzOffsetMin));
    return '${shifted.year}-${shifted.month.toString().padLeft(2, '0')}';
  }
}

/// Собрать строки сетки в визуальном порядке — сверху вниз.
///
/// [startsMonth] — по флагу на кадр: начинает ли он новый месяц. Заголовок ставится ПЕРЕД таким
/// кадром, и вместе с ним начинается новый ряд: иначе половина ряда осталась бы от прошлого
/// месяца, и подпись относилась бы не ко всем кадрам под ней.
///
/// Флаги считаются по всему окну сразу, а режется оно потом на два плеча: так на стыке плеч
/// заголовок месяца остаётся там, где ему и место, — перед первым кадром месяца.
///
/// [tzOffsetMin] — сдвиг пояса зрителя: месяц подписи считается по нему, как и бакеты шкалы
/// таймлайна (`/media/months?tz=`). Иначе заголовок и шкала могли бы разойтись на кадре,
/// снятом у границы месяца.
List<GalleryRow> buildGalleryRows({
  required List<MediaItem> items,
  required List<bool> startsMonth,
  required double width,
  required int tzOffsetMin,
}) {
  final step = GalleryGrid.rowStep(width);
  final rows = <GalleryRow>[];
  var current = <MediaItem>[];
  for (var i = 0; i < items.length; i++) {
    if (startsMonth[i]) {
      if (current.isNotEmpty) {
        rows.add(GalleryRow.items(List.unmodifiable(current), step));
        current = [];
      }
      rows.add(GalleryRow.header(_headerLabel(items[i], tzOffsetMin), GalleryGrid.headerHeight));
    }
    current.add(items[i]);
    if (current.length == GalleryGrid.columns) {
      rows.add(GalleryRow.items(List.unmodifiable(current), step));
      current = [];
    }
  }
  if (current.isNotEmpty) rows.add(GalleryRow.items(List.unmodifiable(current), step));
  return rows;
}

/// Плечо окна: строки от якоря наружу и их геометрия.
///
/// Окно галереи растёт в две стороны от якоря (кадра, с которого началось окно): вверх —
/// к свежему, вниз — к старому. Строки обоих плеч лежат в порядке «от якоря наружу», и это не
/// деталь вёрстки: слот, стоящий непосредственно над якорем, — первый в своём плече, и
/// добавление страниц вверх не сдвигает то, что человек видит (см. `GalleryController`).
class GalleryArm {
  const GalleryArm({required this.rows, required this.tops, required this.height});

  /// Строки в порядке от якоря наружу: `rows[0]` примыкает к якорю.
  final List<GalleryRow> rows;

  /// Смещение начала каждой строки от якоря: `tops[0] == 0`, дальше растёт наружу.
  /// По нему позиция прокрутки переводится в строку (и наоборот) без обхода всего списка.
  final List<double> tops;

  /// Полная высота плеча.
  final double height;

  /// Пустое плечо — окно из одного якоря и без кадров по эту сторону.
  static const GalleryArm empty = GalleryArm(rows: [], tops: [0], height: 0);

  /// Индекс строки, накрывающей расстояние [distance] от якоря.
  ///
  /// Бинарный поиск: строк в окне бывают сотни, а зовётся это на каждом событии прокрутки.
  /// Перелёт (расстояние больше плеча — бывает, пока грузится страница) даёт последнюю строку,
  /// а не ошибку: показать крайнюю строку честнее, чем ничего.
  int rowAt(double distance) {
    if (rows.isEmpty) return -1;
    if (distance <= 0) return 0;
    var lo = 0;
    var hi = rows.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (tops[mid] <= distance) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Собрать плечо из строк в визуальном порядке.
  ///
  /// [up] — плечо выше якоря: там строки визуального порядка идут от якоря наружу в обратном
  /// порядке (ближайшая к якорю — последняя нарисованная). Именно поэтому у плеч один и тот же
  /// вид «от якоря наружу», а слоты вёрстки берут строки как есть.
  factory GalleryArm.of(List<GalleryRow> visualRows, {required bool up}) {
    if (visualRows.isEmpty) return GalleryArm.empty;
    final rows = up ? visualRows.reversed.toList() : visualRows;
    final tops = <double>[0];
    for (var i = 1; i < rows.length; i++) {
      tops.add(tops[i - 1] + rows[i - 1].height);
    }
    return GalleryArm(rows: rows, tops: tops, height: tops.last + rows.last.height);
  }
}

/// Подпись месяца для заголовка строки: «Май 2021».
///
/// Считается по времени съёмки самого кадра, а не по разбивке с сервера: заголовок обязан
/// совпадать с тем кадром, над которым он стоит, даже если разбивка отстала (или её вовсе нет,
/// пока локальный индекс не наполнен).
String _headerLabel(MediaItem item, int tzOffsetMin) {
  final at = item.capturedAt;
  final dt = at == null ? null : DateTime.tryParse(at);
  if (dt == null) return 'Без даты';
  return monthLabel(GalleryGrid.monthKey(dt, tzOffsetMin));
}
