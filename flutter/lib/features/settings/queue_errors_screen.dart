import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import 'queue_format.dart';

/// Экран ошибок очереди превью: что не собралось, почему и с какой попытки.
///
/// Отдельный маршрут, а не раздел внутри панели, потому что список бывает длинным
/// (по 50 записей на страницу) и его просматривают, а не мельком глядят. Раньше это была
/// вторая страница внутри виджета настроек (`_view = 'queue-errors'`) со своей копией
/// `Scaffold`; теперь маршрут обычный, поэтому кнопка «назад» и системный жест работают сами.
///
/// Отсюда же файл можно вернуть в очередь по одному или вернуть все сразу.
class QueueErrorsScreen extends ConsumerStatefulWidget {
  const QueueErrorsScreen({super.key});

  @override
  ConsumerState<QueueErrorsScreen> createState() => _QueueErrorsScreenState();
}

/// Состояние списка ошибок: страница, счётчики и признак идущей операции.
class _QueueErrorsScreenState extends ConsumerState<QueueErrorsScreen> {
  /// Размер страницы: 50 записей — столько сервер отдаёт за раз и столько же умещается
  /// в прокрутку без подгрузки.
  static const _limit = 50;
  /// Сколько ошибок всего (может быть больше одной страницы).
  int _total = 0;
  List<QueueErrorRow> _items = const [];
  /// Смещение текущей страницы — оно же адрес запроса.
  int _offset = 0;
  String? _error;
  /// Идёт массовый повтор: блокирует кнопку, чтобы не вернуть всё в очередь дважды.
  bool _busy = false;

  @override
  /// Открытие страницы: читаем первую порцию ошибок.
  void initState() {
    super.initState();
    _load();
  }

  /// Читает страницу ошибок.
  ///
  /// Побочно: `_total`, `_items`, снятие ошибки; при сбое список остаётся прежним.
  Future<void> _load() async {
    try {
      final page = await ref.read(appStateProvider).api.queueErrors(limit: _limit, offset: _offset);
      if (mounted) {
        setState(() {
          _total = page.total;
          _items = page.items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Возвращает в очередь один файл.
  ///
  /// `entryId == null` значит, что запись о файле уже удалена (в списке это «файл удалён»):
  /// возвращать в очередь нечего, кнопка в строке для такого случая выключена.
  /// Побочно: подсказка и перечитка списка.
  Future<void> _retryOne(String? entryId) async {
    if (entryId == null) return;
    try {
      await ref.read(appStateProvider).api.retryPreview(entryId);
      if (!mounted) return;
      snack(context, 'Файл снова в очереди');
      await _load();
    } catch (e) {
      if (!mounted) return;
      snack(context, e.toString());
    }
  }

  /// Возвращает в очередь все ошибки сразу.
  ///
  /// Страница сбрасывается на первую: после массового повтора список перестраивается, и
  /// оставаться на пятой странице прежнего списка было бы бессмысленно. Побочно: `_busy`,
  /// подсказка с числом возвращённых файлов и перечитка.
  Future<void> _retryAll() async {
    setState(() => _busy = true);
    try {
      final retried = await ref.read(appStateProvider).api.retryQueueErrors();
      if (!mounted) return;
      snack(context, 'Возвращено в очередь: $retried');
      setState(() => _offset = 0);
      await _load();
    } catch (e) {
      if (!mounted) return;
      snack(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Переход на предыдущую порцию ошибок.
  ///
  /// Смещение зажимается нулём: сервер возвращает страницу с конца списка, и вычитание
  /// без зажима увело бы запрос в отрицательное смещение.
  void _prevPage() {
    setState(() => _offset = (_offset - _limit).clamp(0, 1 << 30));
    _load();
  }

  /// Переход на следующую порцию ошибок.
  void _nextPage() {
    setState(() => _offset += _limit);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Шапку красит `appBarTheme` из `theme.dart`: своего цвета у неё тут нет.
      appBar: AppBar(
        title: const Text('Ошибки очереди', style: TextStyle(color: C.fg, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            children: [
              Text(groupDigits(_total), style: const TextStyle(color: C.fg3, fontSize: 14)),
              const Spacer(),
              FilledButton(
                onPressed: (_busy || _total == 0) ? null : _retryAll,
                child: const Text('Повторить все'),
              ),
            ],
          ),
          if (_error != null) Text(_error!, style: const TextStyle(color: C.danger)),
          if (_items.isEmpty && _error == null)
            const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Ошибок нет', style: TextStyle(color: C.fg3))),
          ..._items.map((j) => Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                          j.kind == 'video'
                              ? Icons.movie_outlined
                              : j.kind == 'pdf'
                                  ? Icons.picture_as_pdf_outlined
                                  : Icons.image_outlined,
                          color: C.fg3),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(j.name ?? 'файл удалён',
                                style: const TextStyle(color: C.fg, fontSize: 14)),
                            Text(j.error, style: const TextStyle(color: C.danger, fontSize: 12)),
                            Text(
                                'попыток: ${j.attempts}${j.finishedAt != null ? ' · ${fmtLocal(j.finishedAt)}' : ''}',
                                style: const TextStyle(color: C.fg3, fontSize: 11)),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh, color: C.accent),
                        onPressed: j.entryId == null ? null : () => _retryOne(j.entryId),
                      ),
                    ],
                  ),
                ),
              )),
          if (_total > _limit)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: _offset == 0 ? null : _prevPage,
                  child: const Text('назад'),
                ),
                Text('${_offset + 1}–${_offset + _items.length} из ${groupDigits(_total)}',
                    style: const TextStyle(color: C.fg3, fontSize: 12)),
                TextButton(
                  onPressed: (_offset + _items.length >= _total) ? null : _nextPage,
                  child: const Text('вперёд'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
