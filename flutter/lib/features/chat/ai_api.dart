/// REST-клиент раздела «Чат» — третий (после облачного и фактурного) источник HTTP-запросов.
///
/// Почему не методы в [CloudlyApi]: у раздела свои модели и свои ручки, а облачный клиент уже
/// 1700 строк про файлы, почту и синхронизацию. Общими остаются ровно две вещи, и обе берутся
/// из [CloudlyApi], а не копируются:
///  - адрес сервера и база `/api/v1` — из [CloudlyApi.baseUrl];
///  - Cookie веб-сессии — из [CloudlyApi.authHeaders] (замыканием, чтобы клиент всегда видел
///    текущую сессию, а не ту, что была в момент создания объекта).
///
/// Адреса модели здесь нет и быть не должно: к ней ходит сервер, а приложение — только в наши
/// ручки `/ai/*`. Модель считает на домашнем маке и приходит на сервер через туннель, поэтому
/// в сборке нечего извлекать (APK лежит на публичной ссылке), а причины отказов видны в логах
/// сервера, а не только сообщением на экране.
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../api/cloudly_api.dart';
import 'ai_types.dart';

/// Ошибка обращения к ручкам чата.
///
/// Отдельный тип, а не [ApiException] облака, ради одного различия: «модель недоступна»
/// (503 с кодом `ai_not_configured`) — это не сбой запроса, а состояние раздела, и человеку
/// тут нечего повторять. Всё остальное — обычные сбои с кодом и текстом.
class AiApiException implements Exception {
  /// Ошибка с кодом HTTP (0 — ответа не было) и текстом для человека.
  const AiApiException(this.status, this.message, {this.code});

  /// Код HTTP; 0 — ответа не было вовсе (нет связи, таймаут).
  final int status;

  /// Текст для человека: сервер шлёт готовую причину.
  final String message;

  /// Машиночитаемый код ответа сервера (`ai_not_configured` и прочие).
  final String? code;

  /// Модель недоступна (её нет на сервере модели) — чинится не повтором запроса, а тем, что
  /// машина с моделью вернётся в сеть.
  bool get notConfigured => code == 'ai_not_configured';

  /// Повтор запроса имеет смысл: ответа не было, таймаут, 429 или 5xx.
  bool get retryable => status == 0 || status == 408 || status == 429 || status >= 500;

  @override
  String toString() => message;
}

/// Состояние раздела: доступна ли модель и какие модели есть на сервере модели.
class AiModelsReply {
  /// Список моделей и признак «модель доступна».
  const AiModelsReply({required this.configured, required this.models});

  /// Доступна ли модель: `false` — сервер не видит LM Studio на маке.
  final bool configured;

  /// Модели, загруженные в LM Studio.
  final List<AiModel> models;
}

/// Клиент ручек `/ai/*`.
class AiApi {
  /// Собирает клиент поверх уже существующего облачного: адрес и сессия берутся у него.
  ///
  /// [cloudly] передаётся целиком, а не строкой адреса: при смене сервера приложение
  /// пересоздаёт облачный клиент, и чат обязан ходить на новый адрес с новой сессией.
  AiApi(this.cloudly) {
    _http = Dio(BaseOptions(
      baseUrl: cloudly.baseUrl,
      connectTimeout: const Duration(seconds: 20),
      // Ответ модели приходит потоком, между порциями бывают десятки секунд (reasoning-модель
      // думает молча). Таймаут на чтение не задаём: ждать придётся столько, сколько модель
      // думает, а прерывает ответ кнопка «Стоп».
      receiveTimeout: Duration.zero,
    ));
    _http.interceptors.add(InterceptorsWrapper(
      onRequest: (o, h) {
        o.headers.addAll(cloudly.authHeaders);
        o.headers['Accept'] = 'application/json';
        h.next(o);
      },
    ));
  }

  final CloudlyApi cloudly;
  late final Dio _http;

  /// Состояние раздела: доступна ли модель и какие модели по ней есть.
  Future<AiModelsReply> models() async {
    final data = await _send<Map<String, dynamic>>(() => _http.get('/ai/models'));
    final configured = data?['configured'] == true;
    final raw = data?['models'];
    final models = <AiModel>[
      if (raw is List)
        for (final m in raw)
          if (m is Map) AiModel.fromJson(m.cast<String, dynamic>()),
    ];
    return AiModelsReply(configured: configured, models: models);
  }

