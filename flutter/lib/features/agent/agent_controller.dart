import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import 'agent_api.dart';
import 'agent_types.dart';

final agentApiProvider = Provider<AgentApi>(
  (ref) => AgentApi(() => ref.read(appStateProvider).api),
);


class AgentHarnessesState {
  final List<AgentHarness> harnesses;

  final bool loading;

  final String? error;

  const AgentHarnessesState({
    this.harnesses = const [],
    this.loading = false,
    this.error,
  });

  List<AgentHarness> get available => [
    for (final h in harnesses)
      if (h.available) h,
  ];

  String nameOf(String harness) {
    for (final h in harnesses) {
      if (h.harness == harness) return h.label;
    }
    return harness;
  }
}

final agentHarnessesProvider =
    NotifierProvider<AgentHarnessesController, AgentHarnessesState>(
      AgentHarnessesController.new,
    );

class AgentHarnessesController extends Notifier<AgentHarnessesState> {
  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentHarnessesState build() => const AgentHarnessesState();

  Future<void> load() async {
    state = AgentHarnessesState(harnesses: state.harnesses, loading: true);
    try {
      state = AgentHarnessesState(harnesses: await _api.harnesses());
    } on AgentApiException catch (e) {
      state = AgentHarnessesState(harnesses: state.harnesses, error: e.message);
    }
  }
}


class AgentModelsState {
  final String harness;

  final List<AgentModel> models;

  final List<AgentEffort> efforts;

  final bool loading;

  final String? error;

  const AgentModelsState({
    this.harness = 'claude',
    this.models = const [],
    this.efforts = const [],
    this.loading = false,
    this.error,
  });

  List<AgentModel> get local => [
    for (final m in models)
      if (m.local) m,
  ];

  List<AgentModel> get remote => [
    for (final m in models)
      if (!m.local) m,
  ];

  AgentModel? byKey(String? key) {
    if (key == null || key.isEmpty) return null;
    for (final m in models) {
      if (m.key == key) return m;
    }
    return null;
  }
}

final agentModelsProvider =
    NotifierProvider<AgentModelsController, AgentModelsState>(
      AgentModelsController.new,
    );

class AgentModelsController extends Notifier<AgentModelsState> {
  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentModelsState build() => const AgentModelsState();

  Future<void> load({String harness = 'claude'}) async {
    final keep = state.harness == harness ? state.models : const <AgentModel>[];
    final keepEfforts = state.harness == harness
        ? state.efforts
        : const <AgentEffort>[];
    state = AgentModelsState(
      harness: harness,
      models: keep,
      efforts: keepEfforts,
      loading: true,
    );
    try {
      final (models, efforts) = await _api.catalog(harness: harness);
      state = AgentModelsState(
        harness: harness,
        models: models,
        efforts: efforts,
      );
    } on AgentApiException catch (e) {
      state = AgentModelsState(
        harness: harness,
        models: keep,
        efforts: keepEfforts,
        error: e.message,
      );
    }
  }
}


class AgentAllModelsState {
  final Map<String, List<AgentModel>> byHarness;

  final bool loading;

  final String? error;

  const AgentAllModelsState({
    this.byHarness = const {},
    this.loading = false,
    this.error,
  });

  List<AgentModel> of(String harness) => byHarness[harness] ?? const [];
}

final agentAllModelsProvider =
    NotifierProvider<AgentAllModelsController, AgentAllModelsState>(
      AgentAllModelsController.new,
    );

class AgentAllModelsController extends Notifier<AgentAllModelsState> {
  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentAllModelsState build() => const AgentAllModelsState();

  Future<void> load(List<String> harnesses) async {
    state = AgentAllModelsState(byHarness: state.byHarness, loading: true);
    final byHarness = <String, List<AgentModel>>{...state.byHarness};
    String? error;
    for (final harness in harnesses) {
      try {
        byHarness[harness] = await _api.models(harness: harness);
      } on AgentApiException catch (e) {
        error ??= e.message;
      }
    }
    state = AgentAllModelsState(byHarness: byHarness, error: error);
  }
}


