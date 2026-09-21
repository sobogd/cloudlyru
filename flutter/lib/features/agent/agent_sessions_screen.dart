import 'dart:async';

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

  /// Обновление списка и снимка работы, пока экран открыт.
  ///
  /// Раз в пять секунд: этого хватает, чтобы увидеть чужой прогон (с телефона или из терминала)
  /// и что разговор дописался, а лишних запросов к маку не плодит.
  Timer? _ticker;

  /// Какие разговоры были «готовы» на прошлом проходе — чтобы показать про новые один раз.
  Set<String> _finishedBefore = const {};

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
      _sessions.load(widget.project).then((_) {
        if (mounted) _sessions.selectHarness(_harness);
      });
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
  ///
  /// Вызывается таймером: чужой прогон виден только так — мост не присылает событий тому, кто
  /// на него не подписан.
  void _refresh() {
    if (!mounted) return;
    _sessions.load(widget.project, silent: true);
    ref.read(agentActivityProvider.notifier).load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Открывает сессию (новую или существующую) и переходит в переписку.
  ///
  /// Открытие — это запуск процесса pi на маке: он занимает секунду-две, поэтому кнопка на это
  /// время гаснет, а отказ показывается на экране, а не молчанием. У новой сессии модель берётся
  /// из выбранной ранее (`ui.agentModel`), у существующей — та, что записана в её файле.
  Future<void> _open({String? sessionId, String? harness}) async {
    // Разговор, который открывают, больше не «готов»: человек увидит его сам
    if (sessionId != null) {
      ref.read(agentActivityProvider.notifier).markSeen(sessionId);
    }
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
            // Уборка старых разговоров: у Claude Code их копятся сотни (в ~/work/tangem их было
            // 246), и по одному они не удаляются — нужна разовая чистка с понятным правилом
            tooltip: 'Убрать старые',
            onPressed: state.loading ? null : _purge,
            icon: const Icon(Icons.cleaning_services_outlined),
          ),
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
        onSelectionChanged: (value) {
          setState(() => _harness = value.first);
          _sessions.selectHarness(_harness);
        },
      ),
    );
  }

  /// Убирает старые сессии выбранного харнесса по выбранному правилу.
  ///
  /// Правило выбирает человек, и числа он видит до нажатия: диалог считает, сколько разговоров
  /// уйдёт по каждому варианту. Удаление необратимо, поэтому подтверждение отдельное и с числом.
  Future<void> _purge() async {
    final state = ref.read(agentSessionsProvider);
    final sessions = [
      for (final s in state.sessions)
        if (s.harness == _harness) s,
    ];
    if (sessions.isEmpty) {
      snack(context, 'Убирать нечего: разговоров у этого агента нет');
      return;
    }
    final rule = await showDialog<_PurgeRule>(
      context: context,
      builder: (_) => _PurgeDialog(
        sessions: sessions,
        harnessName: ref.read(agentHarnessesProvider).nameOf(_harness),
      ),
    );
    if (rule == null || !mounted) return;

    final ok = await confirmDialog(
      context,
      'Убрать старые сессии',
      '${rule.count} разговоров будут удалены на маке вместе с историей. Восстановить их нечем.',
      danger: true,
      confirmLabel: 'Удалить',
    );
    if (!ok || !mounted) return;
    final result = await _sessions.purgeOld(
      olderThanDays: rule.olderThanDays,
      keep: rule.keep,
    );
    if (!mounted || result == null) return;
    final restored = result.anyRestored
        ? ', ${result.restored} вернулись: их ведут живые процессы Claude Code'
        : '';
    snack(context, 'Удалено разговоров: ${result.deleted}$restored');
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
      leading: Icon(
        _harnessIcon(session.harness),
        // значок агента подсвечен, пока он работает или пока ответ ждёт просмотра: разговор
        // может считаться и без открытого экрана, и это должно быть видно из списка
        color:
            session.busy ||
                ref.watch(agentActivityProvider).isRunning(session.id) ||
                ref.watch(agentActivityProvider).isFinished(session.id)
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
          if (session.busy ||
              ref.watch(agentActivityProvider).isRunning(session.id))
            '● работает'
          else if (ref.watch(agentActivityProvider).isFinished(session.id))
            '✓ готово',
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

/// Правило уборки: что именно удалять и сколько разговоров под него попадает.
class _PurgeRule {
  /// Удалять старше стольких дней; `null` — по возрасту не ограничиваем.
  final int? olderThanDays;

  /// Сколько самых свежих разговоров не трогать; `null` — не защищаем ничего.
  final int? keep;

  /// Сколько разговоров уйдёт по этому правилу (посчитано заранее, для подтверждения).
  final int count;

  /// Правило уборки.
  const _PurgeRule({this.olderThanDays, this.keep, required this.count});
}

/// Диалог уборки: два правила с готовыми числами.
///
/// Числа считаются здесь же, из уже загруженного списка: человек должен видеть «удалится 192»
/// до нажатия, а не узнавать это по факту.
class _PurgeDialog extends StatefulWidget {
  /// Сессии выбранного харнесса в этом проекте.
  final List<AgentSession> sessions;

  /// Название харнесса для подписи.
  final String harnessName;

  /// Диалог уборки.
  const _PurgeDialog({required this.sessions, required this.harnessName});

  @override
  State<_PurgeDialog> createState() => _PurgeDialogState();
}

/// Состояние диалога: выбранное правило.
class _PurgeDialogState extends State<_PurgeDialog> {
  /// Выбрано правило «оставить только свежие».
  bool _keepFresh = false;

  /// Сколько свежих разговоров оставляем во втором правиле.
  static const _keepFreshCount = 5;

  /// Сколько удалится, если оставить [_keepFreshCount] самых свежих.
  int get _countKeepFresh => _countFor(keep: _keepFreshCount);

  /// Сколько удалится, если убрать старше недели.
  int get _countByAge => _countFor(olderThanDays: 7);

  /// Считает, сколько сессий попадёт под правило.
  ///
  /// Повторяет арифметику моста: свежие защищены, остальное удаляется по возрасту. Нужно, чтобы
  /// число в диалоге совпадало с тем, что произойдёт на маке.
  int _countFor({int? olderThanDays, int? keep}) {
    final sorted = [...widget.sessions]
      ..sort(
        (a, b) =>
            (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)),
      );
    final protected = <String>{
      if (keep != null)
        for (final s in sorted.take(keep)) s.id,
    };
    final threshold = olderThanDays == null
        ? null
        : DateTime.now().subtract(Duration(days: olderThanDays));
    return widget.sessions
        .where(
          (s) =>
              !protected.contains(s.id) &&
              (threshold == null || (s.updatedAt?.isBefore(threshold) ?? true)),
        )
        .length;
  }

  @override
  Widget build(BuildContext context) {
    final keepCount = _countKeepFresh;
    final weekCount = _countByAge;
    return AlertDialog(
      backgroundColor: C.surface,
      title: Text(
        'Убрать старые · ${widget.harnessName}',
        style: const TextStyle(color: C.fg, fontSize: 16),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Всего разговоров: ${widget.sessions.length}. Удаление необратимо.',
            style: const TextStyle(color: C.fg3, fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 8),
          RadioGroup<bool>(
            groupValue: _keepFresh,
            onChanged: (v) => setState(() => _keepFresh = v ?? false),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<bool>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: false,
                  title: Text(
                    'Удалить старше 7 дней — $weekCount',
                    style: const TextStyle(color: C.fg, fontSize: 14),
                  ),
                  subtitle: const Text(
                    'Разговоры за последнюю неделю остаются все',
                    style: TextStyle(color: C.fg3, fontSize: 11.5),
                  ),
                ),
                RadioListTile<bool>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: true,
                  title: Text(
                    'Оставить только $_keepFreshCount свежих — $keepCount',
                    style: const TextStyle(color: C.fg, fontSize: 14),
                  ),
                  subtitle: const Text(
                    'Всё остальное, включая вчерашнее, удаляется',
                    style: TextStyle(color: C.fg3, fontSize: 11.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(
            _keepFresh
                ? _PurgeRule(keep: _keepFreshCount, count: keepCount)
                : _PurgeRule(olderThanDays: 7, count: weekCount),
          ),
          child: const Text('Дальше'),
        ),
      ],
    );
  }
}
