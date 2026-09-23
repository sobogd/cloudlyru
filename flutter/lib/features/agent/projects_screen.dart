import 'dart:async';

// `CupertinoPageRoute` берём точечно: это маршрут с горизонтальным слайдом и пальцевым
// возвратом от края на всех платформах, а из всего `cupertino.dart` в файле он один.
import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../theme.dart';
import '../../util/widgets.dart';
import 'agent_controller.dart';
import 'agent_launch.dart';
import 'agent_new_session.dart';
import 'agent_thread_screen.dart';
import 'agent_types.dart';
import '../mac/pull_requests_screen.dart';

/// Раздел «Проекты»: общий список разговоров с агентами на домашнем маке.
///
/// Раздел открывается списком разговоров, а не списком папок: разговоры — это то, ради чего в
/// него заходят, а папка нужна лишь один раз, при заведении новой сессии. Список собирается со
/// всех проектов сразу и по обоим харнессами (pi и Claude Code) — разговор, начатый вчера в
/// терминале, открывается отсюда одним тапом, а не через выбор папки и фильтр.
///
/// Агент работает на маке, но запросы делает сервер приложения; приложению виден только раздел
/// `/projects/*`. Кнопка «Новая сессия» — последней строкой списка, тем же лейаутом, что и
/// разговоры: значок слева, имя за ним; открывает мастер «папка → модель» (локальные, удалённые,
/// Claude Code).
class ProjectsScreen extends ConsumerStatefulWidget {
  /// Экран раздела «Проекты».
  const ProjectsScreen({super.key});

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

/// Что показывает левая колонка раздела.
enum _Tab {
  /// Разговоры с агентами.
  sessions,

  /// Доска открытых пул-реквестов.
  pulls,
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

  /// Что показано в левой колонке: разговоры или пул-реквесты.
  _Tab _tab = _Tab.sessions;

  /// Текст, с которым открывается следующий разговор (просьба о ревью из доски PR).
  String? _openPrompt;

  /// Имя, которое получит следующий открытый разговор (`repo#123` из доски PR).
  String? _openName;

  /// Контроллер списка проектов (он же отдаёт состояние моста).
  late final AgentProjectsController _projects;

  /// Снимок работы на каждом такте: он лёгкий (сервер отвечает им из своей памяти, не ходя к
  /// маку), поэтому частый опрос здесь не стоит ничего.
  Timer? _ticker;

  /// Подписка на возврат приложения на передний план: она и заменяет прежний частый опрос списка.
  AppLifecycleListener? _lifecycle;

  /// Сколько тактов таймера прошло: по нему решается, когда перечитывать список разговоров
  /// (см. [_refresh]).
  int _ticks = 0;

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

  /// Повтор последнего неудавшегося действия — для кнопки «Повторить» над списком.
  ///
  /// Без него повтор всегда перечитывал список, даже когда упало открытие разговора или
  /// удаление: человек жал кнопку и не получал ни того, что просил, ни объяснения.
  Future<void> Function()? _retry;

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
      // Вернулись на экран или в приложение — перечитываем список сразу: пока его не было,
      // разговоры могли дописаться, а на экране осталось старое.
      _lifecycle = AppLifecycleListener(onResume: _refresh);
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

