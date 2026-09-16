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
///
/// Предел заодно останавливает обход: на телефоне с сотнями тысяч папок поиск по частому
/// запросу («dcim») нашёл бы десятки тысяч совпадений и держал бы диск занятым минутами.
/// О том, что список усечён, экран говорит в подписи под строкой поиска.
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
///
/// Открывается из «Настроек» → «Синхронизация» (см. `features/settings/sync_panel.dart`)
/// отдельно для каждого раздела: [section] определяет и набор выбранных папок, и подписи
/// на экране.
///
/// Второй режим — [FolderTreeScreen.pick]: выбрать одну папку и вернуть её путь. Так
/// выбирается папка устройства для связки (см. `features/settings/sync_links_screen.dart`):
/// связка — это ровно одна пара папок, поэтому отметка тут одиночная и в настройки раздела
/// не пишется вовсе.
class FolderTreeScreen extends ConsumerStatefulWidget {
  /// [section] — какой раздел настраивается: у «Файлов» и «Фото» свои наборы папок, и один
  /// экран обслуживает оба, потому что поведение у них одинаковое.
  const FolderTreeScreen({super.key, required this.section}) : pick = false;

  /// Выбор одной папки устройства: экран закрывается с выбранным путём
  /// (`Navigator.pop<String>(path)`), ничего не записывая в настройки раздела.
  const FolderTreeScreen.pick({super.key})
    : section = Section.files,
      pick = true;

  final Section section;

  /// Режим выбора одной папки вместо набора папок раздела.
  final bool pick;

  @override
  ConsumerState<FolderTreeScreen> createState() => _FolderTreeScreenState();
}

