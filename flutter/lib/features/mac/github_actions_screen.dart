import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';

/// Экран «GitHub Actions»: настроенные workflow на маке и их запуск.
///
/// Список и токен живут на маке (`github-actions.json` и `~/work/.env`); сервер только
/// проксирует ручки `/mac/github-actions*`. Приложение не знает ни токена, ни адреса API —
/// запуск отправляется по имени репозитория и пути workflow.
class GithubActionsScreen extends ConsumerStatefulWidget {
  /// Экран GitHub Actions.
  const GithubActionsScreen({super.key});

  @override
  ConsumerState<GithubActionsScreen> createState() => _GithubActionsScreenState();
}

/// Состояние экрана: список workflow, ошибка и признак загрузки.
class _GithubActionsScreenState extends ConsumerState<GithubActionsScreen> {
  /// Список workflow из `/mac/github-actions`; `null` — ответа ещё не было.
  List<Map<String, dynamic>>? _rows;

  /// Текст последней неудачи.
  String? _err;

  /// Идёт запрос.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Перечитывает дашборд.
  Future<void> _load({bool refresh = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final d = await ref.read(appStateProvider).api.macGithubActions(refresh: refresh);
      final list = (d['workflows'] is List) ? (d['workflows'] as List) : const [];
      if (!mounted) return;
      setState(() {
        _rows = list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
        _err = d['ok'] == false ? '${d['msg'] ?? 'ошибка на маке'}' : null;
      });
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Спрашивает ветку/тег и запускает workflow.
  Future<void> _run(Map<String, dynamic> row) async {
    final latest = (row['latest'] is Map) ? (row['latest'] as Map).cast<String, dynamic>() : const {};
    final controller = TextEditingController(text: '${latest['branch'] ?? 'main'}');
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${row['name'] ?? row['path']}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${row['repo']} · ${row['path']}', style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: 'Ветка или тег'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Запустить')),
        ],
      ),
    );
    if (go != true) return;
    final branch = controller.text.trim();
    try {
      final res = await ref.read(appStateProvider).api.macGithubRun({
        'repo': row['repo'],
        'path': row['path'],
        'ref': branch,
        'inputs': <String, dynamic>{},
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${res['ok'] == false ? res['msg'] : 'Запущено: ${row['name']}'}')),
        );
      }
      await _load(refresh: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(
        title: const Text('GitHub Actions'),
        actions: [
          IconButton(onPressed: _busy ? null : () => _load(refresh: true), icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _err != null && rows == null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Мак недоступен: $_err')))
          : rows == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) => _rowTile(rows[i]),
                ),
    );
  }

  /// Строка одного workflow: имя, репозиторий, последний статус и кнопка запуска.
  Widget _rowTile(Map<String, dynamic> row) {
    final latest = (row['latest'] is Map) ? (row['latest'] as Map).cast<String, dynamic>() : const {};
    final status = '${latest['status'] ?? '—'}${latest['conclusion'] != null ? ' / ${latest['conclusion']}' : ''}';
    final avg = row['average_seconds'];
    return ListTile(
      title: Text('${row['name'] ?? row['path']}'),
      subtitle: Text('${row['repo']} · $status${avg != null ? ' · ~$avg с' : ''}'),
      trailing: FilledButton(onPressed: () => _run(row), child: const Text('Run')),
    );
  }
}