  /// Чаты владельца, свежие сверху.
  Future<List<AiChat>> chats() async {
    final data = await _send<Map<String, dynamic>>(() => _http.get('/ai/chats'));
    final raw = data?['chats'];
    return <AiChat>[
      if (raw is List)
        for (final c in raw)
          if (c is Map) AiChat.fromJson(c.cast<String, dynamic>()),
    ];
  }

  /// Новый чат; модель можно не указывать — сервер подставит модель по умолчанию.
  Future<AiChat> createChat({String? model}) async {
    // тело собираем по частям, а не литералом: пустое поле `model` сервер понял бы как
    // «модель не выбрана», и это было бы то же самое, но лишним полем в запросе
    final body = <String, dynamic>{};
    if (model != null) body['model'] = model;
    final data = await _send<Map<String, dynamic>>(
      () => _http.post('/ai/chats', data: body),
    );
    return AiChat.fromJson(data ?? const {});
  }

  /// Переименование чата и смена его модели.
  Future<AiChat> patchChat(String chatId, {String? title, String? model}) async {
    final body = <String, dynamic>{};
    if (title != null) body['title'] = title;
    if (model != null) body['model'] = model;
    final data = await _send<Map<String, dynamic>>(
      () => _http.patch('/ai/chats/$chatId', data: body),
    );
    return AiChat.fromJson(data ?? const {});
  }

  /// Удаление чата вместе с его сообщениями.
  Future<void> deleteChat(String chatId) async {
    await _send<Map<String, dynamic>>(() => _http.delete('/ai/chats/$chatId'));
  }