class AgentActivityState {
  final AgentActivity activity;

  final String? error;

  const AgentActivityState({this.activity = AgentActivity.empty, this.error});

  bool isRunning(String id) => activity.running.contains(id);

  bool isFinished(String id) => activity.finished.contains(id);
}

final agentActivityProvider =
    NotifierProvider<AgentActivityController, AgentActivityState>(
      AgentActivityController.new,
    );

class AgentActivityController extends Notifier<AgentActivityState> {
  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentActivityState build() => const AgentActivityState();

  Future<void> load() async {
    try {
      state = AgentActivityState(activity: await _api.activity());
    } on AgentApiException catch (e) {
      state = AgentActivityState(activity: state.activity, error: e.message);
    }
  }

  void markSeen(String sessionId) {
    if (!state.activity.finished.contains(sessionId)) return;
    state = AgentActivityState(
      activity: AgentActivity(
        running: state.activity.running,
        finished: {
          for (final id in state.activity.finished)
            if (id != sessionId) id,
        },
        updatedAt: state.activity.updatedAt,
      ),
    );
  }
}


class AgentProjectsState {
  final List<AgentProject> projects;

  final AgentHealth health;

  final bool loading;

  final String? error;

  const AgentProjectsState({
    this.projects = const [],
    this.health = const AgentHealth(),
    this.loading = false,
    this.error,
  });

  AgentProjectsState copyWith({
    List<AgentProject>? projects,
    AgentHealth? health,
    bool? loading,
  }) => AgentProjectsState(
    projects: projects ?? this.projects,
    health: health ?? this.health,
    loading: loading ?? this.loading,
    error: error,
  );

  AgentProjectsState ready({
    List<AgentProject>? projects,
    AgentHealth? health,
  }) => AgentProjectsState(
    projects: projects ?? this.projects,
    health: health ?? this.health,
    loading: false,
  );

  AgentProjectsState withError(String message) => AgentProjectsState(
    projects: projects,
    health: health,
    loading: false,
    error: message,
  );
}

final agentProjectsProvider =
    NotifierProvider<AgentProjectsController, AgentProjectsState>(
      AgentProjectsController.new,
    );

class AgentProjectsController extends Notifier<AgentProjectsState> {
  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentProjectsState build() => const AgentProjectsState();

  Future<void> load() async {
    state = state.copyWith(loading: true);
    try {
      final health = await _api.health();
      final projects = await _api.projects();
      state = state.ready(projects: projects, health: health);
    } on AgentApiException catch (e) {
      state = state.withError(e.message);
    }
  }
}


class AgentSessionsState {
  final List<AgentSession> sessions;

  final bool loading;

  final String? error;

  const AgentSessionsState({
    this.sessions = const [],
    this.loading = false,
    this.error,
  });
}

final agentSessionsProvider =
    NotifierProvider<AgentSessionsController, AgentSessionsState>(
      AgentSessionsController.new,
    );

class AgentSessionsController extends Notifier<AgentSessionsState> {
  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentSessionsState build() => const AgentSessionsState();

  Future<void> load({bool silent = false}) async {
    state = AgentSessionsState(
      sessions: state.sessions,
      loading: !silent,
      error: state.error,
    );
    try {
      state = AgentSessionsState(sessions: await _api.sessions());
    } on AgentApiException catch (e) {
      state = AgentSessionsState(sessions: state.sessions, error: e.message);
    }
  }

