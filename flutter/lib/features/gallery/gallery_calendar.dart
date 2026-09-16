import '../../api/models.dart';
import '../../util/format.dart';

/// Где стоит ползунок шкалы: доля дорожки либо зона кадров без даты.
///
/// Отсчёт — СВЕРХУ ВНИЗ, как у самой шкалы: 0 — самый верх (самое свежее), 1 — самый низ
/// (самое старое). Так же устроена и сетка: сверху свежие кадры, ниже старые, поэтому
/// прокрутка вниз двигает ползунок вниз, а не наоборот.
///
/// Доля — это время, а не количество кадров: шкала календарно равномерная (см. [GalleryCalendar]),
/// поэтому «середина дорожки» означает середину отрезка съёмки.
class GalleryRailPosition {
  /// Доля дорожки от 0 (верх, самое свежее) до 1 (низ, самое старое).
  final double fraction;

  /// Ползунок стоит в зоне кадров без даты — она ниже всей дорожки, ниже самого старого месяца:
  /// в ленте такие кадры идут последними.
  final bool tail;

  const GalleryRailPosition(this.fraction, {this.tail = false});

  /// Верх дорожки — положение до первой раскладки.
  static const GalleryRailPosition start = GalleryRailPosition(0);
}

/// Таймлайн галереи: месяцы съёмки, разложенные по времени равномерно.
///
/// ## Почему равномерно по календарю, а не по числу кадров
///
/// Шкала отвечает на вопрос «где я во времени», и на него отвечает календарь: месяц с тремя
/// кадрами и месяц с тремя тысячами — это одинаковый отрезок жизни. Раскладка «по количеству»
/// давала обратное: отпуск занимал треть шкалы, а полгода редких снимков — волосок, и найти
/// по ней нужный год было нельзя.
///
/// Пустые месяцы из раскладки не выбрасываются: иначе шкала перестала бы быть календарём.
/// Прыжок в пустой месяц ведёт к ближайшим кадрам — просто потому, что кадров в нём нет.
///
/// ## Порядок на дорожке
///
/// Сверху — самое свежее, снизу — самое старое: так же, как в сетке, и так же, как в ленте
/// (`capturedAt DESC`). Поэтому «доля дорожки» в наружном виде считается сверху вниз
/// ([GalleryRailPosition]), а внутренние доли этого класса — от старого края ([fractionOf]):
/// перевод между ними делается один раз, на границе шкалы.
///
/// ## Как считается
///
/// Всё внутри — «настенные» моменты пояса зрителя (`DateTime.utc`, несущий местное время):
/// именно в этом поясе сервер считает бакеты месяцев (`capturedAt + tz`, `/media/months?tz=`),
/// поэтому границы месяцев у шкалы и у ленты совпадают. Наружу отдаются UTC-моменты
/// (`monthBoundaryUtc`) — их понимает лента.
///
/// ## Что откуда берётся
///
/// Месяцы приходят из разбивки (она же лежит в локальном индексе): только те, в которых
/// что-то есть. Отрезок шкалы — от начала самого старого месяца до начала месяца после самого
/// свежего: показывать «сегодня» пустым хвостом смысла нет, а вот знать, что съёмка кончилась
/// в марте, полезно.
class GalleryCalendar {
  GalleryCalendar({required List<MediaMonthBucket> months, required this.tzOffsetMin})
      : months = _sorted(months),
        undatedCount = _undated(months),
        _counts = {for (final m in _sorted(months)) m.month!: m.count};

  /// Месяцы съёмки по возрастанию (от старых к свежим), без бакета «без даты».
  final List<MediaMonthBucket> months;

  /// Сколько кадров без даты съёмки: они живут в отдельной зоне под шкалой.
  final int undatedCount;

  /// Сдвиг пояса зрителя в минутах на восток — в нём считаются месяцы шкалы.
  final int tzOffsetMin;

  /// Число кадров по месяцам — по нему подсказка у ползунка показывает, сколько там снимков.
  final Map<String, int> _counts;

  /// Пустая шкала: кадров нет вовсе (или разбивка ещё не приехала).
  bool get isEmpty => months.isEmpty;

  /// Начало отрезка шкалы — первый день самого старого месяца (настенное время).
  DateTime get start => _monthStart(months.first.month!);

  /// Конец отрезка — первый день месяца, следующего за самым свежим (настенное время).
  ///
  /// Именно начало следующего месяца, а не конец текущего: так доля 1.0 означает «свежее
  /// некуда» без возни с длиной последнего месяца.
  DateTime get end => _monthStart(nextMonth(months.last.month!));

