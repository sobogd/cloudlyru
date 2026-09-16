import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../theme.dart';

/// Шкала месяцев у правого края ленты: ползунок с подписью месяца и риски периодов.
///
/// Почему не обычный ползунок прокрутки: у ленты десятки тысяч кадров и годы съёмки, и «тянуть
/// ползунок, пока не найдёшь нужное» по ней бесполезно — нужен переход к периоду. Шкала это и
/// делает: положение ползунка переводится в индекс кадра, месяц под ним показывается подписью,
/// так что видно, куда едешь, ещё до того, как отпустил.
///
/// Геометрия здесь ровно одна и та же для пальца, ползунка и рисок — дорожка между
/// [_trackInset] сверху и снизу. Это принципиально: раньше палец считался по всей высоте
/// виджета, а ползунок рисовался по доле прокрутки (`offset / maxScrollExtent`), и эти две
/// величины не совпадали — ползунок уезжал от пальца, а лента вставала не туда. Теперь доля
/// одна: положение пальца по дорожке → индекс кадра → лента, и ползунок ставится ровно в ту
/// же точку дорожки.
class MonthTimeline extends StatefulWidget {
  const MonthTimeline({
    super.key,
    required this.months,
    required this.total,
    required this.position,
    required this.labelAt,
    required this.onJump,
    required this.onJumpEnd,
  });

  /// Разбивка по месяцам в порядке ленты — из неё рисуются риски периодов.
  final List<MediaMonthBucket> months;

  /// Сколько всего кадров: по нему положение пальца переводится в индекс кадра.
  final int total;

  /// Доля ленты, на которой стоит ползунок (0 — начало, 1 — конец). Лента считает её как
  /// «первый видимый кадр / всего кадров» — та же величина, что получается при перетаскивании,
  /// поэтому ползунок оказывается под пальцем.
  final ValueListenable<double> position;

  /// Подпись месяца для кадра с этим индексом (лента знает её по своим диапазонам).
  final String Function(int index) labelAt;

  /// Прыжок к кадру: лента делает `jumpTo`.
  final void Function(int index) onJump;

  /// Перетаскивание закончилось — лента подгружает окно на новом месте.
  final VoidCallback onJumpEnd;

  /// Ширина шкалы: на неё же отступает сетка справа, чтобы плитки не уходили под ползунок.
  static const double width = 44;

  @override
  State<MonthTimeline> createState() => _MonthTimelineState();
}

/// Состояние шкалы: идёт перетаскивание и подпись месяца под пальцем.
class _MonthTimelineState extends State<MonthTimeline> {
  /// Палец на шкале: пока true, показывается подпись месяца.
  bool _dragging = false;

  /// Месяц, к которому ведёт текущее положение пальца.
  String _label = '';

  /// Доля, на которую указывает палец, — по ней ставится подпись (не по ползунку: тот
  /// двигается после прыжка ленты и отставал бы от пальца).
  double _dragFrac = 0;

  /// Толщина дорожки, длина риски месяца и диаметр ползунка.
  ///
  /// Ползунок крупный намеренно: это орган управления, а не индикатор — за мелкий кружок
  /// палец не зацепится.
  static const double _trackWidth = 5;
  static const double _markWidth = 18;
  static const double _thumbSize = 26;

  /// Отступ дорожки от краёв виджета: на столько шкала короче экрана.
  static const double _trackInset = 16;

  /// Перевести положение пальца в индекс кадра и попросить ленту прыгнуть.
  ///
  /// Доля считается по дорожке (между её началом и концом), а не по высоте виджета: палец на
  /// верхнем конце дорожки — это начало ленты, на нижнем — конец.
  void _handleDrag(double localY, double trackTop, double trackLength) {
    if (trackLength <= 0 || widget.total <= 0) return;
    final fraction = ((localY - trackTop) / trackLength).clamp(0.0, 1.0);
    final index = (fraction * (widget.total - 1)).round().clamp(0, widget.total - 1);
    setState(() {
      _dragging = true;
      _dragFrac = fraction;
      _label = widget.labelAt(index);
    });
    widget.onJump(index);
  }

