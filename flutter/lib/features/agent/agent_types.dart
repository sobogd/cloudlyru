/// Типы раздела «Проекты»: то, что приходит от моста до харнесса pi (`agents/pi-bridge`).
///
/// Отдельным файлом от клиента ([agent_api.dart]) и состояния ([agent_controller.dart]) — как
/// в остальных разделах: разбор JSON не должен быть перемешан с сетью и экраном.
///
/// Все поля разбираются мягко (недостающее — пустое значение, а не исключение): список
/// проектов важнее строгости одной строки, а мост и приложение обновляются порознь.
library;

/// Проект — папка, в которой работает агент.
///
/// Именно папка, а не запись в базе: у pi сессия привязана к рабочей директории, и вся
/// «регистрация проекта» — это наличие папки внутри разрешённого корня.
class AgentProject {
  /// Полный путь на маке; он же идентификатор проекта в ручках моста.
  final String path;

  /// Имя последней папки — то, что показывается в списке.
  final String name;

  /// Сколько сессий уже есть в этой папке.
  final int sessions;

  /// Время последней сессии, если она была.
  final DateTime? lastUsed;

  /// Проект из ответа моста.
  const AgentProject({
    required this.path,
    required this.name,
    this.sessions = 0,
    this.lastUsed,
  });

  /// Разбор строки списка проектов.
  factory AgentProject.fromJson(Map<String, dynamic> json) => AgentProject(
    path: json['path']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    sessions: json['sessions'] is num ? (json['sessions'] as num).toInt() : 0,
    lastUsed: DateTime.tryParse(json['lastUsed']?.toString() ?? ''),
  );
}

/// Сессия pi в проекте — строка списка сессий (файл истории на маке).
class AgentSession {
  /// Идентификатор сессии pi; им же она продолжается.
  final String id;

  /// Имя сессии: поставленное человеком (`/name`) или первые слова первого вопроса.
  final String name;

  /// Сколько сообщений в сессии.
  final int messages;

  /// Модель, которой считался разговор (`провайдер` и идентификатор из первой записи сессии).
  ///
  /// Нужна списку: по ней видно, где считалась сессия — на маке или по API, — и это не
  /// приходится выяснять, открыв разговор.
  final String provider;
  final String model;

  /// Харнесс разговора (`pi` или `claude`) и его название для значка в списке.
  final String harness;
  final String harnessName;

  /// Когда сессия начата и когда в ней последний раз что-то происходило.
  final DateTime? startedAt;
  final DateTime? updatedAt;

  /// Сессия из ответа моста.
  const AgentSession({
    required this.id,
    this.name = '',
    this.messages = 0,
    this.provider = '',
    this.model = '',
    this.harness = '',
    this.harnessName = '',
    this.startedAt,
    this.updatedAt,
  });

  /// Разбор сессии из ответа моста.
  factory AgentSession.fromJson(Map<String, dynamic> json) => AgentSession(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    messages: json['messages'] is num ? (json['messages'] as num).toInt() : 0,
    provider: json['provider']?.toString() ?? '',
    model: json['model']?.toString() ?? '',
    harness: json['harness']?.toString() ?? '',
    harnessName: json['harnessName']?.toString() ?? '',
    startedAt: DateTime.tryParse(json['startedAt']?.toString() ?? ''),
    updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
  );

  /// Подпись модели для строки списка: `провайдер/идентификатор` или пустая строка.
  String get modelLabel => model.isEmpty ? '' : '$provider/$model';
}

/// Открытая сессия: то, что мост шлёт в ответ на открытие и в конце каждого ответа.
///
/// Кроме модели и занятости несёт статистику разговора: сколько занято окно модели, сколько
/// токенов израсходовано и сколько в сессии сообщений и вызовов инструментов. Это нужно экрану
/// сессии — по этим числам видно, когда пора сжимать контекст, и как долго идёт работа.
class AgentSessionInfo {
  /// Идентификатор сессии.
  final String id;

  /// Рабочая папка процесса pi.
  final String path;

  /// Имя сессии, если задано.
  final String name;

  /// Модель и её провайдер (например, `qwen/qwen3.5-9b` и `local`).
  final String model;
  final String provider;

