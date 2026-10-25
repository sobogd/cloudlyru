import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../providers.dart';
import '../../theme.dart';
import '../../util/widgets.dart';
import '../data/selection_rules.dart';
import '../device/device_files.dart';
import '../sync_controller.dart';

/// Сколько совпадений показываем в поиске: больше в ручном листании всё равно не нужно.
///
/// Предел заодно останавливает обход: на телефоне с сотнями тысяч папок поиск по частому
/// запросу («dcim») нашёл бы десятки тысяч совпадений и держал бы диск занятым минутами.
/// О том, что список усечён, экран говорит в подписи под строкой поиска.
const int _searchLimit = 500;

/// Выбор одной папки устройства: дерево телефона, отметка — радиокнопкой.
///
/// Экран отдельный, а не диалог: дерево большое, в окне поверх интерфейса его не показать.
/// Отмеченная папка вбирает всё поддерево — связка синхронизирует её целиком.
///
/// Дерево ленивое: подпапки читаются при раскрытии узла, а не обходом всего телефона —
/// на телефоне десятки тысяч папок, и ждать их ради первого экрана нельзя. Полный обход
/// нужен только поиску, и он идёт по вводу запроса, с прогрессом и кнопкой «стоп».
///
/// Выбор не пишет ничего в настройки: экран закрывается с выбранным путем
/// (`Navigator.pop<String>(path)`), а связку создаёт вызывающий
/// (`features/settings/sync_links_screen.dart`) — связка это ровно одна пара папок.
///
/// ОСОБЫЙ случай — iOS. Там дерева файловой системы нет вовсе: приложение заперто в своей
/// песочнице, и папку можно только выбрать в системном «Файлах» (см. `device/ios_folders.dart`).
/// Поэтому корнями становятся выбранные папки, а вместо блуждания по диску на экране есть
/// кнопка «Добавить» — и та же отметка, что и везде: выбранное поддерево внутри папки
/// отмечается как обычно, потому что внутри неё обычный Dart уже всё видит.
class FolderTreeScreen extends ConsumerStatefulWidget {
  const FolderTreeScreen.pick({super.key});

  @override
  ConsumerState<FolderTreeScreen> createState() => _FolderTreeScreenState();
}

/// Состояние экрана: раскрытые узлы, кэш прочитанных подпапок, выбор и поиск.
///
/// Всё это живёт только пока экран открыт: выбор забирает вызывающий экран, а кэш подпапок
/// и раскрытие — состояние показа, а не данные.
class _FolderTreeScreenState extends ConsumerState<FolderTreeScreen> {
  /// Раскрытые узлы: что именно раскрыто — состояние экрана, а не выбора папок.
  final Set<String> _expanded = {};

  /// Прочитанные подпапки: путь → узлы. Кэш на время жизни экрана.
  final Map<String, List<FolderNode>> _children = {};

  /// Папки, которые не удалось прочитать: «нет доступа» и «пусто» — разные вещи, и человек
  /// должен видеть, какая именно папка не открылась, а не решать, что она пустая.
  final Set<String> _unreadable = {};

  /// Что читается прямо сейчас: у таких узлов вместо стрелки показываем точку ожидания.
  final Set<String> _busyDirs = {};

  /// Текущий выбор экрана — одна папка (или пусто). Копия нужна, чтобы отметка отзывалась
  /// сразу, не дожидаясь чтения настроек (которых тут и нет: в настройки записывает
  /// вызывающий экран).
  Set<String> _chosen = const {};

  /// Корни томов с уже прочитанными подпапками первого уровня и признак, что они ещё грузятся.
  List<FolderNode> _roots = const [];
  bool _loadingRoots = true;

  /// Поле поиска и его состояние: [Timer] для выдержки на ввод, найденные совпадения (null —
  /// поиск не идёт и показывается дерево), флаг обхода и подпись о ходе поиска.
  final TextEditingController _search = TextEditingController();
  Timer? _searchDebounce;

  /// Совпадения поиска: `null` — поиска нет, показывается обычное дерево; пустой список —
  /// поиск шёл и ничего не нашёл.
  List<FolderNode>? _matches;
  bool _searching = false;

