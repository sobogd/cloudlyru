import 'dart:convert';

import 'package:dio/dio.dart';

import 'ai_provider.dart';
import 'ai_types.dart';

/// Провайдер xAI (Grok): список моделей и ответ потоком.
///
/// Почему сразу `chat/completions`, хотя у xAI он помечен как legacy: это документированный
/// OpenAI-совместимый SSE, которого достаточно для чата, тогда как `/v1/responses` тянет за
/// собой состояние на стороне провайдера (история хранится у него 30 дней) — это отдельное
/// решение, которое принимают, когда понадобятся инструменты и веб-поиск.
///
/// Клиент здесь отдельный от `CloudlyApi`: у того своя cookie-сессия, свой baseUrl и своя
/// логика ошибок, а общий клиент связал бы чат с адресом нашего сервера — чат ходит напрямую
/// в xAI и работает, даже когда наш сервер недоступен.
class GrokProvider implements AiProvider {
  /// База API xAI. Версия в пути (`/v1`) — часть контракта, а не украшение.
  static const _baseUrl = 'https://api.x.ai/v1';

  final Dio _dio;

  /// Провайдер, подписывающий запросы ключом владельца.
  ///
  /// [apiKey] пустым быть не должен: экран чата не отправляет запрос без ключа
  /// (`AiKeys.hasGrok`), а здесь пустой ключ — это заведомый `401`.
  GrokProvider({required String apiKey})
      : _dio = Dio(BaseOptions(
          baseUrl: _baseUrl,
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          connectTimeout: const Duration(seconds: 20),
          // `receiveTimeout` не задаём намеренно: у Dio он считается между порциями данных, а
          // reasoning-модель может молчать десятками секунд перед первым словом — запрос
          // обрывался бы «сам по себе» ровно в тот момент, когда модель думает. Вместо
          // таймаута поток рвёт человек кнопкой «Стоп» (отмена запроса, см. [stream]).
        ));

  /// Модели, доступные этому ключу, — из `GET /v1/language-models` плюс размер контекста
  /// из `GET /v1/models`.
  ///
  /// Берём именно `language-models`, а не `/v1/models`: он отдаёт чат-модели и модели
  /// понимания картинок, то есть ровно то, что подходит для чата. В `/v1/models` лежат ещё и
  /// генераторы картинок с видео, а признака «это чат» там нет — в списке выбора они были бы
  /// лишними строками, на которых запрос всё равно не работает.
  ///
  /// Размер контекста приходит только во втором списке (в `language-models` его нет — там есть
  /// лишь порог длинного контекста, а это другое число), поэтому модели собираются из двух
  /// ответов. Неудача второго запроса список не отменяет: контекст — справка в подписи, и
  /// терять из-за него сами модели нельзя.
  ///
  /// Порядок моделей оставляем таким, каким его отдал провайдер: своей «правильной»
  /// сортировки у нас нет, а алфавитная спрятала бы свежие модели в середину списка.
  @override
  Future<List<AiModel>> listModels() async {
    final models = await _fetchLanguageModels();
    final contexts = await _fetchContextLengths();
    if (contexts.isEmpty) return models;
    return [
      for (final m in models)
        contexts[m.id] == null ? m : m.copyWith(contextLength: contexts[m.id]),
    ];
  }

  /// Чат-модели ключа с ценами — из `GET /v1/language-models`.
  Future<List<AiModel>> _fetchLanguageModels() async {
    final Response<Map<String, dynamic>> res;
    try {
      res = await _dio.get<Map<String, dynamic>>(
        '/language-models',
        // таймаут только на этот запрос: список моделей — короткий обмен, и ждать его вечно
        // незачем, в отличие от генерации ответа
        options: Options(receiveTimeout: const Duration(seconds: 30)),
      );
    } on DioException catch (e) {
      throw _error(e);
    }

    final models = res.data?['models'];
    if (models is! List) {
      throw const AiException(AiErrorKind.other, 'xAI вернул список моделей в незнакомом виде');
    }
    return [
      for (final m in models)
        if (m is Map) _modelFromJson(m),
    ];
  }