  /// Человеческое название модели («Qwen3.5-9B Q6_K (локально, llama.cpp)»), если pi его дал.
  final String modelName;

  /// Модель считает на домашнем маке, а не по API — по этому признаку сессия подписывается
  /// словами, чтобы удалённая модель не выглядела как локальная.
  final bool local;

  /// Харнесс разговора (`pi` или `claude`).
  final String harness;
  final String harnessName;

  /// Заполнение контекста — оценка, а не точное число (так у Claude Code: он не отдаёт
  /// «занято токенов» одним полем, и процент считается из расхода последнего хода).
  final bool contextEstimated;

  /// Сколько сообщений в сессии.
  final int messages;

  /// Занята ли сессия: идёт генерация.
  final bool busy;

  /// Уровень «размышлений» у pi (`off`, `medium`, …): у локальной модели выключен, у
  /// reasoning-моделей по API включается на маке.
  final String thinkingLevel;

  /// Сколько токенов контекста занято и каково окно модели.
  final int? contextTokens;
  final int? contextWindow;

  /// Заполнение окна в процентах — то же число, что показывает pi.
  final double contextPercent;

  /// Расход токенов за всю сессию (по данным провайдера) и стоимость, если провайдер её считает.
  final int tokensInput;
  final int tokensOutput;
  final int tokensCacheRead;
  final int tokensTotal;
  final double cost;

  /// Счётчики разговора: вопросов, ответов и вызовов инструментов.
  final int userMessages;
  final int assistantMessages;
  final int toolCalls;

  /// Когда сессия начата и когда в ней последний раз что-то происходило.
  final DateTime? startedAt;
  final DateTime? updatedAt;

  /// Файл сессии на маке: путь показывается в сведениях, чтобы разговор можно было найти
  /// в терминале (`pi -r`) или удалить руками.
  final String sessionFile;

  /// Сессия из ответа моста.
  const AgentSessionInfo({
    required this.id,
    required this.path,
    this.name = '',
    this.model = '',
    this.provider = '',
    this.modelName = '',
    this.local = false,
    this.harness = '',
    this.harnessName = '',
    this.contextEstimated = false,
    this.messages = 0,
    this.busy = false,
    this.thinkingLevel = '',
    this.contextTokens,
    this.contextWindow,
    this.contextPercent = 0,
    this.tokensInput = 0,
    this.tokensOutput = 0,
    this.tokensCacheRead = 0,
    this.tokensTotal = 0,
    this.cost = 0,
    this.userMessages = 0,
    this.assistantMessages = 0,
    this.toolCalls = 0,
    this.startedAt,
    this.updatedAt,
    this.sessionFile = '',
  });

  /// Разбор сессии из ответа моста.
  factory AgentSessionInfo.fromJson(Map<String, dynamic> json) {
    final tokens = json['tokens'] is Map
        ? (json['tokens'] as Map).cast<String, dynamic>()
        : const {};
    int? num_(Object? v) => v is num ? v.toInt() : null;
    return AgentSessionInfo(
      id: json['id']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      provider: json['provider']?.toString() ?? '',
      modelName: json['modelName']?.toString() ?? '',
      local: json['local'] == true,
      harness: json['harness']?.toString() ?? '',
      harnessName: json['harnessName']?.toString() ?? '',
      contextEstimated: json['contextEstimated'] == true,
      messages: num_(json['messages']) ?? 0,
      busy: json['busy'] == true,
      thinkingLevel: json['thinkingLevel']?.toString() ?? '',
      contextTokens: num_(json['contextTokens']),
      contextWindow: num_(json['contextWindow']),
      contextPercent: json['contextPercent'] is num
          ? (json['contextPercent'] as num).toDouble()
          : 0,
      tokensInput: num_(tokens['input']) ?? 0,
      tokensOutput: num_(tokens['output']) ?? 0,
      tokensCacheRead: num_(tokens['cacheRead']) ?? 0,
      tokensTotal: num_(tokens['total']) ?? 0,
      cost: json['cost'] is num ? (json['cost'] as num).toDouble() : 0,
      userMessages: num_(json['userMessages']) ?? 0,
      assistantMessages: num_(json['assistantMessages']) ?? 0,
      toolCalls: num_(json['toolCalls']) ?? 0,
      startedAt: DateTime.tryParse(json['startedAt']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
      sessionFile: json['sessionFile']?.toString() ?? '',
    );
  }

  /// Сколько токенов окна ещё свободно; `null`, если pi пока не посчитал заполнение.
  ///
  /// Нужно экрану прямо: «осталось 5 021» понятнее, чем «84%», когда думаешь, влезет ли в
  /// контекст ещё одна большая команда.
  int? get contextFree {
    final used = contextTokens;
    final window = contextWindow;
    if (used == null || window == null) return null;
    return (window - used).clamp(0, window);
  }

  /// Подпись модели для шапки и сведений: название из pi, иначе идентификатор.
  String get modelLabel => modelName.isNotEmpty ? modelName : model;

  /// Где считает модель — словами для экрана.
  String get whereLabel => local ? 'локальная (на маке)' : 'по API (удалённая)';
}

/// Харнесс — агент, который работает в папке проекта: pi или Claude Code.
///
/// Их может быть несколько, и разговоры у каждого свои: истории лежат в разных местах на маке,
/// а модели задаются по-своему. Поэтому у сессии всегда есть харнесс, и приложение показывает
/// его значком, чтобы не путать, чей это разговор.
class AgentHarness {
  /// Имя харнесса: `pi` или `claude`.
  final String harness;

