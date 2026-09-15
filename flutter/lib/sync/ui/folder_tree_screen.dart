import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../providers.dart';
import '../../theme.dart';
import '../../util/widgets.dart';
import '../data/selection_rules.dart';
import '../device/device_files.dart';
import '../section.dart';
import '../sync_controller.dart';

/// Сколько совпадений показываем в поиске: больше в ручном листании всё равно не нужно.
const int _searchLimit = 500;

/// Выбор папок раздела: дерево телефона, отметка ставится галочкой.
///
/// Экран отдельный, а не диалог: дерево большое, в окне поверх интерфейса его не показать.
/// Отмеченная папка вбирает всё поддерево. Если снять галочку внутри отмеченной папки,
/// выбранный предок «раскрывается» — иначе снять отметку с части дерева было бы нечем.
///
/// Дерево ленивое: подпапки читаются при раскрытии узла, а не обходом всего телефона —
/// на телефоне десятки тысяч папок, и ждать их ради первого экрана нельзя. Полный обход
/// нужен только поиску, и он идёт по вводу запроса, с прогрессом и кнопкой «стоп».
///
/// Сам выбор пишется в настройки сразу (это дёшево), а вот [SyncController.onSelectionChanged]
/// — это обход диска и пересборка очереди. Его вызываем один раз при выходе с экрана: дёргать
/// проход на каждую галочку значило бы сканировать телефон десятки раз подряд.
class FolderTreeScreen extends ConsumerStatefulWidget {
  const FolderTreeScreen({super.key, required this.section});

  final Section section;

  @override
  ConsumerState<FolderTreeScreen> createState() => _FolderTreeScreenState();
}

class _FolderTreeScreenState extends ConsumerState<FolderTreeScreen> {
  /// Раскрытые узлы: что именно раскрыто — состояние экрана, а не выбора папок.
  final Set<String> _expanded = {};

  /// Прочитанные подпапки: путь → узлы. Кэш на время жизни экрана.
  final Map<String, List<FolderNode>> _children = {};

  /// Что читается прямо сейчас: у таких узлов вместо стрелки показываем точку ожидания.
  final Set<String> _busyDirs = {};

  Set<String> _chosen = const {};

  /// Выбор менялся: наполнять очередь при выходе нужно только тогда.
  bool _dirty = false;

  List<FolderNode> _roots = const [];
  bool _loadingRoots = true;
  bool _applied = false;

  final TextEditingController _search = TextEditingController();
  Timer? _searchDebounce;
  List<FolderNode>? _matches;
  bool _searching = false;
  bool _cancelSearch = false;
  String? _searchNote;

  SyncController get _sync => ref.read(syncControllerProvider);

  @override
  void initState() {
    super.initState();
    // выбор уже мог быть сделан раньше: показываем его, а не пустое дерево
    _chosen = _sync.selection?.paths(widget.section) ?? const <String>{};
    _search.addListener(_onQueryChanged);
    unawaited(_loadRoots());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    // обход может идти прямо сейчас: просим его остановиться, иначе он продолжил бы
    // читать диск после закрытия экрана
    _cancelSearch = true;
    _search.dispose();
    super.dispose();
  }

  /// Корни выбора (внутренняя память и карты памяти) вместе с их подпапками.
  ///
  /// Подпапки корня читаем сразу: без них у корня не понять, есть ли что раскрывать,
  /// и стрелка у него врала бы — а корней всего два-три.
  Future<void> _loadRoots() async {
    final files = _sync.files;
    final roots = await files.roots();
    final nodes = <FolderNode>[];
    for (final root in roots) {
      final kids = await files.subdirs(root.path);
      _children[root.path] = _childNodes(kids, 1);
      nodes.add(FolderNode(root.path, root.name, 0, kids.isNotEmpty));
    }
    if (!mounted) return;
    setState(() {
      _roots = nodes;
      _loadingRoots = false;
    });
  }

  List<FolderNode> _childNodes(List<String> paths, int depth) => [
    for (final path in paths) FolderNode(path, p.basename(path), depth, false),
  ];

  /// Есть ли что раскрывать. Пока подпапки не прочитаны — считаем, что есть: у папки на
  /// телефоне почти всегда что-то лежит, а стрелка, пропадающая после раскрытия, честнее
  /// стрелки, которой не было вовсе.
  bool _canExpand(String path) {
    final known = _children[path];
    return known == null ? true : known.isNotEmpty;
  }

  Future<void> _toggleExpand(FolderNode node) async {
    if (_expanded.contains(node.path)) {
      setState(() => _expanded.remove(node.path));
      return;
    }
    setState(() => _expanded.add(node.path));
    if (_children.containsKey(node.path)) return;
    setState(() => _busyDirs.add(node.path));
    final kids = await _sync.files.subdirs(node.path);
    if (!mounted) return;
    setState(() {
      _children[node.path] = _childNodes(kids, node.depth + 1);
      _busyDirs.remove(node.path);
    });
  }