/// Состояние экрана: раскрытые узлы, кэш прочитанных подпапок, выбор и поиск.
///
/// Всё это живёт только пока экран открыт: выбор хранится в настройках (через
/// `SyncController.selection`), а кэш подпапок и раскрытие — состояние показа, а не данные.
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

  /// Текущий выбор раздела — копия того, что лежит в настройках. Копия нужна, чтобы галочки
  /// отзывались сразу, не дожидаясь чтения настроек.
  Set<String> _chosen = const {};

  /// Выбор менялся: наполнять очередь при выходе нужно только тогда.
  bool _dirty = false;

  /// Корни томов с уже прочитанными подпапками первого уровня и признак, что они ещё грузятся.
  List<FolderNode> _roots = const [];
  bool _loadingRoots = true;

  /// Пересборка наблюдения и очереди уже запускалась: второй раз при выходе её не нужно —
  /// экран можно закрыть двумя способами («Готово» и системная кнопка «назад»), и оба зовут
  /// [_apply].
  bool _applied = false;

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

  /// Первый кадр: подставляем уже сделанный выбор и читаем корни томов.
  ///
  /// Выбор берётся из контроллера, а не из настроек напрямую: контроллер уже прочитал их при
  /// запуске, и второй раз то же самое читать незачем.
  @override
  void initState() {
    super.initState();
    // выбор уже мог быть сделан раньше: показываем его, а не пустое дерево. В режиме выбора
    // одной папки показывать нечего: там выбор начинается с пустого места, и в настройках
    // раздела он не лежит
    _chosen = widget.pick
        ? const <String>{}
        : (_sync.selection?.paths(widget.section) ?? const <String>{});
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

  /// Галочка: отметка вбирает поддерево, снятие внутри выбранной папки раскрывает предка.
  ///
  /// В режиме выбора одной папки отметка просто переезжает на тронутый узел: связка — это
  /// одна пара папок, и записывать тут нечего — выбор забирает вызывающий экран.
  Future<void> _toggle(FolderNode node) async {
    if (widget.pick) {
      setState(() => _chosen = {node.path});
      return;
    }
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
        cache[dir] = (await device.subdirs(dir)).paths;
      }
      dir = p.dirname(dir);
    }
    return (String key) => cache[key] ?? const <String>[];
  }

  /// Снять весь выбор раздела: [SelectionRules] очищается целиком, в настройках остаётся пустой
  /// список. Следствие — при выходе с экрана очередь пересобирается заново, и строки снятых
  /// папок из неё уходят (см. [_apply]).
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
  ///
  /// Зовётся при выходе с экрана (`PopScope` и кнопка «Готово»), поэтому у неё есть особенность:
  /// если приложение свернули или убили прямо на этом экране, пересборка наблюдения и очереди
  /// не произойдёт вовсе — до следующего запуска приложения (там её сделает `SyncController`
  /// при старте). Выбор при этом не теряется: он пишется в настройки сразу при каждой галочке.
  Future<void> _apply() async {
    // Режим одиночного выбора в настройки раздела ничего не пишет: пересобирать наблюдение
    // и очередь тут не от чего — связку применяет экран, который этот выбор забрал
    if (widget.pick) return;
    if (_applied || !_dirty) return;
    _applied = true;
    await _sync.onSelectionChanged(widget.section);
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

  /// Заголовок экрана: он же отличает, какой раздел настраивается — «Файлы» или «Фото» —
  /// и что это вообще за экран, когда выбирают одну папку.
  String get _title => widget.pick
      ? 'Папка на устройстве'
      : switch (widget.section) {
          Section.photos => 'Папки для фото и видео',
          Section.files => 'Папки для файлов',
        };

  /// Как называется раздел в основном интерфейсе: подсказка на экране должна называть его
  /// теми же словами, иначе человек ищет вкладку, которой нет.
  String get _sectionHint => switch (widget.section) {
    Section.photos => '«Фото и видео»',
    Section.files => '«Файлы»',
  };

  /// Сборка экрана: дерево или результаты поиска, подсказка о доступе и панель действий.
  ///
  /// `PopScope` вместо кнопки «назад» в шапке: экран закрывают и системным жестом, и в обоих
  /// случаях выбор надо применить — иначе снятая галочка осталась бы только в настройках,
  /// а очередь и наблюдение за папками остались бы прежними (см. [_apply]).
  @override
  Widget build(BuildContext context) {
    // за доступом следим отдельно: дерево перерисовывается на каждый статус зеркала,
    // а доступ меняется только когда человек вернулся из системных настроек
    final access = ref.watch(syncControllerProvider.select((c) => c.access));
    final matches = _matches;
    // Поиск показывается вместо дерева, а не поверх: совпадения лежат в разных местах дерева,
    // и вперемешку с ним они читались бы как один список
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
                    : widget.pick
                    ? _chosen.first
                    : 'выбрано папок: ${_chosen.length}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: C.fg3, fontSize: 11),
              ),
            ],
          ),
          actions: [
            // В режиме выбора одной папки кнопка одна: закрыть экран с выбранным путём.
            // «Снять всё» и «Готово» здесь не нужны — выбор не набор, а одна пара папок
            if (widget.pick)
              TextButton(
                onPressed: _chosen.isEmpty ? null : _confirmPick,
                child: const Text('Выбрать'),
              )
            else ...[
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
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Text(
                widget.pick
                    ? 'Отметьте папку, содержимое которой поедет в выбранную папку облака. '
                          'Отмеченная папка включает все вложенные.'
                    : 'Отмеченная папка включает все вложенные. Содержимое этих папок '
                          'появится в разделе $_sectionHint.',
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
                          // в режиме одной папки частичной отметки не бывает: поддерево
                          // не вбирается, отметка стоит ровно на одном узле
                          partly:
                              !widget.pick &&
                              !SelectionRules.isCovered(_chosen, node.path) &&
                              SelectionRules.hasInside(_chosen, node.path),
                          pick: widget.pick,
                          expandable: matches == null && _canExpand(node.path),
                          expanded: _expanded.contains(node.path),
                          busy: _busyDirs.contains(node.path),
                          unreadable: _unreadable.contains(node.path),
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
          hintText: 'поиск папки по всему телефону',
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

/// Строка дерева: стрелка раскрытия, отметка и путь.
///
/// Тап по строке ставит или снимает галочку — так же, как в нативном клиенте: попадать
/// пальцем в небольшой квадратик галочки на телефоне неудобно. В режиме выбора одной папки
/// вместо галочки кружок: он и показывает, что отметить можно ровно одну папку.
class _FolderRow extends StatelessWidget {
  /// [covered] — папка выбрана (или покрыта выбранным предком), [partly] — внутри неё есть
  /// выбранные (галочка в промежуточном состоянии), [expandable] и [expanded] — про стрелку,
  /// [busy] — подпапки читаются прямо сейчас, [unreadable] — папку не удалось прочитать
  /// (нет доступа): об этом в строке написано словами, иначе пустая папка и закрытая
  /// выглядели бы одинаково. [pick] — режим выбора одной папки: отметка рисуется кружком.
  const _FolderRow({
    required this.node,
    required this.covered,
    required this.partly,
    required this.pick,
    required this.expandable,
    required this.expanded,
    required this.busy,
    required this.unreadable,
    required this.onToggle,
    required this.onExpand,
  });

  final FolderNode node;
  final bool covered;
  final bool partly;
  final bool pick;
  final bool expandable;
  final bool expanded;
  final bool busy;
  final bool unreadable;
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
            if (pick)
              Icon(
                covered
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: covered ? C.accent : C.fg3,
              )
            else
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
