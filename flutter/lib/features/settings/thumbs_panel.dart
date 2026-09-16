import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../media/thumb_cache.dart';
import '../../media/thumb_store.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import 'queue_format.dart';

/// Панель миниатюр галереи: сколько их на телефоне, прогрев всей библиотеки и очистка.
///
/// Зачем панель вообще: миниатюры лежат в данных приложения (см. `ThumbStore`), а не в
/// кэш-каталоге, поэтому система их не вычищает — и освободить место можно только отсюда.
/// Заодно отсюда видно, что прогрев вообще идёт: он занимает часы и работает в фоне.
///
/// Панель ничего не качает сама: очередь и прогресс живут в [ThumbCache], она лишь показывает
/// их состояние и дёргает два метода. Подписка на его `ValueNotifier` вместо таймера — потому
/// что здесь прогресс меняется в процессе, а не по расписанию.
class ThumbsPanel extends ConsumerStatefulWidget {
  const ThumbsPanel({super.key});

  @override
  ConsumerState<ThumbsPanel> createState() => _ThumbsPanelState();
}

/// Состояние панели: размер хранилища, признак занятости и подписки на очередь.
class _ThumbsPanelState extends ConsumerState<ThumbsPanel> {
  /// Сколько миниатюр лежит на диске и сколько занимает. `null` — ещё не считали.
  ThumbStats? _stats;

  /// Считаем размер прямо сейчас (обход дерева): защита от второго запуска и от мигания кнопки.
  bool _busy = false;

  /// Кэш, на чьи уведомления подписана панель. Хранится, чтобы снять подписку в [dispose].
  ThumbCache? _cache;

  @override
  /// Первый подсчёт размера и подписка на очередь.
  ///
  /// Провайдер асинхронный (хранилище открывается с диска), поэтому подписка ставится в
  /// `listenManual` — она переживает пересоздание провайдера и снимается в [dispose].
  void initState() {
    super.initState();
    ref.listenManual(thumbCacheProvider, (_, next) {
      next.whenData(_attach);
    }, fireImmediately: true);
  }

  @override
  /// Снимаем подписки на уведомления очереди.
  void dispose() {
    _detach();
    super.dispose();
  }

  /// Подписаться на очередь и прогрев и сразу посчитать размер хранилища.
  void _attach(ThumbCache cache) {
    if (identical(_cache, cache)) return;
    _detach();
    _cache = cache;
    cache.queue.addListener(_onChanged);
    cache.warm.addListener(_onChanged);
    unawaited(_recount());
  }

  /// Снять подписки: панель уходит с экрана, уведомления ей больше не нужны.
  void _detach() {
    final cache = _cache;
    if (cache == null) return;
    cache.queue.removeListener(_onChanged);
    cache.warm.removeListener(_onChanged);
    _cache = null;
  }

  /// Перерисоваться на изменение очереди или прогресса.
  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Пересчитать размер хранилища.
  ///
  /// Обход запускается и после прогрева: миниатюры докачиваются в фоне, и цифра на экране
  /// иначе осталась бы от момента открытия панели.
  Future<void> _recount() async {
    final cache = _cache;
    if (cache == null || _busy) return;
    setState(() => _busy = true);
    try {
      final stats = await cache.stats();
      if (mounted) setState(() => _stats = stats);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Скачать миниатюры всей библиотеки и по завершении обновить размер.
  Future<void> _warmAll() async {
    final cache = _cache;
    if (cache == null) return;
    await cache.warmLibrary();
    await _recount();
  }

  /// Стереть все миниатюры: спрашиваем подтверждение, действие необратимое (качать заново).
  Future<void> _clear() async {
    final cache = _cache;
    if (cache == null) return;
    final ok = await confirmDialog(
      context,
      'Очистить миниатюры?',
      'Галерея останется без картинок, пока они не скачаются заново. '
          'Файлы в облаке не затрагиваются.',
      confirmLabel: 'Очистить',
      danger: true,
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await cache.clear();
      final stats = await cache.stats();
      if (mounted) setState(() => _stats = stats);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  /// Размер хранилища, ход прогрева и две кнопки: скачать всё и очистить.
  Widget build(BuildContext context) {
    final cacheAsync = ref.watch(thumbCacheProvider);
    final cache = cacheAsync.value;
    final stats = _stats;
    final queue = cache?.queue.value ?? ThumbQueueStats.idle;
    final warm = cache?.warm.value;
    final warming = warm?.running ?? false;

    // Размер: до первого подсчёта показываем многоточие, а не ноль — ноль читался бы
    // как «миниатюр нет вовсе», хотя они есть и просто ещё не посчитаны.
    final sizeLine = stats == null
        ? 'считаем…'
        : '${groupDigits(stats.files)} шт · ${fmtSize(stats.bytes)}';

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.grid_view_outlined, color: C.fg3),
              const SizedBox(width: 8),
              const Text('Миниатюры галереи',
                  style: TextStyle(color: C.fg, fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              // Размер виден всегда: миниатюры не чистятся системой, и человек должен
              // понимать, сколько места он отдал под них.
              Text(sizeLine, style: const TextStyle(color: C.fg3, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Все миниатюры хранятся на телефоне: галерея листается без сети. '
            'Качаются по одной — при первом показе и в фоне целиком.',
            style: TextStyle(color: C.fg3, fontSize: 12),
          ),
          if (queue.busy) ...[
            const SizedBox(height: 8),
            Text(
              'в очереди ${groupDigits(queue.queued)}, качается ${queue.running}, '
              'готово ${groupDigits(queue.done)}'
              '${queue.failed > 0 ? ', ошибок ${groupDigits(queue.failed)}' : ''}',
              style: const TextStyle(color: C.fg3, fontSize: 12),
            ),
          ],
          if (warm != null) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: warming ? warm.fraction : 1,
              backgroundColor: C.surface3,
              color: C.accent,
              minHeight: 4,
            ),
            const SizedBox(height: 4),
            Text(
              warming
                  ? 'просмотрено ${groupDigits(warm.scanned)} из ${groupDigits(warm.total)}'
                  : 'прогрев закончен: просмотрено ${groupDigits(warm.scanned)} из ${groupDigits(warm.total)}',
              style: const TextStyle(color: C.fg3, fontSize: 12),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              // Во время прогрева кнопка превращается в «Остановить»: иначе запустить
              // второй прогрев нельзя, а понять, как его прервать, — неоткуда.
              FilledButton(
                onPressed: cache == null || _busy
                    ? null
                    : (warming ? cache.stopWarm : () => unawaited(_warmAll())),
                child: Text(warming ? 'Остановить' : 'Скачать все'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: cache == null || _busy ? null : () => unawaited(_clear()),
                child: const Text('Очистить'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
