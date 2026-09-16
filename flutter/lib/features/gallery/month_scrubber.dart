import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme.dart';
import 'gallery_calendar.dart';

/// Шкала таймлайна у правого края галереи: дорожка, риски месяцев, ползунок и подсказка.
///
/// Зачем она вообще: у ленты нет ни начала, ни конца, которые можно было бы промотать, — есть
/// только время. Тянуть ползунок «пока не найдёшь нужное» по годам съёмки бесполезно, поэтому
/// шкала не прокручивает список, а переводит палец во время: под пальцем видно месяц и число
/// кадров, а окно переставляется один раз — когда ползунок отпустили ([onJumpToMonth]).
///
/// Раскладка календарно равномерная ([GalleryCalendar]): каждый месяц занимает одинаковую долю
/// дорожки, пустые месяцы тоже. Геометрия одна на всё — на палец, на риски и на ползунок:
/// раньше палец считался по всей высоте виджета, а ползунок по доле прокрутки, и эти величины
/// расходились — ползунок уезжал от пальца, а список вставал не туда.
class MonthScrubber extends StatefulWidget {
  const MonthScrubber({
    super.key,
    required this.calendar,
    required this.position,
    required this.onScrub,
    required this.onJumpToMonth,
    required this.onJumpToTail,
  });

  /// Таймлайн: месяцы съёмки и их доли на дорожке.
  final GalleryCalendar calendar;

  /// Где стоит ползунок сейчас (по видимому кадру).
  final ValueListenable<GalleryRailPosition> position;

  /// Ползунок взяли в палец (`true`) и отпустили (`false`) — по этому признаку сетка
  /// приглушается, а плитки перестают просить миниатюры.
  final ValueChanged<bool> onScrub;

  /// Ползунок отпущен на месяце [month] — окно пора переставить.
  final ValueChanged<String> onJumpToMonth;

  /// Ползунок отпущен в зоне кадров без даты.
  final VoidCallback onJumpToTail;

  /// Ширина шкалы: на неё же отступает сетка справа, чтобы клетки не уходили под ползунок.
  static const double width = 44;

  /// Отступ дорожки от краёв: на столько шкала короче экрана.
  static const double trackInset = 16;

  /// Высота зоны кадров без даты под дорожкой (она есть, только если такие кадры есть).
  static const double tailZone = 30;

  @override
  State<MonthScrubber> createState() => _MonthScrubberState();
}

/// Состояние шкалы: идёт перетаскивание и что показывать в подсказке.
class _MonthScrubberState extends State<MonthScrubber> {
  /// Толщина дорожки, длина риски месяца, длина риски января и диаметр ползунка.
  ///
  /// Ползунок крупный намеренно: это орган управления, а не индикатор, и за мелкий кружок
  /// палец не зацепится.
  static const double _trackWidth = 5;
  static const double _markWidth = 7;
  static const double _markWidthYear = 18;
  static const double _thumbSize = 26;

  /// Палец на шкале: подсказка видна, а ползунок стоит под пальцем, а не там, где окно.
  bool _dragging = false;

  /// Доля, на которую указывает палец (для ползунка и подсказки).
  double _dragFraction = 0;

  /// Палец в зоне кадров без даты.
  bool _dragTail = false;

  /// Геометрия дорожки, посчитанная в раскладке: по ней переводятся координаты пальца.
  double _trackTop = 0;
  double _trackLength = 0;

  /// Высота зоны кадров без даты (0 — таких кадров нет).
  double get _tailHeight => widget.calendar.undatedCount > 0 ? MonthScrubber.tailZone : 0;

  /// Перевести точку пальца в цель и показать её в подсказке.
  ///
  /// Окно здесь не переставляется: пока палец на шкале, видно только «куда едем». Переставит
  /// его [_endDrag] — один раз, когда ползунок отпустят.
  void _handleDrag(double localY) {
    final tailTop = _trackTop + _trackLength;
    final inTail = _tailHeight > 0 && localY >= tailTop;
    final fraction = _trackLength <= 0 ? 0.0 : ((localY - _trackTop) / _trackLength).clamp(0.0, 1.0);
    setState(() {
      _dragging = true;
      _dragTail = inTail;
      _dragFraction = inTail ? 1.0 : fraction;
    });
    widget.onScrub(true);
  }

