import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../upload/upload_queue.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import 'file_detail.dart';
import 'folder_detail.dart';

/// Шаг пути к открытой папке: `id == null` — корень облака, `name` — то, что видно
/// в заголовке. Стек таких шагов и есть хлебные крошки экрана (отдельного виджета нет).
typedef Crumb = ({String? id, String name});

/// Сколько страниц листинга экран догружает сам за одну перечитку.
///
/// Сервер отдаёт содержимое папки страницами по 1000 записей на каждый список (см. `FolderView`)
/// и в каждой странице говорит, есть ли продолжение. Раньше экран читал только первую страницу,
/// и папка с 3000 файлов молча показывалась как папка с 1000. Предел нужен, чтобы «Фото» на
/// десятки тысяч записей не превращалось в поток запросов на каждое обновление: остаток
/// добирается кнопкой «Показать ещё» (см. [_FilesScreenState._loadMore]).
const _maxPagesPerLoad = 5;

/// Экран «Файлы»: один уровень облака за раз — папки сверху, файлы под ними.
///
/// Данные — `listFolder` по последнему шагу стека, страница за страницей, пока сервер не
/// скажет, что продолжения нет. Кэша нет намеренно: тот же уровень меняют синхронизатор
/// телефона и веб-клиент, а «что изменилось» сервер не рассказывает, поэтому каждый переход,
/// каждое возвращение с деталей и жест «потянуть вниз» перечитывают папку заново.
///
/// Экран же владеет двумя чужими состояниями: буфером обмена сервера (он общий для всех
/// устройств и переживает перезапуск, поэтому читается с сервера) и очередью загрузок —
/// ею экран только пользуется, панель прогресса живёт над списком и рисуется из очереди.
class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key});

  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

/// Состояние списка: где мы стоим, что ответил сервер и чем закончилась последняя операция.
class _FilesScreenState extends ConsumerState<FilesScreen> {
  /// Путь от корня к открытой папке, последний шаг — текущая папка. Живёт в состоянии,
  /// а не в навигаторе: уровни не отдельные маршруты, поэтому системный «назад» уводит
  /// из вкладки, а на уровень выше ведёт стрелка в AppBar.
  List<Crumb> _stack = const [(id: null, name: 'Главная')];
  /// Ответ сервера на текущий уровень: папки, файлы и id этой самой папки (нужен как адрес
  /// для вставки и загрузки).
  FolderView? _view;
  /// Текст последней неудачи. Показывается строкой над списком и список не сбрасывает:
  /// ошибка одной операции не должна выглядеть как «папка пуста».
  String? _error;
  /// Результат удачной операции («Скопировано: …»). В отличие от ошибки живёт до следующего
  /// действия — сообщать о вставке больше нечем, тостов на этом экране нет.
  String? _notice;
  /// Буфер обмена сервера: что и как вставлять, знает только он.
  ClipboardView? _clip;
  /// Корень зоны «Фото». Из «Файлов» его прячем: это служебная папка медиатеки, её содержимое
  /// показывают вкладки «Фото» и «Медиа», а в дереве файлов она выглядела бы обычной папкой.
  String? _photoFolderId;
  /// Курсор продолжения листинга: имя записи, с которой начинается не загруженная ещё страница.
  /// `null` — сервер отдал всё, что есть (или первая страница ещё не пришла).
  String? _more;
  /// Идёт операция над файлами (вставка буфера, создание папки, догрузка страницы): пока она
  /// в полёте, кнопки выключены. Без этого второе нажатие «Вставить» отправило бы на сервер
  /// вторую копию того же самого, а повторная догрузка — тот же запрос дважды.
  bool _busy = false;

  /// Папка, открытая сейчас: id последнего шага стека (`null` — корень).
  String? get _currentId => _stack.last.id;