  /// Плоский список видимых строк: собирается по раскрытым узлам, диск не трогает.
  List<FolderNode> get _visible {
    final out = <FolderNode>[];
    void walk(FolderNode node) {
      out.add(node);
      if (!_expanded.contains(node.path)) return;
      for (final child in _children[node.path] ?? const <FolderNode>[]) {
        walk(child);
      }
    }

    for (final root in _roots) {
      walk(root);
    }
    return out;
  }

  /// Галочка: отметка вбирает поддерево, снятие внутри выбранной папки раскрывает предка.
  Future<void> _toggle(FolderNode node) async {
    final selection = _sync.selection;
    if (selection == null) return;
    final covered = SelectionRules.isCovered(_chosen, node.path);
    if (covered) {
      // раскрытие выбранного предка читает диск синхронным колбэком, поэтому подпапки
      // всех покрывающих предков читаем заранее
      final childDirsOf = await _childReaderFor(node.path);
      final next = await selection.unchoose(
        widget.section,
        node.path,
        childDirsOf,
      );
      if (!mounted) return;
      setState(() {
        _chosen = next;
        _dirty = true;
      });
    } else {
      final next = await selection.choose(widget.section, node.path);
      if (!mounted) return;
      setState(() {
        _chosen = next;
        _dirty = true;
      });
    }
  }

  /// Колбэк для [SelectionRules.unchoose]: он синхронный, а чтение диска — нет.
  ///
  /// Раскрывать приходится только предков пути, и только те, что покрыты выбором: правило
  /// поднимается от самой папки вверх, заменяя выбранного предка его прямыми подпапками.
  /// Прямые подпапки — это тоже предки пути, поэтому чтения хватает на всю цепочку.
  Future<List<String> Function(String)> _childReaderFor(String path) async {
    final device = _sync.files;
    final cache = <String, List<String>>{};
    var dir = p.dirname(path);
    while (dir.isNotEmpty && dir != p.dirname(dir)) {
      if (SelectionRules.isCovered(_chosen, dir)) {
        cache[dir] = await device.subdirs(dir);
      }
      dir = p.dirname(dir);
    }
    return (String key) => cache[key] ?? const <String>[];
  }

  Future<void> _clearAll() async {
    final selection = _sync.selection;
    if (selection == null) return;
    final next = await selection.clear(widget.section);
    if (!mounted) return;
    setState(() {
      _chosen = next;
      _dirty = true;
    });
  }

  /// Выход с экрана: пересобираем наблюдение за папками и наполняем очередь заново.
  ///
  /// Только если выбор и правда менялся: наполнение очереди — это обход всего телефона,
  /// и запускать его ради того, что человек только посмотрел на дерево, незачем.
  Future<void> _apply() async {
    if (_applied || !_dirty) return;
    _applied = true;
    await _sync.onSelectionChanged(widget.section);
  }

  void _onQueryChanged() {
    _searchDebounce?.cancel();
    // поиск обходит диск целиком: пока человек печатает, обход запускать бессмысленно
    _searchDebounce = Timer(const Duration(milliseconds: 350), _runSearch);
  }

