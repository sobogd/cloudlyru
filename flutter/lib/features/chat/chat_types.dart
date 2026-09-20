/// Типы раздела «Чат»: то, что приходит из ручек `/chat/*`.
///
/// Отдельным файлом от клиента ([chat_api.dart]) и состояния ([chat_controller.dart]), как это
/// сделано в остальных разделах приложения: разбор JSON не должен быть перемешан с сетью и
/// состоянием экрана.
library;

/// Чат в списке: тема, модель и число сообщений.
class ChatSummary {
  /// Идентификатор чата (uuid с сервера).
  final String id;

  /// Тема; выводится сервером из первого вопроса, правится вручную.
  final String title;

  /// Модель этого чата в том виде, в каком её понимает сервер модели.
  final String model;

  /// Время последнего сообщения; по нему список отсортирован.
  final DateTime? updatedAt;

  /// Сколько сообщений в чате (счётчик для строки списка).
  final int messages;

  /// Чат из ответа сервера.
  const ChatSummary({
    required this.id,
    required this.title,
    required this.model,
    this.updatedAt,
    this.messages = 0,
  });

  /// Разбор ответа сервера; недостающие поля заменяются пустыми значениями, а не падением:
  /// список чатов важнее, чем строгость разбора одной строки.
  factory ChatSummary.fromJson(Map<String, dynamic> json) => ChatSummary(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        model: json['model']?.toString() ?? '',
        updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
        messages: json['messages'] is num ? (json['messages'] as num).toInt() : 0,
      );
}

/// Источник ответа: страница, по которой модель отвечала.
///
/// Номер [position] — это то самое `[1]` в тексте ответа: по нему упоминание превращается
/// в ссылку, а сам адрес открывается по нажатию на строку источника.
class ChatSource {
  /// Номер источника в ответе, начиная с единицы.
  final int position;

  /// Заголовок страницы (или заголовок из поисковой выдачи, если страница не открылась).
  final String title;

  /// Адрес страницы.
  final String url;

  /// Страница прочитана целиком, а не только выдержка из выдачи.
  final bool read;

  /// Сколько символов текста страницы ушло модели.
  final int chars;

  /// Источник из ответа сервера.
  const ChatSource({
    required this.position,
    required this.title,
    required this.url,
    this.read = false,
    this.chars = 0,
  });

  /// Разбор ответа сервера.
  factory ChatSource.fromJson(Map<String, dynamic> json) => ChatSource(
        position: json['position'] is num ? (json['position'] as num).toInt() : 0,
        title: json['title']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
        read: json['read'] == true,
        chars: json['chars'] is num ? (json['chars'] as num).toInt() : 0,
      );

  /// Домен страницы — то, что показывается в строке источника вместо длинного адреса.
  String get host {
    final uri = Uri.tryParse(url);
    return uri?.host.replaceFirst('www.', '') ?? url;
  }
}

/// Сообщение переписки: вопрос человека или ответ модели вместе с источниками.
class ChatMessage {
  /// Идентификатор на сервере; пустая строка у сообщения, которое ещё не сохранено.
  final String id;

  /// 'user' или 'assistant' — те же имена ролей, что понимает API модели.
  final String role;

  /// Текст сообщения.
  final String content;

  /// «Размышления» reasoning-модели (в контекст следующего запроса не уходят).
  final String reasoning;

  /// Поисковый запрос, которым добывались данные для этого ответа.
  final String? searchQuery;

  /// Расход токенов на ответ (у вопроса — null).
  final int? promptTokens;
  final int? completionTokens;

  /// Источники ответа в порядке нумерации.
  final List<ChatSource> sources;

  /// Сообщение переписки.
  const ChatMessage({
    this.id = '',
    this.role = 'assistant',
    this.content = '',
    this.reasoning = '',
    this.searchQuery,
    this.promptTokens,
    this.completionTokens,
    this.sources = const [],
  });

  /// Пустая заготовка ответа: показывается, пока модель не прислала первый кусок текста.
  const ChatMessage.pending()
      : id = '',
        role = 'assistant',
        content = '',
        reasoning = '',
        searchQuery = null,
        promptTokens = null,
        completionTokens = null,
        sources = const [];