  @override
  /// Первое заполнение экрана: кто пользователь, где мы стоим, что лежит в буфере обмена.
  void initState() {
    super.initState();
    // Пользователь и настройки к этому моменту уже подняты: вкладка строится только после
    // восстановления сессии, см. providers.dart.
    final state = ref.read(appStateProvider);
    _photoFolderId = state.user?.photoFolderId;
    // Позицию восстанавливаем из UI-состояния: стек пишется туда на каждой навигации
    // (см. _saveStack), а вкладка при переключении пересоздаёт экран — без этого человек
    // каждый раз оказывался бы в корне. Битую запись геттер отбрасывает сам, поэтому кастовать
    // сырое значение из prefs (`as List`) здесь не нужно.
    final saved = state.settings.ui.filesStack;
    if (saved != null) _stack = saved;
    _load();
    _loadClip();
  }

  /// Сохраняет текущий путь в UI-состоянии (prefs), чтобы позиция пережила пересоздание экрана.
  ///
  /// Запись не ждём и ошибку не показываем: неудачное сохранение настройки не повод задерживать
  /// переход или сообщать о нём — позиция в файлах это удобство, а не данные пользователя.
  void _saveStack() {
    unawaited(
      ref.read(appStateProvider).settings.ui.patch({
        'files': {
          'stack': _stack.map((c) => {'id': c.id, 'name': c.name}).toList(),
        },
      }),
    );
  }