  /// Обход просят остановиться: ставится кнопкой «стоп», закрытием экрана и новым вводом.
  /// Проверяется внутри обхода, поэтому остановка происходит на ближайшей папке.
  bool _cancelSearch = false;
  String? _searchNote;

  /// Контроллер синхронизации: у него берутся чтение диска ([DeviceFiles]), текущий выбор папок
  /// и единственный вызов, который пересобирает очередь.
  SyncController get _sync => ref.read(syncControllerProvider);

  /// iOS: папки не обходятся, а выбираются в системном «Файлах» — у экрана другой вход
  /// (кнопка «Добавить»), другое пустое состояние и своя подсказка.
  bool get _ios => Platform.isIOS;

  /// Добавить папку через системный выбор «Файлов» (iOS).
  ///
  /// После выбора корни перечитываются: нативная часть (см. `ios/Runner/FolderAccess.swift`)
  /// уже открыла доступ к папке, и она появляется в дереве — с подпапками, которые читаются
  /// обычными средствами Dart, как и всё остальное в дереве.
  Future<void> _addFolder() async {
    final picked = await _sync.files.pickFolder();
    if (!mounted || picked == null) return;
    await _loadRoots();
  }

  /// Забыть папку (iOS): доступ к ней закрывается, и она исчезает из списка навсегда.
  ///
  /// Подтверждение обязательно: вместе с папкой уходит право на доступ, а вернуть его можно
  /// только выбором заново — то есть человеком, а не приложением.
  ///
  /// Если внутри забытой папки лежал выбор раздела, он снимается. Это не педантизм: зеркало
  /// считает исчезнувшую папку удалением и убрало бы её содержимое из облака — ровно то,
  /// чего от «забыть папку» никто не ждёт (см. `MirrorEngine`).
  Future<void> _forgetFolder(String path) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Забыть папку?'),
        content: Text(
          '$path\n\nДоступ к ней закроется, и вернуть его можно только выбором заново. '
          'Папка исчезнет из списка, а её содержимое — из выбранных для синхронизации.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Забыть'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _sync.files.forgetFolder(path);
    if (!mounted) return;
    await _loadRoots();
  }

  /// Первый кадр: читаем корни томов. Выбор начинается с пустого места: в этот экран он
  /// не вносится, и в настройки раздела он не пишется.
  @override
  void initState() {
    super.initState();
    _search.addListener(_onQueryChanged);
    unawaited(_loadRoots());
  }

