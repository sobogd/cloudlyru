import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import '../data/queue_store.dart';
import '../device/media_rules.dart';
import '../queue/upload_runner.dart';
import '../section.dart';
import '../sync_controller.dart';

/// Раздел «Очередь»: что нашлось нового и ждёт выгрузки.
///
/// Запуск ручной и строго по одному файлу: пока идёт выгрузка, остальные кнопки неактивны.
/// Автоматически ничего не уезжает — очередь только готовит работу, а решение остаётся
/// за человеком (и за зеркалом, у которого свой проход).
class QueueScreen extends ConsumerStatefulWidget {
  const QueueScreen({super.key});

  @override
  ConsumerState<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends ConsumerState<QueueScreen> {
  List<QueueItem> _items = const [];
  Map<QueueState, int> _counts = const {};
  int _total = 0;
  bool _loading = true;
  bool _rebuilding = false;
  UploadProgress? _progress;

  SyncController get _sync => ref.read(syncControllerProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final store = _sync.queueStore;
    if (store == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final items = await store.items();
    final counts = await store.counts();
    if (!mounted) return;
    setState(() {
      _items = items;
      _counts = counts;
      // очередь показывается порциями: если строк больше, об усечении надо сказать,
      // иначе «в очереди 2000» выглядит как правда о всей очереди
      _total = counts.values.fold(0, (a, b) => a + b);
      _loading = false;
    });
  }

  Future<void> _rebuild() async {
    setState(() => _rebuilding = true);
    try {
      final result = await _sync.refreshQueue();
      if (!mounted) return;
      if (result == null) {
        snack(context, _sync.queueNote ?? 'очередь не обновлена');
      }
    } finally {
      if (mounted) setState(() => _rebuilding = false);
      await _reload();
    }
  }

  Future<void> _clearFinished() async {
    await _sync.queueStore?.clearFinished();
    await _reload();
  }

  /// Выгрузка одного файла. Пока она идёт, состояние строки показываем по байтам, а не
  /// «в очереди»: иначе непонятно, работает ли что-нибудь вообще.
  Future<void> _upload(int id, {bool retry = false}) async {
    if (_progress != null) return;
    if (retry) await _sync.queueStore?.markPending(id);
    await _reload();
    setState(
      () => _progress = UploadProgress(id: id, name: '', sent: 0, total: 0),
    );
    try {
      await _sync.uploadItem(
        id,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
    } finally {
      if (mounted) setState(() => _progress = null);
      await _reload();
    }
  }

  int get _waiting =>
      (_counts[QueueState.pending] ?? 0) + (_counts[QueueState.failed] ?? 0);

  @override
  Widget build(BuildContext context) {
    // очередь меняется сама: наполнение идёт в фоне, поэтому счётчик ожидающих —
    // единственный признак, по которому экран надо перечитать
    ref.listen(syncControllerProvider.select((c) => c.waiting), (prev, next) {
      if (prev != next) unawaited(_reload());
    });
    final sync = ref.watch(syncControllerProvider);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.canvas,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Очередь', style: TextStyle(color: C.fg, fontSize: 17)),
            Text(
              _waiting == 0 ? 'нечего выгружать' : 'ждут запуска: $_waiting',
              style: const TextStyle(color: C.fg3, fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _items.isEmpty
                ? null
                : () => unawaited(_clearFinished()),
            child: const Text('Очистить готовые'),
          ),
          IconButton(
            tooltip: 'Обновить очередь',
            onPressed: _rebuilding ? null : () => unawaited(_rebuild()),
            icon: const Icon(Icons.refresh, color: C.fg),
          ),
        ],
      ),
      body: _body(sync),
    );
  }

  Widget _body(SyncController sync) {
    if (sync.queueStore == null) {
      return _centered('Синхронизация не запущена: войдите в аккаунт');
    }
    final note = sync.queueNote;
    return Stack(
      children: [
        Column(
          children: [
            if (sync.activity != null || (note != null && note.isNotEmpty))
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    sync.activity ?? note!,
                    style: const TextStyle(color: C.fg3, fontSize: 11),
                  ),
                ),
              ),
            if (_counts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _countsLine(),
                    style: const TextStyle(color: C.fg3, fontSize: 11),
                  ),
                ),
              ),
            if (_total > _items.length)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'показаны первые ${_items.length} из $_total строк',
                    style: const TextStyle(color: C.fg3, fontSize: 11),
                  ),
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : (_items.isEmpty
                        ? _empty()
                        : ListView.builder(
                            itemCount: _items.length,
                            itemBuilder: (context, i) => _row(_items[i]),
                          )),
            ),
          ],
        ),
        if (_rebuilding || _progress != null)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }

  String _countsLine() {
    final parts = <String>[];
    for (final state in QueueState.values) {
      final n = _counts[state] ?? 0;
      if (n > 0) parts.add('${_stateText(state)}: $n');
    }
    return parts.join(' · ');
  }

  Widget _row(QueueItem item) {
    final progress = _progress?.id == item.id ? _progress : null;
    final canStart =
        _progress == null &&
        (item.state == QueueState.pending || item.state == QueueState.failed);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Icon(
                MediaRules.isVideo(item.name)
                    ? Icons.movie_outlined
                    : (MediaRules.isImage(item.name)
                          ? Icons.image_outlined
                          : Icons.insert_drive_file_outlined),
                color: C.accent,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: C.fg, fontSize: 15),
                    ),
                    Text(
                      progress == null
                          ? _subtitle(item)
                          // размер известен не с первого байта: пока его нет, «0% из 0 Б»
                          // читалось бы как сломанный счётчик
                          : (progress.total <= 0
                                ? 'выгрузка…'
                                : 'выгрузка: ${progress.percent}% из ${fmt(progress.total)}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: C.fg3, fontSize: 11),
                    ),
                    if (item.state == QueueState.failed &&
                        (item.lastError ?? '').isNotEmpty)
                      Text(
                        item.lastError!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: C.danger, fontSize: 11),
                      ),
                  ],
                ),
              ),
              // «повторить» отличается от «play» только тем, что снимает состояние ошибки:
              // так видно, что попытка не первая
              if (item.state == QueueState.failed)
                IconButton(
                  tooltip: 'Повторить',
                  onPressed: canStart
                      ? () => unawaited(_upload(item.id, retry: true))
                      : null,
                  icon: const Icon(Icons.replay, color: C.fg3, size: 20),
                ),
              IconButton(
                tooltip: 'Выгрузить файл',
                onPressed: canStart ? () => unawaited(_upload(item.id)) : null,
                icon: const Icon(Icons.play_arrow, color: C.accent),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _empty() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Очередь пуста',
            style: TextStyle(color: C.fg, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          const Text(
            'Новое и изменённое в выбранных папках появится здесь само. '
            'Папки выбираются в настройках.',
            textAlign: TextAlign.center,
            style: TextStyle(color: C.fg3, fontSize: 12),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _rebuilding ? null : () => unawaited(_rebuild()),
            child: const Text('Обновить очередь'),
          ),
        ],
      ),
    );
  }

  Widget _centered(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, style: const TextStyle(color: C.fg3, fontSize: 13)),
      ),
    );
  }

  String _subtitle(QueueItem item) {
    final where = item.section == Section.photos ? 'Фото' : 'Файлы';
    final place = item.relDir.isEmpty ? 'плоско' : item.relDir;
    return '$where · $place · ${fmt(item.size)} · ${_stateText(item.state)}';
  }

  String _stateText(QueueState state) => switch (state) {
    QueueState.pending => 'ждёт запуска',
    QueueState.running => 'грузится',
    QueueState.done => 'выгружен',
    QueueState.skipped => 'уже в облаке',
    QueueState.failed => 'ошибка',
  };
}
