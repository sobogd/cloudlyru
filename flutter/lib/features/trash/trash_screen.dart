import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';

class TrashScreen extends ConsumerStatefulWidget {
  const TrashScreen({super.key});

  @override
  ConsumerState<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends ConsumerState<TrashScreen> {
  TrashView? _view;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await ref.read(appStateProvider).api.trash();
      if (mounted) setState(() {
        _view = v;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _restore(String kind, String id) async {
    try {
      await ref.read(appStateProvider).api.restoreItem(kind, id);
      await _load();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  Future<void> _purge() async {
    final ok = await confirmDialog(context, 'Очистить корзину?',
        'Удалённые файлы и превью будут стёрты безвозвратно.', danger: true);
    if (!ok) return;
    try {
      await ref.read(appStateProvider).api.purgeTrash();
      await _load();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = <TrashItem>[
      ...(_view?.folders ?? const <TrashItem>[]),
      ...(_view?.entries ?? const <TrashItem>[]),
    ];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.canvas,
        title: const Text('Корзина', style: TextStyle(color: C.fg, fontSize: 18)),
        actions: [
          IconButton(
            tooltip: 'Очистить корзину',
            onPressed: items.isEmpty ? null : _purge,
            icon: const Icon(Icons.delete_sweep_outlined, color: C.danger),
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text(_error!, style: const TextStyle(color: C.danger)))
          : _view == null
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
                  ? const Center(child: Text('Корзина пуста', style: TextStyle(color: C.fg3)))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final t = items[i];
                        return ListTile(
                          leading: Icon(
                            t.kind == 'folder' ? Icons.folder_outlined : fileIcon(null),
                            color: C.fg3,
                          ),
                          title: Text(t.name, style: const TextStyle(color: C.fg)),
                          subtitle: Text(
                            t.deletedAt == null
                                ? ''
                                : fmtLocal(t.deletedAt) ?? t.deletedAt!,
                            style: const TextStyle(color: C.fg3, fontSize: 12),
                          ),
                          trailing: TextButton(
                            onPressed: () => _restore(t.kind, t.id),
                            child: const Text('восстановить'),
                          ),
                        );
                      },
                    ),
    );
  }
}
