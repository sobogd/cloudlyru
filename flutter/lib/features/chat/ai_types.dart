import 'package:flutter/foundation.dart';

/// Роль сообщения в переписке с моделью.
///
/// Имена значений совпадают с ролями в API провайдеров (`system`, `user`, `assistant`) и
/// подставляются в тело запроса как есть ([AiMessage.toApiJson]): переименование значения —
/// это правка протокола, а не косметика, и оно молча сломает запрос.
enum AiRole { system, user, assistant }

/// Одно сообщение переписки: кто и что сказал.
///
/// Объект неизменяемый: список сообщений целиком пересобирается контроллером чата, а поток
/// ответа порождает новую копию последнего сообщения на каждую полученную дельту
/// ([AiMessage.copyWith]). Так у экрана всегда цельная картина состояния, а не список,
/// который кто-то правит на месте.
@immutable
class AiMessage {
  /// Кто автор сообщения.
  final AiRole role;

  /// Текст сообщения без «размышлений»: именно он уходит в следующий запрос как история.
  final String text;

  /// «Размышления» модели, пришедшие вместе с ответом (у reasoning-моделей).
  ///
  /// В контекст следующего запроса они **не** отправляются: OpenAI-совместимые API такого поля
  /// во входных сообщениях не принимают, а у xAI для этого есть отдельный механизм
  /// (`reasoning.encrypted_content`). Здесь они хранятся только чтобы показать их человеку.
  final String reasoning;

  /// Сообщение целиком: роль, текст и, если есть, «размышления».
  const AiMessage({required this.role, required this.text, this.reasoning = ''});

  /// Копия сообщения с заменёнными полями — нужна потоку ответа, который дописывает текст
  /// по дельтам, не трогая уже собранный список.
  AiMessage copyWith({String? text, String? reasoning}) => AiMessage(
        role: role,
        text: text ?? this.text,
        reasoning: reasoning ?? this.reasoning,
      );

  /// Представление для тела запроса к провайдеру.
  ///
  /// Провайдеры (xAI и OpenAI) принимают `content` строкой — так и отдаём. Роль переводится
  /// в строку через `name`, поэтому значения [AiRole] обязаны совпадать с именами ролей API.
  Map<String, dynamic> toApiJson() => {'role': role.name, 'content': text};
}

/// Модель, доступная ключу владельца, — как её отдаёт сам провайдер.
///
/// Список моделей никогда не хардкодится: набор зависит от ключа (у разных ключей разные
/// уровни доступа), а провайдер выпускает новые модели и снимает старые. Отсюда и поля:
/// идентификатор нужен для запроса, остальное — чтобы человек понимал, что выбирает.
@immutable
class AiModel {
  /// Идентификатор для поля `model` в запросе (`grok-4.6`, `grok-4.3` и т. п.).
  ///
  /// Хранить и сравнивать нужно именно его: индекс в списке между запусками меняется.
  final String id;

  /// Размер контекста в токенах, если провайдер его сообщил.
  final int? contextLength;

  /// Цена входа за 1 млн токенов в долларах, если провайдер её сообщил.
  final double? inputPricePerMillion;

  /// Цена выхода за 1 млн токенов в долларах, если провайдер её сообщил.
  final double? outputPricePerMillion;

  /// Модель с идентификатором и, если провайдер их дал, ценой и размером контекста.
  const AiModel({
    required this.id,
    this.contextLength,
    this.inputPricePerMillion,
    this.outputPricePerMillion,
  });

  /// Копия модели с заменённым размером контекста.
  ///
  /// Нужна потому, что цена и контекст приходят разными ручками провайдера: список чат-моделей
  /// отдаёт цены, а размер контекста лежит в другом списке (`GrokProvider.listModels`), и
  /// модель собирается из двух ответов.
  AiModel copyWith({int? contextLength}) => AiModel(
        id: id,
        contextLength: contextLength ?? this.contextLength,
        inputPricePerMillion: inputPricePerMillion,
        outputPricePerMillion: outputPricePerMillion,
      );

  /// Подпись для списка выбора: идентификатор и через точку то, что о модели известно.
  ///
  /// Цены — единственный способ увидеть, во что обойдётся разговор: у xAI разница между
  /// `grok-4.6` и `grok-4.3` втрое на выходе, а из идентификатора этого не видно.
  String get label {
    final parts = <String>[];
    if (contextLength != null) parts.add('${_shortTokens(contextLength!)} контекст');
    if (inputPricePerMillion != null && outputPricePerMillion != null) {
      parts.add('\$${inputPricePerMillion!.toStringAsFixed(2)}/'
          '\$${outputPricePerMillion!.toStringAsFixed(2)} за 1M');
    }
    return parts.isEmpty ? id : '$id · ${parts.join(' · ')}';
  }

  /// Токены в короткой записи (`500k`, `1M`) — полное число в списке не помещается и не читается.
  static String _shortTokens(int tokens) {
    if (tokens >= 1000000) {
      final m = tokens / 1000000;
      return '${m == m.roundToDouble() ? m.round() : m.toStringAsFixed(1)}M';
    }
    if (tokens >= 1000) return '${(tokens / 1000).round()}k';
    return '$tokens';
  }
}

/// Расход токенов на один ответ — то, за что провайдер выставит счёт.
///
/// Приходит в каждом чанке потока, а не один раз в конце, поэтому контроллер чата берёт
/// последнее полученное значение ([AiChunk.usage]).
@immutable
class AiUsage {
  /// Токенов во входе (вся отправленная история плюс системная часть).
  final int promptTokens;

  /// Токенов в ответе, включая «размышления».
  final int completionTokens;

  /// Всего токенов в запросе.
  final int totalTokens;

  /// Расход по одному ответу.
  const AiUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
  });
}

/// Порция ответа, пришедшая из потока.
///
/// Один чанк несёт что-то одно: либо кусок обычного текста, либо кусок «размышлений», либо
/// только расход токенов. Разделение оставлено как есть, а не склеено в «текст», потому что
/// «размышления» на экране показываются отдельным сворачиваемым блоком.
@immutable
class AiChunk {
  /// Кусок текста ответа или `null`, если в этом чанке текста нет.
  final String? text;

  /// Кусок «размышлений» или `null`, если в этом чанке их нет.
  final String? reasoning;

  /// Расход токенов на текущий момент или `null`, если провайдер его не прислал.
  final AiUsage? usage;

  /// Чанк с одним из трёх видов полезной нагрузки (остальные — `null`).
  const AiChunk({this.text, this.reasoning, this.usage});
}
