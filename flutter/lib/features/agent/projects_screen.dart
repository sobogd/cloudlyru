import 'dart:async';

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

class ProjectsScreen extends ConsumerStatefulWidget {
  const ProjectsScreen({super.key});

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

enum _Tab {
  sessions,

  harness,

  pulls,
}

class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
  static const _twoPaneMin = 720.0;

  static const _sidebarMin = 300.0;
  static const _sidebarMax = 380.0;

  late final AgentSessionsController _sessions;

  late final AgentHarnessSessionsController _harness;

  _Tab _tab = _Tab.sessions;

  String? _openPrompt;

  String? _openName;

  late final AgentProjectsController _projects;

  Timer? _ticker;

  AppLifecycleListener? _lifecycle;

  int _ticks = 0;

  Set<String> _finishedBefore = const {};

  String? _selectedId;

  AgentSessionInfo? _opened;

  AgentProject? _openProject;

  bool _starting = false;

  int _openSeq = 0;

  Widget? _thread;
  String? _threadKey;

  Future<void> Function()? _retry;

  @override
  void initState() {
    super.initState();
    _sessions = ref.read(agentSessionsProvider.notifier);
    _harness = ref.read(agentHarnessSessionsProvider.notifier);
    _projects = ref.read(agentProjectsProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _projects.load();
      ref.read(agentHarnessesProvider.notifier).load();
      _sessions.load();
      _harness.load();
      ref.read(agentActivityProvider.notifier).load();
      _ticker = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
      _lifecycle = AppLifecycleListener(onResume: _refresh);
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

  void _refresh() {
    if (!mounted) return;
    _ticks += 1;
    if (_ticks <= 4 || _ticks % 6 == 0) {
      _sessions.load(silent: true);
      _harness.load(silent: true);
    }
    ref.read(agentActivityProvider.notifier).load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  Future<void> _newSession({
    required bool wide,
    String? prompt,
    String? sessionName,
  }) async {    if (sessionName != null && sessionName.isNotEmpty) {
      final existing = findReviewSession(ref, sessionName);
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
      nameIt: choice.name.isNotEmpty ? choice.name : sessionName,
      reviewKey: sessionName,
    );
  }

  void _openNewHarness({required bool wide}) {
    _open(AgentProject.fromPath(''), harness: 'harness', embedded: wide);
  }

  Future<void> _open(
    AgentProject project, {
    String harness = 'pi',
    String? sessionId,
    String? modelKey,
    required bool embedded,
    String? prompt,
    String? nameIt,
    String? reviewKey,
  }) async {
    _openPrompt = prompt;
    _openName = nameIt;
    if (sessionId != null) {
      ref.read(agentActivityProvider.notifier).markSeen(sessionId);
    }
    final seq = ++_openSeq;
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
            builder: (_) => AgentThreadScreen(session: fast, project: project, hidden: true),
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
      effort: harness == 'claude'
          ? ref.read(settingsProvider).ui.agentEffort('claude')
          : null,
    );
    if (seq != _openSeq) return;
    if (session == null) {
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
    if (project.path.isEmpty && session.path.isNotEmpty) {
      project = AgentProject.fromPath(session.path);
    }
    final pendingName = sessionId == null && nameIt != null
        ? await applySessionName(ref, session.id, nameIt)
        : null;
    if (sessionId == null && reviewKey != null && reviewKey.isNotEmpty) {
      await rememberReviewSession(ref, reviewKey, session.id);
    }
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
      CupertinoPageRoute<void>(
        builder: (_) => AgentThreadScreen(
          session: session,
          project: project,
          initialPrompt: prompt,
          pendingName: pendingName,
          hidden: true,
        ),
      ),
    );
    _openPrompt = null;
    _openName = null;
    if (mounted) await _sessions.load();
  }

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

  void _clearSelection() => setState(() {
    _openSeq++;
    _starting = false;
    _selectedId = null;
    _opened = null;
    _openProject = null;
  });

  void _pruneSelection() {
    final id = _selectedId;
    if (id == null) return;
    if (ref.read(agentSessionsProvider).sessions.any((s) => s.id == id)) return;
    if (ref.read(agentHarnessSessionsProvider).sessions.any((s) => s.id == id)) return;
    _clearSelection();
  }

  Future<void> _delete(AgentSession session) async {
    final isHarness = session.harness == 'harness';
    final ok = await confirmDialog(
      context,
      'Удалить сессию',
      'Разговор «${_title(session)}» будет удалён на маке вместе с историей '
          '(${session.messages} сообщ.). Восстановить его нечем.',
      danger: true,
      confirmLabel: 'Удалить',
    );
    if (!ok || !mounted) return;
    final AgentDeleteResult? result = isHarness
        ? await _harness.remove(session.id)
        : await _sessions.remove(session.id);
    if (!mounted || result == null) return;
    _pruneSelection();
    if (!isHarness && result.anyRestored) {
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

  String _title(AgentSession session) {
    if (session.name.isNotEmpty) return session.name;
    if (session.preview.isNotEmpty) return session.preview;
    return 'Сессия ${session.id.substring(session.id.lastIndexOf('-') + 1).substring(0, 8)}';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(agentSessionsProvider);

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= _twoPaneMin;
        return wide ? _twoPaneBody(state, c.maxWidth) : _singlePane(state);
      },
    );
  }

  Widget _singlePane(AgentSessionsState state) => Scaffold(
    body: _sidebar(state, wide: false),
  );

  Widget _twoPaneBody(AgentSessionsState state, double width) {
    final sidebar = (width * 0.34).clamp(_sidebarMin, _sidebarMax);
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: sidebar, child: _sidebar(state, wide: true)),
          const VerticalDivider(width: 1, thickness: 1, color: C.brd),
          Expanded(child: _detail(width - sidebar - 1)),
        ],
      ),
    );
  }

  Widget _sidebar(AgentSessionsState state, {required bool wide}) => Material(
    color: C.island,
    child: Column(
      children: [
        _sidebarHeader(),
        if (state.error != null) _errorBar(state.error!),
        Expanded(
          child: switch (_tab) {
            _Tab.sessions => _body(state, wide: wide),
            _Tab.harness => _harnessBody(ref.watch(agentHarnessSessionsProvider), wide: wide),
            _Tab.pulls => PullRequestsScreen(
              embedded: true,
              onReview: (name, prompt) =>
                  _newSession(wide: wide, prompt: prompt, sessionName: name),
            ),
          },
        ),
      ],
    ),
  );

  Widget _sidebarHeader() => SizedBox(
    height: 56,
    child: Padding(
      padding: const EdgeInsets.only(left: 16, right: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              switch (_tab) {
                _Tab.sessions => 'Проекты',
                _Tab.harness => 'Харнесс',
                _Tab.pulls => 'Пул-реквесты',
              },
              style: const TextStyle(color: C.fg, fontSize: 18),
            ),
          ),
          _tabButton(_Tab.sessions, Icons.forum_outlined, 'Разговоры'),
          _tabButton(_Tab.harness, Icons.build_outlined, 'Харнесс'),
          _tabButton(_Tab.pulls, Icons.merge_type, 'Пул-реквесты'),
        ],
      ),
    ),
  );

  Widget _tabButton(_Tab tab, IconData icon, String tooltip) => IconButton(
    tooltip: tooltip,
    onPressed: _tab == tab ? null : () => setState(() => _tab = tab),
    icon: Icon(icon, size: 20, color: _tab == tab ? C.fg : C.fg2),
  );

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

  Widget _threadView(AgentSessionInfo session, AgentProject project, double width) {
    final key = '${session.id}@$width';
    if (_threadKey != key || _thread == null) {
      _threadKey = key;
      final prompt = _openPrompt;
      final pendingName = _openName;
      _openPrompt = null;
      _openName = null;
      _thread = AgentThreadScreen(
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

  Widget _body(AgentSessionsState state, {required bool wide}) {
    if (state.loading && state.sessions.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final count = state.sessions.length;
    final empty = count == 0;
    return RefreshIndicator(
      onRefresh: () => _sessions.load(),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(bottom: navBarInset(context) + 24),
        itemCount: count + 1 + (empty ? 1 : 0),
        itemBuilder: (context, i) {
          if (i < count) return _sessionTile(state.sessions[count - 1 - i], wide: wide);
          if (i == count && empty) return _emptyHint();
          return _addTile(state, wide: wide);
        },
      ),
    );
  }

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

  Widget _emptyHint() => const Padding(
    padding: EdgeInsets.fromLTRB(24, 24, 24, 0),
    child: Text(
      'Разговоров пока нет. Нажмите «Новая сессия» — выберите папку и модель, и агент '
      'запустится в ней: он сможет читать и править файлы проекта и запускать команды.',
      textAlign: TextAlign.center,
      style: TextStyle(color: C.fg3, fontSize: 13, height: 1.4),
    ),
  );

  Widget _harnessBody(AgentHarnessSessionsState state, {required bool wide}) {
    if (state.loading && state.sessions.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final count = state.sessions.length;
    final empty = count == 0;
    return RefreshIndicator(
      onRefresh: () => _harness.load(),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(bottom: navBarInset(context) + 24),
        itemCount: count + 1 + (empty ? 1 : 0),
        itemBuilder: (context, i) {
          if (i < count) return _sessionTile(state.sessions[count - 1 - i], wide: wide);
          if (i == count && empty) return _harnessEmptyHint();
          return _harnessAddTile(wide: wide);
        },
      ),
    );
  }

  Widget _harnessAddTile({required bool wide}) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: () => _openNewHarness(wide: wide),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            const Icon(Icons.add, size: 22, color: C.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Новый прогон',
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

  Widget _harnessEmptyHint() => const Padding(
    padding: EdgeInsets.fromLTRB(24, 24, 24, 0),
    child: Text(
      'Прогонов пока нет. Нажмите «Новый прогон» — LLM-агент запустится на маке, '
      'он сможет читать файлы и выполнять команды.',
      textAlign: TextAlign.center,
      style: TextStyle(color: C.fg3, fontSize: 13, height: 1.4),
    ),
  );

  Widget _sessionTile(AgentSession session, {required bool wide}) {
    final activity = ref.watch(agentActivityProvider);
    final selected = wide && session.id == _selectedId;
    final running = session.busy || activity.isRunning(session.id);
    final finished = !running && activity.isFinished(session.id);
    return Material(
      color: selected ? C.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: session.path.isEmpty ? null : () => _openOrSelect(session, wide: wide),
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

  void _openOrSelect(AgentSession session, {required bool wide}) {
    if (wide && session.id == _selectedId) return;
    _open(
      AgentProject.fromPath(session.path),
      harness: session.harness.isEmpty ? 'pi' : session.harness,
      sessionId: session.id,
      embedded: wide,
    );
  }

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

  Future<void> _rename(AgentSession session) async {
    final name = await promptDialog(
      context,
      'Имя разговора',
      initial: session.name,
    );
    if (!mounted || name == null) return;
    final clean = name.trim();
    if (clean.isEmpty) return;
    final String? saved = session.harness == 'harness'
        ? await _harness.rename(session.id, clean)
        : await _sessions.rename(session.id, clean);
    if (!mounted || saved == null) return;
    if (_opened?.id == session.id) {
      ref.read(agentThreadProvider.notifier).rename(saved);
    }
  }

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