  Future<AgentSessionInfo?> open(
    AgentProject project, {
    String harness = 'claude',
    String? sessionId,
    String? modelKey,
    String? effort,
  }) async {
    state = AgentSessionsState(
      sessions: state.sessions,
      loading: true,
      error: state.error,
    );
    try {
      final session = await _api.openSession(
        project.path,
        harness: harness,
        sessionId: sessionId,
        modelKey: sessionId == null ? modelKey : null,
        effort: harness == 'claude' ? effort : null,
      );
      state = AgentSessionsState(sessions: state.sessions);
      return session;
    } on AgentApiException catch (e) {
      state = AgentSessionsState(sessions: state.sessions, error: e.message);
      return null;
    }
  }

  Future<AgentDeleteResult?> remove(String sessionId) async {
    try {
      final result = await _api.deleteSession(sessionId);
      state = AgentSessionsState(
        sessions: [
          for (final s in state.sessions)
            if (s.id != sessionId) s,
        ],
      );
      await load();
      await ref.read(agentProjectsProvider.notifier).load();
      return result;
    } on AgentApiException catch (e) {
      showError(e.message);
      return null;
    }
  }

  Future<String?> rename(String sessionId, String name) async {
    try {
      final saved = await _api.renameSession(sessionId, name);
      await load();
      return saved;
    } on AgentApiException catch (e) {
      showError(e.message);
      return null;
    }
  }

  void showError(String message) {
    state = AgentSessionsState(sessions: state.sessions, error: message);
  }
}

class AgentHarnessSessionsState {
  final List<AgentSession> sessions;

  final bool loading;

  final String? error;

  const AgentHarnessSessionsState({
    this.sessions = const [],
    this.loading = false,
    this.error,
  });
}

final agentHarnessSessionsProvider =
    NotifierProvider<AgentHarnessSessionsController, AgentHarnessSessionsState>(
      AgentHarnessSessionsController.new,
    );

class AgentHarnessSessionsController extends Notifier<AgentHarnessSessionsState> {
  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentHarnessSessionsState build() => const AgentHarnessSessionsState();

  Future<void> load({bool silent = false}) async {
    state = AgentHarnessSessionsState(
      sessions: state.sessions,
      loading: !silent,
      error: state.error,
    );
    try {
      state = AgentHarnessSessionsState(
        sessions: await _api.sessions(null, 'harness'),
      );
    } on AgentApiException catch (e) {
      state = AgentHarnessSessionsState(
        sessions: state.sessions,
        error: e.message,
      );
    }
  }

  Future<AgentDeleteResult?> remove(String sessionId) async {
    try {
      final result = await _api.deleteSession(sessionId);
      state = AgentHarnessSessionsState(
        sessions: [
          for (final s in state.sessions)
            if (s.id != sessionId) s,
        ],
      );
      await load();
      return result;
    } on AgentApiException catch (e) {
      state = AgentHarnessSessionsState(
        sessions: state.sessions,
        error: e.message,
      );
      return null;
    }
  }

  Future<String?> rename(String sessionId, String name) async {
    try {
      final saved = await _api.renameSession(sessionId, name);
      await load();
      return saved;
    } on AgentApiException catch (e) {
      state = AgentHarnessSessionsState(
        sessions: state.sessions,
        error: e.message,
      );
      return null;
    }
  }
}


class AgentThreadState {
  final AgentSessionInfo? session;

  final List<AgentItem> items;

  final bool loading;

  final bool sending;

  final String step;

  final AgentUsage? usage;

  final String? error;

  final int queued;

  final DateTime? runStartedAt;

  final bool hasOlder;

  const AgentThreadState({
    this.session,
    this.items = const [],
    this.loading = false,
    this.sending = false,
    this.step = '',
    this.usage,
    this.error,
    this.queued = 0,
    this.runStartedAt,
    this.hasOlder = false,
  });

  AgentThreadState copyWith({
    AgentSessionInfo? session,
    List<AgentItem>? items,
    bool? loading,
    bool? sending,
    String? step,
    AgentUsage? usage,
    int? queued,
    DateTime? runStartedAt,
    bool? hasOlder,
  }) => AgentThreadState(
    session: session ?? this.session,
    items: items ?? this.items,
    loading: loading ?? this.loading,
    sending: sending ?? this.sending,
    step: step ?? this.step,
    usage: usage ?? this.usage,
    error: error,
    runStartedAt: runStartedAt ?? this.runStartedAt,
    hasOlder: hasOlder ?? this.hasOlder,
  );

