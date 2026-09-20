import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import 'agent_api.dart';
import 'agent_types.dart';

/// Клиент раздела «Проекты» поверх текущего облачного клиента.
///
/// Провайдером, а не полем состояния: адрес сервера и сессия меняются в рантайме (вход, выход,
/// смена сервера в настройках), и каждый следующий запрос должен уходить с текущими — поэтому
/// клиент читается заново, а не хранится. Так же устроен чат.
final agentApiProvider = Provider<AgentApi>((ref) => AgentApi(ref.read(appStateProvider).api));

// --- проекты ---

/// Состояние списка проектов: сами проекты, признак загрузки, состояние моста и ошибка.
class AgentProjectsState {
  /// Проекты внутри разрешённых корней.
  final List<AgentProject> projects;

  /// Состояние моста: версия pi, модель, корни. Пустое — мост ещё не отвечал.
  final AgentHealth health;

  /// Идёт загрузка списка.
  final bool loading;

  /// Причина последней неудачи или `null`.
  final String? error;

  /// Состояние списка проектов.
  const AgentProjectsState({
    this.projects = const [],
    this.health = const AgentHealth(),
    this.loading = false,
    this.error,
  });

  /// Копия состояния; ошибку снимает только [ready].
  AgentProjectsState copyWith({
    List<AgentProject>? projects,
    AgentHealth? health,
    bool? loading,
  }) =>
      AgentProjectsState(
        projects: projects ?? this.projects,
        health: health ?? this.health,
        loading: loading ?? this.loading,
        error: error,
      );

  /// Копия без ошибки.
  AgentProjectsState ready({
    List<AgentProject>? projects,
    AgentHealth? health,
  }) =>
      AgentProjectsState(
        projects: projects ?? this.projects,
        health: health ?? this.health,
        loading: false,
      );

  /// Копия с проставленной ошибкой.
  AgentProjectsState withError(String message) => AgentProjectsState(
        projects: projects,
        health: health,
        loading: false,
        error: message,
      );
}

/// Провайдер списка проектов.
final agentProjectsProvider =
    NotifierProvider<AgentProjectsController, AgentProjectsState>(AgentProjectsController.new);

/// Список проектов: загрузка с моста, состояние моста и текст ошибки для экрана.
class AgentProjectsController extends Notifier<AgentProjectsState> {
  /// Клиент моста.
  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentProjectsState build() => const AgentProjectsState();

  /// Читает проекты и состояние моста.
  ///
  /// Состояние моста спрашивается тем же заходом: в шапке раздела видно, какой харнесс и
  /// какая модель отвечают, — без этого непонятно, куда вообще уходит запрос. Если проект
  /// список не отдал, причина уже в [AgentProjectsState.error], и второй отказ не нужен.
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

// --- сессии проекта ---

/// Состояние списка сессий одного проекта.
class AgentSessionsState {
  /// Проект, чьи сессии показаны.
  final AgentProject? project;

  /// Сессии, свежие сверху.
  final List<AgentSession> sessions;

  /// Идёт загрузка списка или открытие сессии.
  final bool loading;

  /// Причина последней неудачи или `null`.
  final String? error;

  /// Состояние списка сессий.
  const AgentSessionsState({
    this.project,
    this.sessions = const [],
    this.loading = false,
    this.error,
  });
}

/// Провайдер сессий проекта.
final agentSessionsProvider =
    NotifierProvider<AgentSessionsController, AgentSessionsState>(AgentSessionsController.new);

/// Сессии проекта: список из файлов pi и открытие новой сессии.
class AgentSessionsController extends Notifier<AgentSessionsState> {
  /// Клиент моста.
  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentSessionsState build() => const AgentSessionsState();

  /// Читает сессии проекта.
  Future<void> load(AgentProject project) async {
    state = AgentSessionsState(project: project, sessions: state.sessions, loading: true);
    try {
      final sessions = await _api.sessions(project.path);
      // проект могли сменить, пока шёл ответ: тогда список относится уже не к тому экрану
      if (state.project?.path != project.path) return;
      state = AgentSessionsState(project: project, sessions: sessions);
    } on AgentApiException catch (e) {
      state = AgentSessionsState(project: project, sessions: state.sessions, error: e.message);
    }
  }

