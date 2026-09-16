import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import 'queue_format.dart';

/// Панель очереди превью: остаток, разбивка по типам, срок, диск сервера и ошибки.
///
/// Состояние очереди живёт на сервере (её разбирают воркеры), поэтому панель просто опрашивает
/// его по таймеру: без опроса прогресс не сдвинулся бы на экране до действий пользователя.
///
/// Панель ничего не знает про экран ошибок: переход отдаётся снаружи через [onErrors] —
/// владелец экрана сам решает, каким маршрутом открыть список.
class QueuePanel extends ConsumerStatefulWidget {
  /// Что делать по нажатию на «Ошибки: N». `null` — кнопка выключена (список открывать некуда).
  final VoidCallback? onErrors;
  const QueuePanel({super.key, this.onErrors});
  @override
  ConsumerState<QueuePanel> createState() => _QueuePanelState();
}

/// Состояние панели: снимок очереди, ошибка и признак идущей операции.
class _QueuePanelState extends ConsumerState<QueuePanel> {
  QueueStatus? _q;
  String? _error;
  /// Идёт операция над очередью (пересчёт или очистка): блокирует кнопки, чтобы не запустить
  /// вторую такую же.
  bool _busy = false;
  /// Опрос состояния очереди.
  Timer? _timer;

  @override
  /// Первый снимок очереди и запуск опроса.
  void initState() {
    super.initState();
    _load();
    // Раз в 5 секунд: очередь разбирается в фоне и движется без нас, а чаще опрашивать
    // незачем — прогресс превью идёт минутами.
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  /// Уходим с экрана — опрос очереди снимаем.
  void dispose() {
    // Таймер надо снять: иначе он продолжил бы ходить на сервер после ухода с экрана.
    _timer?.cancel();
    super.dispose();
  }

  /// Читает состояние очереди.
  ///
  /// Ошибку показываем только пока данных нет (`_q == null`): разовый сбой опроса не должен
  /// затирать уже показанную картину — очередь от этого не изменилась.
  Future<void> _load() async {
    try {
      final q = await ref.read(appStateProvider).api.queueStatus();
      if (mounted) {
        setState(() {
          _q = q;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && _q == null) setState(() => _error = e.toString());
    }
  }

  /// Ставит очередь на паузу или снимает её.
  ///
  /// Пауза серверная: задачи остаются в очереди, но воркеры их не берут — так останавливают
  /// разбор, не теряя уже поставленное. Побочно: перечитка состояния, чтобы кнопка сразу
  /// показала новое положение.
  Future<void> _togglePause() async {
    final q = _q;
    if (q == null) return;
    try {
      await ref.read(appStateProvider).api.setQueuePaused(!q.paused);
      await _load();
    } catch (e) {
      if (!mounted) return;
      snack(context, e.toString());
    }
  }

  /// Ставит в очередь задачи на все файлы, у которых превью нет или оно устарело.
  ///
  /// Это не «пересчитать всё заново»: сервер сам решает, что требует работы, и возвращает,
  /// сколько задач реально поставлено (`queued`). Ноль — тоже результат, и про него говорится
  /// словами, иначе нажатие выглядело бы как «ничего не произошло».
  /// Побочно: `_busy` на время запроса и перечитка состояния.
  Future<void> _rebuild() async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(appStateProvider).api.rebuildPreviews();
      final queued = toNum(r['queued'])?.toInt() ?? 0;
      if (!mounted) return;
      snack(context, queued > 0 ? 'Поставлено задач: ${groupDigits(queued)}' : 'Новых задач нет');
      await _load();
    } catch (e) {
      if (!mounted) return;
      snack(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Снимает все задачи из очереди, не удаляя уже собранные превью.
  ///
  /// В диалоге это сказано прямо: очистка очереди и удаление превью — разные вещи, и после
  /// неё недостающее возвращается кнопкой «Пересчитать». Отмена — выход без запроса.
  /// Побочно: `_busy`, подсказка и перечитка состояния.
  Future<void> _clear() async {
    final ok = await confirmDialog(context, 'Очистить очередь?',
        'Собранные превью останутся на месте. Вернуть недостающие можно «Пересчитать».',
        danger: true, confirmLabel: 'Очистить');
    // Диалог ждут: пока он был открыт, панель могли закрыть вместе с экраном настроек
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(appStateProvider).api.clearQueue();
      if (!mounted) return;
      snack(context, 'Очередь очищена');
      await _load();
    } catch (e) {
      if (!mounted) return;
      snack(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _q;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Очередь превью', style: TextStyle(color: C.fg, fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton(onPressed: q == null ? null : _togglePause,
                  child: Text((q?.paused ?? false) ? 'Продолжить' : 'Пауза')),
              TextButton(onPressed: (_busy || q == null) ? null : _clear, child: const Text('Очистить')),
              TextButton(onPressed: (_busy || q == null) ? null : _rebuild,
                  child: _busy ? const Text('…') : const Text('Пересчитать')),
            ],
          ),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: C.danger, fontSize: 13)),
          if (q == null && _error == null)
            const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: CircularProgressIndicator())
          else if (q != null) ...[
            const SizedBox(height: 6),
            Text('Осталось: ${groupDigits(q.remaining)}',
                style: const TextStyle(color: C.fg, fontSize: 14)),
            if (q.remaining > 0)
              Text(
                'фото: ${groupDigits(q.remainingByKind['photo'] ?? 0)}${etaSuffix(q, 'photo')}'
                ' · видео: ${groupDigits(q.remainingByKind['video'] ?? 0)}${etaSuffix(q, 'video')}'
                '${(q.remainingByKind['pdf'] ?? 0) > 0 ? ' · PDF: ${groupDigits(q.remainingByKind['pdf']!)}${etaSuffix(q, 'pdf')}' : ''}',
                style: const TextStyle(color: C.fg3, fontSize: 12),
              ),
            Text(
              q.paused
                  ? 'пауза — задачи ждут в очереди'
                  : (q.remaining > 0 ? 'очередь разбирается' : 'очередь пуста'),
              style: const TextStyle(color: C.fg3, fontSize: 12),
            ),
            if (q.diskFree != null)
              Text(
                q.diskLow == true
                    ? 'на диске сервера мало места (${fmt(q.diskFree!)} свободно)'
                    : 'диск сервера: ${fmt(q.diskFree!)} свободно',
                style: TextStyle(
                    color: q.diskLow == true ? C.warn : C.fg3, fontSize: 12),
              ),
            if (q.errors > 0)
              TextButton(
                onPressed: widget.onErrors,
                style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                child: Text('Ошибки: ${groupDigits(q.errors)}',
                    style: const TextStyle(color: C.warn, fontSize: 12)),
              ),
          ],
        ],
      ),
    );
  }
}