  /// Человеческое название для экрана.
  final String name;

  /// Стоит ли он на маке (иначе предлагать его бессмысленно).
  final bool available;

  /// Версия, как её печатает сам харнесс.
  final String version;

  /// Харнесс из ответа моста.
  const AgentHarness({
    required this.harness,
    this.name = '',
    this.available = false,
    this.version = '',
  });

  /// Разбор харнесса из ответа моста.
  factory AgentHarness.fromJson(Map<String, dynamic> json) => AgentHarness(
    harness: json['harness']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    available: json['available'] == true,
    version: json['version']?.toString() ?? '',
  );

  /// Подпись для экрана: название, а если его нет — имя харнесса.
  String get label => name.isNotEmpty ? name : harness;
}

/// Провайдер моделей, настроенный у pi на маке: свой (с адресом и ключом) или встроенный.
///
/// Ключ сюда не попадает никогда — только признак «задан» и его длина: приложению незачем
/// знать сам ключ, а показать «ключ сохранён» и «похоже, вставился не полностью» по длине можно.
class AgentProvider {
  /// Идентификатор провайдера у pi (`local`, `deepseek`, `openai`, …).
  final String key;

  /// Человеческое название.
  final String name;

  /// Адрес API; у встроенных провайдеров пусто — pi знает его сам.
  final String baseUrl;

  /// Тип API (`openai-completions` и подобные) — только у своих провайдеров.
  final String api;

  /// Свой провайдер из `models.json` (можно править и удалять) или встроенный (`auth.json`).
  final bool custom;

  /// Ключ задан (или не нужен, как у локальной модели).
  final bool hasKey;

  /// Длина сохранённого ключа: по ней видно, вставился ли он целиком.
  final int keyLength;

  /// Провайдер считает на этом маке (llama.cpp), а не по API.
  final bool local;

  /// Модели, описанные у своего провайдера (у встроенных список даёт сам pi).
  final List<AgentModel> models;

  /// Провайдер из ответа моста.
  const AgentProvider({
    required this.key,
    this.name = '',
    this.baseUrl = '',
    this.api = '',
    this.custom = false,
    this.hasKey = false,
    this.keyLength = 0,
    this.local = false,
    this.models = const [],
  });

  /// Разбор провайдера из ответа моста.
  factory AgentProvider.fromJson(Map<String, dynamic> json) => AgentProvider(
    key: json['key']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    baseUrl: json['baseUrl']?.toString() ?? '',
    api: json['api']?.toString() ?? '',
    custom: json['custom'] == true,
    hasKey: json['hasKey'] == true,
    keyLength: json['keyLength'] is num
        ? (json['keyLength'] as num).toInt()
        : 0,
    local: json['local'] == true,
    models: <AgentModel>[
      if (json['models'] is List)
        for (final m in json['models'] as List)
          if (m is Map)
            AgentModel.fromJson({
              ...m.cast<String, dynamic>(),
              'provider': json['key']?.toString() ?? '',
              'local': json['local'] == true,
              'hasKey': json['hasKey'] == true,
            }),
    ],
  );