  /// Открывает сессию проекта: новую или существующую.
  ///
  /// Возвращает описание открытой сессии (её идентификатор выдаёт pi) либо `null`, если мост
  /// отказал: причина при этом уже лежит в состоянии и показывается на экране.
  Future<AgentSessionInfo?> open(AgentProject project, {String? sessionId}) async {
    state = AgentSessionsState(
      project: project,
      sessions: state.sessions,
      loading: true,
      error: state.error,
    );
    try {
      final session = await _api.openSession(project.path, sessionId: sessionId);
      state = AgentSessionsState(project: project, sessions: state.sessions);
      return session;
    } on AgentApiException catch (e) {
      state = AgentSessionsState(
        project: project,
        sessions: state.sessions,
        error: e.message,
      );
      return null;
    }
  }

  /// Показывает ошибку, полученную не от списка (например, отказ моста на открытии).
  void showError(String message) {
    state = AgentSessionsState(
      project: state.project,
      sessions: state.sessions,
      error: message,
    );
  }
}

// --- открытая сессия ---

/// Состояние открытого разговора с агентом.
class AgentThreadState {
  /// Открытая сессия; `null` — ещё не открыта.
  final AgentSessionInfo? session;

  /// Элементы переписки в порядке появления.
  final List<AgentItem> items;

  /// Идёт загрузка истории.
  final bool loading;

  /// Идёт работа агента: кнопка отправки становится «Стоп», поле ввода закрывается.
  final bool sending;

  /// Что агент делает прямо сейчас («выполняю команду»), словами моста.
  final String step;

  /// Расход токенов последнего ответа.
  final AgentUsage? usage;

  /// Причина последней неудачи или `null`.
  final String? error;

  /// Состояние разговора.
  const AgentThreadState({
    this.session,
    this.items = const [],
    this.loading = false,
    this.sending = false,
    this.step = '',
    this.usage,
    this.error,
  });

  /// Копия состояния; ошибку и расход трогают только явные методы.
  AgentThreadState copyWith({
    AgentSessionInfo? session,
    List<AgentItem>? items,
    bool? loading,
    bool? sending,
    String? step,
    AgentUsage? usage,
  }) =>
      AgentThreadState(
        session: session ?? this.session,
        items: items ?? this.items,
        loading: loading ?? this.loading,
        sending: sending ?? this.sending,
        step: step ?? this.step,
        usage: usage ?? this.usage,
        error: error,
      );

  /// Копия с проставленной ошибкой.
  AgentThreadState withError(String message) => AgentThreadState(
        session: session,
        items: items,
        loading: loading,
        sending: sending,
        step: step,
        usage: usage,
        error: message,
      );

  /// Копия без ошибки.
  AgentThreadState clearError() => AgentThreadState(
        session: session,
        items: items,
        loading: loading,
        sending: sending,
        step: step,
        usage: usage,
      );

  /// Последний элемент переписки (в него дописывается текущий ответ), либо `null`.
  AgentItem? get last => items.isEmpty ? null : items.last;
}

/// Провайдер открытого разговора.
final agentThreadProvider =
    NotifierProvider<AgentThreadController, AgentThreadState>(AgentThreadController.new);

/// Разговор с агентом: история сессии, отправка сообщения и дописывание ответа потоком.
///
/// Один контроллер на открытую сессию, а не семейство по id: открыт всегда ровно один
/// разговор — экран лежит отдельным маршрутом поверх списка сессий.
class AgentThreadController extends Notifier<AgentThreadState> {
  /// Подписка на поток ответа; `null` — генерации нет.
  StreamSubscription<AgentEvent>? _sub;

  /// Ожидание окончания генерации: [send] не возвращается, пока ответ не дописан или отменён.
  Completer<void>? _done;

  /// Отмену запросил человек — отличает «Стоп» от обрыва связи: в первом случае ошибку
  /// показывать не нужно, во втором — нужно.
  bool _cancelledByUser = false;

