import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers.dart';
import '../agent/agent_controller.dart';
import '../agent/agent_launch.dart';
import '../agent/agent_types.dart';

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

/// Снимок доски, переживающий уход с экрана.
///
/// Экран открывают несколько раз за день и почти всегда чтобы посмотреть глазами, а не чтобы
/// увидеть изменения за минуту: запрос на маке идёт ~20 секунд и стоит лимита GitHub, поэтому
/// список загружается один раз и живёт до явного «Обновить».
class _Board {
  /// Снимок доски.
  const _Board(this.pulls, this.repos, this.error, this.loadedAt, this.freshDays);

  /// Все открытые PR из ответа мака.
  final List<Map<String, dynamic>> pulls;

  /// Репозитории из конфига мака.
  final List<String> repos;

  /// Текст неудачи, если мак ответил ошибкой.
  final String? error;

  /// Когда снимок приехал — показывается в шапке списка.
  final DateTime loadedAt;

  /// За сколько последних дней мак взял пул-реквесты; 0 — окно неизвестно.
  final int freshDays;
}

/// Держатель снимка: живёт в контейнере Riverpod, то есть столько же, сколько само приложение.
class _BoardCache {
  /// Последний загруженный снимок; `null` — за сеанс ещё не загружали.
  _Board? value;
}

/// Кэш доски пул-реквестов на время жизни приложения.
final _boardCacheProvider = Provider<_BoardCache>((ref) => _BoardCache());

/// Экран «Пул-реквесты»: открытые PR настроенных репозиториев с фильтрами.
///
/// Мак отдаёт снимок целиком и без фильтров (`/mac/pull-requests`), включая разобранный из
/// заголовка ключ задачи и счётчики обсуждения. Группировка, сортировка и фильтры считаются
/// здесь: переключение не стоит запроса к GitHub и не тратит лимит API.
class PullRequestsScreen extends ConsumerStatefulWidget {
  /// Доска пул-реквестов.
  const PullRequestsScreen({super.key, this.embedded = false, this.onReview});

  /// Доска показана колонкой внутри другого раздела, а не отдельным экраном.
  ///
  /// В этом виде своих `Scaffold` и `AppBar` у неё нет — их рисует раздел, — а группировка,
  /// сортировка и обновление уезжают в строку фильтров.
  final bool embedded;

  /// Отдать пул-реквест агенту силами раздела, в который встроена доска.
  ///
  /// Нужно, чтобы в «Проектах» разговор открывался в правой панели рядом со списком, а не
  /// экраном поверх него. `null` — доска поднимает сессию сама ([startAgentSession]).
  ///
  /// Первым аргументом идёт имя разговора (`repo#123`), вторым — текст просьбы.
  final Future<void> Function(String sessionName, String prompt)? onReview;

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

  /// Когда приехал показанный снимок; `null` — данных ещё нет.
  DateTime? _loadedAt;

  /// Окно свежести с мака: в списке нет PR, которых месяц никто не трогал, и это видно в шапке.
  int _freshDays = 0;

  @override
  void initState() {
    super.initState();
    final cached = ref.read(_boardCacheProvider).value;
    if (cached != null) {
      _all = cached.pulls;
      _repos = cached.repos;
      _err = cached.error;
      _loadedAt = cached.loadedAt;
      _freshDays = cached.freshDays;
    } else {
      _load();
    }
  }

  /// Загружает снимок с мака и кладёт его в кэш.
  ///
  /// Вызывается только руками — при первом открытии за сеанс и по кнопке «Обновить»; каждый
  /// такой вызов просит мак сходить в GitHub заново (`refresh=1`), иначе кнопка обновления
  /// возвращала бы тот же ответ из минутного кэша панели.
  Future<void> _load() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final d = await ref.read(appStateProvider).api.macPullRequests(refresh: true);
      final list = (d['pulls'] is List) ? (d['pulls'] as List) : const [];
      final repos = (d['repos'] is List) ? (d['repos'] as List) : const [];
      final board = _Board(
        list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList(),
        repos.whereType<String>().toList(),
        d['ok'] == false ? '${d['msg'] ?? 'ошибка на маке'}' : null,
        DateTime.now(),
        d['fresh_days'] as int? ?? 0,
      );
      ref.read(_boardCacheProvider).value = board;
      if (!mounted) return;
      setState(() {
        _all = board.pulls;
        _repos = board.repos;
        _err = board.error;
        _loadedAt = board.loadedAt;
        _freshDays = board.freshDays;
      });
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Имя разговора для этого PR: по нему второе нажатие робота возвращает в ту же переписку.
  String _sessionName(Map<String, dynamic> row) => '${row['repo']}#${row['number']}';

