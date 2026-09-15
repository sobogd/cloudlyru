import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import 'updater.dart';

String _group(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return b.toString();
}

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String _view = 'main';

  @override
  void initState() {
    super.initState();
    debugPrint('settings screen built');
  }

  @override
  Widget build(BuildContext context) {
    if (_view == 'queue-errors') {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: C.canvas,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: C.fg),
            onPressed: () => setState(() => _view = 'main'),
          ),
          title: const Text('Ошибки очереди', style: TextStyle(color: C.fg, fontSize: 18)),
        ),
        body: const QueueErrorsPanel(),
      );
    }
    final state = ref.watch(appStateProvider);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.canvas,
        title: const Text('Настройки', style: TextStyle(color: C.fg, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.person_outline, color: C.fg3),
                    const SizedBox(width: 8),
                    Text(state.user?.login ?? '', style: const TextStyle(color: C.fg, fontSize: 15, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: C.danger),
                      onPressed: () => ref.read(appStateProvider).logout(),
                      child: const Text('Выйти'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(ref.read(appStateProvider).settings.serverUrl,
                    style: const TextStyle(color: C.fg3, fontSize: 12)),
              ],
            ),
          ),
          const _TokensPanel(),
          const UpdaterPanel(),
          QueuePanel(onErrors: () => setState(() => _view = 'queue-errors')),
          const _MailAccountsPanel(),
        ],
      ),
    );
  }
}

// ---------- токены (только чтение: выпуск/отзыв — веб-сессия) ----------

class _TokensPanel extends ConsumerStatefulWidget {
  const _TokensPanel();

  @override
  ConsumerState<_TokensPanel> createState() => _TokensPanelState();
}

class _TokensPanelState extends ConsumerState<_TokensPanel> {
  List<ApiTokenRow> _tokens = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await ref.read(appStateProvider).api.listTokens();
      if (mounted) setState(() => _tokens = t);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Приложения (WebDAV/Finder)',
              style: TextStyle(color: C.fg, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (_tokens.isEmpty)
            const Text('Токенов нет — управление в веб-версии', style: TextStyle(color: C.fg3, fontSize: 13))
          else
            ..._tokens.map((t) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.key_outlined, color: C.fg3),
                  title: Text(t.label, style: const TextStyle(color: C.fg, fontSize: 14)),
                  subtitle: Text(
                    t.lastUsedAt == null ? 'не использовался' : 'последний раз: ${fmtLocal(t.lastUsedAt) ?? t.lastUsedAt!}',
                    style: const TextStyle(color: C.fg3, fontSize: 12),
                  ),
                )),
        ],
      ),
    );
  }
}

// ---------- очередь превью ----------

class QueuePanel extends ConsumerStatefulWidget {
  final VoidCallback? onErrors;
  const QueuePanel({super.key, this.onErrors});
  @override
  ConsumerState<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends ConsumerState<QueuePanel> {
  QueueStatus? _q;
  String? _error;
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final q = await ref.read(appStateProvider).api.queueStatus();
      if (mounted) setState(() {
        _q = q;
        _error = null;
      });
    } catch (e) {
      if (mounted && _q == null) setState(() => _error = e.toString());
    }
  }

  Future<void> _togglePause() async {
    final q = _q;
    if (q == null) return;
    try {
      await ref.read(appStateProvider).api.setQueuePaused(!q.paused);
      await _load();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  Future<void> _rebuild() async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(appStateProvider).api.rebuildPreviews();
      final queued = toNum(r['queued'])?.toInt() ?? 0;
      if (mounted) snack(context, queued > 0 ? 'Поставлено задач: ${_group(queued)}' : 'Новых задач нет');
      await _load();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final ok = await confirmDialog(context, 'Очистить очередь?',
        'Собранные превью останутся на месте. Вернуть недостающие можно «Пересчитать».', danger: true);
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await ref.read(appStateProvider).api.clearQueue();
      if (mounted) snack(context, 'Очередь очищена');
      await _load();
    } catch (e) {
      if (mounted) snack(context, e.toString());
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
            Text('Осталось: ${_group(q.remaining)}',
                style: const TextStyle(color: C.fg, fontSize: 14)),
            if (q.remaining > 0)
              Text(
                'фото: ${_group(q.remainingByKind['photo'] ?? 0)} · видео: ${_group(q.remainingByKind['video'] ?? 0)}'
                '${(q.remainingByKind['pdf'] ?? 0) > 0 ? ' · PDF: ${_group(q.remainingByKind['pdf']!)}' : ''}',
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
                child: Text('Ошибки: ${_group(q.errors)}',
                    style: const TextStyle(color: C.warn, fontSize: 12)),
              ),
          ],
        ],
      ),
    );
  }
}

