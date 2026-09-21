import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import 'agent_controller.dart';
import 'agent_new_session.dart';
import 'agent_providers_screen.dart';
import 'agent_purge.dart';
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
/// `/projects/*`. Кнопка «+» открывает мастер: папка → модель (локальные, удалённые, Claude Code).
class ProjectsScreen extends ConsumerStatefulWidget {
  /// Экран раздела «Проекты».
  const ProjectsScreen({super.key});

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

/// Состояние экрана: контроллеры, снимок работы и признак «открываю сессию».
class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
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
  Future<void> _newSession() async {
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
    );
  }

  /// Открывает сессию (новую или существующую) и переходит в переписку.
  ///
  /// Открытие — это запуск процесса агента на маке: он занимает секунду-две, поэтому кнопка на
  /// это время гаснет, а отказ показывается на экране, а не молчанием.
  Future<void> _open(
    AgentProject project, {
    String harness = 'pi',
    String? sessionId,
    String? modelKey,
  }) async {
    // Разговор, который открывают, больше не «готов»: человек увидит его сам
    if (sessionId != null) {
      ref.read(agentActivityProvider.notifier).markSeen(sessionId);
    }
    final session = await _sessions.open(
      project,
      harness: harness,
      sessionId: sessionId,
      modelKey: modelKey,
    );
    if (session == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            AgentThreadScreen(session: session, project: project),
      ),
    );
    if (mounted) await _sessions.load();
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
    final result = await _sessions.remove(session.id);
    if (!mounted || result == null) return;
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

  /// Закрывает процесс сессии на маке: история остаётся, память под контекст освобождается.
  Future<void> _close(AgentSession session) async {
    await _sessions.close(session.id);
    if (mounted) snack(context, 'Сессия закрыта на маке (история сохранена)');
  }

  /// Уборка старых разговоров: папку, харнесс и правило выбирают в диалоге.
  ///
  /// В общем списке ни папки, ни харнесса не задано, поэтому их выбирает человек. Число уходящих
  /// разговоров видно до подтверждения — удаление необратимо.
  Future<void> _purge() async {
    final projects = ref.read(agentProjectsProvider).projects;
    if (projects.isEmpty) {
      snack(context, 'Список папок ещё не загружен');
      return;
    }
    final choice = await showPurgeDialog(
      context,
      projects: projects,
      sessions: ref.read(agentSessionsProvider).sessions,
      harnesses: ref.read(agentHarnessesProvider).available,
    );
    if (choice == null || !mounted) return;
    if (choice.count == 0) {
      snack(context, 'Убирать нечего: под это правило ничего не попадает');
      return;
    }
    final ok = await confirmDialog(
      context,
      'Убрать старые сессии',
      '${choice.count} разговоров будут удалены в «${choice.project.name}» на маке вместе с '
          'историей. Восстановить их нечем.',
      danger: true,
      confirmLabel: 'Удалить',
    );
    if (!ok || !mounted) return;
    final result = await _sessions.purgeOld(
      project: choice.project,
      harness: choice.harness,
      olderThanDays: choice.olderThanDays,
      keep: choice.keep,
    );
    if (!mounted || result == null) return;
    final restored = result.anyRestored
        ? ', ${result.restored} вернулись: их ведут живые процессы Claude Code'
        : '';
    snack(context, 'Удалено разговоров: ${result.deleted}$restored');
  }

  /// Подпись разговора для списка и вопросов: имя, а если его нет — начало идентификатора.
  String _title(AgentSession session) => session.name.isEmpty
      ? 'Сессия ${session.id.substring(0, 8)}'
      : session.name;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(agentSessionsProvider);
    final projects = ref.watch(agentProjectsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Проекты',
          style: TextStyle(color: C.fg, fontSize: 18),
        ),
        actions: [
          IconButton(
            // Провайдеры и ключи — рядом с моделями, а не в «Настройках» приложения: это
            // настройка харнесса на маке, и живёт она там же, где список разговоров
            tooltip: 'Модели и ключи',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AgentProvidersScreen(),
              ),
            ),
            icon: const Icon(Icons.vpn_key_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: 'Ещё',
            onSelected: (v) => v == 'purge' ? _purge() : null,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'purge',
                child: Text('Убрать старые…'),
              ),
            ],
          ),
          IconButton(
            tooltip: 'Обновить список',
            onPressed: state.loading ? null : () => _sessions.load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Новая сессия',
        backgroundColor: C.accent,
        foregroundColor: C.accentFg,
        onPressed: state.loading ? null : _newSession,
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          // чем отвечает харнесс: без этой строки непонятно, какая модель считает — а на маке
          // она одна на чат и на агента
          if (projects.health.label.isNotEmpty) _harnessLine(projects.health),
          if (state.error != null) _errorBar(state.error!),
          Expanded(child: _body(state)),
        ],
      ),
    );
  }

  /// Тело экрана: индикатор загрузки, пустой список или сами разговоры.
  Widget _body(AgentSessionsState state) {
    if (state.loading && state.sessions.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Разговоров пока нет. Нажмите «+» — выберите папку и модель, и агент запустится '
            'в ней: он сможет читать и править файлы проекта и запускать команды.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: C.fg3, fontSize: 13, height: 1.4),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _sessions.load(),
      child: ListView.builder(
        padding: EdgeInsets.only(bottom: 88 + navBarInset(context)),
        itemCount: state.sessions.length,
        itemBuilder: (context, i) => _sessionTile(state.sessions[i]),
      ),
    );
  }

  /// Строка списка: имя разговора, проект, харнесс, модель, число сообщений и время.
  Widget _sessionTile(AgentSession session) {
    final activity = ref.watch(agentActivityProvider);
    return ListTile(
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
          : () => _open(
              AgentProject.fromPath(session.path),
              harness: session.harness.isEmpty ? 'pi' : session.harness,
              sessionId: session.id,
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

  /// Строка о харнессе и модели над списком.
  Widget _harnessLine(AgentHealth health) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        health.label,
        style: const TextStyle(color: C.fg3, fontSize: 12),
      ),
    ),
  );

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
