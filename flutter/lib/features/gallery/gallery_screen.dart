import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../media/media_viewer.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/widgets.dart';
import 'data/gallery_sync.dart';
import 'gallery_controller.dart';
import 'gallery_rows.dart';
import 'gallery_tile.dart';
import 'month_scrubber.dart';

/// Ключ слота, от которого отсчитывается прокрутка сетки.
///
/// `center` в `CustomScrollView` — это и есть весь смысл вёрстки галереи: окно растёт в две
/// стороны от якоря, и слот ниже якоря служит нулевой точкой. Поэтому страница, добавленная
/// вверх, ложится в отрицательные смещения и ничего не сдвигает на экране — то, что человек
/// читает, остаётся на месте. Ключ обязан быть на самом слоте из `slivers` (обёртка с
/// отступами — тоже слот), иначе `center` его не найдёт и прокрутка встанет на первом слоте.
const _anchorKey = ValueKey('gallery-anchor');

/// Экран «Медиа»: сетка кадров зоны «Фото» с таймлайном месяцев справа.
///
/// Раздел устроен как галерея, а не как список: у ленты нет ни начала, ни конца, которые можно
/// было бы посчитать заранее, поэтому окно кадров живёт вокруг якоря (`GalleryController`),
/// а навигация идёт по времени — шкалой месяцев. Подробности модели — в доке контроллера,
/// подробности раскладки шкалы — в доке `GalleryCalendar`.
class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