  AgentThreadState withError(String message) => AgentThreadState(
    session: session,
    items: items,
    loading: loading,
    sending: sending,
    step: step,
    usage: usage,
    error: message,
    queued: queued,
    runStartedAt: runStartedAt,
    hasOlder: hasOlder,
  );

  AgentThreadState clearError() => AgentThreadState(
    session: session,
    items: items,
    loading: loading,
    sending: sending,
    step: step,
    usage: usage,
    queued: queued,
    runStartedAt: runStartedAt,
    hasOlder: hasOlder,
  );

  AgentItem? get last => items.isEmpty ? null : items.last;
}

final agentThreadProvider =
    NotifierProvider<AgentThreadController, AgentThreadState>(
      AgentThreadController.new,
    );

class AgentThreadController extends Notifier<AgentThreadState> {
  StreamSubscription<AgentEvent>? _sub;

  Completer<void>? _done;

  bool _cancelledByUser = false;

  String _runningText = '';

  static const _pageSize = 200;

  int _oldestIndex = 0;

  DateTime? _lastEventAt;

  DateTime? _failingSince;

  bool _reconnecting = false;

  Timer? _watchdog;

  bool _sawTerminal = false;

  bool _newAnswerPending = false;

  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentThreadState build() {
    ref.onDispose(() {
      _sub?.cancel();
      _stopWatchdog();
      _finish();
    });
    return const AgentThreadState();
  }

  Future<void> attach(AgentSessionInfo session) async {
    state = AgentThreadState(session: session, loading: true);
    try {
      final page = await _api.messagesPage(session.id, limit: _pageSize);
      if (state.session?.id != session.id) {
        return;
      }
      _oldestIndex = page.total - page.items.length;
      state = state.copyWith(
        items: page.items,
        loading: false,
        hasOlder: page.hasMore,
      );
      final full = await _fullInfo(session);
      if (state.session?.id != session.id) return;
      state = state.copyWith(session: full);
      if (full.busy) await _followRunning(session.id);
    } on AgentApiException catch (e) {
      state = state.copyWith(loading: false).withError(e.message);
    }
  }

  Future<AgentSessionInfo> _fullInfo(AgentSessionInfo session) async {
    try {
      final full = await _api.session(session.id);
      return full.name.isEmpty && session.name.isNotEmpty
          ? full.withName(session.name)
          : full;
    } on AgentApiException {
      return session;
    }
  }

  Future<void> loadOlder() async {
    final session = state.session;
    if (session == null || state.loading || !state.hasOlder) return;
    try {
      final page = await _api.messagesPage(
        session.id,
        limit: _pageSize,
        before: _oldestIndex,
      );
      _oldestIndex -= page.items.length;
      state = state.copyWith(
        items: [...page.items, ...state.items],
        hasOlder: page.hasMore,
      );
    } on AgentApiException catch (e) {
      state = state.withError(e.message);
    }
  }

  Future<void> _followRunning(String sessionId) async {
    state = state.copyWith(
      sending: true,
      step: 'агент уже работает',
      runStartedAt: DateTime.now(),
    );
    _cancelledByUser = false;
    _newAnswerPending = true;
    final done = Completer<void>();
    _done = done;
    _hold(_api.running(sessionId), sessionId);
    await done.future;
  }