  /// Перечитывает открытый уровень — целиком, а не только первую страницу.
  ///
  /// Побочно: снимает прошлую ошибку, перерисовывает список и обновляет курсор продолжения.
  /// Вызывается при открытии экрана, после каждой операции над файлами, при возврате из деталей
  /// и жестом «потянуть вниз». Страницы догружаются здесь же: сервер отдаёт папку по 1000
  /// записей, и остановиться на первой — значит показать неполное содержимое без единого
  /// признака. Дальше [_maxPagesPerLoad] страниц идёт кнопка «Показать ещё».
  Future<void> _load() async {
    // Курсор снимается сразу: пока едет новый уровень, прежняя кнопка «Показать ещё»
    // относилась бы к прошлой папке и догрузила бы из неё страницу в новый список.
    setState(() {
      _error = null;
      _more = null;
    });
    final api = ref.read(appStateProvider).api;
    // Папка запроса запоминается: пока страницы едут, человек может уйти в другую папку,
    // и ответ про прежнюю показывать уже нельзя.
    final parent = _currentId;
    try {
      var view = await api.listFolder(parent);
      var pages = 1;
      while (view.hasMore && view.nextAfter != null && pages < _maxPagesPerLoad) {
        view = _merge(view, await api.listFolder(parent, after: view.nextAfter));
        pages++;
      }
      if (!mounted || parent != _currentId) return;
      setState(() {
        _view = view;
        // Курсор берём только вместе с признаком продолжения: `hasMore` без `nextAfter`
        // догрузить нечем, и обещать строку «Показать ещё» было бы нечестно.
        _more = (view.hasMore && view.nextAfter != null) ? view.nextAfter : null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    }
  }

  /// Догружает следующую страницу открытой папки — кнопка «Показать ещё» в конце списка.
  ///
  /// Нужна папкам, у которых страниц больше, чем [_maxPagesPerLoad]: показать их целиком сразу —
  /// это десятки тысяч строк, а промолчать про остаток нельзя, поэтому остаток виден строкой
  /// и грузится по нажатию.
  Future<void> _loadMore() async {
    final after = _more;
    if (after == null || _view == null || _busy) return;
    setState(() => _busy = true);
    final parent = _currentId;
    try {
      final next = await ref
          .read(appStateProvider)
          .api
          .listFolder(parent, after: after);
      if (!mounted || parent != _currentId) return;
      // Пока страница ехала, список мог быть перечитан заново (жест «потянуть вниз»): тогда
      // приклеивать страницу нужно к свежему ответу, а не к тому, что был на момент нажатия.
      final cur = _view;
      if (cur == null) return;
      setState(() {
        _view = _merge(cur, next);
        _more = (next.hasMore && next.nextAfter != null) ? next.nextAfter : null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Склеивает две страницы листинга в одну: записи второй дописываются к первой.
  ///
  /// Признак продолжения берётся у второй страницы — он относится к концу списка, а не к началу.
  /// Порядок записей сохраняется: сервер отдаёт страницы в устойчивом порядке имён, и склейка
  /// ничего не пересортировывает.
  FolderView _merge(FolderView head, FolderView tail) => FolderView(
    parentId: head.parentId,
    folders: [...head.folders, ...tail.folders],
    entries: [...head.entries, ...tail.entries],
    hasMore: tail.hasMore,
    nextAfter: tail.nextAfter,
  );

  /// Читает буфер обмена у сервера.
  ///
  /// Ошибку глотаем намеренно: недоступный буфер и пустой буфер для списка значат одно —
  /// вставлять нечего, и говорить об этом пользователю нечем.
  Future<void> _loadClip() async {
    try {
      final c = await ref.read(appStateProvider).api.clipboard();
      if (mounted) setState(() => _clip = c);
    } catch (_) {}
  }

  /// Создаёт папку в открытом уровне.
  ///
  /// Имя спрашивает диалогом: пустое или из одних пробелов — отказ без запроса к серверу.
  /// Побочно: перечитка уровня; ошибку сервера показывает строкой `_error`, список не сбрасывая.
  /// Пока запрос в полёте, кнопка выключена (`_busy`) — второй диалог завёл бы две папки.
  Future<void> _mkdir() async {
    if (_busy) return;
    final name = await promptDialog(context, 'Новая папка');
    if (name == null || name.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref.read(appStateProvider).api.mkdir(name.trim(), _currentId);
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Вставляет буфер обмена в открытую папку. Копирование это или перенос, решает сервер:
  /// буфер лежит у него, после переноса он очищается, после копирования остаётся.
  ///
  /// Адрес вставки — `_view.parentId`, но это не родитель открытой папки: в ответе листинга
  /// `parentId` — id самой этой папки (см. folders.service.listChildren), то есть вставка
  /// идёт в текущий уровень. Фолбэк на `_currentId` нужен для момента, пока ответа ещё нет.
  /// Побочно: `_notice` с названием и видом операции, перечитка уровня и буфера — перенос мог
  /// его опустошить. Пока запрос в полёте, `_busy` держит кнопку выключенной: второе нажатие
  /// отправило бы на сервер вторую копию того же файла.
  Future<void> _paste() async {
    if (_busy) return;
    final target = _view?.parentId ?? _currentId;
    if (target == null) return;
    setState(() => _busy = true);
    try {
      final r = await ref.read(appStateProvider).api.pasteClipboard(target);
      setState(
        () => _notice =
            '${r['action'] == 'copied' ? 'Скопировано' : 'Перенесено'}: ${r['name']}',
      );
      await _load();
      await _loadClip();
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Убирает буфер обмена на сервере (крестик рядом с именем источника над списком).
  ///
  /// Побочно: `_clip = null` — исчезают и полоска буфера, и кнопка «вставить» в AppBar.
  Future<void> _clearClip() async {
    try {
      await ref.read(appStateProvider).api.clearClipboard();
      if (mounted) setState(() => _clip = null);
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    }
  }

  /// Выбирает файлы системным пикером и отдаёт их очереди загрузок.
  ///
  /// Экран загрузку не ждёт: очередь глобальная (живёт поверх вкладок и переживает уход
  /// с экрана), прогресс рисует `UploadPanel` выше по дереву. Отменённый пикер — пустой
  /// список, и тогда не происходит ничего. Выбор во время уже идущей загрузки не теряется:
  /// очередь дописывает строки в текущий проход (см. `UploadQueue.addFiles`).
  Future<void> _pickUpload() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    final target = _view?.parentId ?? _currentId;
    await ref.read(appStateProvider).uploads.addFiles(files, target);
  }

  /// Открывает деталку файла и перечитывает уровень, если файл там что-то изменил.
  ///
  /// Контракт возврата: `true` — имя или само наличие записи поменялись (переименование,
  /// удаление); `null`/`false` — трогать список незачем.
  Future<void> _openFile(String entryId) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => FileDetailScreen(entryId: entryId)),
    );
    if (changed == true) await _load();
  }

  /// Открывает деталку папки (иконка «i» в AppBar).
  ///
  /// Ответ деталки различает два случая (см. [FolderMetaResult]): папку удалили — шага в дереве
  /// больше нет, и он снимается; папку переименовали — шаг остаётся, но с новым именем, иначе
  /// заголовок и хлебные крошки показывали бы старое. `null` — не менялось ничего.
  Future<void> _openFolderMeta(String folderId) async {
    final res = await Navigator.push<FolderMetaResult>(
      context,
      MaterialPageRoute(builder: (_) => FolderDetailScreen(folderId: folderId)),
    );
    if (res == null || !mounted) return;
    // Кнопка «Инфо о папке» есть только не в корне, поэтому снимать всегда есть что; проверка
    // оставлена на случай, если маршрут открыли не кнопкой (тест, диплинк).
    if (_stack.length <= 1) return;
    setState(() {
      final parent = _stack.sublist(0, _stack.length - 1);
      _stack = res.deleted ? parent : [...parent, (id: folderId, name: res.name)];
    });
    _saveStack();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appStateProvider);
    final uploads = state.uploads;
    // Корень зеркала этого устройства читается здесь же, в build: подпись «синхронизируется»
    // должна появиться, когда синхронизатор назовёт корень, а не при следующем действии
    // человека. Список его не читает сам — иначе было бы неясно, что в экране реактивно, а что
    // снимок на момент сборки.
    final mirrorRootId = ref.watch(
      syncControllerProvider.select((c) => c.mirrorRootId),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _stack.last.name,
          style: const TextStyle(color: C.fg, fontSize: 17),
        ),
        leading: IconButton(
          // Стрелка «вверх» ведёт на уровень выше по стеку и в корне выключена: системный
          // «назад» здесь уводит из вкладки, а не по дереву.
          icon: const Icon(Icons.arrow_upward, color: C.fg),
          onPressed: _stack.length <= 1
              ? null
              : () {
                  setState(() => _stack = _stack.sublist(0, _stack.length - 1));
                  _saveStack();
                  _load();
                },
        ),
        actions: [
          if (_stack.length > 1)
            IconButton(
              tooltip: 'Инфо о папке',
              icon: const Icon(Icons.info_outline, color: C.fg),
              onPressed: _currentId == null
                  ? null
                  : () => _openFolderMeta(_currentId!),
            ),
          if (_clip != null)
            IconButton(
              // Источник буфера мог исчезнуть (удалён с другого устройства) — тогда кнопка
              // не вставляет, а объясняет в подсказке, почему нечего вставлять. Пока вставка
              // в полёте, кнопка выключена: второе нажатие вставило бы вторую копию.
              tooltip: _clip!.available
                  ? 'Вставить сюда (${_clip!.mode == 'cut' ? 'перенести' : 'скопировать'} «${_clip!.name}»)'
                  : 'Источник «${_clip!.name}» больше недоступен',
              icon: const Icon(Icons.content_paste, color: C.fg),
              onPressed: (_clip!.available && !_busy) ? _paste : null,
            ),
          IconButton(
            tooltip: 'Новая папка',
            icon: const Icon(Icons.create_new_folder_outlined, color: C.fg),
            onPressed: _busy ? null : _mkdir,
          ),
          IconButton(
            tooltip: 'Загрузить файлы',
            icon: const Icon(Icons.upload_file, color: C.fg),
            onPressed: _pickUpload,
          ),
        ],
      ),
      body: Column(
        children: [
          ListenableBuilder(
            // Панель загрузок живёт своей жизнью: очередь — глобальный ChangeNotifier,
            // поэтому её появление и прогресс не требуют setState всего экрана.
            listenable: uploads,
            builder: (context, _) => uploads.rows.isEmpty
                ? const SizedBox.shrink()
                : UploadPanel(queue: uploads),
          ),
          if (_clip != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    _clip!.mode == 'cut' ? Icons.content_cut : Icons.copy,
                    size: 14,
                    color: C.fg3,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _clip!.name,
                      style: const TextStyle(color: C.fg3, fontSize: 12),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 16, color: C.fg3),
                    onPressed: _clearClip,
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Text(
                _error!,
                style: const TextStyle(color: C.danger, fontSize: 13),
              ),
            ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Text(
                _notice!,
                style: const TextStyle(color: C.ok, fontSize: 13),
              ),
            ),
          Expanded(child: _buildList(state.api, mirrorRootId)),
        ],
      ),
    );
  }

  /// Собирает содержимое уровня: сверху папки, под ними файлы (сервер отдаёт оба списка
  /// по алфавиту; порядок разделов фиксированный, вложенности в списке нет — уровень
  /// открывается тапом и становится новым шагом стека).
  ///
  /// [api] и [mirrorRootId] приходят из `build`: список не читает провайдеры сам, чтобы было
  /// видно, что он получает снимок на момент сборки, а не подписывается на что-то своё.
  Widget _buildList(CloudlyApi api, String mirrorRootId) {
    final v = _view;
    if (v == null && _error != null) {
      // Данных нет и пришли с ошибкой: показывать здесь «Пусто — нажмите Загрузить» нельзя,
      // человек прочитал бы это как «папка пуста», а её содержимое просто не приехало.
      return _refreshable(_retry('Не удалось прочитать папку'));
    }
    if (v == null) {
      // Первый ответ ещё не пришёл. Показывать «Пусто» рано: медленная сеть выглядела бы
      // как пустая папка.
      return const Center(child: CircularProgressIndicator());
    }
    // Медиатека — служебная папка зоны «Фото»: её содержимое показывают вкладки «Фото»
    // и «Медиа», а в дереве файлов она читалась бы как обычная папка с тысячами кадров.
    final folders = v.folders.where((f) => f.id != _photoFolderId).toList();
    final entries = v.entries;
    if (folders.isEmpty && entries.isEmpty) {
      return _refreshable(
        const Center(
          child: Text(
            'Пусто — нажмите «Загрузить», чтобы добавить файлы в эту папку',
            style: TextStyle(color: C.fg3),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final insideMirror = _stack.any((e) => e.id == mirrorRootId);
    return RefreshIndicator(
      // Жест «потянуть вниз»: содержимое папки меняют синхронизатор и веб-клиент, а сам экран
      // об изменениях не узнаёт — так его можно перечитать, не уходя из папки.
      onRefresh: _load,
      child: ListView(
        // Список бывает короче экрана, а обновление жестом должно работать и на нём.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          ...folders.map(
            (f) => ListTile(
              leading: const Icon(Icons.folder, color: C.accent),
              title: Text(f.name, style: const TextStyle(color: C.fg)),
              trailing: (f.id == mirrorRootId || insideMirror)
                  ? Tooltip(
                      message: f.id == mirrorRootId
                          ? 'Зеркало этого устройства: содержимое совпадает с выбранными '
                                'папками телефона'
                          : 'Внутри зеркала устройства: эта папка синхронизируется с телефоном',
                      child: Icon(
                        Icons.sync,
                        size: 18,
                        color: f.id == mirrorRootId ? C.accent : C.fg3,
                      ),
                    )
                  : null,
              onTap: () {
                // Новый шаг стека и перечитка под него. Старый список остаётся на экране,
                // пока не придёт ответ: так переход не мигает пустотой.
                setState(() => _stack = [..._stack, (id: f.id, name: f.name)]);
                _saveStack();
                _load();
              },
            ),
          ),
          ...entries.map(
            (e) => ListTile(
              leading: _Thumb(entry: e, api: api),
              title: Text(e.name, style: const TextStyle(color: C.fg)),
              onTap: () => _openFile(e.id),
            ),
          ),
          // Показано не всё: у папки остались незагруженные страницы. Строка и есть признак
          // того, что список неполный, — без неё человек считал бы его полным.
          if (_more != null) _moreTile(),
        ],
      ),
    );
  }

  /// Обёртка «потянуть вниз, чтобы обновить» для содержимого, которое не занимает экран целиком.
  ///
  /// Пустая папка и состояние ошибки — как раз те случаи, когда обновление нужнее всего, а
  /// обычный [RefreshIndicator] на невысоком содержимом жест не поймает: поэтому содержимое
  /// растягивается минимум на высоту окна, а прокрутка разрешается всегда.
  Widget _refreshable(Widget child) => RefreshIndicator(
    onRefresh: _load,
    child: LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: child,
        ),
      ),
    ),
  );

  /// Заглушка состояния «данных нет, запрос не удался»: объяснение и кнопка повтора.
  ///
  /// Ошибка при уже показанном списке так не выглядит — она идёт красной строкой над списком
  /// (`_error` в `build`) и список не сбрасывает.
  Widget _retry(String title) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: const TextStyle(color: C.fg3), textAlign: TextAlign.center),
        const SizedBox(height: 8),
        TextButton(onPressed: _load, child: const Text('Повторить')),
      ],
    ),
  );

  /// Строка «Показать ещё» в конце списка — продолжение листинга за пределами [_maxPagesPerLoad].
  ///
  /// Пока страницы едут, на её месте спиннер: повторное нажатие ничего не делает (`_busy`),
  /// но должно быть видно, что запрос уже идёт.
  Widget _moreTile() => ListTile(
    leading: _busy
        ? const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.expand_more, color: C.fg3),
    title: const Text('Показать ещё', style: TextStyle(color: C.fg)),
    onTap: _busy ? null : _loadMore,
  );
}