// ---------- ошибки очереди ----------

class QueueErrorsPanel extends ConsumerStatefulWidget {
  const QueueErrorsPanel({super.key});
  @override
  ConsumerState<QueueErrorsPanel> createState() => _QueueErrorsPanelState();
}

class _QueueErrorsPanelState extends ConsumerState<QueueErrorsPanel> {
  static const _limit = 50;
  int _total = 0;
  List<QueueErrorRow> _items = const [];
  int _offset = 0;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ref.read(appStateProvider).api.queueErrors(limit: _limit, offset: _offset);
      if (mounted) setState(() {
        _total = toNum(r['total'])?.toInt() ?? 0;
        _items = (r['items'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => QueueErrorRow.fromJson(e.cast<String, dynamic>()))
            .toList();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _retryOne(String? entryId) async {
    if (entryId == null) return;
    try {
      await ref.read(appStateProvider).api.retryPreview(entryId);
      if (mounted) snack(context, 'Файл снова в очереди');
      await _load();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  Future<void> _retryAll() async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(appStateProvider).api.retryQueueErrors();
      if (mounted) snack(context, 'Возвращено в очередь: ${r['retried']}');
      setState(() => _offset = 0);
      await _load();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Text('${_group(_total)}', style: const TextStyle(color: C.fg3, fontSize: 14)),
            const Spacer(),
            FilledButton(
              onPressed: (_busy || _total == 0) ? null : _retryAll,
              child: const Text('Повторить все'),
            ),
          ],
        ),
        if (_error != null) Text(_error!, style: const TextStyle(color: C.danger)),
        if (_items.isEmpty && _error == null)
          const Padding(padding: EdgeInsets.all(24), child: Text('Ошибок нет', style: TextStyle(color: C.fg3))),
        ..._items.map((j) => Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(j.kind == 'video' ? Icons.movie_outlined : j.kind == 'pdf' ? Icons.picture_as_pdf_outlined : Icons.image_outlined, color: C.fg3),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(j.name ?? 'файл удалён', style: const TextStyle(color: C.fg, fontSize: 14)),
                          Text(j.error, style: const TextStyle(color: C.danger, fontSize: 12)),
                          Text('попыток: ${j.attempts}${j.finishedAt != null ? ' · ${fmtLocal(j.finishedAt)}' : ''}',
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
                onPressed: _offset == 0 ? null : () { setState(() => _offset = (_offset - _limit).clamp(0, 1 << 30)); _load(); },
                child: const Text('назад'),
              ),
              Text('${_offset + 1}–${_offset + _items.length} из ${_group(_total)}',
                  style: const TextStyle(color: C.fg3, fontSize: 12)),
              TextButton(
                onPressed: (_offset + _items.length >= _total) ? null : () { setState(() => _offset += _limit); _load(); },
                child: const Text('вперёд'),
              ),
            ],
          ),
      ],
    );
  }
}

// ---------- почтовые аккаунты ----------

class _MailAccountsPanel extends ConsumerStatefulWidget {
  const _MailAccountsPanel();
  @override
  ConsumerState<_MailAccountsPanel> createState() => _MailAccountsPanelState();
}

class _MailAccountsPanelState extends ConsumerState<_MailAccountsPanel> {
  List<MailAccountRow> _rows = const [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await ref.read(appStateProvider).api.mailAccounts();
      if (mounted) setState(() => _rows = r);
    } catch (_) {}
  }

  String _status(MailAccountRow r) {
    if (!r.enabled) return 'выключен';
    if (r.status == 'syncing') return 'забираем письма…';
    if (r.status == 'error') return r.statusError ?? 'ошибка';
    if (r.lastSyncAt == null) return 'ещё не проверялся';
    return 'проверен ${fmtLocal(r.lastSyncAt) ?? r.lastSyncAt!}';
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Почта', style: TextStyle(color: C.fg, fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton(
                onPressed: () async {
                  try {
                    await ref.read(appStateProvider).api.mailSync();
                    if (mounted) snack(context, 'Проверка запущена');
                  } catch (e) {
                    if (mounted) snack(context, e.toString());
                  }
                },
                child: const Text('Проверить'),
              ),
            ],
          ),
          ..._rows.map((r) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.mail_outline, color: C.fg3),
                title: Text(r.email, style: const TextStyle(color: C.fg, fontSize: 14)),
                subtitle: Text('${r.counts.inbox} вх · ${r.counts.sent} исх · ${_status(r)}',
                    style: const TextStyle(color: C.fg3, fontSize: 12)),
              )),
        ],
      ),
    );
  }
}
