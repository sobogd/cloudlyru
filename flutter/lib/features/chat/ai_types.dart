import 'package:flutter/foundation.dart';

/// Модель, доступная ключу сервера.
///
/// Список моделей приходит от нашего сервера (`GET /ai/models`), а тот спрашивает его у xAI
/// ключом из своего окружения. В приложении ключа нет вовсе, и хардкодить модели тоже нельзя:
/// набор зависит от ключа, а провайдер выпускает новые модели и снимает старые.
@immutable
class AiModel {
  /// Идентификатор для поля `model` в запросе (`grok-4.6`, `grok-4.3` и т. п.).
  ///
  /// Хранится и сравнивается именно он: индекс в списке между запусками меняется.
  final String id;

  /// Размер контекста в токенах — если провайдер его сообщил.
  final int? contextLength;

  /// Цена входа за 1 млн токенов в долларах.
  final double? inputPricePerMillion;

  /// Цена выхода за 1 млн токенов в долларах.
  final double? outputPricePerMillion;

  /// Модель с идентификатором и тем, что о ней сообщил сервер.
  const AiModel({
    required this.id,
    this.contextLength,
    this.inputPricePerMillion,
    this.outputPricePerMillion,
  });

  /// Разбор модели из ответа сервера.
  ///
  /// Незнакомые поля игнорируем, отсутствующие цены и контекст оставляем `null`: список должен
  /// показаться, даже если сервер поменяет формат, а не упасть разбором.
  factory AiModel.fromJson(Map<String, dynamic> json) => AiModel(
        id: json['id']?.toString() ?? '',
        contextLength: json['contextLength'] is int ? json['contextLength'] as int : null,
        inputPricePerMillion:
            json['inputPricePerMillion'] is num ? (json['inputPricePerMillion'] as num).toDouble() : null,
        outputPricePerMillion:
            json['outputPricePerMillion'] is num ? (json['outputPricePerMillion'] as num).toDouble() : null,
      );

  /// Подпись для списка выбора: идентификатор и через точку то, что о модели известно.
  ///
  /// Цены здесь не для красоты: разница между `grok-4.6` и `grok-4.3` на выходе втрое, и из
  /// идентификатора этого не видно.
  String get label {
    final parts = <String>[];
    if (contextLength != null) parts.add('${_shortTokens(contextLength!)} контекст');
    if (inputPricePerMillion != null && outputPricePerMillion != null) {
      parts.add('\$${inputPricePerMillion!.toStringAsFixed(2)}/'
          '\$${outputPricePerMillion!.toStringAsFixed(2)} за 1M');
    }
    return parts.isEmpty ? id : '$id · ${parts.join(' · ')}';
  }

  /// Токены в короткой записи (`500k`, `1M`): полное число в списке не помещается и не читается.
  static String _shortTokens(int tokens) {
    if (tokens >= 1000000) {
      final m = tokens / 1000000;
      return '${m == m.roundToDouble() ? m.round() : m.toStringAsFixed(1)}M';
    }
    if (tokens >= 1000) return '${(tokens / 1000).round()}k';
    return '$tokens';
  }
}

/// Стиль ответа: как модель говорит (задаётся подсказкой на сервере).
///
/// Список стилей приходит с сервера (`GET /ai/styles`) — там же живут их подсказки, поэтому
/// приложение показывает ровно то, что сервер умеет применить.
@immutable
class AiStyle {
  /// Идентификатор стиля для поля `style` (`normal`, `caveman`, `humanizer`).
  final String id;

  /// Подпись для списка выбора.
  final String title;

  /// Короткое пояснение: что стиль делает с ответом.
  final String hint;

  /// Стиль с подписью и пояснением.
  const AiStyle({required this.id, required this.title, required this.hint});

  /// Разбор стиля из ответа сервера.
  factory AiStyle.fromJson(Map<String, dynamic> json) => AiStyle(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        hint: json['hint']?.toString() ?? '',
      );
}

/// Чат в списке: тема, модель и когда в нём последний раз что-то происходило.
@immutable
class AiChat {
  /// Идентификатор чата: по нему открывается переписка и уходят запросы.
  final String id;

  /// Тема чата — её выводит сервер из первого вопроса.
  final String title;

  /// Модель, которой отвечает этот чат.
  final String model;

  /// Стиль ответа чата (`AiStyle.id`).
  final String style;

  /// Время последнего сообщения (сервер отдаёт по нему сортировку списка).
  final DateTime? updatedAt;

  /// Сколько сообщений в чате — видно в списке, не открывая переписку.
  final int messages;