  /// Доля шкалы, на которой находится момент съёмки [at].
  double fractionOf(DateTime at) =>
      _fractionWall(at.toUtc().add(Duration(minutes: tzOffsetMin)));

  /// Месяц, на который указывает доля [fraction] (доля прижимается к отрезку).
  ///
  /// Доля переводится во время, а время — в месяц: это обратное преобразование к [fractionOf],
  /// поэтому ползунок, отпущенный в точке X, встаёт ровно в X, а не рядом.
  String monthAt(double fraction) {
    final span = end.difference(start).inMilliseconds;
    final wall = start.add(Duration(milliseconds: (span * fraction.clamp(0.0, 1.0)).round()));
    final key = '${wall.year}-${wall.month.toString().padLeft(2, '0')}';
    // За границы списка месяцев доля не выводит (fractionOf и monthAt согласованы), но кадр
    // может стоять в пустом месяце — тогда ближайший сосед из списка и есть ответ.
    if (key.compareTo(months.first.month!) < 0) return months.first.month!;
    if (key.compareTo(months.last.month!) > 0) return months.last.month!;
    return key;
  }

  /// Момент начала месяца [month] в UTC — граница для прыжка по шкале.
  ///
  /// Прыжок к месяцу делается лентой «старше этой границы» (см. `GalleryController.jumpToMonth`):
  /// строго старше начала следующего месяца — это и есть запрошенный месяц и всё, что до него,
  /// а первый кадр такой страницы — самый свежий кадр месяца. Так прыжок не требует знать id
  /// первого кадра месяца, которого у клиента нет.
  DateTime monthBoundaryUtc(String month) =>
      _monthStart(month).subtract(Duration(minutes: tzOffsetMin));

  /// Ключ месяца, следующего за [month].
  String nextMonth(String month) {
    final y = int.tryParse(month.substring(0, 4)) ?? 1970;
    final m = int.tryParse(month.substring(5, 7)) ?? 1;
    return m == 12 ? '${y + 1}-01' : '$y-${(m + 1).toString().padLeft(2, '0')}';
  }

  /// Сколько кадров в месяце [month]; `0` — месяц пустой.
  int countOf(String month) => _counts[month] ?? 0;

  /// Подпись месяца для подсказки у ползунка: «Май 2021 · 128».
  ///
  /// Число кадров — не украшение: по пустому месяцу видно, что прыжок приведёт «куда-то рядом»,
  /// и это лучше, чем молча оказаться в соседнем месяце.
  String labelOf(String month) {
    final n = countOf(month);
    return n > 0 ? '${monthLabel(month)} · $n' : '${monthLabel(month)} · пусто';
  }

  /// Риски шкалы: начало каждого месяца и его доля — по ним рисуется дорожка.
  ///
  /// Пустые месяцы здесь есть, и это осознанно: дорожка — календарь, а не список месяцев
  /// с кадрами. Какие из них непустые, знает [countOf].
  List<({String month, double from, double to, bool january})> ticks() {
    if (isEmpty) return const [];
    final out = <({String month, double from, double to, bool january})>[];
    final last = months.last.month!;
    var key = months.first.month!;
    while (true) {
      out.add((
        month: key,
        from: _fractionWall(_monthStart(key)),
        to: _fractionWall(_monthStart(nextMonth(key))),
        // Январь — начало года: он и подписывается на дорожке, и рисуется заметнее.
        january: key.endsWith('-01'),
      ));
      if (key == last) break;
      key = nextMonth(key);
    }
    return out;
  }

  /// Доля шкалы для «настенного» момента.
  double _fractionWall(DateTime wall) {
    final span = end.difference(start).inMilliseconds;
    if (span <= 0) return 0;
    return (wall.difference(start).inMilliseconds / span).clamp(0.0, 1.0);
  }

  /// Первое число месяца из ключа «ГГГГ-ММ» — настенное время без сдвига пояса.
  DateTime _monthStart(String month) {
    final y = int.tryParse(month.substring(0, 4)) ?? 1970;
    final m = int.tryParse(month.substring(5, 7)) ?? 1;
    return DateTime.utc(y, m);
  }

  /// Месяцы съёмки по возрастанию, без пустых бакетов.
  static List<MediaMonthBucket> _sorted(List<MediaMonthBucket> months) =>
      months.where((m) => m.month != null && m.count > 0).toList()
        ..sort((a, b) => a.month!.compareTo(b.month!));

  /// Сколько кадров в бакете «без даты» (сервер отдаёт его строкой с `month = null`).
  static int _undated(List<MediaMonthBucket> months) {
    for (final m in months) {
      if (m.month == null) return m.count;
    }
    return 0;
  }
}
