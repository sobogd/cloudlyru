import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../theme.dart';

/// Вертикальная шкала месяцев у правого края ленты: перетаскивание прыгает к месяцу.
///
/// Почему не обычный ползунок прокрутки: у ленты десятки тысяч кадров и годы съёмки, и «тянуть
/// ползунок, пока не найдёшь нужное» по ней бесполезно — нужен переход к периоду. Шкала это и
/// делает: положение пальца переводится в индекс кадра, а месяц под пальцем показывается
/// подписью, так что видно, куда едешь, ещё до того, как отпустил.
///
/// Ширина намеренно узкая, а зона касания шире видимой полосы: тянут её пальцем по краю
/// экрана, и промахнуться мимо тонкой линии было бы обычным делом.
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

  /// Положение прокрутки долей от 0 до 1 — по нему рисуется бегунок.
  final ValueListenable<double> position;

  /// Подпись месяца для кадра с этим индексом (лента знает её по своим диапазонам).
  final String Function(int index) labelAt;

  /// Прыжок к кадру: лента делает `jumpTo`.
  final void Function(int index) onJump;

  /// Перетаскивание закончилось — лента подгружает окно на новом месте.
  final VoidCallback onJumpEnd;

  @override
  State<MonthTimeline> createState() => _MonthTimelineState();
}

/// Состояние шкалы: идёт перетаскивание и подпись месяца под пальцем.
class _MonthTimelineState extends State<MonthTimeline> {
  /// Палец на шкале: пока true, показывается подпись месяца.
  bool _dragging = false;

  /// Месяц, к которому ведёт текущее положение пальца.
  String _label = '';

  /// Доля высоты, где сейчас палец, — по ней ставится подпись (не по бегунку: тот двигается
  /// уже после прыжка ленты, и подпись отставала бы от пальца).
  double _dragFrac = 0;

  /// Ширина зоны касания и толщина видимой полосы.
  static const double _touchWidth = 34;
  static const double _trackWidth = 3;

  /// Перевести положение пальца в индекс кадра и попросить ленту прыгнуть.
  ///
  /// Индекс считается по доле высоты: шкала линейна по числу кадров, а не по месяцам, — тогда
  /// палец в середине шкалы оказывается в середине библиотеки, что и ожидается при перетаскивании.
  void _handleDrag(double localY, double height) {
    if (height <= 0 || widget.total <= 0) return;
    final fraction = (localY / height).clamp(0.0, 1.0);
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
  /// Полоса с рисками месяцев, бегунок текущего положения и подпись под пальцем.
  Widget build(BuildContext context) {
    return SizedBox(
      width: _touchWidth,
      child: LayoutBuilder(builder: (context, c) {
        final height = c.maxHeight;
        return GestureDetector(
          // Прозрачная зона на всю высоту: тянуть можно в любом месте шкалы, а не только
          // по видимой полосе.
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (d) => _handleDrag(d.localPosition.dy, height),
          onVerticalDragUpdate: (d) => _handleDrag(d.localPosition.dy, height),
          onVerticalDragEnd: (_) => _endDrag(),
          onVerticalDragCancel: _endDrag,
          onTapDown: (d) => _handleDrag(d.localPosition.dy, height),
          onTapUp: (_) => _endDrag(),
          child: Stack(
            // Подпись выходит за границы виджета — влево, поверх сетки.
            clipBehavior: Clip.none,
            children: [
              // Дорожка и риски месяцев.
              Positioned(
                right: 4,
                top: 8,
                bottom: 8,
                child: CustomPaint(
                  size: Size(_trackWidth, height - 16),
                  painter: _TimelinePainter(
                    // Доли начала месяцев: по ним рисуются риски, чтобы шкала читалась
                    // как таймлайн, а не как безымянная полоса.
                    marks: _monthMarks(),
                  ),
                ),
              ),
              // Бегунок: где лента находится сейчас. Слушает только положение прокрутки,
              // поэтому прокрутка не перерисовывает ни сетку, ни подпись.
              Positioned(
                right: 0,
                top: 8,
                bottom: 8,
                child: ValueListenableBuilder<double>(
                  valueListenable: widget.position,
                  builder: (context, frac, _) => Align(
                    alignment: Alignment(0, frac * 2 - 1),
                    child: Container(
                      width: 11,
                      height: 11,
                      decoration: BoxDecoration(
                        color: C.accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: C.canvas, width: 2),
                      ),
                    ),
                  ),
                ),
              ),
              // Подпись месяца под пальцем.
              if (_dragging)
                Positioned(
                  right: _touchWidth - 2,
                  top: (height * _dragFrac - 16).clamp(0.0, height - 34),
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
  const _TimelinePainter({required this.marks});

  /// Доли начала месяцев от 0 до 1 (сверху вниз).
  final List<double> marks;

  @override
  /// Полоса-дорожка и поперечные риски на границах месяцев.
  void paint(Canvas canvas, Size size) {
    final track = Paint()
      ..color = C.brd
      ..strokeWidth = size.width
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(size.width / 2, 0), Offset(size.width / 2, size.height), track);

    final mark = Paint()
      ..color = C.fg3
      ..strokeWidth = 1.5;
    for (final m in marks) {
      final y = m * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width * 2.2, y), mark);
    }
  }

  @override
  /// Перерисовываем, когда изменились риски: они зависят от разбивки по месяцам.
  bool shouldRepaint(_TimelinePainter old) => !listEquals(old.marks, marks);
}