  /// Клиент моста.
  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentThreadState build() {
    // уход с экрана не должен оставлять висящий запрос: разрыв соединения гасит и работу
    // агента на маке (мост шлёт abort), а не только поток в приложении
    ref.onDispose(() {
      _sub?.cancel();
      _finish();
    });
    return const AgentThreadState();
  }

  /// Открывает сессию: показывает её описание и читает историю.
  Future<void> attach(AgentSessionInfo session) async {
    state = AgentThreadState(session: session, loading: true);
    try {
      final items = await _api.messages(session.id);
      if (state.session?.id != session.id) return; // сессию успели сменить, пока шёл ответ
      state = state.copyWith(items: items, loading: false);
    } on AgentApiException catch (e) {
      state = state.copyWith(loading: false).withError(e.message);
    }
  }

  /// Отправляет сообщение: дописывает его в переписку и запускает поток ответа.
  Future<void> send(String text) async {
    final prompt = text.trim();
    final session = state.session;
    if (prompt.isEmpty || session == null || state.sending) return;
    state = state
        .copyWith(items: [...state.items, AgentItem(kind: 'user', text: prompt)])
        .clearError();
    await _run(session.id, prompt);
  }

  /// Повторяет последний вопрос после ошибки.
  ///
  /// Ничего не дописывает: вопрос уже в переписке, а ответ на него не пришёл.
  Future<void> retry() async {
    final session = state.session;
    final lastUser = state.items.lastWhere(
      (i) => i.isUser,
      orElse: () => const AgentItem(kind: 'user'),
    );
    if (session == null || state.sending || lastUser.text.isEmpty) return;
    state = state.clearError();
    await _run(session.id, lastUser.text);
  }

  /// Прерывает работу агента: рвёт поток и просит мост остановить генерацию.
  ///
  /// Уже полученный текст не откатывается: это то, что агент успел сказать, и оно осталось
  /// в истории сессии на маке.
  Future<void> stop() async {
    final sub = _sub;
    final session = state.session;
    if (sub == null || session == null) return;
    _cancelledByUser = true;
    await sub.cancel();
    // Отдельный abort, а не только разрыв соединения: мост гасит работу и по обрыву, но
    // явная команда снимает занятость сессии сразу, и следующий вопрос не упрётся в 409.
    try {
      await _api.abort(session.id);
    } on AgentApiException catch (e) {
      state = state.withError(e.message);
    }
    _finish();
  }

  /// Сжимает контекст сессии: длинный разговор иначе перестанет влезать в окно модели.
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

  /// Закрывает процесс pi и отпускает память на маке.
  ///
  /// Вызывается при уходе с экрана: держать процесс живым ради разговора, который человек
  /// закрыл, незачем — история лежит в файле сессии, и продолжение поднимет процесс заново.
  Future<void> close() async {
    final session = state.session;
    if (session == null) return;
    try {
      await _api.closeSession(session.id);
    } on AgentApiException {
      // молча: закрытие — уборка, и мешать ею уходу с экрана незачем
    }
  }

  /// Запускает поток ответа на [prompt], который уже лежит в состоянии последним вопросом.
  Future<void> _run(String sessionId, String prompt) async {
    state = state.copyWith(sending: true, step: '');
    _cancelledByUser = false;
    final done = Completer<void>();
    _done = done;

    _sub = _api.prompt(sessionId, prompt).listen(
          _applyEvent,
          onError: (Object e) {
            if (!_cancelledByUser) _fail(e);
            _finish();
          },
          onDone: _finish,
        );

    await done.future;
  }