  Future<void> send(String text) async {
    final prompt = text.trim();
    final session = state.session;
    if (prompt.isEmpty || session == null) return;
    final since = state.runStartedAt;
    final accidental =
        state.sending &&
        _runningText == prompt &&
        since != null &&
        DateTime.now().difference(since) < const Duration(seconds: 3);
    if (accidental) {
      state = state.copyWith(
        items: [
          ...state.items,
          const AgentItem(
            kind: 'note',
            text: 'этот вопрос уже в работе — ответ придёт сюда',
          ),
        ],
      );
      return;
    }
    state = state
        .copyWith(
          items: [
            ...state.items,
            AgentItem(kind: 'user', text: prompt),
          ],
        )
        .clearError();
    if (state.sending) {
      await _queue(session.id, prompt, _newMessageId());
      return;
    }
    await _run(session.id, prompt);
  }

  Future<void> _queue(String sessionId, String prompt, String messageId) async {
    try {
      final result = await _api.queueMessage(sessionId, prompt, messageId);
      if (result.duplicate) {
        state = state.copyWith(
          queued: result.position,
          items: [
            ...state.items,
            const AgentItem(
              kind: 'note',
              text: 'этот вопрос уже отправлен — жду ответа на него',
            ),
          ],
        );
        return;
      }
      if (result.position == 0) {
        await _run(sessionId, prompt);
        return;
      }
      state = state.copyWith(queued: result.position);
    } on AgentApiException catch (e) {
      state = state.withError(e.message);
    }
  }

  Future<void> retry() async {
    final session = state.session;
    if (session == null || state.sending) return;
    state = state.clearError();
    final lastUser = state.items.lastWhere(
      (i) => i.isUser,
      orElse: () => const AgentItem(kind: 'user'),
    );
    if (lastUser.text.isEmpty) return;
    try {
      final fresh = await _api.session(session.id);
      state = state.copyWith(session: fresh);
    } on AgentApiException catch (e) {
      state = state.withError(e.message);
      return;
    }
    if (state.session == null) return;
    if (state.session!.busy) {
      await _followRunning(session.id);
      return;
    }
    try {
      final page = await _api.messagesPage(session.id, limit: _pageSize);
      _oldestIndex = page.total - page.items.length;
      state = state.copyWith(items: page.items, hasOlder: page.hasMore);
    } on AgentApiException catch (e) {
      state = state.withError(e.message);
      return;
    }
    final last = state.items.isEmpty ? null : state.items.last;
    if (last != null && last.isAssistant && !last.isEmpty) {
      _finish();
      return;
    }
    await _run(session.id, lastUser.text);
  }

  void rename(String name) {
    final session = state.session;
    if (session == null || name.isEmpty) return;
    state = state.copyWith(session: session.withName(name));
  }

  void detach() {
    _sub?.cancel();
    _sub = null;
    _stopWatchdog();
    _cancelledByUser = false;
    _finish();
  }

  Future<void> stop() async {
    final sub = _sub;
    final session = state.session;
    if (sub == null || session == null) return;
    final wasSending = state.sending;
    _cancelledByUser = true;
    await sub.cancel();
    _finish();
    if (!wasSending) return;
    try {
      await _api.abort(session.id);
      final fresh = await _api.session(session.id);
      state = state.copyWith(session: fresh);
    } on AgentApiException catch (e) {
      state = state.withError(e.message);
    }
  }

  Future<AgentDeleteResult?> deleteSession() async {
    final session = state.session;
    if (session == null) return null;
    if (state.sending) await stop();
    try {
      return await _api.deleteSession(session.id);
    } on AgentApiException catch (e) {
      state = state.withError(e.message);
      return null;
    }
  }

  Future<void> setModel(AgentModel model) async {
    final session = state.session;
    if (session == null || state.sending) return;
    try {
      final updated = await _api.setModel(session.id, model.key);
      state = state.copyWith(session: updated).clearError();
      await ref
          .read(settingsProvider)
          .ui
          .setAgentModel(updated.harness, model.key);
    } on AgentApiException catch (e) {
      state = state.withError(e.message);
    }
  }

