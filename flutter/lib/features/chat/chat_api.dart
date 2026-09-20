import 'dart:convert';

import 'package:dio/dio.dart';

import '../../api/cloudly_api.dart';
import 'chat_types.dart';

/// Ошибка обращения к ручкам чата.
///
/// Отдельный тип, а не [ApiException] облака, ради одного различия: «локальная модель
/// недоступна» — это не сбой запроса, а состояние раздела (мак спит, туннель отключился), и
/// человеку тут нечего повторять. Всё остальное — обычные сбои с кодом и текстом сервера.
class ChatApiException implements Exception {
  /// Ошибка с кодом HTTP (0 — ответа не было) и текстом для человека.
  const ChatApiException(this.status, this.message, {this.code});

  /// Код HTTP; 0 — ответа не было вовсе (нет связи, таймаут).
  final int status;

  /// Текст для человека: сервер шлёт готовую причину.
  final String message;

  /// Машиночитаемый код ответа сервера.
  final String? code;

  /// Ответа нет, но запрос имеет смысл повторить (обрыв, таймаут, 5xx).
  bool get retryable => status == 0 || status == 408 || status == 429 || status >= 500;

  @override
  String toString() => message;
}

/// Клиент ручек `/chat/*`.
///
/// Собирается поверх уже существующего облачного клиента: адрес сервера и cookie веб-сессии
/// берутся у него замыканием, чтобы смена сервера в настройках применялась и к чату.
class ChatApi {
  /// Клиент чата поверх облачного: адрес и сессия — из него.
  ChatApi(this.cloudly) {
    _http = Dio(BaseOptions(
      baseUrl: cloudly.baseUrl,
      connectTimeout: const Duration(seconds: 20),
      // Ответ приходит потоком, и между порциями бывают десятки секунд: пока идёт поиск и
      // чтение страниц, сервер молчит по 10-15 секунд, а модель думает молча. Таймаут на
      // чтение поэтому не задаём — ждать придётся столько, сколько нужно, а прерывает ответ
      // кнопка «Стоп».
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

  /// Облачный клиент, у которого взяты адрес и сессия.
  final CloudlyApi cloudly;

  /// HTTP-клиент раздела.
  late final Dio _http;

  /// Состояние раздела: доступна ли модель и какие модели есть.
  ///
  /// Недоступный мак — не ошибка: сервер отвечает `configured: false`, и экран показывает
  /// «модель недоступна» вместо сбоя сети.
  Future<ChatModelsReply> models() async {
    final data = await _send<Map<String, dynamic>>(() => _http.get('/chat/models'));
    final raw = data?['models'];
    return ChatModelsReply(
      configured: data?['configured'] == true,
      models: <ChatModel>[
        if (raw is List)
          for (final m in raw)
            if (m is Map) ChatModel.fromJson(m.cast<String, dynamic>()),
      ],
    );
  }

  /// Чаты владельца, свежие сверху.
  Future<List<ChatSummary>> chats() async {
    final data = await _send<Map<String, dynamic>>(() => _http.get('/chat/chats'));
    final raw = data?['chats'];
    return <ChatSummary>[
      if (raw is List)
        for (final c in raw)
          if (c is Map) ChatSummary.fromJson(c.cast<String, dynamic>()),
    ];
  }

  /// Новый чат: тема появится из первого вопроса.
  Future<ChatSummary> createChat() async {
    final data = await _send<Map<String, dynamic>>(() => _http.post('/chat/chats'));
    return ChatSummary.fromJson(data?['chat'] is Map ? (data!['chat'] as Map).cast<String, dynamic>() : const {});
  }

  /// Переименование чата: тема, выведенная из вопроса, не всегда подходит.
  Future<ChatSummary> renameChat(String chatId, String title) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.patch('/chat/chats/$chatId', data: <String, dynamic>{'title': title}),
    );
    return ChatSummary.fromJson(data?['chat'] is Map ? (data!['chat'] as Map).cast<String, dynamic>() : const {});
  }

  /// Удаление чата вместе с перепиской и источниками.
  Future<void> deleteChat(String chatId) async {
    await _send<Map<String, dynamic>>(() => _http.delete('/chat/chats/$chatId'));
  }

  /// Сообщения чата в порядке отправки, вместе с источниками ответов.
  Future<List<ChatMessage>> messages(String chatId) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.get('/chat/chats/$chatId/messages'),
    );
    final raw = data?['messages'];
    return <ChatMessage>[
      if (raw is List)
        for (final m in raw)
          if (m is Map) ChatMessage.fromJson(m.cast<String, dynamic>()),
    ];
  }

  /// Память владельца: текст, который подмешивается в системную часть каждого запроса.
  Future<String> memory() async {
    final data = await _send<Map<String, dynamic>>(() => _http.get('/chat/settings'));
    return data?['memory']?.toString() ?? '';
  }

  /// Сохраняет память владельца и возвращает её в сохранённом виде.
  Future<String> saveMemory(String memory) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.put('/chat/settings', data: <String, dynamic>{'memory': memory}),
    );
    return data?['memory']?.toString() ?? '';
  }

  /// Отправляет вопрос и отдаёт поток событий ответа.
  ///
  /// [search] — переключатель из интерфейса: `true` искать всегда, `false` не искать, `null`
  /// отдать решение серверу (он ищет только по вопросам про свежие данные).
  ///
  /// Прерывание потока (кнопка «Стоп», уход с экрана) рвёт и HTTP-запрос: сервер по разрыву
  /// соединения гасит свою работу, поэтому поиск и генерация не продолжаются «в никуда» и не
  /// занимают единственный поток модели на маке.
  Stream<ChatChunk> send(String chatId, String text, {bool? search}) async* {
    final Response<ResponseBody> res;
    try {
      res = await _http.post<ResponseBody>(
        '/chat/chats/$chatId/messages',
        // `search` не отправляем в режиме «авто»: решение принимает сервер по тексту вопроса.
        data: <String, dynamic>{'text': text, 'search': ?search},
        // тело читаем сами как поток байтов: Dio не должен пытаться разобрать SSE как JSON
        options: Options(responseType: ResponseType.stream),
      );
    } on DioException catch (e) {
      throw _error(e);
    }

    final body = res.data;
    if (body == null) throw const ChatApiException(0, 'Сервер закрыл соединение, не прислав ответ');

    // `cast<List<int>>()` обязателен, а не косметика: `body.stream` — поток `Uint8List`, а
    // `utf8.decoder` объявлен над `List<int>`; в Dart дженерики ковариантны, поэтому без
    // приведения код собирается анализатором, но падает на runtime.
    //
    // Декодер обязан быть потоковым: русский текст занимает два байта на символ, и сетевой
    // чанк может разрезать символ посередине. Построчный разбор отдан `LineSplitter`: чанк
    // может разрезать и строку JSON, а этот преобразователь держит буфер и склеивает обрывки.
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
        // битая порция — потеря куска ответа; исключение здесь оборвало бы всю генерацию
        continue;
      }
      if (decoded is! Map) continue;
      final chunk = _chunkFromEvent(decoded.cast<String, dynamic>());
      if (chunk != null) yield chunk;
    }
  }

  /// Разбор одного события потока; `null` — событие не про ответ.
  ChatChunk? _chunkFromEvent(Map<String, dynamic> event) {
    switch (event['type']?.toString()) {
      case 'delta':
        final text = event['text'];
        return text is String && text.isNotEmpty ? ChatChunk(text: text) : null;
      case 'reasoning':
        final text = event['text'];
        return text is String && text.isNotEmpty ? ChatChunk(reasoning: text) : null;
      case 'title':
        final title = event['title'];
        return title is String && title.isNotEmpty ? ChatChunk(title: title) : null;
      case 'status':
        final searching = event['searching'];
        return searching is bool ? ChatChunk(searching: searching) : null;
      case 'sources':
        final raw = event['sources'];
        if (raw is! List) return null;
        final sources = <ChatSource>[
          for (final s in raw)
            if (s is Map) ChatSource.fromJson(s.cast<String, dynamic>()),
        ];
        return ChatChunk(sources: sources);
      case 'done':
        return ChatChunk(
          done: true,
          // в событии завершения расход лежит плоскими полями, а не вложенным объектом
          usage: ChatUsage(
            promptTokens: event['promptTokens'] is num ? (event['promptTokens'] as num).toInt() : 0,
            completionTokens:
                event['completionTokens'] is num ? (event['completionTokens'] as num).toInt() : 0,
          ),
          sources: <ChatSource>[
            if (event['sources'] is List)
              for (final s in event['sources'] as List)
                if (s is Map) ChatSource.fromJson(s.cast<String, dynamic>()),
          ],
        );
      case 'error':
        return ChatChunk(
          done: true,
          error: event['message']?.toString() ?? 'не удалось получить ответ',
        );
      default:
        // Незнакомое событие пропускаем: сервер может добавить своё, и старая сборка
        // приложения не должна из-за этого ломаться.
        return usageOrNull(event);
    }
  }

  /// Расход отдельным событием у серверов, которые присылают его не в `done`.
  ChatChunk? usageOrNull(Map<String, dynamic> event) {
    if (event['usage'] is! Map) return null;
    return ChatChunk(usage: ChatUsage.fromJson((event['usage'] as Map).cast<String, dynamic>()));
  }

  /// Выполняет запрос и переводит сбой в [ChatApiException] с текстом сервера.
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
  /// Текст берём из тела ответа (`{statusCode, message, code}` от `AllExceptionsFilter`): его
  /// `message` — готовая причина («чат не найден», «локальная модель недоступна»). Свой текст
  /// остаётся на случай, когда ответа нет вовсе.
  static ChatApiException _error(DioException e) {
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
    return ChatApiException(status, message, code: code);
  }
}