  /// Экран закрывается: гасим выдержку поиска и просим идущий обход остановиться.
  ///
  /// `dispose` не может ждать (`Future` тут возвращать некуда), поэтому обходу только выставляется
  /// флаг: он проверяется на каждой папке, и обход заканчивается сам, не тронув уничтоженное
  /// состояние.
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
      _children[root.path] = _childNodes(kids.paths, 1);
      if (kids.unreadable) _unreadable.add(root.path);
      nodes.add(FolderNode(root.path, root.name, 0, kids.paths.isNotEmpty));
    }
    if (!mounted) return;
    setState(() {
      _roots = nodes;
      _loadingRoots = false;
    });
  }

  /// Подпапки пути превращаются в узлы дерева. Уровень приходит аргументом: он нужен только
  /// для отступа на экране, и вычислять его из пути значило бы разбирать путь второй раз.
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

  /// Раскрыть или свернуть узел; подпапки читаются один раз и остаются в кэше до закрытия экрана.
  ///
  /// Пока чтение идёт, узел помечен в `_busyDirs` — стрелка заменяется точкой ожидания, и
  /// повторный тап по ней невозможен. Проверка `mounted` после чтения обязательна: человек
  /// мог закрыть экран за это время, и `setState` на уничтоженном состоянии был бы ошибкой.
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
      _children[node.path] = _childNodes(kids.paths, node.depth + 1);
      _busyDirs.remove(node.path);
      // признак отказа обновляем каждый раз: доступ могли выдать или отозвать, пока экран открыт
      if (kids.unreadable) {
        _unreadable.add(node.path);
      } else {
        _unreadable.remove(node.path);
      }
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

  /// Отметка: одна папка, и переезжает на тронутый узел. Записывать нечего — выбор забирает
  /// вызывающий экран при закрытии ([_confirmPick]).
  void _toggle(FolderNode node) {
    setState(() => _chosen = {node.path});
  }

  /// Ввод в поиске: перезапускаем выдержку. Она нужна, потому что поиск — это обход всего
  /// телефона, и запускать его на каждую букву значило бы обходить диск столько раз, сколько
  /// символов набрал человек. 350 мс — пауза, после которой ввод считается законченным.
  void _onQueryChanged() {
    _searchDebounce?.cancel();
    // поиск обходит диск целиком: пока человек печатает, обход запускать бессмысленно
    _searchDebounce = Timer(const Duration(milliseconds: 350), _runSearch);
  }

  /// Поиск по всему телефону: ленивое дерево не знает о папках, которые ещё не раскрыты.
  /// Обход отменяемый — на десятках тысяч папок без этого экран пришлось бы закрывать.
  ///
  /// Запрос короче двух символов поиском не считается: одна буква совпала бы почти со всеми
  /// папками, и результат был бы бесполезен. Совпадение ищется и по имени, и по полному пути —
  /// так находится папка, имя которой человек помнит лишь частью (`DCIM/Camera`).
  ///
  /// Итог поиска кладётся в `_matches`; [SyncController] он не трогает: поиск показывает папки,
  /// а не меняет выбор.
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
      // (500 папок — примерно раз в секунду на телефоне), а на каждой папке это был бы
      // setState чаще, чем экран успевает отрисоваться
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

  /// Закрыть экран с выбранной папкой. Связку создаёт вызывающий: этот экран знает только
  /// путь на телефоне, а пару «устройство ↔ облако» собирает экран связок.
  void _confirmPick() {
    if (_chosen.length != 1) return;
    Navigator.of(context).pop(_chosen.first);
  }

  /// Заголовок экрана: одна и та же подпись — экран выбирают только папку устройства.
  String get _title => 'Папка на устройстве';

  /// Сборка экрана: дерево или результаты поиска, подсказка о доступе и панель действий.
  @override
  Widget build(BuildContext context) {
    // за доступом следим отдельно: дерево перерисовывается на каждый статус зеркала,
    // а доступ меняется только когда человек вернулся из системных настроек
    final access = ref.watch(syncControllerProvider.select((c) => c.access));
    final matches = _matches;
    // Поиск показывается вместо дерева, а не поверх: совпадения лежат в разных местах дерева,
    // и вперемешку с ним они читались бы как один список
    final rows = matches ?? _visible;

    return Scaffold(
        appBar: AppBar(
          backgroundColor: C.canvas,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_title, style: const TextStyle(color: C.fg, fontSize: 17)),
              Text(
                _chosen.isEmpty ? 'ничего не выбрано' : _chosen.first,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: C.fg3, fontSize: 11),
              ),
            ],
          ),
          actions: [
            // iOS: папку негде искать обходом диска — её выбирают в системном «Файлах»,
            // поэтому вход в выбор здесь кнопкой, а не деревом
            if (_ios)
              TextButton(
                onPressed: () => unawaited(_addFolder()),
                child: const Text('Добавить'),
              ),
            // Одна кнопка: закрыть экран с выбранным путём. «Снять всё» и «Готово» не
            // нужны — выбор не набор, а одна пара папок
            TextButton(
              onPressed: _chosen.isEmpty ? null : _confirmPick,
              child: const Text('Выбрать'),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Text(
                _ios
                    ? 'Отметьте папку, содержимое которой поедет в выбранную папку облака. '
                          'Отмеченная папка включает все вложенные. Папки выбираются в '
                          'системном «Файлах»: обойти диск на iPad нельзя.'
                    : 'Отметьте папку, содержимое которой поедет в выбранную папку облака. '
                          'Отмеченная папка включает все вложенные.',
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
                          expandable: matches == null && _canExpand(node.path),
                          expanded: _expanded.contains(node.path),
                          busy: _busyDirs.contains(node.path),
                          unreadable: _unreadable.contains(node.path),
                          onToggle: () => _toggle(node),
                          onExpand: () => unawaited(_toggleExpand(node)),
                          // Забыть папку можно только у корня, и только на iOS: там корень —
                          // это выбранная в «Файлах» папка, и без этой кнопки убрать её
                          // из списка было бы нечем
                          onForget: _ios && node.depth == 0
                              ? () => unawaited(_forgetFolder(node.path))
                              : null,
                        );
                      },
                    ),
            ),
          ],
        ),
      );
  }

  /// Поле поиска. Крестик очистки появляется только когда есть что чистить, и очистка идёт
  /// через контроллер — тот же путь, что и обычный ввод, поэтому выдержка и обход отработают
  /// как обычно.
  ///
  /// `ValueListenableBuilder` вокруг поля, а не `setState` по вводу: крестик зависит от текста,
  /// и без него он появлялся бы только через выдержку поиска (350 мс), а после нажатия на
  /// крестик пропадал бы с той же задержкой. Слушатель контроллера (`_onQueryChanged`) при этом
  /// никуда не девается: сам поиск по-прежнему запускается с выдержкой, а не на каждую букву.
  Widget _searchField() {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _search,
      builder: (context, value, _) => TextField(
        controller: _search,
        decoration: InputDecoration(
          isDense: true,
          // на iOS обходить нечего: поиск идёт по выбранным папкам, и обещать «по всему
          // телефону» там было бы неправдой
          hintText: _ios ? 'поиск по выбранным папкам' : 'поиск папки по всему телефону',
          prefixIcon: const Icon(Icons.search, size: 20, color: C.fg3),
          suffixIcon: value.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18, color: C.fg3),
                  onPressed: () => _search.clear(),
                ),
        ),
        style: const TextStyle(color: C.fg, fontSize: 14),
      ),
    );
  }

  /// Пустой список строк. Кнопка «Открыть настройки» показывается только при известном отказе
  /// в доступе: если доступ есть, а папок нет — значит их правда нет, и звать в настройки незачем.
  ///
  /// На iOS пусто всегда означает одно и то же — папки ещё не выбраны, — и кнопка тут ведёт
  /// не в системные настройки, а в системный выбор папки.
  Widget _empty(SyncAccess access) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _ios ? 'Папки не выбраны' : 'Папок не найдено',
            style: const TextStyle(color: C.fg, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            _ios
                ? 'Выберите папку в «Файлах» — её содержимое поедет в выбранную папку '
                      'облака. Обойти диск на iPad нельзя: система не выпускает '
                      'приложение за пределы его хранилища.'
                : 'Скорее всего у приложения нет доступа ко всем файлам.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: C.fg3, fontSize: 12),
          ),
          if (_ios) ...[
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => unawaited(_addFolder()),
              child: const Text('Выбрать папку'),
            ),
          ] else if (access == SyncAccess.denied) ...[
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

/// Строка дерева: стрелка раскрытия, отметка и путь.
///
/// Тап по строке ставит отметку — так же, как в нативном клиенте: попадать пальцем в
/// небольшой квадратик отметки на телефоне неудобно. Отметка рисуется кружком: он
/// показывает, что отметить можно ровно одну папку.
class _FolderRow extends StatelessWidget {
  /// [covered] — папка выбрана, [expandable] и [expanded] — про стрелку,
  /// [busy] — подпапки читаются прямо сейчас, [unreadable] — папку не удалось прочитать
  /// (нет доступа): об этом в строке написано словами, иначе пустая папка и закрытая
  /// выглядели бы одинаково.
  const _FolderRow({
    required this.node,
    required this.covered,
    required this.expandable,
    required this.expanded,
    required this.busy,
    required this.unreadable,
    required this.onToggle,
    required this.onExpand,
    this.onForget,
  });

  final FolderNode node;
  final bool covered;
  final bool expandable;
  final bool expanded;
  final bool busy;
  final bool unreadable;
  final VoidCallback onToggle;
  final VoidCallback onExpand;

  /// Убрать папку из списка (iOS): `null` — у этой строки такого действия нет.
  final VoidCallback? onForget;

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
            const SizedBox(width: 40),
            Icon(
              covered
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: covered ? C.accent : C.fg3,
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
                  if (unreadable)
                    const Text(
                      'папка не открылась: нет доступа',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: C.danger, fontSize: 10),
                    ),
                ],
              ),
            ),
            if (onForget != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Забыть папку',
                onPressed: onForget,
                icon: const Icon(Icons.close, size: 18, color: C.fg3),
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
  /// [onOpen] — открыть системный экран выдачи доступа: тот же обработчик, что у кнопки
  /// в пустом списке, и он же уходит в `SyncController.requestAccess`.
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