  /// Сообщения чата в порядке отправки.
  Future<List<AiMessage>> messages(String chatId) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.get('/ai/chats/$chatId/messages'),
    );
    final raw = data?['messages'];
    return <AiMessage>[
      if (raw is List)
        for (final m in raw)
          if (m is Map) AiMessage.fromJson(m.cast<String, dynamic>()),
    ];
  }

  /// Память владельца: текст, который подмешивается в системную часть каждого запроса.
  Future<String> memory() async {
    final data = await _send<Map<String, dynamic>>(() => _http.get('/ai/settings'));
    return data?['memory']?.toString() ?? '';
  }

  /// Сохраняет память владельца и возвращает её в сохранённом виде.
  Future<String> saveMemory(String memory) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.put('/ai/settings', data: {'memory': memory}),
    );
    return data?['memory']?.toString() ?? '';
  }

  /// Отправляет вопрос и отдаёт поток событий ответа.
  ///
  /// Прерывание потока (кнопка «Стоп», уход с экрана) рвёт и HTTP-запрос — сервер по разрыву
  /// соединения гасит свой запрос к модели, поэтому генерация не продолжается «в никуда»
  /// и не занимает единственный поток мака. Прогон агента на телефоне при этом доигрывается до
  /// конца: отмены у него нет, и бросить его на середине значит оставить телефон в непонятном
  /// состоянии (см. `AgentService.run` на сервере).
  ///
  /// [agent] включает режим агента на телефоне. В этом режиме поиск не нужен (агент сам ходит
  /// по интернету), поэтому вызывающий код отправляет `search: false` — но решает всё равно
  /// сервер, он же и объясняет причину отказа.
  Stream<AiChunk> send(String chatId, String text, {bool? search, bool? agent}) async* {
    final Response<ResponseBody> res;
    try {
      res = await _http.post<ResponseBody>(
        '/ai/chats/$chatId/messages',
        // `search` не отправляем, если режим «авто»: тогда решение принимает сервер по тексту
        // вопроса (он же знает, что стоит денег). Null-aware запись `?` — то же, что
        // `if (search != null)`, но её требует линтер проекта.
        data: <String, dynamic>{'text': text, 'search': ?search, 'agent': ?agent},
        // тело читаем сами как поток байтов: Dio не должен пытаться разобрать SSE как JSON
        options: Options(responseType: ResponseType.stream),
      );
    } on DioException catch (e) {
      throw _error(e);
    }

    final body = res.data;
    if (body == null) throw const AiApiException(0, 'Сервер закрыл соединение, не прислав ответ');

    // `cast<List<int>>()` здесь обязателен, а не косметика: `body.stream` — это поток
    // `Uint8List`, а `utf8.decoder` объявлен над `List<int>`. В Dart дженерики ковариантны,
    // поэтому `stream.transform(utf8.decoder)` собирается анализатором, но падает на runtime
    // (`_TypeError: type 'Utf8Decoder' is not a subtype of type 'StreamTransformer<Uint8List,
    // String>'`) — ровно это и было причиной «Не удалось получить ответ» при живом ответе
    // сервера. Приведение меняет и тип потока на runtime, а не только на бумаге.
    //
    // Декодер обязан быть потоковым (`utf8.decoder`, а не `utf8.decode` на чанк): русский текст
    // приходит несколькими байтами на символ, и чанк может разрезать символ посередине.
    //
    // Построчный разбор отдан `LineSplitter`: сетевой чанк не обязан совпадать со строкой и
    // может разрезать JSON посередине — этот преобразователь держит буфер и склеивает обрывки.
    final lines = body.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring('data:'.length).trim();
      if (payload.isEmpty) continue;

      final Object? decoded;
      try {
        decoded = jsonDecode(payload);
      } catch (_) {
        // битая порция — потеря нескольких символов ответа; исключение здесь оборвало бы
        // всю генерацию, поэтому просто пропускаем
        continue;
      }
      if (decoded is! Map) continue;
      final chunk = _chunkFromEvent(decoded.cast<String, dynamic>());
      if (chunk != null) yield chunk;
    }
  }

  /// Разбор одного события потока в чанк; `null` — если событие не про ответ.
  AiChunk? _chunkFromEvent(Map<String, dynamic> event) {
    final type = event['type']?.toString();
    switch (type) {
      case 'delta':
        final text = event['text'];
        return text is String && text.isNotEmpty ? AiChunk(text: text) : null;
      case 'reasoning':
        final text = event['text'];
        return text is String && text.isNotEmpty ? AiChunk(reasoning: text) : null;
      case 'title':
        final title = event['title'];
        return title is String ? AiChunk(title: title) : null;
      case 'status':
        // Одно событие несёт оба признака: сервер помечает в нём и поиск, и работу агента, а
        // отсутствующий ключ означает «про это не изменилось» — поэтому `null`, а не `false`.
        return AiChunk(
          searching: event['searching'] is bool ? event['searching'] as bool : null,
          agentRunning: event['agent'] is bool ? event['agent'] as bool : null,
        );
      case 'done':
        final usage = event['usage'];
        return AiChunk(
          done: true,
          usage: usage is Map ? AiUsage.fromJson(usage.cast<String, dynamic>()) : null,
        );
      case 'error':
        return AiChunk(done: true, error: event['message']?.toString() ?? 'не удалось получить ответ');
      default:
        return null;
    }
  }

  /// Выполняет запрос и переводит сбой в [AiApiException] с текстом сервера.
  Future<T?> _send<T>(Future<Response<T>> Function() request) async {
    try {
      final res = await request();
      return res.data;
    } on DioException catch (e) {
      throw _error(e);
    }
  }

  /// Сбой клиента → ошибка чата с причиной, которую сервер уже сформулировал.
  ///
  /// Текст берём из тела ответа: сервер отвечает `{statusCode, message, code}` (см.
  /// `AllExceptionsFilter`), и его `message` — это готовая причина («чат не найден», «на сервере
  /// модель недоступна»). Свой текст оставляем на случай, когда ответа нет вовсе.
  static AiApiException _error(DioException e) {
    final status = e.response?.statusCode ?? 0;
    final data = e.response?.data;
    String? message;
    String? code;
    if (data is Map) {
      final m = data['message'];
      if (m is String && m.isNotEmpty) message = m;
      if (m is List && m.isNotEmpty) message = m.first.toString();
      final c = data['code'];
      if (c is String) code = c;
    }
    message ??= switch (e.type) {
      DioExceptionType.connectionError ||
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout =>
        'Нет связи с сервером. Проверьте интернет и повторите.',
      DioExceptionType.cancel => 'Запрос отменён.',
      _ => status == 0 ? 'Не удалось обратиться к серверу.' : 'Сервер ответил ошибкой $status.',
    };
    return AiApiException(status, message, code: code);
  }
}