/// Текст ошибки для человека.
///
/// [ApiException] уже несёт готовое сообщение: серверный текст или разбор сетевого сбоя
/// (см. `CloudlyApi._toException`), поэтому его `toString` и есть то, что нужно показать.
/// Всё остальное — ошибка разбора или наш баг, и её сырой `toString` (с типом исключения)
/// человеку ничего не объясняет: показываем общую формулировку.
///
/// Заводить это в `util` пока нечем: экраны другого владельца ошибки показывают как есть,
/// а общий маппер должен лежать там же, где и остальные общие виджеты.
String _errText(Object e) =>
    e is ApiException ? e.message : 'не удалось выполнить операцию';

/// Миниатюра файла в списке.
///
/// Картинку отдаёт сервер по id записи (`thumbUrl`), авторизация — теми же заголовками, что
/// и у остальных запросов. Пока картинка едет — серый квадрат, если превью не собралось —
/// иконка по mime (`fileIcon`): строка должна читаться и без картинки.
///
/// Ключ кэша — sha256 содержимого, а не адрес картинки: адрес привязан к id записи, а он при
/// замене содержимого не меняется (синхронизация обновляет существующую запись), поэтому по
/// одному лишь URL кэш отдавал бы превью старого файла — и держал бы его до своего срока
/// хранения, который длиннее серверных десяти минут (`Cache-Control: private, max-age=600`).
/// Задать срок жизни у `CachedNetworkImage` нельзя (в 4.x такого параметра нет), а новый ключ
/// от старой картинки избавляет надёжнее: у заменённого файла другой sha256. Хеша в листинге
/// нет только у папок и у старых ответов сервера — тогда ключом остаётся id, то есть прежнее
/// поведение.
class _Thumb extends StatelessWidget {
  final FolderEntry entry;
  final CloudlyApi api;
  const _Thumb({required this.entry, required this.api});