  /// Это вопрос человека.
  bool get isUser => role == 'user';

  /// Разбор сообщения из ответа сервера.
  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id']?.toString() ?? '',
        role: json['role']?.toString() ?? 'assistant',
        content: json['content']?.toString() ?? '',
        reasoning: json['reasoning']?.toString() ?? '',
        searchQuery: json['searchQuery']?.toString(),
        promptTokens: json['promptTokens'] is num ? (json['promptTokens'] as num).toInt() : null,
        completionTokens:
            json['completionTokens'] is num ? (json['completionTokens'] as num).toInt() : null,
        sources: <ChatSource>[
          if (json['sources'] is List)
            for (final s in json['sources'] as List)
              if (s is Map) ChatSource.fromJson(s.cast<String, dynamic>()),
        ],
      );

  /// Копия с заменёнными полями; `null` означает «оставить как было».
  ChatMessage copyWith({
    String? content,
    String? reasoning,
    List<ChatSource>? sources,
    int? promptTokens,
    int? completionTokens,
  }) =>
      ChatMessage(
        id: id,
        role: role,
        content: content ?? this.content,
        reasoning: reasoning ?? this.reasoning,
        searchQuery: searchQuery,
        promptTokens: promptTokens ?? this.promptTokens,
        completionTokens: completionTokens ?? this.completionTokens,
        sources: sources ?? this.sources,
      );
}

/// Модель сервера модели; стандартная ручка отдаёт только идентификатор.
class ChatModel {
  /// Идентификатор, который понимает сервер модели (например, `qwen/qwen3.5-9b`).
  final String id;

  /// Модель из ответа сервера.
  const ChatModel({required this.id});

  /// Разбор ответа сервера.
  factory ChatModel.fromJson(Map<String, dynamic> json) => ChatModel(
        id: json['id']?.toString() ?? '',
      );

  /// Подпись для экрана: у стандартной ручки это и есть идентификатор.
  String get label => id;
}

/// Ответ ручки моделей: есть ли вообще настроенный сервер модели.
class ChatModelsReply {
  /// Настроен ли раздел (`false` — сервер не видит модель на маке).
  final bool configured;

  /// Доступные модели.
  final List<ChatModel> models;

  /// Ответ ручки моделей.
  const ChatModelsReply({required this.configured, required this.models});
}

/// Расход токенов на ответ.
class ChatUsage {
  /// Токенов во входе (весь запрос: история, источники, вопрос).
  final int promptTokens;

  /// Токенов в ответе.
  final int completionTokens;

  /// Расход токенов.
  const ChatUsage({this.promptTokens = 0, this.completionTokens = 0});

  /// Разбор расхода из ответа сервера.
  factory ChatUsage.fromJson(Map<String, dynamic> json) => ChatUsage(
        promptTokens: json['promptTokens'] is num ? (json['promptTokens'] as num).toInt() : 0,
        completionTokens:
            json['completionTokens'] is num ? (json['completionTokens'] as num).toInt() : 0,
      );
}

/// Одно событие потока ответа.
///
/// Событие несёт ровно то, что изменилось: кусок текста, кусок размышлений, новую тему чата,
/// готовые источники, признак «идёт поиск» или завершение. Поля необязательные, поэтому
/// незнакомый тип события не ломает разбор — клиент просто ничего не меняет.
class ChatChunk {
  /// Кусок текста ответа.
  final String? text;

  /// Кусок «размышлений».
  final String? reasoning;

  /// Тема чата, которую сервер вывел из первого вопроса.
  final String? title;

  /// Идёт поиск в интернете (и чтение страниц) — на экране это подпись вместо «печатает».
  final bool? searching;

  /// Готовые источники ответа: приходят до генерации, чтобы ссылки были видны сразу.
  final List<ChatSource>? sources;

  /// Ответ завершён.
  final bool done;

  /// Причина отказа; вместе с [done] означает, что поток закончился ошибкой.
  final String? error;

  /// Расход токенов (приходит последним событием).
  final ChatUsage? usage;

  /// Событие потока; все поля необязательные.
  const ChatChunk({
    this.text,
    this.reasoning,
    this.title,
    this.searching,
    this.sources,
    this.done = false,
    this.error,
    this.usage,
  });
}
