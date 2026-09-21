import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
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
/// на маке, и наоборот. Здесь же сессию можно закрыть (освободить память мака, историю
/// сохранив) или удалить совсем.
class AgentSessionsScreen extends ConsumerStatefulWidget {
  /// Проект, чьи сессии открываются.
  final AgentProject project;

  /// Экран сессий проекта.
  const AgentSessionsScreen({super.key, required this.project});

  @override
  ConsumerState<AgentSessionsScreen> createState() =>
      _AgentSessionsScreenState();
}

/// Состояние экрана: контроллер списка, выбранный харнесс и признак «открываю сессию».
class _AgentSessionsScreenState extends ConsumerState<AgentSessionsScreen> {
  /// Контроллер списка сессий.
  late final AgentSessionsController _sessions;

  /// Выбранный харнесс: им же фильтруется список, и он же пойдёт новой сессии.
  ///
  /// Харнессы держат истории в разных местах на маке, и разговоры у них разные — показывать их
  /// одной кучей без деления значило бы путать «чем я это делал».
  String _harness = 'pi';

  @override
  void initState() {
    super.initState();
    _sessions = ref.read(agentSessionsProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // харнессы читаем сразу: от них зависит и список, и то, что предложить новой сессии
      ref.read(agentHarnessesProvider.notifier).load();
      _sessions.load(widget.project);
    });
  }

  /// Открывает сессию (новую или существующую) и переходит в переписку.
  ///
  /// Открытие — это запуск процесса pi на маке: он занимает секунду-две, поэтому кнопка на это
  /// время гаснет, а отказ показывается на экране, а не молчанием. У новой сессии модель берётся
  /// из выбранной ранее (`ui.agentModel`), у существующей — та, что записана в её файле.
  Future<void> _open({String? sessionId, String? harness}) async {
    final target = harness ?? _harness;
    final modelKey = ref.read(settingsProvider).ui.agentModel(target);
    final session = await _sessions.open(
      widget.project,
      harness: target,
      sessionId: sessionId,
      modelKey: modelKey,
    );
    if (session == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            AgentThreadScreen(session: session, project: widget.project),
      ),
    );
    if (mounted) await _sessions.load(widget.project);
  }

  /// Удаляет сессию на маке вместе с историей.
  ///
  /// Спрашиваем подтверждение: файл стирается с диска, и вернуть разговор нечем. Отдельно от
  /// «закрыть» — там история остаётся и сессию можно открыть снова.
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
    await _sessions.remove(session.id);
    if (mounted) snack(context, 'Сессия удалена');
  }

  /// Закрывает процесс сессии на маке: история остаётся, память под контекст освобождается.
  Future<void> _close(AgentSession session) async {
    await _sessions.close(session.id);
    if (mounted) snack(context, 'Сессия закрыта на маке (история сохранена)');
  }

  /// Подпись сессии для списка и вопросов: имя, а если его нет — начало идентификатора.
  String _title(AgentSession session) => session.name.isEmpty
      ? 'Сессия ${session.id.substring(0, 8)}'
      : session.name;

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
            onPressed: state.loading
                ? null
                : () => _sessions.load(widget.project),
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
        label: Text(
          'Новая: ${ref.watch(agentHarnessesProvider).nameOf(_harness)}',
        ),
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
          _harnessPicker(),
          if (state.error != null) _errorBar(state.error!),
          Expanded(child: _body(state)),
        ],
      ),
    );
  }

  /// Переключатель харнесса: он же фильтр списка и выбор для новой сессии.
  ///
  /// Показывается, только если на маке больше одного харнесса: там, где стоит один, выбирать
  /// нечего.
  Widget _harnessPicker() {
    final harnesses = ref.watch(agentHarnessesProvider).available;
    if (harnesses.length < 2) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: SegmentedButton<String>(
        segments: [
          for (final harness in harnesses)
            ButtonSegment<String>(
              value: harness.harness,
              label: Text(harness.label),
              icon: Icon(_harnessIcon(harness.harness), size: 16),
            ),
        ],
        selected: <String>{_harness},
        showSelectedIcon: false,
        onSelectionChanged: (value) => setState(() => _harness = value.first),
      ),
    );
  }

  /// Значок харнесса: у pi терминал, у Claude Code — звёздочка его бренда.
  IconData _harnessIcon(String harness) =>
      harness == 'claude' ? Icons.auto_awesome : Icons.terminal;

  /// Тело экрана: индикатор, пустой список или сами сессии выбранного харнесса.
  Widget _body(AgentSessionsState state) {
    if (state.loading && state.sessions.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final sessions = [
      for (final s in state.sessions)
        if (s.harness == _harness) s,
    ];
    if (sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'У ${ref.watch(agentHarnessesProvider).nameOf(_harness)} в этом проекте ещё не было '
            'разговоров. Нажмите «Новая» — агент запустится в папке ${widget.project.name} и '
            'сможет читать и править её файлы.',
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
        itemCount: sessions.length,
        itemBuilder: (context, i) => _sessionTile(sessions[i]),
      ),
    );
  }

  /// Строка списка: имя сессии, харнесс, модель, число сообщений и время последнего обращения.
  Widget _sessionTile(AgentSession session) {
    return ListTile(
      leading: Icon(_harnessIcon(session.harness), color: C.fg2),
      title: Text(
        _title(session),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: C.fg, fontSize: 15),
      ),
      subtitle: Text(
        [
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
      onTap: () => _open(
        sessionId: session.id,
        harness: session.harness.isEmpty ? 'pi' : session.harness,
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'Действия',
        onSelected: (v) => v == 'close' ? _close(session) : _delete(session),
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'close', child: Text('Закрыть на маке')),
          PopupMenuItem(value: 'delete', child: Text('Удалить сессию')),
        ],
      ),
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
          child: Text(
            message,
            style: const TextStyle(color: C.fg2, fontSize: 13, height: 1.3),
          ),
        ),
        TextButton(
          onPressed: () => _sessions.load(widget.project),
          child: const Text('Повторить'),
        ),
      ],
    ),
  );
}
