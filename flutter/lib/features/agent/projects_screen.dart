import 'dart:async';

// `CupertinoPageRoute` берём точечно: это маршрут с горизонтальным слайдом и пальцевым
// возвратом от края на всех платформах, а из всего `cupertino.dart` в файле он один.
import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import 'agent_controller.dart';
import 'agent_new_session.dart';
import 'agent_thread_screen.dart';
import 'agent_types.dart';

/// Раздел «Проекты»: общий список разговоров с агентами на домашнем маке.
///
/// Раздел открывается списком разговоров, а не списком папок: разговоры — это то, ради чего в
/// него заходят, а папка нужна лишь один раз, при заведении новой сессии. Список собирается со
/// всех проектов сразу и по обоим харнессами (pi и Claude Code) — разговор, начатый вчера в
/// терминале, открывается отсюда одним тапом, а не через выбор папки и фильтр.
///
/// Агент работает на маке, но запросы делает сервер приложения; приложению виден только раздел
/// `/projects/*`. Кнопка «Новая сессия» в начале списка открывает мастер: папка → модель
/// (локальные, удалённые, Claude Code).
class ProjectsScreen extends ConsumerStatefulWidget {
  /// Экран раздела «Проекты».
  const ProjectsScreen({super.key});

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

/// Состояние экрана: контроллеры, снимок работы, выбранный разговор и его панель.
class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
  /// Минимальная ширина раздела, с которой список разговоров и сам разговор показываются рядом.
  ///
  /// Порог только по ширине, без оглядки на высоту: короткий горизонтальный экран (телефон с
  /// внешней клавиатурой) — тоже рабочий случай, и две панели там нужны так же, как на мониторе.
  static const _twoPaneMin = 720.0;

  /// Пределы ширины колонки со списком в двухпанельном виде.
  ///
  /// Ниже минимума колонка уже не читается, а выше максимума список забрал бы у переписки
  /// больше трети экрана — на большом мониторе это заметно.
  static const _sidebarMin = 300.0;
  static const _sidebarMax = 380.0;

  /// Контроллер общего списка разговоров.
  late final AgentSessionsController _sessions;

  /// Контроллер списка проектов (он же отдаёт состояние моста).
  late final AgentProjectsController _projects;

  /// Обновление списка и снимка работы, пока экран открыт.
  ///
  /// Раз в пять секунд: этого хватает, чтобы увидеть чужой прогон (с телефона или из терминала)
  /// и что разговор дописался, а лишних запросов к маку не плодит.
  Timer? _ticker;

  /// Какие разговоры были «готовы» на прошлом проходе — чтобы показать про новые один раз.
  Set<String> _finishedBefore = const {};

  /// Разговор, выбранный в двухпанельном виде (id строки списка); `null` — ничего не выбрано.
  ///
  /// Хранится именно id, а не сама строка: список раз в пять секунд перечитывается, и объекты
  /// [AgentSession] заменяются новыми — выбранная строка иначе устарела бы в ту же секунду.
  String? _selectedId;

  /// Открытая сессия выбранного разговора; `null` — мост ещё поднимает процесс на маке.
  AgentSessionInfo? _opened;

  /// Проект выбранного разговора: из строки списка или из мастера новой сессии.
  ///
  /// Хранится вместе с сессией, а не выводится из её пути: у новой сессии проекта в строке нет,
  /// а имя папки и имя проекта — не одно и то же.
  AgentProject? _openProject;

  /// Идёт открытие разговора в панели (включая новый — у него ещё нет id).
  bool _starting = false;

  /// Номер последнего открытия: ответ моста применяется, только если он всё ещё последний.
  ///
  /// Без него повторный тап по списку, пока открывался предыдущий разговор, показывал бы в панели
  /// тот, на который человек уже не смотрит — а то и навсегда оставлял бы спиннер.
  int _openSeq = 0;

  /// Готовый виджет панели разговора и ключ, под который он собран.
  ///
  /// Экземпляр держится, чтобы отдавать из `build` тот же объект: `Element.updateChild`
  /// пропускает перестройку поддерева для идентичного виджета. Иначе обновление списка раз в
  /// пять секунд (и каждого снимка работы) перестраивало бы переписку целиком — то есть заново
  /// разбирало markdown каждого видимого сообщения.
  Widget? _thread;
  String? _threadKey;

