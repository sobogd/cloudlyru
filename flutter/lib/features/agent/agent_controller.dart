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
final agentApiProvider = Provider<AgentApi>(
  (ref) => AgentApi(ref.read(appStateProvider).api),
);

// --- харнессы ---

/// Состояние списка харнессов: кто вообще есть на маке.
class AgentHarnessesState {
  /// Харнессы с признаком «стоит на маке».
  final List<AgentHarness> harnesses;

  /// Идёт загрузка.
  final bool loading;

  /// Причина последней неудачи или `null`.
  final String? error;

  /// Состояние списка харнессов.
  const AgentHarnessesState({
    this.harnesses = const [],
    this.loading = false,
    this.error,
  });

  /// Доступные на маке.
  List<AgentHarness> get available => [
    for (final h in harnesses)
      if (h.available) h,
  ];

  /// Название харнесса по имени (`pi`, `claude`); пусто — если такого нет в списке.
  String nameOf(String harness) {
    for (final h in harnesses) {
      if (h.harness == harness) return h.label;
    }
    return harness;
  }
}

/// Провайдер списка харнессов.
final agentHarnessesProvider =
    NotifierProvider<AgentHarnessesController, AgentHarnessesState>(
      AgentHarnessesController.new,
    );

/// Харнессы на маке: читаются один раз при входе в раздел.
class AgentHarnessesController extends Notifier<AgentHarnessesState> {
  /// Клиент раздела.
  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentHarnessesState build() => const AgentHarnessesState();

  /// Читает список харнессов.
  Future<void> load() async {
    state = AgentHarnessesState(harnesses: state.harnesses, loading: true);
    try {
      state = AgentHarnessesState(harnesses: await _api.harnesses());
    } on AgentApiException catch (e) {
      state = AgentHarnessesState(harnesses: state.harnesses, error: e.message);
    }
  }
}

// --- модели ---

/// Состояние списка моделей: что выбранный харнесс может запустить.
class AgentModelsState {
  /// Чей это список: модели у pi и Claude Code разные.
  final String harness;

  /// Локальные и удалённые модели.
  final List<AgentModel> models;

  /// Уровни усилия харнесса: у Claude Code их пять, у pi список пустой.
  final List<AgentEffort> efforts;

  /// Идёт загрузка.
  final bool loading;

  /// Причина последней неудачи или `null`.
  final String? error;

  /// Состояние списка моделей.
  const AgentModelsState({
    this.harness = 'pi',
    this.models = const [],
    this.efforts = const [],
    this.loading = false,
    this.error,
  });

  /// Только локальные (считают на маке) и только удалённые — для группировки в выборе.
  List<AgentModel> get local => [
    for (final m in models)
      if (m.local) m,
  ];

  /// Модели по API.
  List<AgentModel> get remote => [
    for (final m in models)
      if (!m.local) m,
  ];

  /// Модель по ключу `провайдер/идентификатор`, если она есть в списке.
  AgentModel? byKey(String? key) {
    if (key == null || key.isEmpty) return null;
    for (final m in models) {
      if (m.key == key) return m;
    }
    return null;
  }
}

/// Провайдер списка моделей.
final agentModelsProvider =
    NotifierProvider<AgentModelsController, AgentModelsState>(
      AgentModelsController.new,
    );

/// Список моделей харнесса: читается один раз при первом открытии выбора и обновляется кнопкой.
class AgentModelsController extends Notifier<AgentModelsState> {
  /// Клиент раздела.
  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentModelsState build() => const AgentModelsState();