  /// Размеры контекста по идентификаторам моделей — из `GET /v1/models`.
  ///
  /// Любая неудача — это пустая карта, а не ошибка: подпись модели останется без контекста,
  /// а список моделей и чат будут работать.
  Future<Map<String, int>> _fetchContextLengths() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/models',
        options: Options(receiveTimeout: const Duration(seconds: 30)),
      );
      final data = res.data?['data'];
      if (data is! List) return const {};
      final out = <String, int>{};
      for (final m in data) {
        if (m is! Map) continue;
        final id = m['id'];
        final ctx = m['context_length'];
        if (id is String && ctx is int && ctx > 0) out[id] = ctx;
      }
      return out;
    } on DioException {
      return const {};
    }
  }

  /// Ответ модели потоком по `POST /v1/chat/completions` с `stream: true`.
  ///
  /// История уходит целиком в каждом запросе: API провайдера не помнит предыдущие сообщения
  /// (в отличие от `/v1/responses`, где контекст живёт на стороне xAI).
  ///
  /// Прерывание потока рвёт и HTTP-запрос: `finally` срабатывает и при отмене подписки
  /// потребителем (кнопка «Стоп»), и тогда `CancelToken` закрывает соединение. Без этого
  /// генерация продолжалась бы до конца, а токены списывались бы за уже не нужный ответ.
  @override
  Stream<AiChunk> stream({
    required String model,
    required List<AiMessage> messages,
  }) async* {
    final cancelToken = CancelToken();
    try {
      final Response<ResponseBody> res;
      try {
        res = await _dio.post<ResponseBody>(
          '/chat/completions',
          data: {
            'model': model,
            'messages': [for (final m in messages) m.toApiJson()],
            'stream': true,
          },
          // тело ответа читаем сами как поток байтов: Dio не должен пытаться разобрать SSE
          // как JSON
          options: Options(responseType: ResponseType.stream),
          cancelToken: cancelToken,
        );
      } on DioException catch (e) {
        throw _error(e);
      }

      final body = res.data;
      if (body == null) {
        throw const AiException(AiErrorKind.other, 'xAI закрыл соединение, не прислав ответ');
      }
      yield* _parse(body.stream);
    } finally {
      // Сюда попадаем и при обычном завершении, и при отмене подписки; во втором случае
      // запрос ещё жив и его надо погасить.
      if (!cancelToken.isCancelled) cancelToken.cancel('поток закрыт');
    }
  }

  /// Разбирает поток SSE в чанки ответа.
  ///
  /// Построчный разбор отдан `utf8.decoder` + `LineSplitter`, а не написан руками: сетевой
  /// чанк не обязан совпадать со строкой и может разрезать JSON посередине. Эти два
  /// преобразователя держат буфер и склеивают обрывки сами — ручной разбор здесь обычно и
  /// даёт ответ, который «через раз» приходит битым на длинных сообщениях.
  static Stream<AiChunk> _parse(Stream<List<int>> raw) async* {
    await for (final line in raw.transform(utf8.decoder).transform(const LineSplitter())) {
      // Полезная нагрузка SSE лежит в строках `data:`; комментарии-пинги (`: ping`) и
      // служебные поля (`event:`, `id:`) чату не нужны.
      if (!line.startsWith('data:')) continue;
      final payload = line.substring('data:'.length).trim();
      if (payload.isEmpty) continue;
      // конец потока: xAI закрывает ответ этой строкой, а не закрытием соединения
      if (payload == '[DONE]') return;

      final chunk = _chunkFromFrame(payload);
      // чанк бывает пустым (например, только служебные поля) — пропускаем его, а не отдаём
      // наверх пустую порцию
      if (chunk != null) yield chunk;
    }
  }

  /// Разбирает одну порцию `data:` в чанк ответа или отдаёт `null`, если разбирать нечего.
  ///
  /// Битый JSON не считается ошибкой потока: одна неразобранная порция — это потеря нескольких
  /// символов ответа, тогда как исключение здесь оборвало бы всю генерацию.
  static AiChunk? _chunkFromFrame(String payload) {
    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;

    String? text;
    String? reasoning;
    final choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      final delta = first is Map ? first['delta'] : null;
      if (delta is Map) {
        text = _nonEmpty(delta['content']);
        // «размышления» reasoning-модели приходят тем же потоком, но отдельным полем — их
        // показывают отдельным блоком, а не подмешивают в текст ответа
        reasoning = _nonEmpty(delta['reasoning_content']);
      }
    }

    AiUsage? usage;
    final usageJson = decoded['usage'];
    if (usageJson is Map) {
      // xAI присылает usage в каждом чанке (накопительно), а не один раз в конце: наверх
      // отдаём как есть, а последнее полученное значение и есть расход всего ответа
      usage = AiUsage(
        promptTokens: _intOf(usageJson['prompt_tokens']),
        completionTokens: _intOf(usageJson['completion_tokens']),
        totalTokens: _intOf(usageJson['total_tokens']),
      );
    }

    if (text == null && reasoning == null && usage == null) return null;
    return AiChunk(text: text, reasoning: reasoning, usage: usage);
  }

  /// Модель из элемента ответа `/v1/language-models`.
  ///
  /// Размер контекста здесь не читается: в этом ответе его нет, он приходит из `/v1/models`
  /// ([_fetchContextLengths]). Незнакомые поля игнорируем, отсутствующие цены оставляем `null`:
  /// список должен показаться, даже если провайдер поменяет формат, а не упасть разбором.
  static AiModel _modelFromJson(Map json) => AiModel(
        id: json['id']?.toString() ?? '',
        inputPricePerMillion: _usdPerMillion(json['prompt_text_token_price']),
        outputPricePerMillion: _usdPerMillion(json['completion_text_token_price']),
      );

  /// Цена xAI в долларах за 1 млн токенов или `null`, если цена не пришла.
  ///
  /// Провайдер отдаёт цены в **центах за 100 млн токенов** (`12500` — это $125 за 100 млн,
  /// то есть $1.25 за 1M), поэтому делим на 10 000. Без этого пересчёта в интерфейсе были бы
  /// цены, отличающиеся от настоящих в сто раз.
  static double? _usdPerMillion(Object? cents) {
    if (cents is! num || cents <= 0) return null;
    return cents / 10000;
  }

  /// Значение строкой, но пустую строку считаем отсутствием значения: у xAI пустой `content`
  /// приходит в служебных чанках, и показывать его на экране нечем.
  static String? _nonEmpty(Object? v) => (v is String && v.isNotEmpty) ? v : null;

  /// Целое из ответа или `0`: расход токенов — не то поле, ради которого стоит ронять разбор.
  static int _intOf(Object? v) => v is int ? v : 0;

  /// Переводит ошибку HTTP-клиента в ошибку провайдера с понятной человеку причиной.
  ///
  /// Коды разбираем по смыслу: `401`/`403` — ключ, `429` — лимит, `400` — чаще всего
  /// идентификатор модели. Текст ответа xAI сюда не подставляем: при потоковой выдаче тело
  /// ошибки — это тот же поток, и его чтение ради одной строки задерживало бы сообщение об
  /// ошибке.
  static AiException _error(DioException e) {
    final code = e.response?.statusCode;
    if (code == 401 || code == 403) {
      return const AiException(
        AiErrorKind.auth,
        'xAI не принял ключ. Ключ задаётся при сборке (GROK_API_KEY), в приложении его ввести нельзя.',
      );
    }
    if (code == 429) {
      return const AiException(
        AiErrorKind.rateLimit,
        'xAI отклонил запрос: исчерпан лимит запросов или квота. Попробуйте позже или другую модель.',
      );
    }
    if (code == 400) {
      return const AiException(
        AiErrorKind.other,
        'xAI отклонил запрос: скорее всего, выбрана недоступная модель. Выберите модель заново.',
      );
    }
    if (e.type == DioExceptionType.cancel) {
      return const AiException(AiErrorKind.cancelled, 'Запрос отменён.');
    }
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return const AiException(
        AiErrorKind.network,
        'Нет связи с xAI. Проверьте интернет и повторите запрос.',
      );
    }
    return AiException(
      AiErrorKind.other,
      code == null ? 'Не удалось обратиться к xAI.' : 'xAI ответил ошибкой $code.',
    );
  }
}