  @override
  Widget build(BuildContext context) {
    final sha = entry.sha256;
    return SizedBox(
      width: 44,
      height: 44,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          imageUrl: api.thumbUrl(entry.id),
          cacheKey: (sha != null && sha.isNotEmpty) ? 'thumb-$sha' : 'thumb-${entry.id}',
          httpHeaders: api.authHeaders,
          fit: BoxFit.cover,
          placeholder: (_, _) => Container(color: C.surface3),
          errorWidget: (_, _, _) => Icon(fileIcon(entry.mime), color: C.fg3),
        ),
      ),
    );
  }
}

/// Панель загрузок над списком: одна сводка на всю очередь и строка на каждый файл.
///
/// Слушает `UploadQueue` (это `ChangeNotifier`) и потому перерисовывается сама, без участия
/// экрана файлов: загрузка идёт в фоне, а экран можно закрыть и вернуться. Очередь приходит
/// параметром — панель ею не владеет и создать её не может, поэтому в тестах и на других
/// экранах очередь можно подставить любую.
class UploadPanel extends StatelessWidget {
  final UploadQueue queue;
  const UploadPanel({super.key, required this.queue});

  @override
  Widget build(BuildContext context) {
    final rows = queue.rows;
    final doneN = rows.where((r) => r.state == 'done').length;
    final failN = rows.where((r) => r.state == 'failed').length;
    final active = rows.where((r) => r.state == 'uploading').length;
    // Пока загрузка идёт, текущий файл в «done» ещё не попал — считаем его следующим, иначе
    // счётчик стоял бы на месте всю передачу.
    final label = queue.busy
        ? 'загрузка ${doneN + (active > 0 ? 1 : 0)} из ${rows.length}'
        : failN > 0
        ? 'не загрузилось: $failN'
        : 'загружено $doneN из ${rows.length}';
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: C.surface2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.brd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: C.fg,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (queue.busy)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Отменить — убрать незагруженное',
                  icon: const Icon(Icons.close, size: 18, color: C.fg3),
                  onPressed: queue.cancel,
                )
              else if (failN > 0)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: queue.retryFailed,
                      child: const Text('повторить'),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 18, color: C.fg3),
                      onPressed: queue.dismissFailed,
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 6),
          ...rows.map((r) => _row(r)),
        ],
      ),
    );
  }

  /// Строка одного файла: иконка состояния, имя с размером, полоса прогресса и подпись фазы.
  ///
  /// Подпись нужна ради долгих этапов: у больших файлов видно, что происходит сейчас —
  /// считается sha256, идёт передача (напрямую или через сервер) или сервер проверяет
  /// целостность. Без неё прогресс, стоящий минутами на одном месте, читался бы как зависание.
  Widget _row(UploadRow r) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            r.state == 'done'
                ? Icons.check_circle
                : r.state == 'failed'
                ? Icons.cancel
                : r.state == 'uploading'
                ? Icons.hourglass_top
                : Icons.schedule,
            size: 16,
            color: r.state == 'done'
                ? C.ok
                : r.state == 'failed'
                ? C.danger
                : C.fg3,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${r.name} · ${fmt(r.size)}',
                  style: const TextStyle(color: C.fg, fontSize: 12),
                ),
                if (r.state == 'failed')
                  Text(
                    r.error ?? 'ошибка',
                    style: const TextStyle(color: C.danger, fontSize: 11),
                  )
                else ...[
                  const SizedBox(height: 3),
                  LinearProgressIndicator(
                    value: r.state == 'done' ? 1 : (r.pct / 100).clamp(0, 1),
                    minHeight: 3,
                    backgroundColor: C.surface3,
                    color: r.state == 'done' ? C.ok : C.accent,
                  ),
                  if (r.state == 'uploading')
                    Text(
                      r.phase == 'hash'
                          ? 'считаю sha256 · ${r.pct}%'
                          : r.phase == 'verify'
                          ? 'сервер проверяет целостность…'
                          : '${r.phase == 'relay' ? 'через сервер' : 'загружаю'} · ${r.pct}%${r.note != null ? ' · ${r.note}' : ''}',
                      style: const TextStyle(color: C.fg3, fontSize: 11),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
