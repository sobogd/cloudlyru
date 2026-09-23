import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers.dart';

/// Состояние пул-реквеста, по которому фильтруется список.
enum _State {
  /// Без ограничения.
  any('Все'),

  /// Апрувнуто и без висящих запросов на изменения.
  approved('Апрув'),

  /// Изменения запрошены и не сняты.
  changes('ЧР'),

  /// Ревьюеры назначены, но ревью ещё не было.
  waiting('Ждут ревью'),

  /// Ревью никто не запрашивал.
  none('Без ревью'),

  /// Черновик.
  draft('Черновики');

  /// Состояние с подписью для чипа.
  const _State(this.label);

  /// Подпись на чипе фильтра.
  final String label;
}

/// Авторство пул-реквеста относительно владельца токена.
enum _Author {
  /// Без ограничения.
  any('Все'),

  /// Только свои.
  mine('Мои'),

  /// Только чужие.
  others('Чужие');

  /// Авторство с подписью для чипа.
  const _Author(this.label);

  /// Подпись на чипе фильтра.
  final String label;
}

/// Чем группировать список.
enum _Group {
  /// Плоский список.
  none('Без группировки'),

  /// По задаче Jira из заголовка.
  task('По задаче'),

  /// По репозиторию.
  repo('По репозиторию');

  /// Группировка с подписью для меню.
  const _Group(this.label);

  /// Подпись в меню.
  final String label;
}

/// Чем сортировать список.
enum _Sort {
  /// Последние изменения сверху.
  updated('По обновлению'),

  /// По ключу задачи (новые задачи сверху).
  task('По задаче'),

  /// По репозиторию и номеру.
  repo('По репозиторию');

  /// Сортировка с подписью для меню.
  const _Sort(this.label);

  /// Подпись в меню.
  final String label;
}

/// Экран «Пул-реквесты»: открытые PR настроенных репозиториев с фильтрами.
///
/// Мак отдаёт снимок целиком и без фильтров (`/mac/pull-requests`), включая разобранный из
/// заголовка ключ задачи и счётчики обсуждения. Группировка, сортировка и фильтры считаются
/// здесь: переключение не стоит запроса к GitHub и не тратит лимит API.
class PullRequestsScreen extends ConsumerStatefulWidget {
  /// Экран пул-реквестов.
  const PullRequestsScreen({super.key});

  @override
  ConsumerState<PullRequestsScreen> createState() => _PullRequestsScreenState();
}

/// Состояние экрана: снимок с мака, выбранные фильтры и признак загрузки.
class _PullRequestsScreenState extends ConsumerState<PullRequestsScreen> {
  /// Все открытые PR из ответа мака; `null` — ответа ещё не было.
  List<Map<String, dynamic>>? _all;

  /// Репозитории из конфига мака — источник списка для фильтра по репозиторию.
  List<String> _repos = const [];

  /// Текст последней неудачи.
  String? _err;

  /// Идёт запрос.
  bool _busy = false;

  /// Выбранный репозиторий; `null` — все.
  String? _repo;

  /// Выбранное состояние.
  _State _state = _State.any;

  /// Выбранное авторство.
  _Author _author = _Author.any;

  /// Показывать только те, где после последнего запроса изменений кто-то написал.
  bool _onlyAfterCr = false;

  /// Текущая группировка.
  _Group _group = _Group.none;