  /// Поиск по всему телефону: ленивое дерево не знает о папках, которые ещё не раскрыты.
  /// Обход отменяемый — на десятках тысяч папок без этого экран пришлось бы закрывать.
  Future<void> _runSearch() async {
    final query = _search.text.trim().toLowerCase();
    if (query.length < 2) {
      setState(() {
        _matches = null;
        _searching = false;
        _searchNote = null;
      });
      return;
    }
    _cancelSearch = false;
    setState(() {
      _searching = true;
      _matches = const [];
      _searchNote = 'ищу папки…';
    });

    final files = _sync.files;
    final found = <FolderNode>[];
    var seen = 0;
    await for (final node in files.walkTree(
      await files.roots(),
      isCancelled: () => _cancelSearch || !mounted,
    )) {
      seen++;
      if (node.name.toLowerCase().contains(query) ||
          node.path.toLowerCase().contains(query)) {
        found.add(node);
        if (found.length >= _searchLimit) break;
      }
      // прогресс показываем пачками: обход идёт быстрее, чем успевают перерисовываться кадры
      if (seen % 500 == 0 && mounted) {
        setState(
          () => _searchNote =
              'ищу папки… просмотрено: $seen, найдено: ${found.length}',
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _searching = false;
      _matches = found;
      _searchNote = _cancelSearch
          ? 'поиск остановлен: найдено ${found.length}'
          : 'найдено: ${found.length}${found.length >= _searchLimit ? ' (показаны первые $_searchLimit)' : ''}';
    });
  }

  String get _title => switch (widget.section) {
    Section.photos => 'Папки для фото и видео',
    Section.files => 'Папки для файлов',
  };

  String get _sectionHint => switch (widget.section) {
    Section.photos => '«Фото и видео»',
    Section.files => '«Файлы»',
  };

  @override
  Widget build(BuildContext context) {
    // за доступом следим отдельно: дерево перерисовывается на каждый статус зеркала,
    // а доступ меняется только когда человек вернулся из системных настроек
    final access = ref.watch(syncControllerProvider.select((c) => c.access));
    final matches = _matches;
    final rows = matches ?? _visible;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(_apply());
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: C.canvas,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_title, style: const TextStyle(color: C.fg, fontSize: 17)),
              Text(
                _chosen.isEmpty
                    ? 'ничего не выбрано'
                    : 'выбрано папок: ${_chosen.length}',
                style: const TextStyle(color: C.fg3, fontSize: 11),
              ),
            ],
          ),
          actions: [
            if (_chosen.isNotEmpty)
              TextButton(onPressed: _clearAll, child: const Text('Снять всё')),
            TextButton(
              onPressed: () {
                unawaited(_apply());
                Navigator.of(context).pop();
              },
              child: const Text('Готово'),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Text(
                'Отмеченная папка включает все вложенные. Содержимое этих папок появится '
                'в разделе $_sectionHint.',
                style: const TextStyle(color: C.fg3, fontSize: 11),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              child: _searchField(),
            ),
            if (_loadingRoots || _searching)
              const LinearProgressIndicator(minHeight: 2),
            if (_searchNote != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _searchNote!,
                        style: const TextStyle(color: C.fg3, fontSize: 11),
                      ),
                    ),
                    if (_searching)
                      TextButton(
                        onPressed: () => setState(() => _cancelSearch = true),
                        child: const Text('Стоп'),
                      ),
                  ],
                ),
              ),
            if (access == SyncAccess.denied)
              _NoAccessHint(onOpen: () => _sync.requestAccess()),
            Expanded(
              child: rows.isEmpty && !_loadingRoots && !_searching
                  ? _empty(access)
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final node = rows[i];
                        return _FolderRow(
                          node: node,
                          covered: SelectionRules.isCovered(_chosen, node.path),
                          partly:
                              !SelectionRules.isCovered(_chosen, node.path) &&
                              SelectionRules.hasInside(_chosen, node.path),
                          expandable: matches == null && _canExpand(node.path),
                          expanded: _expanded.contains(node.path),
                          busy: _busyDirs.contains(node.path),
                          onToggle: () => unawaited(_toggle(node)),
                          onExpand: () => unawaited(_toggleExpand(node)),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchField() {
    return TextField(
      controller: _search,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'поиск папки по всему телефону',
        prefixIcon: const Icon(Icons.search, size: 20, color: C.fg3),
        suffixIcon: _search.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close, size: 18, color: C.fg3),
                onPressed: () => _search.clear(),
              ),
      ),
      style: const TextStyle(color: C.fg, fontSize: 14),
    );
  }

  Widget _empty(SyncAccess access) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Папок не найдено',
            style: TextStyle(color: C.fg, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          const Text(
            'Скорее всего у приложения нет доступа ко всем файлам.',
            textAlign: TextAlign.center,
            style: TextStyle(color: C.fg3, fontSize: 12),
          ),
          if (access == SyncAccess.denied) ...[
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => _sync.requestAccess(),
              child: const Text('Открыть настройки'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Строка дерева: стрелка раскрытия, галочка и путь.
///
/// Тап по строке ставит или снимает галочку — так же, как в нативном клиенте: попадать
/// пальцем в небольшой квадратик галочки на телефоне неудобно.
class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.node,
    required this.covered,
    required this.partly,
    required this.expandable,
    required this.expanded,
    required this.busy,
    required this.onToggle,
    required this.onExpand,
  });

  final FolderNode node;
  final bool covered;
  final bool partly;
  final bool expandable;
  final bool expanded;
  final bool busy;
  final VoidCallback onToggle;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: EdgeInsets.fromLTRB(4 + node.depth * 14, 2, 12, 2),
        child: Row(
          children: [
            if (expandable)
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: busy ? null : onExpand,
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        expanded ? Icons.expand_more : Icons.chevron_right,
                        color: C.fg3,
                        size: 20,
                      ),
              )
            else
              const SizedBox(width: 40),
            Checkbox(
              value: covered ? true : (partly ? null : false),
              tristate: true,
              onChanged: (_) => onToggle(),
            ),
            Icon(
              Icons.folder_outlined,
              size: 20,
              color: covered ? C.accent : C.fg3,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: C.fg, fontSize: 14),
                  ),
                  Text(
                    node.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: C.fg3, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Без доступа ко всем файлам дерева не видно вовсе: говорим об этом прямо, а не показываем
/// пустой список — пустой список выглядит как «на телефоне ничего нет».
class _NoAccessHint extends StatelessWidget {
  const _NoAccessHint({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Нужен доступ ко всем файлам',
              style: TextStyle(
                color: C.fg,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Без него не видно ни дерева папок, ни файлов.',
              style: TextStyle(color: C.fg3, fontSize: 12),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: onOpen,
              child: const Text('Открыть настройки'),
            ),
          ],
        ),
      ),
    );
  }
}