  @override
  void initState() {
    super.initState();
    _sessions = ref.read(agentSessionsProvider.notifier);
    _projects = ref.read(agentProjectsProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // всё читаем после первого кадра: до этого провайдеры трогать нельзя
      _projects.load();
      ref.read(agentHarnessesProvider.notifier).load();
      _sessions.load();
      ref.read(agentActivityProvider.notifier).load();
      _ticker = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
      // О новых готовых ответах сообщаем один раз: сравниваем с прошлым снимком
      ref.listen(agentActivityProvider, (_, next) {
        final fresh = next.activity.finished.difference(_finishedBefore);
        _finishedBefore = next.activity.finished;
        if (fresh.isNotEmpty && mounted) {
          snack(
            context,
            fresh.length == 1
                ? 'Агент закончил: ответ готов'
                : 'Агент закончил: готовых ответов ${fresh.length}',
          );
        }
      });
    });
  }

  /// Перечитывает список и снимок работы, не мигая спиннером.
  void _refresh() {
    if (!mounted) return;
    _sessions.load(silent: true);
    ref.read(agentActivityProvider.notifier).load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Мастер новой сессии, затем открытие выбранной сессии.
  ///
  /// Если человек не дошёл до второго шага или закрыл мастер, ничего не открывается. Модель из
  /// выбора запоминается как модель по умолчанию харнесса — следующая новая сессия у этого
  /// агента начнётся с неё, если мастер снова закроют на этом шаге.
  ///
  /// [wide] — открывать разговор в правой панели (широкий экран) или отдельным экраном поверх
  /// списка (телефон): режим выбирает раскладка ([build]), а не сам мастер.
  Future<void> _newSession({required bool wide}) async {
    final choice = await showNewSessionWizard(context, ref);
    if (choice == null || !mounted) return;
    if (choice.modelKey != null) {
      await ref
          .read(settingsProvider)
          .ui
          .setAgentModel(choice.harness, choice.modelKey!);
    }
    await _open(
      choice.project,
      harness: choice.harness,
      modelKey: choice.modelKey,
      embedded: wide,
    );
  }

  /// Открывает сессию (новую или существующую) и показывает её разговор.
  ///
  /// Открытие — это запуск процесса агента на маке: он занимает секунду-две. В двухпанельном
  /// виде строка списка подсвечивается и панель показывает спиннер сразу — иначе отклика не
  /// видно до самого ответа моста; на телефоне разговор открывается экраном поверх списка.
  /// Отказ моста виден строкой над списком, а не молчанием.
  Future<void> _open(
    AgentProject project, {
    String harness = 'pi',
    String? sessionId,
    String? modelKey,
    required bool embedded,
  }) async {
    // Разговор, который открывают, больше не «готов»: человек увидит его сам
    if (sessionId != null) {
      ref.read(agentActivityProvider.notifier).markSeen(sessionId);
    }
    final seq = ++_openSeq;
    if (embedded) {
      setState(() {
        _starting = true;
        _selectedId = sessionId;
        _opened = null;
        _openProject = project;
      });
    }
    final session = await _sessions.open(
      project,
      harness: harness,
      sessionId: sessionId,
      modelKey: modelKey,
    );
    // Пока ждали ответа, человек мог выбрать другой разговор или закрыть панель: тогда этот
    // ответ уже никому не нужен, и показывать его нельзя
    if (seq != _openSeq) return;
    if (session == null) {
      // Причина отказа уже лежит в состоянии списка, а выбранным при этом ничего не остаётся
      if (embedded && mounted) _clearSelection();
      return;
    }
    if (!mounted) return;
    if (embedded) {
      setState(() {
        _starting = false;
        _selectedId = session.id;
        _opened = session;
      });
      await _sessions.load();
      return;
    }
    await Navigator.of(context).push(
      // `CupertinoPageRoute`, а не `MaterialPageRoute`: у него переход — горизонтальный слайд,
      // который можно потянуть назад пальцем от края, и он одинаков на Android и iOS. Переход
      // идёт на композиторе и ничего не перестраивает: список остаётся жив под экраном вместе
      // с прокруткой, поэтому возврат мгновенный.
      CupertinoPageRoute<void>(
        builder: (_) => AgentThreadScreen(session: session, project: project),
      ),
    );
    if (mounted) await _sessions.load();
  }

  /// Сбрасывает выбор в двухпанельном виде: правая панель возвращается к заглушке.
  void _clearSelection() => setState(() {
    _openSeq++;
    _starting = false;
    _selectedId = null;
    _opened = null;
    _openProject = null;
  });

  /// Снимает выбор, если выбранного разговора больше нет в списке.
  ///
  /// Нужно после удаления и уборки: без этого правая панель продолжала бы показывать разговор,
  /// которого на маке уже нет.
  void _pruneSelection() {
    final id = _selectedId;
    if (id == null) return;
    if (ref.read(agentSessionsProvider).sessions.any((s) => s.id == id)) return;
    _clearSelection();
  }

  /// Удаляет сессию на маке вместе с историей.
  ///
  /// Спрашиваем подтверждение: файл стирается с диска, и вернуть разговор нечем. Это
  /// единственное действие над строкой, поэтому оно вынесено иконкой прямо в строку.
  Future<void> _delete(AgentSession session) async {
    final ok = await confirmDialog(
      context,
      'Удалить сессию',
      'Разговор «${_title(session)}» будет удалён на маке вместе с историей '
          '(${session.messages} сообщ.). Восстановить его нечем.',
      danger: true,
      confirmLabel: 'Удалить',
    );
    if (!ok || !mounted) return;
    final result = await _sessions.remove(session.id);
    if (!mounted || result == null) return;
    // Удалённый разговор закрывается и в правой панели, если был в ней открыт
    _pruneSelection();
    if (result.anyRestored) {
      snack(
        context,
        'Этот разговор ведёт живой процесс Claude Code: файл восстановлен, удалить его отсюда '
        'нельзя — только в самом Claude',
      );
      return;
    }
    snack(
      context,
      result.anyDeleted ? 'Сессия удалена' : 'Удалять было нечего',
    );
  }

  /// Подпись разговора для списка и вопросов: имя, а если его нет — начало идентификатора.
  String _title(AgentSession session) => session.name.isEmpty
      ? 'Сессия ${session.id.substring(0, 8)}'
      : session.name;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(agentSessionsProvider);

    return LayoutBuilder(
      builder: (context, c) {
        // Раскладка — по ширине самого раздела: `LayoutBuilder` отдаёт уже урезанные границы,
        // в которые не входят бар разделов и разделитель (`Shell`), поэтому порог один и тот же
        // на всех платформах. `MediaQuery` дал бы ширину окна, и порог пришлось бы подгонять
        // под чужие виджеты — а на маке и iPad окно меняется на лету.
        final wide = c.maxWidth >= _twoPaneMin;
        return wide ? _twoPaneBody(state, c.maxWidth) : _singlePane(state);
      },
    );
  }

  /// Однопанельный вид: список во всю ширину, разговор открывается экраном поверх (телефон).
  ///
  /// Шапки нет вовсе: раздел назван подсветкой в левом баре, а строка «Проекты» отнимала бы
  /// высоту у списка. Новая сессия открывается кнопкой во всю ширину в самом верху списка.
  Widget _singlePane(AgentSessionsState state) => Scaffold(
    body: _sidebar(state, wide: false),
  );

  /// Двухпанельный вид: список разговоров слева, выбранный разговор справа.
  ///
  /// Справа — тот же экран разговора, только встроенный ([AgentThreadScreen.embedded]): работа
  /// с сессией, переписка и поле ввода у него одни и те же, а не вторая копия.
  Widget _twoPaneBody(AgentSessionsState state, double width) {
    final sidebar = (width * 0.34).clamp(_sidebarMin, _sidebarMax);
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: sidebar, child: _sidebar(state, wide: true)),
          // Рамка вместо тени: на тёмной теме тень между двумя поверхностями почти не читается
          const VerticalDivider(width: 1, thickness: 1, color: C.brd),
          Expanded(child: _detail(width - sidebar - 1)),
        ],
      ),
    );
  }

  /// Колонка со списком разговоров: ошибка моста и сам список.
  ///
  /// Шапки с названием раздела нет ни здесь, ни в однопанельном виде: раздел уже назван
  /// подсветкой в левом баре, а строка «Проекты» только отнимала бы высоту у списка.
  Widget _sidebar(AgentSessionsState state, {required bool wide}) => Material(
    // фон колонки со списком — как у левого бара разделов ([C.island]): список и бар читаются
    // одной поверхностью, а разговор справа отделяет только рамка и его собственный фон
    color: C.island,
    child: Column(
      children: [
        if (state.error != null) _errorBar(state.error!),
        Expanded(child: _body(state, wide: wide)),
      ],
    ),
  );

  /// Правая панель: выбранный разговор, заглушка или спиннер, пока мост поднимает процесс.
  ///
  /// Спиннер — и при переходе на другой разговор, и при открытии нового (у него ещё нет id,
  /// подсветить в списке нечего): мост отвечает через секунду-две, и пустая панель в это время
  /// выглядела бы как «ничего не произошло».
  Widget _detail(double width) {
    final opened = _opened;
    if (_starting || (opened != null && opened.id != _selectedId)) {
      return const Center(child: CircularProgressIndicator());
    }
    final project = _openProject;
    if (opened == null || project == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Разговор не выбран. Возьмите его из списка слева — переписка откроется здесь.',
            textAlign: TextAlign.center,
            style: TextStyle(color: C.fg3, fontSize: 13, height: 1.4),
          ),
        ),
      );
    }
    return _threadView(opened, project, width);
  }

  /// Виджет панели разговора: один и тот же экземпляр, пока не сменился разговор или ширина.
  ///
  /// [AgentThreadScreen] держит поток ответа и таймер, а `Element.updateChild` пропускает
  /// перестройку поддерева для идентичного виджета. Обновление списка (раз в пять секунд) и
  /// снимка работы приходят сюда каждые несколько секунд: без этого переписка разбирала бы
  /// markdown всех видимых сообщений столько же раз. Ширина меняется только при изменении
  /// размера окна — тогда пересборка нужна: от неё зависит предел ширины пузыря.
  Widget _threadView(AgentSessionInfo session, AgentProject project, double width) {
    final key = '${session.id}@$width';
    if (_threadKey != key || _thread == null) {
      _threadKey = key;
      _thread = AgentThreadScreen(
        // Ключ по сессии: смена разговора обязана выбросить состояние прежнего — прокрутку,
        // черновик в поле ввода и раскрытые карточки инструментов
        key: ValueKey<String>(session.id),
        session: session,
        project: project,
        embedded: true,
        paneWidth: width,
        onDismiss: _clearSelection,
      );
    }
    return _thread!;
  }

  /// Тело списка: индикатор загрузки, кнопка новой сессии и сами разговоры.
  Widget _body(AgentSessionsState state, {required bool wide}) {
    if (state.loading && state.sessions.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final empty = state.sessions.isEmpty;
    return RefreshIndicator(
      onRefresh: () => _sessions.load(),
      child: ListView.builder(
        // список обязан оставаться прокручиваемым даже из нескольких строк: иначе короткое
        // содержимое не даст ни потянуть вниз для обновления, ни толкнуть колесом
        physics: const AlwaysScrollableScrollPhysics(),
        // низ отбит от края: плавающей кнопки больше нет, но список упирался бы в системную
        // полосу жестов на телефоне
        padding: EdgeInsets.only(bottom: navBarInset(context) + 24),
        // первым элементом идёт кнопка новой сессии: она всегда под рукой, даже когда
        // разговоров ещё нет
        itemCount: state.sessions.length + 1 + (empty ? 1 : 0),
        itemBuilder: (context, i) {
          if (i == 0) return _addTile(state, wide: wide);
          if (empty) return _emptyHint();
          return _sessionTile(state.sessions[i - 1], wide: wide);
        },
      ),
    );
  }

  /// Кнопка новой сессии: первая строка списка во всю ширину колонки.
  ///
  /// Раньше это была плавающая кнопка в углу, но она перекрывала последние строки списка и
  /// спорила с полем ввода разговора. Строкой во всю ширину её видно всегда, и открывать
  /// мастер приходится не через поиск кнопки в углу.
  ///
  /// Заливка — не ярким акцентом, а мягкой подложкой ([C.accentSoft]) от края до края колонки:
  /// на фоне списка ([C.island]) яркая кнопка перетягивала бы взгляд с разговоров на себя.
  /// Текст и значок при этом остаются акцентными — что это кнопка и что она делает, видно.
  Widget _addTile(AgentSessionsState state, {required bool wide}) => Padding(
    // поля только сверху и снизу: подложка должна упираться в края колонки, иначе она
    // выглядит плавающей кнопкой, а не первой строкой списка
    padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
    child: SizedBox(
      height: 46,
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: state.loading ? null : () => _newSession(wide: wide),
        icon: const Icon(Icons.add, size: 20),
        label: const Text('Новая сессия'),
        style: FilledButton.styleFrom(
          backgroundColor: C.accentSoft,
          foregroundColor: C.accent,
          // без скругления: подложка идёт от края до края, и радиус на такой полосе смотрелся
          // бы случайным пятном
          shape: const RoundedRectangleBorder(),
        ),
      ),
    ),
  );

  /// Пояснение под кнопкой, когда разговоров ещё нет.
  Widget _emptyHint() => const Padding(
    padding: EdgeInsets.fromLTRB(24, 16, 24, 24),
    child: Text(
      'Разговоров пока нет. Нажмите «Новая сессия» — выберите папку и модель, и агент '
      'запустится в ней: он сможет читать и править файлы проекта и запускать команды.',
      textAlign: TextAlign.center,
      style: TextStyle(color: C.fg3, fontSize: 13, height: 1.4),
    ),
  );

  /// Строка списка: имя разговора, проект, харнесс, модель, число сообщений и время.
  Widget _sessionTile(AgentSession session, {required bool wide}) {
    final activity = ref.watch(agentActivityProvider);
    final selected = wide && session.id == _selectedId;
    return ListTile(
      // Выбранный разговор подсвечен: в двухпанельном виде он же открыт справа, и по списку
      // должно быть видно, какой именно
      tileColor: selected ? C.accentSoft : null,
      leading: Icon(
        _harnessIcon(session.harness),
        // значок агента подсвечен, пока он работает или пока ответ ждёт просмотра: разговор
        // может считаться и без открытого экрана, и это должно быть видно из списка
        color: session.busy ||
                activity.isRunning(session.id) ||
                activity.isFinished(session.id)
            ? C.ok
            : C.fg2,
      ),
      title: Text(
        _title(session),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: C.fg, fontSize: 15),
      ),
      subtitle: Text(
        [
          // «Работает» — агент считает прямо сейчас (даже если экран разговора закрыт);
          // «готово» — он закончил, пока на него не смотрели
          if (session.busy || activity.isRunning(session.id))
            '● работает'
          else if (activity.isFinished(session.id))
            '✓ готово',
          if (session.projectName.isNotEmpty) session.projectName,
          ref.read(agentHarnessesProvider).nameOf(session.harness),
          if (session.modelLabel.isNotEmpty) session.modelLabel,
          '${session.messages} сообщ.',
          if (session.updatedAt != null)
            listDate(session.updatedAt!, DateTime.now()),
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: C.fg3, fontSize: 12),
      ),
      onTap: session.path.isEmpty
          ? null
          : () {
              // Повторное нажатие на уже открытый разговор ничего не делает: перезапускать
              // процесс на маке ради того же самого незачем
              if (wide && session.id == _selectedId) return;
              _open(
                AgentProject.fromPath(session.path),
                harness: session.harness.isEmpty ? 'pi' : session.harness,
                sessionId: session.id,
                embedded: wide,
              );
            },
      // Удаление — иконкой прямо в строке: это единственное действие над разговором, а меню
      // «троеточие» заставляло открывать его ради одной строки. Закрывать процесс вручную не
      // нужно: агент отпускает память сам, когда закончил работу.
      trailing: IconButton(
        tooltip: 'Удалить сессию',
        onPressed: () => _delete(session),
        icon: const Icon(Icons.delete_outline, color: C.danger),
      ),
    );
  }

  /// Сообщение об ошибке над списком: «мост недоступен» — состояние раздела, а не сбой строки.
  Widget _errorBar(String message) => Container(
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: C.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: C.danger),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline, color: C.danger, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(color: C.fg2, fontSize: 13, height: 1.3),
          ),
        ),
        TextButton(
          onPressed: () => _sessions.load(),
          child: const Text('Повторить'),
        ),
      ],
    ),
  );

  /// Значок харнесса: у pi терминал, у Claude Code — звёздочка его бренда.
  IconData _harnessIcon(String harness) =>
      harness == 'claude' ? Icons.auto_awesome : Icons.terminal;
}