  Future<void> setEffort(String effort) async {
    final session = state.session;
    if (session == null || state.sending) return;
    try {
      final updated = await _api.setEffort(session.id, effort);
      state = state.copyWith(session: updated).clearError();
      await ref
          .read(settingsProvider)
          .ui
          .setAgentEffort(updated.harness, effort);
    } on AgentApiException catch (e) {
      state = state.withError(e.message);
    }
  }

  Future<void> compact() async {
    final session = state.session;
    if (session == null || state.sending) return;
    state = state.copyWith(step: 'сжимаю контекст');
    try {
      await _api.compact(session.id);
      state = state.copyWith(step: '', session: await _api.session(session.id));
    } on AgentApiException catch (e) {
      state = state.copyWith(step: '').withError(e.message);
    }
  }

  Future<void> _run(String sessionId, String prompt) async {
    final messageId = _newMessageId();
    state = state.copyWith(
      sending: true,
      step: '',
      runStartedAt: DateTime.now(),
    );
    _cancelledByUser = false;
    _runningText = prompt;
    _newAnswerPending = true;
    final done = Completer<void>();
    _done = done;
    _hold(_api.prompt(sessionId, prompt, messageId), sessionId);
    await done.future;
  }

  void _hold(Stream<AgentEvent> stream, String sessionId) {
    _failingSince = null;
    _lastEventAt = DateTime.now();
    _startWatchdog();
    _listen(stream, sessionId);
  }

  void _listen(Stream<AgentEvent> stream, String sessionId) {
    _sub?.cancel();
    _sawTerminal = false;
    _sub = stream.listen(
      _applyEvent,
      onError: (Object e) => unawaited(_reconnect(sessionId, e)),
      onDone: () {
        if (_sawTerminal || _cancelledByUser) {
          _finish();
          return;
        }
        unawaited(_reconnect(sessionId, null));
      },
    );
  }

  Future<void> _reconnect(String sessionId, Object? error) async {
    if (_reconnecting || _cancelledByUser || !state.sending) return;
    if (state.session?.id != sessionId) return;
    _reconnecting = true;
    try {
      _failingSince ??= DateTime.now();
      final failing = DateTime.now().difference(_failingSince!);
      if (error != null && failing > const Duration(seconds: 60)) {
        _fail(error);
        _finish();
        return;
      }
      state = state.copyWith(step: 'связь прервалась — продолжаю смотреть ответ');
      await Future<void>.delayed(_retryDelay());
      if (_cancelledByUser || !state.sending) return;
      if (state.session?.id != sessionId) return;
      _listen(_api.running(sessionId), sessionId);
    } finally {
      _reconnecting = false;
    }
  }

  Duration _retryDelay() {
    final failing = DateTime.now().difference(_failingSince ?? DateTime.now());
    if (failing < const Duration(seconds: 1)) return const Duration(milliseconds: 300);
    if (failing < const Duration(seconds: 3)) return const Duration(milliseconds: 800);
    if (failing < const Duration(seconds: 7)) return const Duration(milliseconds: 1500);
    if (failing < const Duration(seconds: 15)) return const Duration(seconds: 3);
    return const Duration(seconds: 5);
  }

  void resume() {
    final session = state.session;
    if (!state.sending || session == null) return;
    _failingSince = null;
    _reconnecting = false;
    unawaited(_reconnect(session.id, null));
  }