  /// Дописывает полученное событие в состояние экрана.
  ///
  /// Каждый вид события меняет ровно свою часть: текст дописывается в последний ответ,
  /// инструменты — в его же карточки, состояние — в строку под перепиской. Список
  /// пересобирается целиком (состояние неизменяемое), но экран перестраивает только хвост.
  void _applyEvent(AgentEvent event) {
    if (event.error != null) {
      state = state.withError(event.error!);
      return;
    }
    if (event.status != null) state = state.copyWith(step: event.status!);
    if (event.usage != null) state = state.copyWith(usage: event.usage);
    if (event.session != null) state = state.copyWith(session: event.session);
    if (event.note != null) {
      state = state.copyWith(items: [...state.items, AgentItem(kind: 'note', text: event.note!)]);
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
    if (event.text == null && event.reasoning == null) return;

    // Текст ответа: инструменты приходят до него, поэтому нужен пустой ответ-контейнер,
    // если последний элемент переписки — не ответ агента (например, это был вопрос).
    final items = [...state.items];
    if (items.isEmpty || !items.last.isAssistant) {
      items.add(const AgentItem(kind: 'assistant'));
    }
    final last = items.last;
    items[items.length - 1] = last.copyWith(
      text: event.text == null ? null : last.text + event.text!,
      reasoning: event.reasoning == null ? null : last.reasoning + event.reasoning!,
    );
    state = state.copyWith(items: items);
  }

  /// Подпись текущего действия по вызову инструмента: «выполняю команду: npm test».
  String _toolStep(AgentTool tool) {
    final summary = tool.summary;
    return summary.isEmpty ? 'выполняю: ${tool.name}' : '${tool.name}: $summary';
  }

  /// Добавляет или обновляет карточку инструмента в последнем ответе агента.
  ///
  /// Карточка живёт внутри ответа, а не отдельным элементом переписки: у pi вызов и его
  /// результат — часть одного ответа, и разрывать их на два пузыря значит показывать
  /// переписку не такой, какой её видит модель. [keepArgs] оставлен для событий прогресса и
  /// завершения: они приходят без аргументов, и затирать ими уже известные нельзя.
  void _upsertTool(AgentTool tool, {bool keepArgs = false, bool finished = false}) {
    final items = [...state.items];
    if (items.isEmpty || !items.last.isAssistant) {
      items.add(const AgentItem(kind: 'assistant'));
    }
    final last = items.last;
    final tools = [...last.tools];
    final index = tools.indexWhere((t) => t.id == tool.id && tool.id.isNotEmpty);
    if (index < 0) {
      tools.add(tool);
    } else {
      final old = tools[index];
      tools[index] = AgentTool(
        id: old.id.isEmpty ? tool.id : old.id,
        name: tool.name.isEmpty ? old.name : tool.name,
        args: keepArgs && tool.args.isEmpty ? old.args : tool.args,
        // вывод у прогресса — накопленный целиком, поэтому заменяем, а не дописываем
        output: tool.output.isEmpty ? old.output : tool.output,
        isError: tool.isError,
        running: finished ? false : (old.running || tool.running),
      );
    }
    items[items.length - 1] = last.copyWith(tools: tools);
    state = state.copyWith(items: items);
  }

  /// Показывает ошибку потока и убирает пустой каркас ответа.
  ///
  /// Пустой каркас после ошибки — это пузырь без текста, который ничего не объясняет: причину
  /// показывает сообщение об ошибке, а вопрос остаётся на месте, чтобы его повторить.
  void _fail(Object e) {
    final message = e is AgentApiException ? e.message : 'Не удалось получить ответ агента.';
    final items = [...state.items];
    if (items.isNotEmpty && items.last.isAssistant && items.last.text.isEmpty && items.last.tools.isEmpty) {
      items.removeLast();
    }
    state = state.copyWith(items: items).withError(message);
  }

  /// Завершает работу: снимает признак занятости, убирает пустой каркас и отпускает ожидание.
  ///
  /// Вызывается из трёх мест (конец потока, ошибка, отмена), поэтому защищена от повторного
  /// входа: второе завершение уже ничего не делает.
  void _finish() {
    final done = _done;
    _done = null;
    _sub = null;
    if (state.sending) {
      final items = [...state.items];
      if (items.isNotEmpty &&
          items.last.isAssistant &&
          items.last.text.isEmpty &&
          items.last.tools.isEmpty) {
        items.removeLast();
      }
      // строку «что делает сейчас» снимаем вместе с работой: иначе она осталась бы висеть
      // над уже готовым ответом
      state = state.copyWith(items: items, sending: false, step: '');
    }
    if (done != null && !done.isCompleted) done.complete();
  }
}