  /// Ползунок отпущен: подсказка убирается, окно переставляется на выбранную дату.
  void _endDrag() {
    if (!_dragging) return;
    final tail = _dragTail;
    final fraction = _dragFraction;
    setState(() => _dragging = false);
    widget.onScrub(false);
    if (tail) {
      widget.onJumpToTail();
    } else {
      widget.onJumpToMonth(widget.calendar.monthAt(fraction));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: MonthScrubber.width,
      child: LayoutBuilder(builder: (context, c) {
        _trackTop = MonthScrubber.trackInset;
        _trackLength = c.maxHeight - MonthScrubber.trackInset * 2 - _tailHeight;
        if (_trackLength <= 0) return const SizedBox.shrink();
        final ticks = widget.calendar.ticks();
        return GestureDetector(
          // Прозрачная зона на всю высоту, но шириной только в саму шкалу: сетка справа имеет
          // такой же отступ, поэтому обычный свайп по списку сюда не попадает.
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (d) => _handleDrag(d.localPosition.dy),
          onVerticalDragUpdate: (d) => _handleDrag(d.localPosition.dy),
          onVerticalDragEnd: (_) => _endDrag(),
          onVerticalDragCancel: _endDrag,
          onTapDown: (d) => _handleDrag(d.localPosition.dy),
          onTapUp: (_) => _endDrag(),
          child: Stack(
            // Подсказка выходит за границы виджета — влево, поверх сетки.
            clipBehavior: Clip.none,
            children: [
              Positioned(
                right: (MonthScrubber.width - _markWidthYear) / 2,
                top: _trackTop,
                child: CustomPaint(
                  size: Size(_markWidthYear, _trackLength),
                  painter: _RailPainter(
                    ticks: ticks,
                    counts: {for (final t in ticks) t.month: widget.calendar.countOf(t.month)},
                    signature: Object.hash(
                      ticks.length,
                      widget.calendar.undatedCount,
                      ticks.isEmpty ? '' : ticks.first.month,
                      ticks.isEmpty ? '' : ticks.last.month,
                    ),
                    trackWidth: _trackWidth,
                    markWidth: _markWidth,
                    yearWidth: _markWidthYear,
                  ),
                ),
              ),
              if (_tailHeight > 0)
                Positioned(
                  right: (MonthScrubber.width - _markWidthYear) / 2,
                  top: _trackTop + _trackLength,
                  child: _tailHint(),
                ),
              // Ползунок: пока тянут — под пальцем, иначе — там, где стоит видимый кадр.
              ValueListenableBuilder<GalleryRailPosition>(
                valueListenable: widget.position,
                builder: (context, pos, _) {
                  final fraction = _dragging ? _dragFraction : pos.fraction;
                  final inTail = _dragging ? _dragTail : pos.tail;
                  final top = inTail
                      ? _trackTop + _trackLength + _tailHeight / 2
                      : _trackTop + fraction.clamp(0.0, 1.0) * _trackLength;
                  return Positioned(
                    right: (MonthScrubber.width - _thumbSize) / 2,
                    top: top - _thumbSize / 2,
                    child: Container(
                      width: _thumbSize,
                      height: _thumbSize,
                      decoration: BoxDecoration(
                        color: C.accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: C.canvas, width: 2),
                        boxShadow: const [
                          BoxShadow(color: Color(0x66000000), blurRadius: 4, offset: Offset(0, 1)),
                        ],
                      ),
                    ),
                  );
                },
              ),
              if (_dragging) _bubble(c.maxHeight),
            ],
          ),
        );
      }),
    );
  }

  /// Подсказка у ползунка: месяц и число кадров в нём (или «Без даты» для зоны хвоста).
  ///
  /// Число кадров — не украшение: по пустому месяцу видно, что прыжок приведёт «куда-то рядом»,
  /// и это лучше, чем молча оказаться в соседнем месяце.
  Widget _bubble(double maxHeight) {
    final text = _dragTail
        ? 'Без даты'
        : widget.calendar.labelOf(widget.calendar.monthAt(_dragFraction));
    final top = _dragTail
        ? _trackTop + _trackLength + _tailHeight / 2
        : _trackTop + _dragFraction * _trackLength;
    return Positioned(
      right: MonthScrubber.width - 4,
      top: (top - 16).clamp(0.0, maxHeight - 34),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: C.surface3,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          text,
          style: const TextStyle(color: C.fg, fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  /// Зона кадров без даты: короткая дорожка и подпись, что она значит.
  Widget _tailHint() {
    return SizedBox(
      width: _markWidthYear,
      height: _tailHeight,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(width: _markWidthYear, height: 2, color: C.brd2),
          const SizedBox(height: 2),
          const Text('—', style: TextStyle(color: C.fg3, fontSize: 11)),
        ],
      ),
    );
  }
}

/// Рисует дорожку шкалы и риски месяцев.
class _RailPainter extends CustomPainter {
  const _RailPainter({
    required this.ticks,
    required this.counts,
    required this.signature,
    required this.trackWidth,
    required this.markWidth,
    required this.yearWidth,
  });

  /// Месяцы шкалы с их долями (см. `GalleryCalendar.ticks`).
  final List<({String month, double from, double to, bool january})> ticks;

  /// Сколько кадров в каждом месяце: пустые месяцы рисуются приглушённо.
  final Map<String, int> counts;

  /// Отпечаток разбивки: риски перерисовываются, когда он изменился.
  final int signature;

  final double trackWidth;
  final double markWidth;
  final double yearWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.width / 2;
    final track = Paint()
      ..color = C.brd
      ..strokeWidth = trackWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(center, 0), Offset(center, size.height), track);

    final mark = Paint()..strokeCap = StrokeCap.round;
    for (final t in ticks) {
      // Первую риску не рисуем: это самый верх дорожки, там и так её начало.
      if (t.from <= 0) continue;
      // Январь — начало года: он длиннее и ярче, по нему видно, сколько на шкале лет.
      final year = t.january;
      final empty = (counts[t.month] ?? 0) == 0;
      mark
        ..color = empty ? C.brd : C.fg3
        ..strokeWidth = year ? 2.5 : 1.5;
      final w = year ? yearWidth : markWidth;
      final y = t.from * size.height;
      canvas.drawLine(Offset(center - w / 2, y), Offset(center + w / 2, y), mark);
    }
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.signature != signature ||
      old.trackWidth != trackWidth ||
      old.markWidth != markWidth ||
      old.yearWidth != yearWidth;
}