  /// Подпись для экрана: название, а если его нет — идентификатор.
  String get label => name.isNotEmpty ? name : key;
}

/// Модель, доступная харнессу на маке: локальная llama.cpp или удалённая по API.
///
/// Список приходит от pi, поэтому в нём ровно то, что он действительно может запустить.
/// Ключей от API здесь нет: они остаются на маке, приложению приходит только признак «ключ
/// задан», чтобы не предлагать модель, которая всё равно не ответит.
class AgentModel {
  /// Провайдер (`local`, `openai`, `deepseek`, …) и идентификатор модели.
  final String provider;
  final String id;

  /// Человеческое название.
  final String name;

  /// Окно контекста и потолок ответа в токенах, если pi их знает.
  final int? contextWindow;
  final int? maxTokens;

  /// Модель умеет «размышления».
  final bool thinking;

  /// Модель считает на этом маке, а не по API.
  final bool local;

  /// У провайдера задан ключ (или он не нужен, как у локальной модели).
  final bool hasKey;

  /// Модель из списка pi.
  const AgentModel({
    required this.provider,
    required this.id,
    this.name = '',
    this.contextWindow,
    this.maxTokens,
    this.thinking = false,
    this.local = false,
    this.hasKey = true,
  });

  /// Разбор модели из ответа моста.
  factory AgentModel.fromJson(Map<String, dynamic> json) => AgentModel(
    provider: json['provider']?.toString() ?? '',
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    contextWindow: json['contextWindow'] is num
        ? (json['contextWindow'] as num).toInt()
        : null,
    maxTokens: json['maxTokens'] is num
        ? (json['maxTokens'] as num).toInt()
        : null,
    thinking: json['thinking'] == true,
    local: json['local'] == true,
    hasKey: json['hasKey'] != false,
  );

  /// Строка для хранения выбора в настройках и для сравнения с текущей моделью сессии.
  String get key => '$provider/$id';

  /// Подпись строки списка: имя модели, а если его нет — идентификатор.
  String get label => name.isNotEmpty ? name : id;
}

/// Вызов инструмента агентом: что попросил, с чем и что получил.
///
/// Одна карточка на вызов: результат приходит отдельным сообщением pi, а показывать его
/// отдельной строкой переписки незачем — это часть одного действия.
class AgentTool {
  /// Идентификатор вызова у pi; по нему результат подклеивается к вызову.
  final String id;

  /// Имя инструмента: `bash`, `read`, `edit`, `write`, `grep`, `find`, `ls` и прочие у pi.
  final String name;

  /// Аргументы вызова как их передал агент (команда, путь, шаблон).
  final Map<String, dynamic> args;

  /// Вывод инструмента; у долгих команд наполняется по мере выполнения.
  final String output;

  /// Инструмент завершился ошибкой.
  final bool isError;

  /// Вызов ещё выполняется — на карточке это спиннер вместо галочки.
  final bool running;

  /// Вызов инструмента.
  const AgentTool({
    required this.id,
    required this.name,
    this.args = const {},
    this.output = '',
    this.isError = false,
    this.running = false,
  });

  /// Разбор вызова из ответа моста (в истории приходит готовым объектом).
  factory AgentTool.fromJson(Map<String, dynamic> json) => AgentTool(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    args: json['args'] is Map
        ? (json['args'] as Map).cast<String, dynamic>()
        : const {},
    output: json['output']?.toString() ?? '',
    isError: json['isError'] == true,
  );

  /// Копия с заменёнными полями; `null` означает «оставить как было».
  AgentTool copyWith({
    Map<String, dynamic>? args,
    String? output,
    bool? isError,
    bool? running,
  }) => AgentTool(
    id: id,
    name: name,
    args: args ?? this.args,
    output: output ?? this.output,
    isError: isError ?? this.isError,
    running: running ?? this.running,
  );

