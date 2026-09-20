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

  /// Когда сессия начата и когда в ней последний раз что-то происходило.
  final DateTime? startedAt;
  final DateTime? updatedAt;

  /// Сессия из ответа моста.
  const AgentSession({
    required this.id,
    this.name = '',
    this.messages = 0,
    this.startedAt,
    this.updatedAt,
  });

  /// Разбор сессии из ответа моста.
  factory AgentSession.fromJson(Map<String, dynamic> json) => AgentSession(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        messages: json['messages'] is num ? (json['messages'] as num).toInt() : 0,
        startedAt: DateTime.tryParse(json['startedAt']?.toString() ?? ''),
        updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
      );
}

/// Открытая сессия: то, что мост шлёт в ответ на открытие и в конце каждого ответа.
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

  /// Сколько сообщений в сессии.
  final int messages;

  /// Занята ли сессия: идёт генерация.
  final bool busy;

  /// Сколько токенов контекста занято и каково окно модели.
  final int? contextTokens;
  final int? contextWindow;

  /// Сессия из ответа моста.
  const AgentSessionInfo({
    required this.id,
    required this.path,
    this.name = '',
    this.model = '',
    this.provider = '',
    this.messages = 0,
    this.busy = false,
    this.contextTokens,
    this.contextWindow,
  });

  /// Разбор сессии из ответа моста.
  factory AgentSessionInfo.fromJson(Map<String, dynamic> json) => AgentSessionInfo(
        id: json['id']?.toString() ?? '',
        path: json['path']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        model: json['model']?.toString() ?? '',
        provider: json['provider']?.toString() ?? '',
        messages: json['messages'] is num ? (json['messages'] as num).toInt() : 0,
        busy: json['busy'] == true,
        contextTokens:
            json['contextTokens'] is num ? (json['contextTokens'] as num).toInt() : null,
        contextWindow:
            json['contextWindow'] is num ? (json['contextWindow'] as num).toInt() : null,
      );
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
        args: json['args'] is Map ? (json['args'] as Map).cast<String, dynamic>() : const {},
        output: json['output']?.toString() ?? '',
        isError: json['isError'] == true,
      );

  /// Копия с заменёнными полями; `null` означает «оставить как было».
  AgentTool copyWith({Map<String, dynamic>? args, String? output, bool? isError, bool? running}) =>
      AgentTool(
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
    for (final key in ['command', 'path', 'file_path', 'pattern', 'query', 'url']) {
      final value = args[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return args.isEmpty ? '' : args.toString();
  }
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

  /// Вызовы инструментов этого ответа.
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
  AgentItem copyWith({String? text, String? reasoning, List<AgentTool>? tools, String? error}) =>
      AgentItem(
        kind: kind,
        text: text ?? this.text,
        reasoning: reasoning ?? this.reasoning,
        tools: tools ?? this.tools,
        error: error ?? this.error,
        command: command,
      );
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
  String get label => [
        if (pi.isNotEmpty) 'pi $pi',
        if (model.isNotEmpty) model,
      ].join(' · ');
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