/// Состояние экрана: контроллер галереи и его подключение к провайдерам.
class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  /// Контроллер живёт ровно столько, сколько экран: вкладки приложения не пересоздаются
  /// (`IndexedStack` в шелле), поэтому окно и позиция прокрутки переживают переходы по вкладкам.
  GalleryController? _c;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  /// Поднять контроллер: база индекса, синхронизация, очередь миниатюр, первое окно.
  ///
  /// Миниатюры подключаются отдельно и не блокируют окно: каталог данных читается с диска,
  /// и ждать его, показывая спиннер, незачем — плитки до его открытия рисуют заглушки.
  Future<void> _prepare() async {
    try {
      final sync = await ref.read(galleryProvider.future);
      if (!mounted) return;
      final controller = GalleryController(sync: sync, apiOf: () => ref.read(appStateProvider).api);
      controller.scroll.addListener(controller.onScroll);
      setState(() => _c = controller);
      unawaited(ref.read(thumbCacheProvider.future).then((thumbs) {
        if (mounted) controller.attachThumbs(thumbs);
      }));
      await controller.open();
    } catch (e) {
      // Без индекса раздел показать нечего, поэтому о причине говорим прямо: спиннер навсегда
      // выглядит как зависшее приложение, а не как неподнявшаяся база.
      if (mounted) snack(context, e.toString());
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      backgroundColor: C.canvas,
      appBar: AppBar(
        // Подпись месяца в шапке — тот, что у верхнего видимого кадра: у ленты нет заголовка
        // «Медиа вообще», и во время прокрутки нужно понимать, в каком году ты находишься.
        title: c == null
            ? const Text('Медиа', style: TextStyle(color: C.fg, fontSize: 17))
            : ValueListenableBuilder<String>(
                valueListenable: c.barTitle,
                builder: (_, title, _) => Text(title, style: const TextStyle(color: C.fg, fontSize: 17)),
              ),
        bottom: c == null ? null : _syncBar(c),
      ),
      body: c == null ? const Center(child: CircularProgressIndicator()) : _body(c),
    );
  }

  /// Полоса наполнения локального индекса.
  ///
  /// Показывается только на полном проходе (первый запуск, пересборка после сброса журнала):
  /// раздел в это время уже работает, но шкала знает ещё не все годы съёмки, и человеку стоит
  /// понимать, почему по ней нельзя прыгнуть далеко в прошлое.
  PreferredSizeWidget _syncBar(GalleryController c) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(3),
      child: ValueListenableBuilder<GallerySyncProgress?>(
        valueListenable: c.sync.progress,
        builder: (_, p, _) => p == null || !p.running
            ? const SizedBox(height: 3)
            : LinearProgressIndicator(
                value: p.fraction,
                backgroundColor: C.surface3,
                color: C.accent,
                minHeight: 3,
              ),
      ),
    );
  }

  /// Тело раздела: сетка, приглушение на время работы со шкалой и сама шкала.
  Widget _body(GalleryController c) {
    // `fit: expand` — чтобы сетка занимала весь раздел: `LayoutBuilder` внутри `Stack` при
    // свободных ограничениях иначе подстраивался бы под содержимое.
    return Stack(fit: StackFit.expand, children: [
      LayoutBuilder(builder: (context, box) {
        // Ширина сетки — экран минус шкала: клетки не должны уходить под ползунок, а сторона
        // клетки считается именно от этой ширины (иначе последний столбец обрезался бы).
        c.setLayout(math.max(0.0, box.maxWidth - MonthScrubber.width));
        if (c.isEmpty) return _stub(c);
        return _grid(c);
      }),
      // Приглушение: пока ползунок в пальце, сетка показывает прежнее место и не должна
      // выглядеть как «то, куда едешь». Оно же перехватывает касания (случайный тап по старому
      // окну не должен открывать кадр) и закрывает миниатюры — их в это время никто не просит.
      ValueListenableBuilder<bool>(
        valueListenable: c.scrubbing,
        builder: (_, scrubbing, _) => scrubbing
            ? const AbsorbPointer(child: ColoredBox(color: Color(0x990D0F14)))
            : const SizedBox.shrink(),
      ),
      if (c.calendar != null && !(c.calendar!.isEmpty))
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: MonthScrubber(
            calendar: c.calendar!,
            position: c.rail,
            onScrub: c.setScrubbing,
            onJumpToMonth: (month) => unawaited(c.jumpToMonth(month)),
            onJumpToTail: () => unawaited(c.jumpToTail()),
          ),
        ),
      if (c.jumping) const Center(child: CircularProgressIndicator()),
    ]);
  }

  /// Сетка: два плеча окна вокруг якоря.
  ///
  /// Слоты обоих плеч отсчитываются от якоря наружу (см. `GalleryArm`), поэтому вёрстка просто
  /// перечисляет строки — ни о пересчёте позиции прокрутки, ни о компенсации добавленных сверху
  /// страниц ей знать не нужно.
  Widget _grid(GalleryController c) {
    final side = GalleryGrid.gap + MonthScrubber.width;
    return CustomScrollView(
      controller: c.scroll,
      center: _anchorKey,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(GalleryGrid.gap, GalleryGrid.gap, side, 0),
          sliver: _arm(c, c.newerArm),
        ),
        SliverPadding(
          key: _anchorKey,
          padding: EdgeInsets.fromLTRB(GalleryGrid.gap, GalleryGrid.gap, side, GalleryGrid.gap),
          sliver: _arm(c, c.olderArm),
        ),
      ],
    );
  }

  /// Слоты одного плеча.
  SliverList _arm(GalleryController c, GalleryArm arm) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, i) => _row(c, arm.rows[i]),
        childCount: arm.rows.length,
      ),
    );
  }

  /// Строка сетки: заголовок месяца или ряд из кадров.
  ///
  /// Высота строки берётся у неё самой, а не считается здесь: по этим высотам контроллер
  /// переводит позицию прокрутки в видимый кадр, и разойтись они не должны.
  Widget _row(GalleryController c, GalleryRow row) {
    if (row.isNote) return _noteRow(c, row);
    if (row.isHeader) {
      return SizedBox(
        height: row.height,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            row.header!,
            style: const TextStyle(color: C.fg2, fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      );
    }
    final side = c.cellSide;
    return SizedBox(
      height: row.height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < row.items.length; i++) ...[
            if (i > 0) const SizedBox(width: GalleryGrid.gap),
            SizedBox(
              width: side,
              height: side,
              child: GalleryTile(
                item: row.items[i],
                side: side,
                thumbs: c.thumbs,
                scrubbing: c.scrubbing,
                onTap: () => _openViewer(c, c.indexOf(row.items[i].entryId)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Строка состояния внизу окна: загрузка страницы или причина сбоя с кнопкой повтора.
  ///
  /// Она нужна именно строкой, а не всплывающей подсказкой: сбой догрузки — это не событие,
  /// а состояние, и человек должен видеть и причину, и способ её пережить.
  Widget _noteRow(GalleryController c, GalleryRow row) {
    final failed = c.error != null;
    return SizedBox(
      height: row.height,
      child: Center(
        child: failed
            ? TextButton.icon(
                onPressed: c.retry,
                icon: const Icon(Icons.refresh, size: 16, color: C.fg2),
                label: Text(
                  'Не загрузилось — повторить',
                  style: const TextStyle(color: C.fg2, fontSize: 13),
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: C.fg3),
                  ),
                  const SizedBox(width: 8),
                  Text(row.note!, style: const TextStyle(color: C.fg3, fontSize: 13)),
                ],
              ),
      ),
    );
  }

  /// Открыть просмотрщик на кадре по его номеру в окне.
  ///
  /// Просмотрщик живёт номерами окна: он листает по ним и просит догрузку (`ensureRange`),
  /// а `total` отдаётся общим счётчиком — иначе после подгрузки страницы или удаления кадра
  /// он остался бы с прежним числом страниц.
  void _openViewer(GalleryController c, int index) {
    if (index < 0) return;
    // Просмотрщик листает по номерам окна, поэтому на время его работы окно не должно расти
    // вверх: новые кадры сдвинули бы все номера, и вместо открытого снимка показался бы соседний.
    c.openViewer();
    Navigator.push(context, MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => MediaViewer(
        api: ref.read(appStateProvider).api,
        total: c.total,
        initialIndex: index,
        getItem: c.itemAt,
        ensure: c.ensureRange,
        onDelete: c.deleteAt,
        revision: c.revision,
      ),
    )).then((_) => c.closeViewer());
  }

  /// Что показывать, когда в окне нет кадров: спиннер, ошибку или «здесь пусто».
  ///
  /// Пусто при непустом индексе не бывает: окно всегда начинается с начала ленты, а если лента
  /// пуста, то и заголовков у неё нет. Ошибку показываем текстом, а не подсказкой: сетке без
  /// кадров показать больше нечего, и подсказка, уехавшая через пару секунд, — единственное,
  /// что человек успел бы увидеть.
  Widget _stub(GalleryController c) {
    if (c.loading || c.jumping) return const Center(child: CircularProgressIndicator());
    if (c.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(c.error!, textAlign: TextAlign.center, style: const TextStyle(color: C.fg3)),
        ),
      );
    }
    return const Center(
      child: Text('Здесь появятся фото и видео из раздела «Фото»', style: TextStyle(color: C.fg3)),
    );
  }
}
