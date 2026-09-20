import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import 'agent_controller.dart';
import 'agent_thread_screen.dart';
import 'agent_types.dart';

/// Сессии одного проекта: список прошлых разговоров и вход в новый.
///
/// Сессии — это файлы pi (`~/.pi/agent/sessions/--<путь>--/`), поэтому список показывает то
/// же, что человек увидит в терминале командой `pi -r`: разговор, начатый здесь, продолжается
/// на маке, и наоборот.
class AgentSessionsScreen extends ConsumerStatefulWidget {
  /// Проект, чьи сессии открываются.
  final AgentProject project;

  /// Экран сессий проекта.
  const AgentSessionsScreen({super.key, required this.project});

  @override
  ConsumerState<AgentSessionsScreen> createState() => _AgentSessionsScreenState();
}

/// Состояние экрана: контроллер списка и признак «открываю сессию».
class _AgentSessionsScreenState extends ConsumerState<AgentSessionsScreen> {
  /// Контроллер списка сессий.
  late final AgentSessionsController _sessions;

  @override
  void initState() {
    super.initState();
    _sessions = ref.read(agentSessionsProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sessions.load(widget.project);
    });
  }

  /// Открывает сессию (новую или существующую) и переходит в переписку.
  ///
  /// Открытие — это запуск процесса pi на маке: он занимает секунду-две, поэтому кнопка
  /// на это время гаснет, а отказ моста показывается на экране, а не молчанием.
  Future<void> _open({String? sessionId}) async {
    final session = await _sessions.open(widget.project, sessionId: sessionId);
    if (session == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentThreadScreen(session: session, project: widget.project),
      ),
    );
    if (mounted) await _sessions.load(widget.project);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(agentSessionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.project.name,
          style: const TextStyle(color: C.fg, fontSize: 18),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Обновить список',
            onPressed: state.loading ? null : () => _sessions.load(widget.project),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: 'Новая сессия',
        backgroundColor: C.accent,
        foregroundColor: C.accentFg,
        onPressed: state.loading ? null : () => _open(),
        icon: const Icon(Icons.add),
        label: const Text('Новая сессия'),
      ),
      body: Column(
        children: [
          // путь проекта целиком: по имени папки не всегда понятно, какая это копия
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                widget.project.path,
                style: const TextStyle(color: C.fg3, fontSize: 12),
              ),
            ),
          ),
          if (state.error != null) _errorBar(state.error!),
          Expanded(child: _body(state)),
        ],
      ),
    );
  }

  /// Тело экрана: индикатор, пустой список или сами сессии.
  Widget _body(AgentSessionsState state) {
    if (state.loading && state.sessions.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'В этом проекте ещё не было разговоров. Нажмите «Новая сессия» — агент запустится '
            'в папке ${widget.project.name} и сможет читать и править её файлы.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: C.fg3, fontSize: 13, height: 1.4),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _sessions.load(widget.project),
      child: ListView.builder(
        padding: EdgeInsets.only(bottom: 88 + navBarInset(context)),
        itemCount: state.sessions.length,
        itemBuilder: (context, i) => _sessionTile(state.sessions[i]),
      ),
    );
  }

  /// Строка списка: имя сессии, число сообщений и время последнего обращения.
  Widget _sessionTile(AgentSession session) {
    return ListTile(
      leading: const Icon(Icons.terminal, color: C.fg2),
      title: Text(
        session.name.isEmpty ? 'Сессия ${session.id.substring(0, 8)}' : session.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: C.fg, fontSize: 15),
      ),
      subtitle: Text(
        [
          '${session.messages} сообщ.',
          if (session.updatedAt != null) listDate(session.updatedAt!, DateTime.now()),
        ].join(' · '),
        style: const TextStyle(color: C.fg3, fontSize: 12),
      ),
      onTap: () => _open(sessionId: session.id),
    );
  }

  /// Сообщение об ошибке над списком.
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
              child: Text(message, style: const TextStyle(color: C.fg2, fontSize: 13, height: 1.3)),
            ),
            TextButton(
              onPressed: () => _sessions.load(widget.project),
              child: const Text('Повторить'),
            ),
          ],
        ),
      );
}