  /// Подпись вызова одной строкой: команда у оболочки, путь у файловых инструментов.
  ///
  /// Нужна строке карточки, пока она свёрнута: по ней видно, что агент делает, не разворачивая
  /// вывод целиком.
  String get summary {
    for (final key in [
      'command',
      'path',
      'file_path',
      'pattern',
      'query',
      'url',
    ]) {
      final value = args[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return args.isEmpty ? '' : args.toString();
  }
}

/// Блок ответа агента в том порядке, в каком он появился: кусок текста, «размышления» или
/// ссылка на карточку вызова инструмента.
///
/// Нужен именно порядок. Модель отвечает так: пишет текст, просит выполнить команду, получает
/// результат, пишет текст дальше — и всё это один ответ на один вопрос. Если рисовать текст
/// отдельно от карточек, новый текст оказывается над карточками, и разговор читается не в том
/// порядке, в каком шёл. Карточки адресуются идентификатором: сам вывод инструмента лежит в
/// [AgentItem.tools] и в блоках не дублируется.
class AgentBlock {
  /// Вид блока: `text`, `reasoning` или `tool`.
  final String type;

  /// Текст блока (для `text` и `reasoning`); у блока-инструмента пусто.
  final String text;

  /// Идентификатор вызова инструмента (для `tool`).
  final String toolId;

  /// Блок ответа.
  const AgentBlock({required this.type, this.text = '', this.toolId = ''});

  /// Кусок текста ответа.
  const AgentBlock.text(String value) : this(type: 'text', text: value);

  /// Кусок «размышлений» модели.
  const AgentBlock.reasoning(String value)
    : this(type: 'reasoning', text: value);

  /// Ссылка на карточку вызова инструмента.
  const AgentBlock.tool(String id) : this(type: 'tool', toolId: id);

  /// Разбор блока из ответа моста.
  factory AgentBlock.fromJson(Map<String, dynamic> json) => AgentBlock(
    type: json['type']?.toString() ?? 'text',
    text: json['text']?.toString() ?? '',
    toolId: json['id']?.toString() ?? '',
  );

  /// Это кусок текста.
  bool get isText => type == 'text';

  /// Это «размышления».
  bool get isReasoning => type == 'reasoning';

  /// Это карточка вызова инструмента.
  bool get isTool => type == 'tool';

  /// Копия с дописанным текстом.
  AgentBlock plus(String extra) =>
      AgentBlock(type: type, text: text + extra, toolId: toolId);
}

/// Элемент переписки: вопрос человека, ответ агента или прямая команда оболочки.
///
/// Одним типом, а не тремя, потому что экран рисует их одним списком и различает по [kind].
class AgentItem {
  /// Вид элемента: `user` (вопрос), `assistant` (ответ агента), `bash` (команда оболочки),
  /// `note` (служебная строка, например автоответ на подтверждение).
  final String kind;

  /// Текст: вопрос, ответ агента или вывод команды.
  final String text;

  /// «Размышления» модели, если она их отдаёт (у локальной qwen они выключены).
  final String reasoning;

  /// Блоки ответа в порядке появления: текст, «размышления» и карточки инструментов.
  ///
  /// Пустой список означает ответ от старого моста, который блоков ещё не присылал: тогда
  /// экран рисует текст, размышления и карточки по отдельным полям.
  final List<AgentBlock> blocks;

  /// Вызовы инструментов этого ответа (в том числе те, на которые ссылаются блоки).
  final List<AgentTool> tools;

  /// Ошибка ответа (например, «Request was aborted»), если прогон не удался.
  final String error;

  /// Команда для элемента `bash`.
  final String command;

  /// Элемент переписки.
  const AgentItem({
    required this.kind,
    this.text = '',
    this.reasoning = '',
    this.blocks = const [],
    this.tools = const [],
    this.error = '',
    this.command = '',
  });

  /// Разбор элемента из ответа моста.
  factory AgentItem.fromJson(Map<String, dynamic> json) => AgentItem(
    kind: json['kind']?.toString() ?? 'assistant',
    text: json['text']?.toString() ?? '',
    reasoning: json['reasoning']?.toString() ?? '',
    error: json['error']?.toString() ?? '',
    command: json['command']?.toString() ?? '',
    blocks: <AgentBlock>[
      if (json['blocks'] is List)
        for (final b in json['blocks'] as List)
          if (b is Map) AgentBlock.fromJson(b.cast<String, dynamic>()),
    ],
    tools: <AgentTool>[
      if (json['tools'] is List)
        for (final t in json['tools'] as List)
          if (t is Map) AgentTool.fromJson(t.cast<String, dynamic>()),
    ],
  );

  /// Это вопрос человека.
  bool get isUser => kind == 'user';

  /// Это ответ агента (пузырь с текстом, размышлениями и карточками инструментов).
  bool get isAssistant => kind == 'assistant';

  /// Копия с заменёнными полями.
  AgentItem copyWith({
    String? text,
    String? reasoning,
    List<AgentBlock>? blocks,
    List<AgentTool>? tools,
    String? error,
  }) => AgentItem(
    kind: kind,
    text: text ?? this.text,
    reasoning: reasoning ?? this.reasoning,
    blocks: blocks ?? this.blocks,
    tools: tools ?? this.tools,
    error: error ?? this.error,
    command: command,
  );

  /// Ответ пуст: ни текста, ни карточек — на экране это ожидание первого куска ответа.
  bool get isEmpty =>
      text.isEmpty && reasoning.isEmpty && tools.isEmpty && blocks.isEmpty;
}

/// Расход токенов на ответ: приходит от провайдера по ходу генерации.
class AgentUsage {
  /// Токенов во входе и в ответе (у локальной llama.cpp вход считается по факту прогрева).
  final int input;
  final int output;

  /// Всего токенов в контексте по данным провайдера.
  final int total;

  /// Расход токенов.
  const AgentUsage({this.input = 0, this.output = 0, this.total = 0});
}

/// Состояние моста: жив ли он, какая версия pi и какая модель выбрана.
class AgentHealth {
  /// Версия харнесса, как её печатает `pi --version`.
  final String pi;

  /// Провайдер и модель, которые мост передаёт pi.
  final String provider;
  final String model;

  /// Корни, внутри которых разрешён выбор проектов.
  final List<String> roots;

  /// Состояние моста.
  const AgentHealth({
    this.pi = '',
    this.provider = '',
    this.model = '',
    this.roots = const [],
  });

  /// Разбор ответа `/health`.
  factory AgentHealth.fromJson(Map<String, dynamic> json) => AgentHealth(
    pi: json['pi']?.toString() ?? '',
    provider: json['provider']?.toString() ?? '',
    model: json['model']?.toString() ?? '',
    roots: <String>[
      if (json['roots'] is List)
        for (final r in json['roots'] as List) r.toString(),
    ],
  );

  /// Подпись «харнесс и модель» для шапки раздела.
  String get label =>
      [if (pi.isNotEmpty) 'pi $pi', if (model.isNotEmpty) model].join(' · ');
}

/// Одно событие потока ответа.
///
/// Как и у чата, событие несёт ровно то, что изменилось, а все поля необязательные: незнакомый
/// тип события не ломает разбор, и старая сборка приложения переживает новый мост.
class AgentEvent {
  /// Кусок текста ответа.
  final String? text;

  /// Кусок «размышлений».
  final String? reasoning;

  /// Что происходит прямо сейчас: «читаю файл», «выполняю команду».
  final String? status;

  /// Начался вызов инструмента.
  final AgentTool? toolStart;

  /// Прогресс вызова: накопленный вывод на текущий момент.
  final AgentTool? toolProgress;

  /// Вызов завершён.
  final AgentTool? toolEnd;

  /// Объявленный (ещё без аргументов) вызов инструмента.
  final AgentTool? toolCall;

  /// Служебная строка для переписки: например, автоответ на подтверждение.
  final String? note;

  /// Расход токенов.
  final AgentUsage? usage;

  /// Сессия после завершения прогона (модель, расход контекста).
  final AgentSessionInfo? session;

  /// Ответ завершён.
  final bool done;

  /// Причина отказа; вместе с [done] означает, что поток закончился ошибкой.
  final String? error;

  /// Событие потока ответа.
  const AgentEvent({
    this.text,
    this.reasoning,
    this.status,
    this.toolStart,
    this.toolProgress,
    this.toolEnd,
    this.toolCall,
    this.note,
    this.usage,
    this.session,
    this.done = false,
    this.error,
  });
}
