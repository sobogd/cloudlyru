import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers.dart';

/// Состояние ревью, по которому фильтруется список.
enum _Review {
  /// Без ограничения.
  any('Все'),

  /// Ещё никто не запросил изменения — то, что обычно и нужно посмотреть.
  noChanges('Без ЧР'),

  /// Изменения запрошены и не сняты.
  changes('С ЧР'),

  /// Апрувнуто.
  approved('Апрувнуто'),

  /// Ревью ещё не было.
  waiting('Ждут ревью');

  /// Состояние ревью с подписью для чипа.
  const _Review(this.label);

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

/// Экран «Пул-реквесты»: открытые PR настроенных репозиториев с фильтрами.
///
/// Мак отдаёт снимок целиком и без фильтров (`/mac/pull-requests`): список у него один,
/// и все выборки — репозиторий, авторство, состояние ревью, черновики — считаются здесь.
/// Так переключение фильтра не стоит запроса к GitHub и не тратит лимит API.
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

  /// Выбранное состояние ревью.
  _Review _review = _Review.any;

  /// Выбранное авторство.
  _Author _author = _Author.any;

  /// Показывать ли черновики.
  bool _drafts = true;

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

  /// Применяет выбранные фильтры к снимку.
  List<Map<String, dynamic>> _filtered() {
    final all = _all ?? const <Map<String, dynamic>>[];
    return all.where((row) {
      if (_repo != null && row['repo'] != _repo) return false;
      if (!_drafts && row['draft'] == true) return false;
      if (_author == _Author.mine && row['mine'] != true) return false;
      if (_author == _Author.others && row['mine'] == true) return false;
      final decision = '${row['review_decision'] ?? 'NONE'}';
      switch (_review) {
        case _Review.any:
          return true;
        case _Review.noChanges:
          return decision != 'CHANGES_REQUESTED';
        case _Review.changes:
          return decision == 'CHANGES_REQUESTED';
        case _Review.approved:
          return decision == 'APPROVED';
        case _Review.waiting:
          return decision != 'APPROVED' && decision != 'CHANGES_REQUESTED';
      }
    }).toList();
  }

  /// Открывает PR в браузере.
  Future<void> _open(Map<String, dynamic> row) async {
    final url = '${row['url'] ?? ''}';
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
                            : ListView.separated(
                                padding: const EdgeInsets.only(bottom: 24),
                                itemCount: rows.length,
                                separatorBuilder: (_, _) => const Divider(height: 1),
                                itemBuilder: (_, i) => _rowTile(rows[i]),
                              ),
                      ),
                    ),
                  ],
                ),
    );
  }

  /// Панель фильтров: репозиторий, авторство, состояние ревью, черновики.
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
          for (final r in _Review.values) ...[
            ChoiceChip(
              label: Text(r.label),
              selected: _review == r,
              onSelected: (_) => setState(() => _review = r),
            ),
            const SizedBox(width: 6),
          ],
          const SizedBox(width: 6),
          FilterChip(
            label: const Text('Черновики'),
            selected: _drafts,
            onSelected: (v) => setState(() => _drafts = v),
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

  /// Строка одного PR: номер и заголовок, репозиторий, автор и состояние.
  Widget _rowTile(Map<String, dynamic> row) {
    final decision = '${row['review_decision'] ?? 'NONE'}';
    final draft = row['draft'] == true;
    final mine = row['mine'] == true;
    final comments = row['comments'];
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
            Text('${row['repo']} · ${mine ? 'я' : row['author']}',
                style: Theme.of(context).textTheme.bodySmall),
            _badge(_decisionLabel(decision), _decisionColor(decision)),
            if (draft) _badge('draft', Theme.of(context).colorScheme.outline),
            if (comments is int && comments > 0)
              Text('💬 $comments', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () => _open(row),
    );
  }

  /// Короткий цветной ярлык состояния.
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