  /// Отпустить шкалу: подпись убирается, лента догружает окно на новом месте.
  void _endDrag() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onJumpEnd();
  }

  @override
  /// Дорожка с рисками, ползунок и подпись месяца под пальцем.
  Widget build(BuildContext context) {
    return SizedBox(
      width: MonthTimeline.width,
      child: LayoutBuilder(builder: (context, c) {
        final trackTop = _trackInset;
        final trackLength = c.maxHeight - _trackInset * 2;
        if (trackLength <= 0) return const SizedBox.shrink();
        return GestureDetector(
          // Прозрачная зона на всю высоту, но шириной только в саму шкалу: сетка справа
          // имеет такой же отступ, поэтому обычный свайп по списку сюда не попадает.
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (d) => _handleDrag(d.localPosition.dy, trackTop, trackLength),
          onVerticalDragUpdate: (d) => _handleDrag(d.localPosition.dy, trackTop, trackLength),
          onVerticalDragEnd: (_) => _endDrag(),
          onVerticalDragCancel: _endDrag,
          onTapDown: (d) => _handleDrag(d.localPosition.dy, trackTop, trackLength),
          onTapUp: (_) => _endDrag(),
          child: Stack(
            // Подпись выходит за границы виджета — влево, поверх сетки.
            clipBehavior: Clip.none,
            children: [
              Positioned(
                right: (MonthTimeline.width - _markWidth) / 2,
                top: trackTop,
                child: CustomPaint(
                  size: Size(_markWidth, trackLength),
                  painter: _TimelinePainter(marks: _monthMarks(), trackWidth: _trackWidth),
                ),
              ),
              // Ползунок: центр ровно в той точке дорожки, которой соответствует текущая
              // позиция ленты.
              ValueListenableBuilder<double>(
                valueListenable: widget.position,
                builder: (context, frac, _) => Positioned(
                  right: (MonthTimeline.width - _thumbSize) / 2,
                  top: trackTop + frac.clamp(0.0, 1.0) * trackLength - _thumbSize / 2,
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
                ),
              ),
              // Подпись месяца под пальцем.
              if (_dragging)
                Positioned(
                  right: MonthTimeline.width - 4,
                  top: (trackTop + _dragFrac * trackLength - 16).clamp(0.0, c.maxHeight - 34),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: C.surface3,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _label,
                      style: const TextStyle(color: C.fg, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }

  /// Доли начала месяцев: риска на каждую границу периода.
  List<double> _monthMarks() {
    final total = widget.total;
    if (total <= 0) return const [];
    var start = 0;
    final marks = <double>[];
    for (final b in widget.months) {
      if (b.count <= 0) continue;
      // Первую риску пропускаем: это самый верх шкалы, там и так её начало.
      if (start > 0) marks.add(start / total);
      start += b.count;
    }
    return marks;
  }
}

/// Рисует дорожку шкалы и риски месяцев.
class _TimelinePainter extends CustomPainter {
  const _TimelinePainter({required this.marks, required this.trackWidth});

  /// Доли начала месяцев от 0 до 1 (сверху вниз).
  final List<double> marks;

  /// Толщина дорожки.
  final double trackWidth;

  @override
  /// Дорожка по центру и поперечные риски на границах месяцев.
  void paint(Canvas canvas, Size size) {
    final center = size.width / 2;
    final track = Paint()
      ..color = C.brd
      ..strokeWidth = trackWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(center, 0), Offset(center, size.height), track);

    final mark = Paint()
      ..color = C.fg3
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (final m in marks) {
      final y = m * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), mark);
    }
  }

  @override
  /// Перерисовываем, когда изменились риски: они зависят от разбивки по месяцам.
  bool shouldRepaint(_TimelinePainter old) =>
      !listEquals(old.marks, marks) || old.trackWidth != trackWidth;
}