  /// Читает список моделей харнесса у моста.
  ///
  /// Список для другого харнесса всегда перечитывается: у pi модели задаются провайдерами, у
  /// Claude Code — его собственным набором, и держать их в одном кэше значило бы показывать
  /// модели не того агента.
  Future<void> load({String harness = 'pi'}) async {
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
      // Модели и уровни усилия — один ответ моста: у Claude Code он несёт и то и другое
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

// --- модели всех харнессов (для новой сессии) ---

/// Модели всех харнессов сразу: нужны выбору модели для новой сессии, где рядом стоят
/// локальные, удалённые и модели Claude Code.
///
/// Отдельно от [agentModelsProvider], который держит список одного харнесса: там выбор идёт
/// внутри уже открытого разговора, где харнесс известен, а здесь его только предстоит выбрать.
class AgentAllModelsState {
  /// Модели по имени харнесса (`pi`, `claude`).
  final Map<String, List<AgentModel>> byHarness;

  /// Идёт загрузка.
  final bool loading;

  /// Причина последней неудачи или `null`.
  final String? error;

  /// Состояние списка моделей всех харнессов.
  const AgentAllModelsState({
    this.byHarness = const {},
    this.loading = false,
    this.error,
  });

  /// Модели харнесса; пусто, если он ещё не загружен или их нет.
  List<AgentModel> of(String harness) => byHarness[harness] ?? const [];
}

/// Провайдер моделей всех харнессов.
final agentAllModelsProvider =
    NotifierProvider<AgentAllModelsController, AgentAllModelsState>(
      AgentAllModelsController.new,
    );

/// Модели всех доступных харнессов: читаются разом при открытии выбора для новой сессии.
class AgentAllModelsController extends Notifier<AgentAllModelsState> {
  /// Клиент раздела.
  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentAllModelsState build() => const AgentAllModelsState();

  /// Читает модели перечисленных харнессов.
  ///
  /// Отказ одного харнесса не отменяет остальные: у Claude Code бывает свой капризный вход, и
  /// терять из-за него список локальных моделей pi было бы неправильно.
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

// --- работа на маке ---

/// Состояние работы на маке: что считается и что закончилось без нас.
class AgentActivityState {
  /// Снимок с сервера.
  final AgentActivity activity;

  /// Причина последней неудачи или `null`.
  final String? error;

  /// Состояние работы.
  const AgentActivityState({this.activity = AgentActivity.empty, this.error});

  /// Сессия считается прямо сейчас.
  bool isRunning(String id) => activity.running.contains(id);

  /// Разговор закончился, пока мы на него не смотрели.
  bool isFinished(String id) => activity.finished.contains(id);
}

/// Провайдер снимка работы.
final agentActivityProvider =
    NotifierProvider<AgentActivityController, AgentActivityState>(
      AgentActivityController.new,
    );

/// Снимок работы на маке: приложение спрашивает его, пока открыт список разговоров.
///
/// Это и есть «уведомление» без push-канала: сервер опрашивает мост всегда, а приложение,
/// оказавшись на экране, узнаёт, что разговор дописался без него, и помечает строку «готово».
class AgentActivityController extends Notifier<AgentActivityState> {
  /// Клиент раздела.
  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentActivityState build() => const AgentActivityState();

  /// Читает снимок работы.
  Future<void> load() async {
    try {
      state = AgentActivityState(activity: await _api.activity());
    } on AgentApiException catch (e) {
      state = AgentActivityState(activity: state.activity, error: e.message);
    }
  }

  /// Снимает пометку «готово» с разговора, который человек открыл.
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

// --- провайдеры ---

/// Состояние списка провайдеров: свои (models.json) и встроенные (auth.json) на маке.
class AgentProvidersState {
  /// Все провайдеры, как их отдаёт мост.
  final List<AgentProvider> providers;

  /// Идёт загрузка или запись.
  final bool loading;

  /// Причина последней неудачи или `null`.
  final String? error;

  /// Состояние списка провайдеров.
  const AgentProvidersState({
    this.providers = const [],
    this.loading = false,
    this.error,
  });

  /// Свои провайдеры: их можно править и удалять.
  List<AgentProvider> get custom => [
    for (final p in providers)
      if (p.custom) p,
  ];

  /// Встроенные провайдеры pi: у них задаётся только ключ.
  List<AgentProvider> get builtin => [
    for (final p in providers)
      if (!p.custom) p,
  ];
}

/// Провайдер списка провайдеров.
final agentProvidersProvider =
    NotifierProvider<AgentProvidersController, AgentProvidersState>(
      AgentProvidersController.new,
    );

/// Провайдеры на маке: чтение, сохранение, удаление и ключи.
///
/// Всё, что здесь меняется, меняется в файлах pi на маке (`models.json`, `auth.json`), а не в
/// приложении: поэтому после каждого действия список перечитывается с мака, а не правится
/// локально — иначе экран показывал бы состояние, которого на маке нет.
class AgentProvidersController extends Notifier<AgentProvidersState> {
  /// Клиент раздела.
  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentProvidersState build() => const AgentProvidersState();

  /// Читает провайдеров с мака.
  Future<void> load() async {
    state = AgentProvidersState(providers: state.providers, loading: true);
    try {
      final providers = await _api.providers();
      state = AgentProvidersState(providers: providers);
    } on AgentApiException catch (e) {
      state = AgentProvidersState(providers: state.providers, error: e.message);
    }
  }

  /// Сохраняет своего провайдера и возвращает `null` при успехе либо текст ошибки.
  ///
  /// Ошибку возвращаем текстом, а не только кладём в состояние: форма показывает её рядом с
  /// полями, где человек как раз и находится.
  Future<String?> save({
    required String key,
    required String name,
    required String baseUrl,
    required String api,
    required String apiKey,
    required List<AgentModel> models,
  }) async {
    state = AgentProvidersState(providers: state.providers, loading: true);
    try {
      final providers = await _api.saveProvider(
        key: key,
        name: name,
        baseUrl: baseUrl,
        api: api,
        apiKey: apiKey,
        models: models,
      );
      state = AgentProvidersState(providers: providers);
      // новый провайдер — новые модели: список моделей в выборе устарел
      await ref.read(agentModelsProvider.notifier).load();
      return null;
    } on AgentApiException catch (e) {
      state = AgentProvidersState(providers: state.providers, error: e.message);
      return e.message;
    }
  }

  /// Удаляет своего провайдера.
  Future<void> remove(String key) async {
    try {
      final providers = await _api.deleteProvider(key);
      state = AgentProvidersState(providers: providers);
      await ref.read(agentModelsProvider.notifier).load();
    } on AgentApiException catch (e) {
      state = AgentProvidersState(providers: state.providers, error: e.message);
    }
  }

  /// Задаёт или убирает ключ встроенного провайдера.
  Future<String?> setKey(String provider, String apiKey) async {
    try {
      final providers = await _api.saveProviderKey(provider, apiKey);
      state = AgentProvidersState(providers: providers);
      await ref.read(agentModelsProvider.notifier).load();
      return null;
    } on AgentApiException catch (e) {
      state = AgentProvidersState(providers: state.providers, error: e.message);
      return e.message;
    }
  }

  /// Проверяет адрес и ключ и отдаёт список моделей провайдера (или ошибку текстом).
  Future<(List<AgentModel>, String?)> probe({
    required String baseUrl,
    String provider = '',
    String apiKey = '',
  }) async {
    try {
      final models = await _api.probeProvider(
        baseUrl: baseUrl,
        provider: provider,
        apiKey: apiKey,
      );
      return (models, null);
    } on AgentApiException catch (e) {
      return (const <AgentModel>[], e.message);
    }
  }
}

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
  }) => AgentProjectsState(
    projects: projects ?? this.projects,
    health: health ?? this.health,
    loading: loading ?? this.loading,
    error: error,
  );

  /// Копия без ошибки.
  AgentProjectsState ready({
    List<AgentProject>? projects,
    AgentHealth? health,
  }) => AgentProjectsState(
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
    NotifierProvider<AgentProjectsController, AgentProjectsState>(
      AgentProjectsController.new,
    );

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

// --- сессии ---

/// Состояние общего списка разговоров: сессии всех проектов и обоих харнессов.
class AgentSessionsState {
  /// Сессии, свежие сверху.
  final List<AgentSession> sessions;

  /// Идёт загрузка списка или открытие сессии.
  final bool loading;

  /// Причина последней неудачи или `null`.
  final String? error;

  /// Состояние списка сессий.
  const AgentSessionsState({
    this.sessions = const [],
    this.loading = false,
    this.error,
  });
}

/// Провайдер общего списка разговоров.
final agentSessionsProvider =
    NotifierProvider<AgentSessionsController, AgentSessionsState>(
      AgentSessionsController.new,
    );

/// Разговоры со всех проектов: список из файлов обоих харнессов, открытие и уборка.
///
/// Список приходит одним запросом (`GET /projects/sessions` без папки), а не обходом проектов:
/// экран показывает разговоры со всего мака сразу, и запрос на каждую папку на каждое
/// обновление был бы и медленнее, и шумнее.
class AgentSessionsController extends Notifier<AgentSessionsState> {
  /// Клиент моста.
  AgentApi get _api => ref.read(agentApiProvider);

  @override
  AgentSessionsState build() => const AgentSessionsState();

  /// Читает общий список разговоров.
  Future<void> load({bool silent = false}) async {
    state = AgentSessionsState(
      sessions: state.sessions,
      // Тихий режим для периодического обновления: список перечитывается, но спиннер не мигает,
      // иначе экран дёргался бы каждые несколько секунд
      loading: !silent,
      error: state.error,
    );
    try {
      state = AgentSessionsState(sessions: await _api.sessions());
    } on AgentApiException catch (e) {
      state = AgentSessionsState(sessions: state.sessions, error: e.message);
    }
  }

  /// Открывает сессию: новую в папке проекта или существующую.
  ///
  /// Возвращает описание открытой сессии (её идентификатор выдаёт pi) либо `null`, если мост
  /// отказал: причина при этом уже лежит в состоянии и показывается на экране.
  Future<AgentSessionInfo?> open(
    AgentProject project, {
    String harness = 'pi',
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
      // модель передаём только для новой сессии: у существующей она уже записана в её файле.
      // Усилие, наоборот, уезжает всегда: в файле разговора его нет, и без него возобновлённый
      // Claude Code взял бы умолчание модели вместо выбранного человеком
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

  /// Удаляет сессию на маке вместе с историей и возвращает итог (что удалилось, что вернулось).
  ///
  /// Необратимо, поэтому вызывающий сначала спрашивает подтверждение. Строка убирается сразу, а
  /// затем список перечитывается с мака: если файл вернул живой процесс, разговор останется в
  /// списке — и это правильнее, чем показать его удалённым.
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
      return result;
    } on AgentApiException catch (e) {
      showError(e.message);
      return null;
    }
  }

  /// Ставит разговору новое имя; возвращает сохранённое имя, а `null` — если мост отказал.
  ///
  /// Список после этого перечитывается с мака: имя приходит из файла сессии, и сразу показать
  /// его иначе нельзя — в строке осталось бы прежнее. Ошибка, как и у остальных ручек над
  /// списком, показывается строкой над ним.
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

  /// Показывает ошибку, полученную не от списка (например, отказ моста на открытии).
  void showError(String message) {
    state = AgentSessionsState(sessions: state.sessions, error: message);
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

  /// Сколько сообщений человека ждут своей очереди: агент занят предыдущим.
  ///
  /// Показывается на экране: иначе отправленное в занятую сессию сообщение выглядит потерянным —
  /// ответа на него ещё нет, а очередь и есть доказательство, что оно живое.
  final int queued;

  /// Когда человек отправил текущее сообщение: по этому времени экран считает, сколько уже
  /// идёт работа. Живёт в состоянии, а не в виджете, потому что перерисовок за прогон много.
  final DateTime? runStartedAt;

  /// Состояние разговора.
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
  });

  /// Копия состояния; ошибку и расход трогают только явные методы.
  AgentThreadState copyWith({
    AgentSessionInfo? session,
    List<AgentItem>? items,
    bool? loading,
    bool? sending,
    String? step,
    AgentUsage? usage,
    int? queued,
    DateTime? runStartedAt,
  }) => AgentThreadState(
    session: session ?? this.session,
    items: items ?? this.items,
    loading: loading ?? this.loading,
    sending: sending ?? this.sending,
    step: step ?? this.step,
    usage: usage ?? this.usage,
    error: error,
    runStartedAt: runStartedAt ?? this.runStartedAt,
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
    queued: queued,
    runStartedAt: runStartedAt,
  );

  /// Копия без ошибки.
  AgentThreadState clearError() => AgentThreadState(
    session: session,
    items: items,
    loading: loading,
    sending: sending,
    step: step,
    usage: usage,
    queued: queued,
    runStartedAt: runStartedAt,
  );

  /// Последний элемент переписки (в него дописывается текущий ответ), либо `null`.
  AgentItem? get last => items.isEmpty ? null : items.last;
}

/// Провайдер открытого разговора.
final agentThreadProvider =
    NotifierProvider<AgentThreadController, AgentThreadState>(
      AgentThreadController.new,
    );

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

  /// Текст вопроса, который сейчас выполняет агент.
  ///
  /// Нужен, чтобы не отправлять тот же вопрос второй раз, пока на него не ответили: повторы
  /// уходили после обрыва связи и по кнопке «Повторить», и каждый из них прогонял всю работу
  /// заново вместе с расходом токенов.
  String _runningText = '';

  /// Уже пробовали подключиться к оборвавшемуся прогону.
  ///
  /// Одна попытка на прогон: если и она не удалась, дальше только ошибка, иначе при мёртвом
  /// соединении приложение уходило бы в бесконечный круг переподключений.
  bool _resumed = false;

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
  ///
  /// Если сессия занята, экран подключается к идущему прогону: показывать ошибку «занята» и
  /// запрещать ввод бессмысленно — ответ уже пишется, и его надо просто показать.
  Future<void> attach(AgentSessionInfo session) async {
    state = AgentThreadState(session: session, loading: true);
    try {
      final items = await _api.messages(session.id);
      if (state.session?.id != session.id) {
        return; // сессию успели сменить, пока шёл ответ
      }
      state = state.copyWith(items: items, loading: false);
      if (session.busy) await _followRunning(session.id);
    } on AgentApiException catch (e) {
      state = state.copyWith(loading: false).withError(e.message);
    }
  }

  /// Подключается к уже идущему прогону и дописывает его в переписку.
  ///
  /// Свой вопрос при этом не отправляется: агент занят предыдущим. Разрыв соединения прогон не
  /// прерывает — «Стоп» для этого есть отдельно.
  Future<void> _followRunning(String sessionId) async {
    state = state.copyWith(
      sending: true,
      step: 'агент уже работает',
      runStartedAt: DateTime.now(),
    );
    _cancelledByUser = false;
    final done = Completer<void>();
    _done = done;
    _sub = _api
        .running(sessionId)
        .listen(
          _applyEvent,
          onError: (Object e) {
            if (!_cancelledByUser) _fail(e);
            _finish();
          },
          onDone: _finish,
        );
    await done.future;
  }

  /// Отправляет сообщение: дописывает его в переписку и запускает поток ответа.
  Future<void> send(String text) async {
    final prompt = text.trim();
    final session = state.session;
    if (prompt.isEmpty || session == null) return;
    // Такой же вопрос, пока на него не ответили, второй раз не отправляем: отправка стоит
    // целого прогона, а ответ придёт и без неё. Строкой в переписке объясняем, почему отправки
    // не произошло, — молчать про нажатую кнопку хуже.
    if (state.sending && _runningText == prompt) {
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
      // Агент занят — сообщение встаёт в очередь на маке и уедет, как только он освободится.
      // Отказывать нельзя: человек дописывает уточнение, пока агент ещё работает.
      await _queue(session.id, prompt);
      return;
    }
    await _run(session.id, prompt);
  }

  /// Ставит сообщение в очередь занятой сессии.
  ///
  /// Если сессия успела освободиться (мост отвечает «очередь не нужна»), отправляем вопрос
  /// обычным путём: иначе он остался бы висеть в очереди, которой уже нет. Если мост узнал
  /// такой же вопрос в работе или в очереди, он повтор не принимает — тогда показываем это
  /// строкой и настоящее место, а второй раз не отправляем.
  Future<void> _queue(String sessionId, String prompt) async {
    try {
      final result = await _api.queueMessage(sessionId, prompt);
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

  /// Обновляет имя открытого разговора после переименования в списке.
  ///
  /// Шапка берёт имя из описания сессии, полученного при открытии, а список живёт отдельным
  /// состоянием: без этого правка была бы видна слева, но не в шапке справа, пока разговор
  /// не закроют и не откроют заново.
  void rename(String name) {
    final session = state.session;
    if (session == null || name.isEmpty) return;
    state = state.copyWith(session: session.withName(name));
  }

  /// Отпускает поток, не трогая агента: экран закрыли, а работа на маке продолжается.
  ///
  /// Так и должно быть: человек ушёл с экрана — не то же самое, что «останови работу». Ответ
  /// продолжает писаться (мост его сохранит), а при возврате экран подключится к идущему прогону
  /// и покажет его целиком. Останавливает агента только «Стоп».
  void detach() {
    _sub?.cancel();
    _sub = null;
    _cancelledByUser = false;
    _finish();
  }

  /// Прерывает работу агента: рвёт поток и просит мост остановить генерацию.
  ///
  /// Уже полученный текст не откатывается: это то, что агент успел сказать, и оно осталось
  /// в истории сессии на маке.
  Future<void> stop() async {
    final sub = _sub;
    final session = state.session;
    if (sub == null || session == null) return;
    final wasSending = state.sending;
    _cancelledByUser = true;
    await sub.cancel();
    _finish();
    if (!wasSending) return;
    // Отдельный abort, а не только разрыв соединения: мост гасит работу и по обрыву, но явная
    // команда снимает занятость сессии сразу, и следующий вопрос не упрётся в 409. Для
    // закрытой сессии мост отвечает «нечего останавливать» — это не ошибка.
    try {
      await _api.abort(session.id);
    } on AgentApiException catch (e) {
      state = state.withError(e.message);
    }
  }

  /// Удаляет сессию на маке вместе с историей. Необратимо: подтверждение спрашивает экран.
  ///
  /// Занятость снимаем до удаления: работающий процесс держит файл открытым, и стирать его
  /// из-под агента — верный способ получить обрывок сессии на диске.
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

  /// Меняет модель открытой сессии: разговор продолжается, меняется тот, кто считает.
  ///
  /// Выбор запоминается в настройках как модель по умолчанию для новых сессий — человек,
  /// который перешёл на удалённую модель, ждёт её и в следующем проекте.
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

  /// Меняет уровень усилия у сессии Claude Code: процесс перезапускается с тем же разговором.
  ///
  /// Пустая строка — «пусть решает модель»: это осмысленный выбор, поэтому он передаётся как
  /// есть. Выбор запоминается в настройках и уезжает при открытии следующих сессий: в файле
  /// разговора усилие не хранится, и без этой памяти оно терялось бы при каждом перезапуске моста.
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

  /// Запускает поток ответа на [prompt], который уже лежит в состоянии последним вопросом.
  Future<void> _run(String sessionId, String prompt) async {
    state = state.copyWith(
      sending: true,
      step: '',
      runStartedAt: DateTime.now(),
    );
    _cancelledByUser = false;
    _runningText = prompt;
    _resumed = false;
    final done = Completer<void>();
    _done = done;

    _sub = _api
        .prompt(sessionId, prompt)
        .listen(
          _applyEvent,
          onError: (Object e) => _onStreamBroken(sessionId, e),
          onDone: _finish,
        );

    await done.future;
  }

  /// Поток ответа оборвался: подключаемся к идущему прогону, а не показываем ошибку.
  ///
  /// Обрыв потока не значит, что прогон кончился: работу на маке мост не гасит (сеть мигнула,
  /// экран свернули, приложение перезапустили), и ответ продолжает писаться. Раньше здесь сразу
  /// появлялась ошибка с кнопкой «Повторить», человек по ней отправлял тот же вопрос, и агент
  /// прогонял ту же работу заново — по нескольку раз на один вопрос. Теперь сначала идём в /events
  /// (ручка для наблюдения за идущим прогоном), а ошибку показываем, только если прогона там уже
  /// нет или повторное подключение тоже оборвалось: тогда «Повторить» осмысленно.
  void _onStreamBroken(String sessionId, Object error) {
    if (_cancelledByUser || _resumed) {
      _fail(error);
      _finish();
      return;
    }
    _resumed = true;
    state = state.copyWith(step: 'связь прервалась — продолжаю смотреть ответ');
    _sub = _api
        .running(sessionId)
        .listen(
          (event) {
            // Прогона нет: пока связи не было, он либо дописался, либо оборвался. Что именно —
            // видно только по истории на маке, её и перечитываем.
            if (event.idle) {
              unawaited(_reloadAfterBreak(error));
              return;
            }
            _applyEvent(event);
          },
          onError: (Object e) {
            _fail(e);
            _finish();
          },
          onDone: _finish,
        );
  }

  /// Перечитывает переписку после обрыва и решает, показать ли ошибку.
  ///
  /// История приходит с мака, и в ней уже есть всё, что агент успел написать без нас: если
  /// ответ там есть, показываем его и ошибки не показываем. Если последним стоит вопрос без
  /// ответа, значит ответ потерян вместе со связью — тогда причина видна, а вопрос на месте,
  /// и его можно повторить.
  Future<void> _reloadAfterBreak(Object error) async {
    final sessionId = state.session?.id;
    if (sessionId != null) {
      try {
        state = state.copyWith(items: await _api.messages(sessionId));
      } on AgentApiException {
        // Историю не отдали — ниже показываем причину обрыва: она честнее молчания
      }
    }
    final items = state.items;
    if (items.isNotEmpty && items.last.isUser) {
      state = state.withError(_messageOf(error));
    }
    _finish();
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
    if (event.queued != null) state = state.copyWith(queued: event.queued);
    if (event.queuedStarted) state = state.copyWith(queued: 0);
    if (event.usage != null) state = state.copyWith(usage: event.usage);
    if (event.session != null) state = state.copyWith(session: event.session);
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
      reasoning: event.reasoning == null
          ? null
          : last.reasoning + event.reasoning!,
      blocks: _appendText(last.blocks, event.text, event.reasoning),
    );
    state = state.copyWith(items: items);
  }

  /// Дописывает кусок текста (или «размышлений») в блоки ответа, сохраняя порядок.
  ///
  /// Кусок продолжает последний блок своего вида, только если тот идёт последним. Как только
  /// между текстом и текстом встала карточка инструмента, начинается новый блок — иначе новый
  /// текст после команды оказался бы выше её карточки, и разговор читался бы не по порядку.
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

  /// Дописывает [extra] в последний блок того же вида, а если его нет — добавляет новый.
  List<AgentBlock> _appendBlock(
    List<AgentBlock> blocks,
    AgentBlock blank,
    String extra,
  ) {
    final next = [...blocks];
    if (next.isNotEmpty && next.last.type == blank.type) {
      next[next.length - 1] = next.last.plus(extra);
    } else {
      next.add(AgentBlock(type: blank.type, text: extra));
    }
    return next;
  }

  /// Подпись текущего действия по вызову инструмента: «выполняю команду: npm test».
  String _toolStep(AgentTool tool) {
    final summary = tool.summary;
    return summary.isEmpty
        ? 'выполняю: ${tool.name}'
        : '${tool.name}: $summary';
  }

  /// Добавляет или обновляет карточку инструмента в последнем ответе агента.
  ///
  /// Карточка живёт внутри ответа, а не отдельным элементом переписки: у pi вызов и его
  /// результат — часть одного ответа, и разрывать их на два пузыря значит показывать
  /// переписку не такой, какой её видит модель. [keepArgs] оставлен для событий прогресса и
  /// завершения: они приходят без аргументов, и затирать ими уже известные нельзя.
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
      // Карточка встаёт в блоки на своё место — там, где инструмент вызван по ходу ответа.
      // Дальнейшие события того же вызова (аргументы, прогресс, результат) только обновляют
      // карточку: порядок уже зафиксирован.
      blocks = [...blocks, AgentBlock.tool(tool.id)];
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
    items[items.length - 1] = last.copyWith(tools: tools, blocks: blocks);
    state = state.copyWith(items: items);
  }

  /// Причина для экрана: у отказа моста есть свой текст, остальное — общая формулировка.
  String _messageOf(Object e) =>
      e is AgentApiException ? e.message : 'Не удалось получить ответ агента.';

  /// Показывает ошибку потока и убирает пустой каркас ответа.
  ///
  /// Пустой каркас после ошибки — это пузырь без текста, который ничего не объясняет: причину
  /// показывает сообщение об ошибке, а вопрос остаётся на месте, чтобы его повторить.
  void _fail(Object e) {
    final message = _messageOf(e);
    final items = [...state.items];
    if (items.isNotEmpty && items.last.isAssistant && items.last.isEmpty) {
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
    // Прогон закончился: повторять его текст уже некому, а новый вопрос вправе быть таким же
    _runningText = '';
    _resumed = false;
    if (state.sending) {
      final items = [...state.items];
      if (items.isNotEmpty && items.last.isAssistant && items.last.isEmpty) {
        items.removeLast();
      }
      // строку «что делает сейчас» снимаем вместе с работой: иначе она осталась бы висеть
      // над уже готовым ответом
      state = state.copyWith(items: items, sending: false, step: '');
    }
    if (done != null && !done.isCompleted) done.complete();
  }
}