  /// Чат с темой, моделью и счётчиком сообщений.
  const AiChat({
    required this.id,
    required this.title,
    required this.model,
    this.style = 'normal',
    this.updatedAt,
    this.messages = 0,
  });

  /// Разбор чата из ответа сервера.
  factory AiChat.fromJson(Map<String, dynamic> json) => AiChat(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? 'Чат',
        model: json['model']?.toString() ?? '',
        style: json['style']?.toString() ?? 'normal',
        updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '')?.toLocal(),
        messages: json['messages'] is int ? json['messages'] as int : 0,
      );
}

/// Сообщение переписки: вопрос человека или ответ модели.
@immutable
class AiMessage {
  /// Идентификатор сообщения; у ответа, который ещё дописывается, он пустой.
  final String id;

  /// `user` или `assistant` — те же имена ролей, что и на сервере.
  final String role;

  /// Текст сообщения без «размышлений».
  final String content;

  /// «Размышления» reasoning-модели: на экране показываются отдельным блоком.
  final String reasoning;

  /// Расход токенов на этот ответ (у вопроса — `null`).
  final int? promptTokens;
  final int? completionTokens;

  /// Сообщение переписки.
  const AiMessage({
    required this.id,
    required this.role,
    required this.content,
    this.reasoning = '',
    this.promptTokens,
    this.completionTokens,
  });

  /// Пустой ответ-заготовка, который дописывается потоком.
  ///
  /// Показывается сразу после отправки: человек видит, что запрос ушёл, а не пустое место до
  /// первого слова модели.
  const AiMessage.pending()
      : id = '',
        role = 'assistant',
        content = '',
        reasoning = '',
        promptTokens = null,
        completionTokens = null;

  /// Это вопрос человека (а не ответ модели).
  bool get isUser => role == 'user';

  /// Разбор сообщения из ответа сервера.
  factory AiMessage.fromJson(Map<String, dynamic> json) => AiMessage(
        id: json['id']?.toString() ?? '',
        role: json['role']?.toString() ?? 'assistant',
        content: json['content']?.toString() ?? '',
        reasoning: json['reasoning']?.toString() ?? '',
        promptTokens: json['promptTokens'] is int ? json['promptTokens'] as int : null,
        completionTokens:
            json['completionTokens'] is int ? json['completionTokens'] as int : null,
      );

  /// Копия сообщения с дописанным текстом — так растёт ответ по мере генерации.
  AiMessage copyWith({String? content, String? reasoning}) => AiMessage(
        id: id,
        role: role,
        content: content ?? this.content,
        reasoning: reasoning ?? this.reasoning,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
      );
}

/// Расход токенов на ответ — то, за что провайдер выставит счёт.
@immutable
class AiUsage {
  /// Токенов во входе: вся отправленная история плюс системная часть.
  final int promptTokens;

  /// Токенов в ответе, включая «размышления».
  final int completionTokens;

  /// Расход по одному ответу.
  const AiUsage({required this.promptTokens, required this.completionTokens});

  /// Разбор расхода из события потока; поля приходят из ответа xAI.
  factory AiUsage.fromJson(Map<String, dynamic> json) => AiUsage(
        promptTokens: json['promptTokens'] is int ? json['promptTokens'] as int : 0,
        completionTokens:
            json['completionTokens'] is int ? json['completionTokens'] as int : 0,
      );
}

/// Событие потока ответа.
///
/// Сервер шлёт их строками SSE (`data: {...}`), каждое несёт что-то одно: кусок текста, кусок
/// «размышлений», новую тему чата, расход токенов в конце или причину отказа. Разделение
/// оставлено как есть, а не склеено в «текст»: «размышления» показываются отдельным блоком,
/// а тему и расход надо разложить по своим местам в состоянии экрана.
@immutable
class AiChunk {
  /// Кусок текста ответа.
  final String? text;

  /// Кусок «размышлений».
  final String? reasoning;

  /// Новая тема чата (сервер выводит её из первого вопроса).
  final String? title;

  /// Расход токенов на текущий момент.
  final AiUsage? usage;

  /// Модель ищет в интернете (`true`) или закончила (`false`); `null` — событие не об этом.
  ///
  /// Отдельным событием, а не молчанием: с поиском ответ идёт десятками секунд, и на экране
  /// должно быть видно, что происходит.
  final bool? searching;

  /// Сервер закончил ответ; дальше событий не будет.
  final bool done;

  /// Причина отказа, полученная уже внутри потока (после начала ответа).
  final String? error;

  /// Событие потока с одной из полезных нагрузок.
  const AiChunk({
    this.text,
    this.reasoning,
    this.title,
    this.usage,
    this.searching,
    this.done = false,
    this.error,
  });
}