  /// Готовая команда ревью для этого PR.
  String _reviewPrompt(Map<String, dynamic> row) =>
      '/pr-review ${row['url'] ?? ''} без оверинжиниринга, если есть замечания то автоматически '
      'review all и ченж реквест если нет замечаний аппрув ставить автоматом';

  /// Копирует готовую команду ревью для этого PR.
  Future<void> _copyReview(Map<String, dynamic> row) async {
    final url = '${row['url'] ?? ''}';
    if (url.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _reviewPrompt(row)));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Команда ревью скопирована: #${row['number']}')));
    }
  }

  /// Открывает новую сессию агента с готовой командой ревью в поле ввода.
  ///
  /// Мастер выбора папки и модели — тот же, что в «Проектах»: ревью просят у агента в той папке,
  /// где лежит репозиторий, и выбор харнесса/модели остаётся за человеком.
  /// Открывает разговор ревью для этого PR: уже начатый — продолжает, нового — заводит.
  Future<void> _reviewWithAgent(Map<String, dynamic> row) async {
    final url = '${row['url'] ?? ''}';
    if (url.isEmpty) return;
    final host = widget.onReview;
    if (host != null) {
      await host(_sessionName(row), _reviewPrompt(row));
      return;
    }
    await startAgentSession(
      context,
      ref,
      prompt: _reviewPrompt(row),
      sessionName: _sessionName(row),
    );
  }

  /// Меню строки: что можно сделать с этим пул-реквестом.
  Future<void> _actions(Map<String, dynamic> row) async {
    final task = '${row['task'] ?? ''}';
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.smart_toy_outlined),
              title: Text(_review(row) == null
                  ? 'Ревью агентом · ${_sessionName(row)}'
                  : 'Вернуться в разговор · ${_sessionName(row)}'),
              onTap: () {
                Navigator.pop(sheet);
                _reviewWithAgent(row);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Скопировать команду ревью'),
              onTap: () {
                Navigator.pop(sheet);
                _copyReview(row);
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: Text('Открыть PR #${row['number']}'),
              onTap: () {
                Navigator.pop(sheet);
                _open('${row['url'] ?? ''}');
              },
            ),
            if (task.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.task_alt),
                title: Text('Открыть $task в Jira'),
                onTap: () {
                  Navigator.pop(sheet);
                  _open('${row['task_url']}');
                },
              ),
          ],
        ),
      ),
    );
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
    // Список разговоров нужен строкам: по нему видно, заведено ли ревью и работает ли агент
    ref.watch(agentSessionsProvider);
    if (widget.embedded) return _body();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Пул-реквесты'),
        actions: _actionButtons(),
      ),
      body: _body(),
    );
  }

  /// Кнопки управления списком: группировка, сортировка, обновление.
  List<Widget> _actionButtons({double size = 24}) => [
        PopupMenuButton<_Group>(
          tooltip: 'Группировка',
          initialValue: _group,
          icon: Icon(Icons.segment, size: size),
          onSelected: (v) => setState(() => _group = v),
          itemBuilder: (_) => [
            for (final g in _Group.values) PopupMenuItem(value: g, child: Text(g.label)),
          ],
        ),
        PopupMenuButton<_Sort>(
          tooltip: 'Сортировка',
          initialValue: _sort,
          icon: Icon(Icons.sort, size: size),
          onSelected: (v) => setState(() => _sort = v),
          itemBuilder: (_) => [
            for (final s in _Sort.values) PopupMenuItem(value: s, child: Text(s.label)),
          ],
        ),
        IconButton(
          tooltip: 'Обновить',
          onPressed: _busy ? null : _load,
          icon: Icon(Icons.refresh, size: size),
        ),
      ];

  /// Содержимое доски: фильтры, счётчик и список.
  Widget _body() {
    final all = _all;
    final rows = _filtered();
    return _err != null && all == null
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
                          Text(
                              '${rows.length} из ${all.length}'
                              '${_freshDays > 0 ? ' · за $_freshDays дн.' : ''}'
                              '${_loadedAt == null ? '' : ' · ${_time(_loadedAt!)}'}',
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
                        onRefresh: _load,
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
          if (widget.embedded) ...[
            ..._actionButtons(size: 20),
            const SizedBox(width: 6),
          ],
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

  /// Разговор ревью этого PR, если он уже заведён.
  AgentSession? _review(Map<String, dynamic> row) =>
      findReviewSession(ref, _sessionName(row));

  /// Строка одного PR: задача, заголовок и таймлайн событий.
  ///
  /// Итогового состояния ревью в строке нет: по нему фильтруют чипами сверху, а глазами всё
  /// равно читают историю — кто когда запросил изменения, сколько было комментариев и что
  /// было после них. Поэтому вместо набора ярлыков-состояний строка показывает ленту событий.
  Widget _rowTile(Map<String, dynamic> row) {
    final task = '${row['task'] ?? ''}';
    final pushedAfterMyCr = row['pushed_after_my_cr'] == true;
    final review = _review(row);
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      // Мой запрос изменений, на который уже запушили правки — единственное состояние доски,
      // требующее действия именно от меня, поэтому подсвечена вся строка, а не только ярлык.
      tileColor: pushedAfterMyCr ? _recheck.withValues(alpha: 0.12) : null,
      title: Text('#${row['number']} ${row['title']}', maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Wrap(
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
              if (row['draft'] == true) _badge('черновик', const Color(0xFFB388FF)),
              if (pushedAfterMyCr) _badge('пушили после моего ЧР', _recheck),
              if (review != null)
                _badge(
                  review.busy ? 'агент работает' : 'ревью · ${review.messages} сообщ.',
                  review.busy ? const Color(0xFF26C6DA) : const Color(0xFF9CCC65),
                ),
            ],
          ),
          _timelineStrip(row),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: review == null ? 'Отдать на ревью агенту' : 'Вернуться в разговор ревью',
            visualDensity: VisualDensity.compact,
            onPressed: () => _reviewWithAgent(row),
            icon: Icon(
              review == null ? Icons.smart_toy_outlined : Icons.smart_toy,
              size: 18,
              color: review == null ? null : const Color(0xFF9CCC65),
            ),
          ),
          const Icon(Icons.open_in_new, size: 18),
        ],
      ),
      onTap: () => _open('${row['url'] ?? ''}'),
      onLongPress: () => _actions(row),
    );
  }

  /// Лента событий пул-реквеста: запросы изменений, комментарии, апрувы, пуши по порядку.
  ///
  /// Мак отдаёт события уже свёрнутыми: подряд идущие комментарии — один шаг со счётчиком,
  /// подряд идущие коммиты одной отправки — один пуш. Здесь остаётся нарисовать их слева
  /// направо в одну строку: история не переносится и не режется, длинную прокручивают пальцем.
  ///
  /// `reverse: true` — это не обратный порядок событий, а начальное положение прокрутки: лента
  /// открыта на конце, где лежит самое свежее, и листается влево в прошлое. Так не нужен
  /// контроллер на строку и прыжок в конец после первого кадра.
  Widget _timelineStrip(Map<String, dynamic> row) {
    final raw = (row['timeline'] is List) ? (row['timeline'] as List) : const [];
    final events = raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    if (events.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 3,
          children: [for (final event in events) _eventChip(event)],
        ),
      ),
    );
  }

  /// Один шаг ленты: подпись со счётчиком, цвет по виду события, во всплывашке — кто и когда.
  Widget _eventChip(Map<String, dynamic> event) {
    final kind = '${event['k'] ?? ''}';
    final count = event['n'] as int? ?? 1;
    final by = '${event['by'] ?? ''}';
    final at = '${event['at'] ?? ''}';
    final (label, color) = switch (kind) {
      'cr' => ('ЧР', Theme.of(context).colorScheme.error),
      'approve' => ('апрув', const Color(0xFF4CAF50)),
      'dismissed' => ('ЧР снят', const Color(0xFF90A4AE)),
      'comment' => ('💬', const Color(0xFF42A5F5)),
      'push' => ('⬆', const Color(0xFFFFB300)),
      _ => (kind, const Color(0xFF90A4AE)),
    };
    final text = count > 1 ? '$label$count' : label;
    final when = _eventTime(at);
    final who = [if (by.isNotEmpty) by, if (when.isNotEmpty) when].join(' · ');
    final chip = _badge(text, color);
    return who.isEmpty ? chip : Tooltip(message: who, child: chip);
  }

  /// Дата события в виде `ДД.ММ ЧЧ:ММ` по местному времени; пустая строка, если её не разобрать.
  String _eventTime(String iso) {
    final at = DateTime.tryParse(iso)?.toLocal();
    if (at == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.day)}.${two(at.month)} ${two(at.hour)}:${two(at.minute)}';
  }

  /// Цвет «нужно перепроверить»: не совпадает ни с одним состоянием ревью, чтобы строка,
  /// ждущая меня, не путалась с обычным ЧР.
  static const _recheck = Color(0xFFEC407A);

  /// Короткий цветной ярлык.
  ///
  /// Подложка и рамка одного цвета с текстом: на тёмной теме приглушённый серый ярлык
  /// сливался с фоном, и «без ревью» читалось хуже всех — а это как раз то, что ищут глазами.
  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.22),
          border: Border.all(color: color.withValues(alpha: 0.7)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w600)),
      );

  /// Время снимка в виде `ЧЧ:ММ` — на телефоне дата не нужна, список живёт часы.
  String _time(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
}