  void _startWatchdog() {
    _stopWatchdog();
    _watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!state.sending || _cancelledByUser) return;
      final last = _lastEventAt;
      if (last == null) return;
      if (DateTime.now().difference(last) < const Duration(seconds: 40)) return;
      _lastEventAt = DateTime.now();
      final session = state.session;
      if (session != null) unawaited(_reconnect(session.id, null));
    });
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  String _newMessageId() {
    final random = Random();
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final tail = random.nextInt(1 << 32).toRadixString(36);
    return '$now-$tail';
  }

  void _applyEvent(AgentEvent event) {
    _lastEventAt = DateTime.now();
    if (event.ping) return;
    if (event.text != null || event.reasoning != null) {
      final text = event.text ?? '';
      final reasoning = event.reasoning ?? '';
      final items = [...state.items];
      if (items.isEmpty || !items.last.isAssistant || _newAnswerPending) {
        items.add(const AgentItem(kind: 'assistant'));
        _newAnswerPending = false;
      }
      final last = items.last;
      items[items.length - 1] = last.copyWith(
        text: text.isEmpty ? null : last.text + text,
        reasoning: reasoning.isEmpty ? null : last.reasoning + reasoning,
        blocks: _appendText(
          last.blocks,
          text.isEmpty ? null : text,
          reasoning.isEmpty ? null : reasoning,
        ),
      );
      state = state.copyWith(items: items);
      return;
    }

    if (event.error != null) {
      _sawTerminal = true;
      state = state.withError(event.error!);
      return;
    }
    if (event.snapshot != null) {
      _applySnapshot(event.snapshot!);
      return;
    }
    if (event.idle) {
      _sawTerminal = true;
      unawaited(_reloadAfterIdle());
      return;
    }
    if (event.status != null) state = state.copyWith(step: event.status!);
    if (event.queued != null) state = state.copyWith(queued: event.queued);
    if (event.queuedStarted) {
      state = state.copyWith(queued: 0);
      _newAnswerPending = true;
    }
    if (event.usage != null) state = state.copyWith(usage: event.usage);
    if (event.session != null) state = state.copyWith(session: event.session);
    if (event.done) {
      _sawTerminal = true;
      _finish();
      unawaited(_maybeAutoCompact());
      return;
    }
    if (event.note != null) {
      state = state.copyWith(
        items: [
          ...state.items,
          AgentItem(kind: 'note', text: event.note!),
        ],
      );
      return;
    }
    if (event.toolCall != null) {
      _upsertTool(event.toolCall!);
      return;
    }
    if (event.toolStart != null) {
      _upsertTool(event.toolStart!);
      state = state.copyWith(step: _toolStep(event.toolStart!));
      return;
    }
    if (event.toolProgress != null) {
      _upsertTool(event.toolProgress!, keepArgs: true);
      return;
    }
    if (event.toolEnd != null) {
      _upsertTool(event.toolEnd!, keepArgs: true, finished: true);
      return;
    }
    if (event.compacted) {
      unawaited(_updateSessionAfterCompact());
      return;
    }
  }

  Future<void> _updateSessionAfterCompact() async {
    final sessionId = state.session?.id;
    if (sessionId == null) return;
    try {
      final session = await _api.session(sessionId);
      state = state.copyWith(
        session: session,
        step: '',
      );
    } on AgentApiException {
      state = state.copyWith(step: '');
    }
  }

  Future<void> _maybeAutoCompact() async {
    final session = state.session;
    if (session == null || state.sending || state.step.isNotEmpty) return;
    final percent = session.contextPercent;
    if (percent < 85) return;
    state = state.copyWith(step: 'сжимаю контекст');
    try {
      await _api.compact(session.id);
      state = state.copyWith(step: '', session: await _api.session(session.id));
    } on AgentApiException catch (e) {
      state = state.copyWith(step: '').withError('compact: ${e.message}');
    }
  }



  void _applySnapshot(AgentItem item) {
    final items = [...state.items];
    final last = items.isEmpty ? null : items.last;
    final callIds = <String>{
      for (final tool in item.tools)
        if (tool.id.isNotEmpty) tool.id,
    };
    bool continues(AgentItem? candidate) =>
        candidate != null &&
        candidate.isAssistant &&
        item.text.startsWith(candidate.text) &&
        item.reasoning.startsWith(candidate.reasoning) &&
        candidate.tools.every((t) => t.id.isEmpty || callIds.contains(t.id));
    var index = continues(last) ? items.length - 1 : -1;
    if (index < 0 && last != null && last.isUser && items.length >= 2) {
      index = continues(items[items.length - 2]) ? items.length - 2 : -1;
    }
    if (index >= 0) {
      items[index] = item;
    } else {
      items.add(item);
    }
    _newAnswerPending = false;
    state = state.copyWith(items: items);
  }

  Future<void> _reloadAfterIdle() async {
    final sessionId = state.session?.id;
    if (sessionId != null) {
      try {
        final page = await _api.messagesPage(sessionId, limit: _pageSize);
        _oldestIndex = page.total - page.items.length;
        state = state.copyWith(items: page.items, hasOlder: page.hasMore);
      } on AgentApiException catch (e) {
        state = state.withError(e.message);
        _finish();
        return;
      }
    }
    final items = state.items;
    if (items.isNotEmpty && items.last.isUser) {
      state = state.withError('Ответ не пришёл: связь прервалась. Повторите вопрос.');
    }
    _finish();
  }

  List<AgentBlock> _appendText(
    List<AgentBlock> blocks,
    String? text,
    String? reasoning,
  ) {
    var result = blocks;
    if (text != null && text.isNotEmpty) {
      result = _appendBlock(result, const AgentBlock.text(''), text);
    }
    if (reasoning != null && reasoning.isNotEmpty) {
      result = _appendBlock(result, const AgentBlock.reasoning(''), reasoning);
    }
    return result;
  }

  List<AgentBlock> _appendBlock(
    List<AgentBlock> blocks,
    AgentBlock blank,
    String extra,
  ) {
    final next = [...blocks];
    if (next.isNotEmpty && next.last.type == blank.type) {
      next[next.length - 1] = next.last.plus(extra);
    } else if (extra.trim().isNotEmpty) {
      next.add(AgentBlock(type: blank.type, text: extra));
    }
    return next;
  }

  String _toolStep(AgentTool tool) {
    final summary = tool.summary;
    return summary.isEmpty
        ? 'выполняю: ${tool.name}'
        : '${tool.name}: $summary';
  }

  void _upsertTool(
    AgentTool tool, {
    bool keepArgs = false,
    bool finished = false,
  }) {
    final items = [...state.items];
    if (items.isEmpty || !items.last.isAssistant) {
      items.add(const AgentItem(kind: 'assistant'));
    }
    final last = items.last;
    final tools = [...last.tools];
    var blocks = last.blocks;
    final index = tools.indexWhere(
      (t) => t.id == tool.id && tool.id.isNotEmpty,
    );
    if (index < 0) {
      tools.add(tool);
      blocks = [...blocks, AgentBlock.tool(tool.id)];
    } else {
      final old = tools[index];
      tools[index] = AgentTool(
        id: old.id.isEmpty ? tool.id : old.id,
        name: tool.name.isEmpty ? old.name : tool.name,
        args: keepArgs && tool.args.isEmpty ? old.args : tool.args,
        output: tool.output.isEmpty ? old.output : tool.output,
        isError: tool.isError,
        running: finished ? false : (old.running || tool.running),
      );
    }
    items[items.length - 1] = last.copyWith(tools: tools, blocks: blocks);
    state = state.copyWith(items: items);
  }

  String _messageOf(Object e) =>
      e is AgentApiException ? e.message : 'Не удалось получить ответ агента.';

  void _fail(Object e) {
    final message = _messageOf(e);
    final items = [...state.items];
    if (items.isNotEmpty && items.last.isAssistant && items.last.isEmpty) {
      items.removeLast();
    }
    state = state.copyWith(items: items).withError(message);
  }

  void _finish() {
    final done = _done;
    _done = null;
    _sub = null;
    _stopWatchdog();
    _runningText = '';
    _failingSince = null;
    _newAnswerPending = false;
    if (state.sending) {
      final items = [...state.items];
      if (items.isNotEmpty && items.last.isAssistant && items.last.isEmpty) {
        items.removeLast();
      }
      state = state.copyWith(items: items, sending: false, step: '');
    }
    if (done != null && !done.isCompleted) done.complete();
  }
}