  /// Текущая сортировка.
  _Sort _sort = _Sort.updated;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Перечитывает снимок с мака.
  Future<void> _load({bool refresh = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final d = await ref.read(appStateProvider).api.macPullRequests(refresh: refresh);
      final list = (d['pulls'] is List) ? (d['pulls'] as List) : const [];
      final repos = (d['repos'] is List) ? (d['repos'] as List) : const [];
      if (!mounted) return;
      setState(() {
        _all = list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
        _repos = repos.whereType<String>().toList();
        _err = d['ok'] == false ? '${d['msg'] ?? 'ошибка на маке'}' : null;
      });
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Применяет фильтры и сортировку к снимку.
  List<Map<String, dynamic>> _filtered() {
    final all = [...(_all ?? const <Map<String, dynamic>>[])];
    final rows = all.where((row) {
      if (_repo != null && row['repo'] != _repo) return false;
      if (_author == _Author.mine && row['mine'] != true) return false;
      if (_author == _Author.others && row['mine'] == true) return false;
      if (_onlyAfterCr && (row['comments_after_cr'] as int? ?? 0) == 0) return false;
      final decision = '${row['review_decision'] ?? 'NONE'}';
      final draft = row['draft'] == true;
      switch (_state) {
        case _State.any:
          return true;
        case _State.draft:
          return draft;
        case _State.approved:
          return decision == 'APPROVED';
        case _State.changes:
          return decision == 'CHANGES_REQUESTED';
        case _State.waiting:
          return decision == 'REVIEW_REQUIRED';
        case _State.none:
          return decision != 'APPROVED' &&
              decision != 'CHANGES_REQUESTED' &&
              decision != 'REVIEW_REQUIRED';
      }
    }).toList();
    rows.sort(_compare);
    return rows;
  }

  /// Порядок двух строк согласно выбранной сортировке.
  int _compare(Map<String, dynamic> a, Map<String, dynamic> b) {
    switch (_sort) {
      case _Sort.updated:
        return '${b['updated_at']}'.compareTo('${a['updated_at']}');
      case _Sort.task:
        final byTask = _taskOrder(b).compareTo(_taskOrder(a));
        return byTask != 0 ? byTask : '${a['repo']}'.compareTo('${b['repo']}');
      case _Sort.repo:
        final byRepo = '${a['repo']}'.compareTo('${b['repo']}');
        return byRepo != 0 ? byRepo : (b['number'] as int? ?? 0) - (a['number'] as int? ?? 0);
    }
  }

  /// Ключ задачи в виде, пригодном для сравнения: префикс и номер с ведущими нулями.
  ///
  /// Иначе `JS-999` оказывается «новее» `JS-7000`, а строки без задачи разъезжаются по списку.
  String _taskOrder(Map<String, dynamic> row) {
    final task = '${row['task'] ?? ''}';
    if (task.isEmpty) return '';
    final dash = task.lastIndexOf('-');
    if (dash < 0) return task;
    final prefix = task.substring(0, dash);
    final number = int.tryParse(task.substring(dash + 1)) ?? 0;
    return '$prefix-${number.toString().padLeft(8, '0')}';
  }

  /// Заголовок группы для строки при текущей группировке.
  String _groupOf(Map<String, dynamic> row) => switch (_group) {
        _Group.none => '',
        _Group.repo => '${row['repo']}',
        _Group.task => '${row['task'] ?? ''}'.isEmpty ? 'Без задачи' : '${row['task']}',
      };

  /// Открывает ссылку во внешнем браузере.
  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не открылось: $url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = _all;
    final rows = _filtered();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Пул-реквесты'),
        actions: [
          PopupMenuButton<_Group>(
            tooltip: 'Группировка',
            initialValue: _group,
            icon: const Icon(Icons.segment),
            onSelected: (v) => setState(() => _group = v),
            itemBuilder: (_) => [
              for (final g in _Group.values) PopupMenuItem(value: g, child: Text(g.label)),
            ],
          ),
          PopupMenuButton<_Sort>(
            tooltip: 'Сортировка',
            initialValue: _sort,
            icon: const Icon(Icons.sort),
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (_) => [
              for (final s in _Sort.values) PopupMenuItem(value: s, child: Text(s.label)),
            ],
          ),
          IconButton(
            tooltip: 'Обновить',
            onPressed: _busy ? null : () => _load(refresh: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _err != null && all == null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Мак недоступен: $_err')))
          : all == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    _filterBar(),
                    if (_err != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(_err!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                      child: Row(
                        children: [
                          Text('${rows.length} из ${all.length}',
                              style: Theme.of(context).textTheme.bodySmall),
                          const Spacer(),
                          if (_busy)
                            const SizedBox(
                                width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                        ],
                      ),
                    ),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: () => _load(refresh: true),
                        child: rows.isEmpty
                            ? ListView(
                                children: const [
                                  SizedBox(height: 80),
                                  Center(child: Text('Под фильтры ничего не попало')),
                                ],
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.only(bottom: 24),
                                itemCount: rows.length,
                                itemBuilder: (_, i) {
                                  final row = rows[i];
                                  final header = _groupOf(row);
                                  final newGroup = _group != _Group.none &&
                                      (i == 0 || _groupOf(rows[i - 1]) != header);
                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      if (newGroup) _groupHeader(header, row),
                                      _rowTile(row),
                                      const Divider(height: 1),
                                    ],
                                  );
                                },
                              ),
                      ),
                    ),
                  ],
                ),
    );
  }

  /// Заголовок группы; для задачи — ссылка в Jira.
  Widget _groupHeader(String header, Map<String, dynamic> row) {
    final taskUrl = _group == _Group.task ? '${row['task_url'] ?? ''}' : '';
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(header, style: Theme.of(context).textTheme.titleSmall),
          ),
          if (taskUrl.isNotEmpty)
            IconButton(
              tooltip: 'Открыть в Jira',
              visualDensity: VisualDensity.compact,
              onPressed: () => _open(taskUrl),
              icon: const Icon(Icons.open_in_new, size: 16),
            ),
        ],
      ),
    );
  }

  /// Панель фильтров: репозиторий, авторство, состояние, «новое после ЧР».
  Widget _filterBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          _repoChip(),
          const SizedBox(width: 12),
          for (final a in _Author.values) ...[
            ChoiceChip(
              label: Text(a.label),
              selected: _author == a,
              onSelected: (_) => setState(() => _author = a),
            ),
            const SizedBox(width: 6),
          ],
          const SizedBox(width: 6),
          for (final s in _State.values) ...[
            ChoiceChip(
              label: Text(s.label),
              selected: _state == s,
              onSelected: (_) => setState(() => _state = s),
            ),
            const SizedBox(width: 6),
          ],
          const SizedBox(width: 6),
          FilterChip(
            label: const Text('Новое после ЧР'),
            selected: _onlyAfterCr,
            onSelected: (v) => setState(() => _onlyAfterCr = v),
          ),
        ],
      ),
    );
  }

  /// Выбор репозитория: все или один из настроенных на маке.
  Widget _repoChip() {
    final items = <String?>[null, ..._repos];
    return PopupMenuButton<String?>(
      initialValue: _repo,
      onSelected: (v) => setState(() => _repo = v),
      itemBuilder: (_) => [
        for (final item in items)
          PopupMenuItem<String?>(value: item, child: Text(item ?? 'Все репозитории')),
      ],
      child: Chip(
        avatar: const Icon(Icons.filter_list, size: 18),
        label: Text(_repo ?? 'Все репозитории'),
      ),
    );
  }

  /// Строка одного PR: задача, заголовок, состояние и обсуждение.
  Widget _rowTile(Map<String, dynamic> row) {
    final decision = '${row['review_decision'] ?? 'NONE'}';
    final task = '${row['task'] ?? ''}';
    final afterCr = row['comments_after_cr'] as int? ?? 0;
    final total = row['comments_total'] as int? ?? 0;
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      title: Text('#${row['number']} ${row['title']}', maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (task.isNotEmpty)
              InkWell(
                onTap: () => _open('${row['task_url']}'),
                child: _badge(task, theme.colorScheme.primary),
              ),
            Text('${row['repo']} · ${row['mine'] == true ? 'я' : row['author']}',
                style: theme.textTheme.bodySmall),
            _badge(_decisionLabel(decision), _decisionColor(decision)),
            if (row['draft'] == true) _badge('draft', theme.colorScheme.outline),
            if (total > 0) Text('💬 $total', style: theme.textTheme.bodySmall),
            if (afterCr > 0) _badge('+$afterCr после ЧР', Colors.orange),
          ],
        ),
      ),
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () => _open('${row['url'] ?? ''}'),
      onLongPress: task.isEmpty ? null : () => _open('${row['task_url']}'),
    );
  }

  /// Короткий цветной ярлык.
  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
      );

  /// Подпись состояния ревью по-русски и коротко.
  String _decisionLabel(String decision) => switch (decision) {
        'APPROVED' => 'апрув',
        'CHANGES_REQUESTED' => 'ЧР',
        'REVIEW_REQUIRED' => 'ждёт ревью',
        _ => 'без ревью',
      };

  /// Цвет состояния ревью.
  Color _decisionColor(String decision) {
    final scheme = Theme.of(context).colorScheme;
    return switch (decision) {
      'APPROVED' => Colors.green,
      'CHANGES_REQUESTED' => scheme.error,
      _ => scheme.outline,
    };
  }
}