  /// Перечитывает список разговоров и снимок работы, не мигая спиннером.
  ///
  /// Список пересчитывается на маке обходом всей истории агентов (с `stat` по каждому файлу
  /// сессии), поэтому в таймере он обновляется редко: часто — только на первых тактах после
  /// открытия экрана, потом в четыре раза реже снимка. Всё остальное свежее приходит по
  /// действию: возврат из разговора, из мастера или из фона.
  void _refresh() {
    if (!mounted) return;
    _ticks += 1;
    // Снимок работы лёгкий (сервер отдаёт его из памяти), а список пересчитывается на маке
    // обходом всей истории: поэтому часто он читается только на первых тактах и при действиях,
    // а дальше раз в 30 секунд
    if (_ticks <= 4 || _ticks % 6 == 0) _sessions.load(silent: true);
    ref.read(agentActivityProvider.notifier).load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _lifecycle?.dispose();
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
  /// [prompt] — текст, который ляжет в поле ввода открытого разговора (просьба о ревью из
  /// доски пул-реквестов). Отправку делает человек сам.
  ///
  /// [sessionName] — имя разговора (`repo#123` из доски PR). Разговор с таким именем уже есть —
  /// открывается он, без мастера: ревью одного пул-реквеста живёт в одной переписке.
  Future<void> _newSession({
    required bool wide,
    String? prompt,
    String? sessionName,
  }) async {
    if (sessionName != null && sessionName.isNotEmpty) {
      final existing = findSessionByName(ref, sessionName);
      if (existing != null) {
        await _open(
          AgentProject.fromPath(existing.path),
          harness: existing.harness,
          sessionId: existing.id,
          embedded: wide,
        );
        return;
      }
    }
    final choice = await showNewSessionWizard(context, ref, suggestedName: sessionName ?? '');
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
      prompt: prompt,
      // Имя, названное человеком в мастере, важнее предложенного доской пул-реквестов.
      nameIt: choice.name.isNotEmpty ? choice.name : sessionName,
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
    String? prompt,
    String? nameIt,
  }) async {
    // Текст и имя переживают открытие: пока мост поднимает процесс, показать их негде, а панель
    // разговора строится уже после ответа.
    _openPrompt = prompt;
    _openName = nameIt;
    // Разговор, который открывают, больше не «готов»: человек увидит его сам
    if (sessionId != null) {
      ref.read(agentActivityProvider.notifier).markSeen(sessionId);
    }
    final seq = ++_openSeq;
    // Существующий разговор показывается сразу по строке списка: его история лежит в файле на
    // маке и процесса не требует, а подъём процесса занимает секунду-две. Раньше всё это время
    // экран оставался пустым — отсюда и ощущение задержки при каждом нажатии на разговор.
    final fast = sessionId == null
        ? null
        : _brief(sessionId, project, harness);
    if (fast != null) {
      if (embedded) {
        setState(() {
          _starting = false;
          _selectedId = sessionId;
          _opened = fast;
          _openProject = project;
        });
      } else {
        await Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (_) => AgentThreadScreen(session: fast, project: project),
          ),
        );
        if (mounted) await _sessions.load();
        return;
      }
    } else if (embedded) {
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
      // Усилие хранится в настройках, а не в файле разговора: без этого возобновлённый Claude
      // Code считался бы с умолчанием модели вместо выбранного человеком уровня. У pi выбор
      // игнорируется — у него уровень задаёт сама модель
      effort: harness == 'claude'
          ? ref.read(settingsProvider).ui.agentEffort('claude')
          : null,
    );
    // Пока ждали ответа, человек мог выбрать другой разговор или закрыть панель: тогда этот
    // ответ уже никому не нужен, и показывать его нельзя
    if (seq != _openSeq) return;
    if (session == null) {
      // Причина отказа уже лежит в состоянии списка, а выбранным при этом ничего не остаётся.
      // Повтор кнопкой над списком должен открыть тот же разговор, а не перечитать список.
      _retry = () => _open(
        project,
        harness: harness,
        sessionId: sessionId,
        modelKey: modelKey,
        embedded: embedded,
      );
      if (embedded && mounted) _clearSelection();
      return;
    }
    _retry = null;
    // Имя принимает сам мост — он помнит его и до появления журнала сессии. Остаток (если мост
    // отказал) уезжает экрану разговора и ставится после первого сообщения.
    final pendingName = sessionId == null && nameIt != null
        ? await applySessionName(ref, session.id, nameIt)
        : null;
    _openName = pendingName;
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
        builder: (_) => AgentThreadScreen(
          session: session,
          project: project,
          initialPrompt: prompt,
          pendingName: pendingName,
        ),
      ),
    );
    _openPrompt = null;
    _openName = null;
    if (mounted) await _sessions.load();
  }

  /// Краткое описание разговора из строки списка: с ним экран открывается, не дожидаясь моста.
  ///
  /// Модель, имя и время берутся из строки (их мост отдаёт в общем списке), а числа контекста и
  /// расхода остаются пустыми: их знает только живой процесс, и придумывать нули вместо них
  /// значило бы показывать неправду. По первому же ответу моста описание уточнится.
  AgentSessionInfo _brief(
    String sessionId,
    AgentProject project,
    String harness,
  ) {
    AgentSession? row;
    for (final s in ref.read(agentSessionsProvider).sessions) {
      if (s.id == sessionId) {
        row = s;
        break;
      }
    }
    return AgentSessionInfo(
      id: sessionId,
      path: row?.path.isNotEmpty == true ? row!.path : project.path,
      name: row?.name ?? '',
      model: row?.model ?? '',
      provider: row?.provider ?? '',
      harness: (row?.harness.isNotEmpty ?? false) ? row!.harness : harness,
      harnessName: row?.harnessName ?? '',
      busy: row?.busy ?? false,
      messages: row?.messages ?? 0,
      startedAt: row?.startedAt,
      updatedAt: row?.updatedAt,
    );
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
  /// Шапку рисует сам список ([_sidebarHeader]) — своей у экрана нет. Новая сессия открывается
  /// строкой в самом низу списка — под старыми разговорами: список идёт от старых к новым, и
  /// новая сессия встаёт туда же, где появится сам разговор.
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

  /// Колонка со списком разговоров: шапка, ошибка моста и сам список.
  ///
  /// Шапка с названием раздела есть и здесь, и в однопанельном виде: в двухпанельном она
  /// встаёт на одной линии с шапкой открытого разговора, а на телефоне заменяет `AppBar`,
  /// которого у экрана нет.
  Widget _sidebar(AgentSessionsState state, {required bool wide}) => Material(
    // фон колонки со списком — как у левого бара разделов ([C.island]): список и бар читаются
    // одной поверхностью, а разговор справа отделяет только рамка и его собственный фон
    color: C.island,
    child: Column(
      children: [
        _sidebarHeader(),
        if (state.error != null) _errorBar(state.error!),
        Expanded(
          child: _tab == _Tab.sessions
              ? _body(state, wide: wide)
              : PullRequestsScreen(
                  embedded: true,
                  onReview: (name, prompt) =>
                      _newSession(wide: wide, prompt: prompt, sessionName: name),
                ),
        ),
      ],
    ),
  );

  /// Шапка списка разговоров: название раздела.
  ///
  /// Высота — как у шапки открытого разговора (56 у `AppBar` на отдельном экране и у шапки
  /// панели в двухпанельном виде): обе шапки стоят на одной линии и читаются одной полосой над
  /// списком и перепиской. Отступы по краям — как у строк списка, чтобы заголовок был с ними
  /// на одной вертикали.
  Widget _sidebarHeader() => SizedBox(
    height: 56,
    child: Padding(
      padding: const EdgeInsets.only(left: 16, right: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(_tab == _Tab.sessions ? 'Проекты' : 'Пул-реквесты',
                style: const TextStyle(color: C.fg, fontSize: 18)),
          ),
          // Пул-реквесты живут здесь, а не в разделе «Mac»: смотрят их затем же, зачем
          // открывают проект — чтобы отдать работу агенту. Вкладкой, а не отдельным экраном,
          // чтобы на широком экране список PR стоял слева, а разговор открывался справа.
          _tabButton(_Tab.sessions, Icons.forum_outlined, 'Разговоры'),
          _tabButton(_Tab.pulls, Icons.merge_type, 'Пул-реквесты'),
        ],
      ),
    ),
  );

  /// Кнопка переключения вкладки левой колонки.
  Widget _tabButton(_Tab tab, IconData icon, String tooltip) => IconButton(
    tooltip: tooltip,
    onPressed: _tab == tab ? null : () => setState(() => _tab = tab),
    icon: Icon(icon, size: 20, color: _tab == tab ? C.fg : C.fg2),
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
      final prompt = _openPrompt;
      final pendingName = _openName;
      _openPrompt = null;
      _openName = null;
      _thread = AgentThreadScreen(
        // Ключ по сессии: смена разговора обязана выбросить состояние прежнего — прокрутку,
        // черновик в поле ввода и раскрытые карточки инструментов
        key: ValueKey<String>(session.id),
        session: session,
        project: project,
        embedded: true,
        paneWidth: width,
        onDismiss: _clearSelection,
        initialPrompt: prompt,
        pendingName: pendingName,
      );
    }
    return _thread!;
  }

  /// Тело списка: индикатор загрузки, кнопка новой сессии и сами разговоры.
  Widget _body(AgentSessionsState state, {required bool wide}) {
    if (state.loading && state.sessions.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final count = state.sessions.length;
    final empty = count == 0;
    return RefreshIndicator(
      onRefresh: () => _sessions.load(),
      child: ListView.builder(
        // список обязан оставаться прокручиваемым даже из нескольких строк: иначе короткое
        // содержимое не даст ни потянуть вниз для обновления, ни толкнуть колесом
        physics: const AlwaysScrollableScrollPhysics(),
        // низ отбит от края: плавающей кнопки больше нет, но список упирался бы в системную
        // полосу жестов на телефоне
        padding: EdgeInsets.only(bottom: navBarInset(context) + 24),
        // последним элементом идёт кнопка новой сессии: список идёт от старых разговоров к новым,
        // и кнопка стоит там же, где появится заведённый ею разговор
        itemCount: count + 1 + (empty ? 1 : 0),
        itemBuilder: (context, i) {
          // мост отдаёт разговоры новыми сверху, а раздел показывает их наоборот — старыми
          // вверх: строка с номером `i` — та же сессия, только с другого конца списка
          if (i < count) return _sessionTile(state.sessions[count - 1 - i], wide: wide);
          // пояснение стоит выше кнопки — так оно читается до неё, а не после
          if (i == count && empty) return _emptyHint();
          return _addTile(state, wide: wide);
        },
      ),
    );
  }

  /// Кнопка новой сессии: последняя строка списка.
  ///
  /// Лейаут — как у строки разговора ([_sessionTile]): значок слева, имя за ним, те же отступы
  /// и высота. От строк списка её отличает только цвет: знак «плюс» и подпись акцентные, чтобы
  /// кнопку было видно среди разговоров, но она не перетягивала взгляд заливкой во всю ширину.
  ///
  /// Раньше это была плавающая кнопка в углу, затем полоса во всю ширину в самом верху: внизу
  /// же она оказывается там, где появляются новые разговоры, и не разрывает порядок списка.
  Widget _addTile(AgentSessionsState state, {required bool wide}) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: state.loading ? null : () => _newSession(wide: wide),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            const Icon(Icons.add, size: 22, color: C.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Новая сессия',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: C.accent, fontSize: 15),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// Пояснение над кнопкой, когда разговоров ещё нет.
  Widget _emptyHint() => const Padding(
    // без нижнего поля: оно отделяло бы пояснение от кнопки, под которой оно стоит
    padding: EdgeInsets.fromLTRB(24, 24, 24, 0),
    child: Text(
      'Разговоров пока нет. Нажмите «Новая сессия» — выберите папку и модель, и агент '
      'запустится в ней: он сможет читать и править файлы проекта и запускать команды.',
      textAlign: TextAlign.center,
      style: TextStyle(color: C.fg3, fontSize: 13, height: 1.4),
    ),
  );

  /// Строка списка: значок состояния разговора и его имя.
  ///
  /// Значок отвечает на единственный вопрос, который задаёт список, — считает ли агент
  /// прямо сейчас: пустой круг — ничего не происходит, вращение — считает, галочка — ответ
  /// готов и его ещё не открывали. Харнесса, модели, проекта и числа сообщений в строке нет:
  /// по ним разговор не выбирают, а место они отнимали больше, чем имя.
  ///
  /// Высота строки — как у пункта левого бара (значок и отступ 11 сверху и снизу): оба
  /// списка читаются одним ритмом.
  Widget _sessionTile(AgentSession session, {required bool wide}) {
    final activity = ref.watch(agentActivityProvider);
    final selected = wide && session.id == _selectedId;
    // Считает прямо сейчас — даже если экран разговора закрыт; «готово» — закончил, пока
    // на него не смотрели
    final running = session.busy || activity.isRunning(session.id);
    final finished = !running && activity.isFinished(session.id);
    // `Material` на строку — ради отклика на нажатие: подложку выбранного разговора рисует
    // он же, и всплеск от нажатия оказывается поверх подсветки, а не под ней
    return Material(
      color: selected ? C.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: session.path.isEmpty ? null : () => _openOrSelect(session, wide: wide),
        // Действия над разговором — по длинному нажатию: удаление иконкой в строке спорило за
        // место с именем, а на телефоне в неё легко попасть мимо
        onLongPress: () => _actions(session),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(
            children: [
              Icon(
                running
                    ? Icons.autorenew
                    : finished
                    ? Icons.check_circle
                    : Icons.circle_outlined,
                size: 22,
                color: running || finished ? C.ok : C.fg3,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _title(session),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: C.fg, fontSize: 15),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Открывает разговор из строки списка.
  ///
  /// Повторное нажатие на уже открытый разговор ничего не делает: перезапускать процесс на
  /// маке ради того же самого незачем.
  void _openOrSelect(AgentSession session, {required bool wide}) {
    if (wide && session.id == _selectedId) return;
    _open(
      AgentProject.fromPath(session.path),
      harness: session.harness.isEmpty ? 'pi' : session.harness,
      sessionId: session.id,
      embedded: wide,
    );
  }

  /// Меню действий над разговором, которое открывает длинное нажатие.
  ///
  /// Показывается карточкой по центру экрана, а не полосой снизу: полоса прижималась к
  /// нижнему краю и растягивалась во всю ширину, так что на телефоне действия читались
  /// отдельно от строки, которую ими правят. Центрированная карточка держит имя разговора и
  /// действия рядом друг с другом и не упирается в края экрана; ширина ограничена, иначе на
  /// планшете и маке карточка расползлась бы во весь экран.
  ///
  /// Имя разговора стоит в меню заголовком: по строке, которую нажали, не всегда видно, что
  /// именно переименовываешь или удаляешь.
  Future<void> _actions(AgentSession session) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: C.surface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  _title(session),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: C.fg3, fontSize: 13),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline, color: C.fg2),
                title: const Text('Переименовать'),
                onTap: () => Navigator.pop(ctx, 'rename'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: C.danger),
                title: const Text('Удалить сессию'),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'rename') await _rename(session);
    if (action == 'delete') await _delete(session);
  }

  /// Переименовывает разговор.
  ///
  /// Имя хранят сами харнессы, в журнале разговора (у pi — запись `session_info`, у Claude
  /// Code — `custom-title`), поэтому переименование видно и в `/resume` на маке, а не только
  /// в приложении. Имя в список и в шапку открытого разговора ставим по ответу моста: он
  /// отдаёт строку уже очищенной от лишних пробелов.
  Future<void> _rename(AgentSession session) async {
    final name = await promptDialog(
      context,
      'Имя разговора',
      initial: session.name,
    );
    if (!mounted || name == null) return;
    final clean = name.trim();
    if (clean.isEmpty) return;
    final saved = await _sessions.rename(session.id, clean);
    if (!mounted || saved == null) return;
    // Открытый справа разговор берёт имя из своего состояния, а не из списка: без этого
    // шапка осталась бы со старым именем, пока разговор не переоткроют
    if (_opened?.id == session.id) {
      ref.read(agentThreadProvider.notifier).rename(saved);
    }
  }

  /// Сообщение об ошибке над списком: «мост недоступен» — состояние раздела, а не сбой строки.
  ///
  /// Кнопка повторяет то действие, которое упало ([_retry]); если такого нет — просто
  /// перечитывает список и снимок работы.
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
          onPressed: () {
            final retry = _retry;
            _retry = null;
            if (retry != null) {
              retry();
              return;
            }
            _refresh();
          },
          child: const Text('Повторить'),
        ),
      ],
    ),
  );
}
