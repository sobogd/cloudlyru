import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../storage/settings.dart';
import 'agent_types.dart';

/// Ошибка обращения к мосту до харнесса pi.
///
/// Отдельный тип, а не [ApiException] облака, ради одного различия: «мост недоступен» — это
/// состояние раздела (мак спит, туннель не поднялся, токен не вписан), а не сбой запроса.
/// Человеку тут нечего повторять, и показывать это надо словами, а не красным «ошибка сети».
class AgentApiException implements Exception {
  /// Ошибка с кодом HTTP (0 — ответа не было) и текстом для человека.
  const AgentApiException(this.status, this.message);

  /// Код HTTP; 0 — ответа не было вовсе (нет связи, таймаут).
  final int status;

  /// Готовая причина для экрана: её формулирует мост, а для сетевых сбоев — этот клиент.
  final String message;

  /// Мост не ответил: мак спит, туннель отключён или адрес в настройках неверный.
  bool get unreachable => status == 0;

  /// Мост ответил отказом в доступе: не тот токен моста или Access не пропустил запрос.
  bool get unauthorized => status == 401 || status == 403;

  @override
  String toString() => message;
}

/// Клиент моста до pi (`agents/pi-bridge`).
///
/// Ходит напрямую, не через сервер Cloudly: история разговора и модель живут на маке, серверу
/// в этой цепочке делать нечего — он только перекладывал бы запросы. Адрес и токены берутся из
/// настроек приложения, поэтому смена адреса применяется к следующему же запросу.
class AgentApi {
  /// Клиент моста поверх настроек: адрес, токен и пара Cloudflare Access — из них.
  AgentApi(this.settings) {
    _http = Dio(BaseOptions(
      baseUrl: settings.agentUrl,
      connectTimeout: const Duration(seconds: 20),
      // Ответ идёт потоком, и между порциями бывают минуты: агент читает файлы и выполняет
      // команды, а локальная модель думает молча. Таймаут на чтение поэтому не задаём —
      // прерывает ответ кнопка «Стоп» или уход с экрана.
      receiveTimeout: Duration.zero,
    ));
    _http.interceptors.add(InterceptorsWrapper(
      onRequest: (o, h) {
        final token = settings.agentToken;
        if (token.isNotEmpty) o.headers['Authorization'] = 'Bearer $token';
        // Пара Cloudflare Access: без неё туннель отвечает 403 ещё до мака, поэтому
        // заголовки уходят на каждый запрос раздела (для истории они не нужны, но и не мешают).
        final cfId = settings.agentCfId;
        final cfSecret = settings.agentCfSecret;
        if (cfId.isNotEmpty && cfSecret.isNotEmpty) {
          o.headers['CF-Access-Client-Id'] = cfId;
          o.headers['CF-Access-Client-Secret'] = cfSecret;
        }
        o.headers['Accept'] = o.headers['Accept'] ?? 'application/json';
        h.next(o);
      },
    ));
  }

  /// Настройки приложения, из которых взяты адрес и токены.
  final Settings settings;

  /// HTTP-клиент раздела.
  late final Dio _http;

  /// Состояние моста: версия pi, выбранная модель, разрешённые корни.
  Future<AgentHealth> health() async {
    final data = await _send<Map<String, dynamic>>(() => _http.get('/health'));
    return AgentHealth.fromJson(data ?? const {});
  }

  /// Проекты: папки внутри разрешённых корней, в которых можно работать.
  Future<List<AgentProject>> projects() async {
    final data = await _send<Map<String, dynamic>>(() => _http.get('/projects'));
    final raw = data?['projects'];
    return <AgentProject>[
      if (raw is List)
        for (final p in raw)
          if (p is Map) AgentProject.fromJson(p.cast<String, dynamic>()),
    ];
  }

  /// Сессии проекта, свежие сверху: их мост читает из файлов pi.
  Future<List<AgentSession>> sessions(String path) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.get('/sessions', queryParameters: <String, dynamic>{'path': path}),
    );
    final raw = data?['sessions'];
    return <AgentSession>[
      if (raw is List)
        for (final s in raw)
          if (s is Map) AgentSession.fromJson(s.cast<String, dynamic>()),
    ];
  }

  /// Открывает сессию в папке проекта: поднимает процесс pi (или продолжает сессию [sessionId]).
  ///
  /// Мост отвечает описанием сессии, в том числе её идентификатором: у новой сессии его
  /// генерирует pi, и до этого ответа приложению нечего показывать.
  Future<AgentSessionInfo> openSession(String path, {String? sessionId}) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.post('/sessions', data: <String, dynamic>{
        'path': path,
        if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
      }),
    );
    return _sessionOf(data);
  }

  /// Состояние сессии: модель, занятость, расход контекста.
  Future<AgentSessionInfo> session(String id) async {
    final data = await _send<Map<String, dynamic>>(() => _http.get('/sessions/$id'));
    return _sessionOf(data);
  }

  /// Переписка сессии в виде элементов экрана.
  Future<List<AgentItem>> messages(String id) async {
    final data = await _send<Map<String, dynamic>>(() => _http.get('/sessions/$id/messages'));
    final raw = data?['items'];
    return <AgentItem>[
      if (raw is List)
        for (final m in raw)
          if (m is Map) AgentItem.fromJson(m.cast<String, dynamic>()),
    ];
  }

  /// Отправляет сообщение агенту и отдаёт поток событий ответа.
  ///
  /// Прерывание потока (кнопка «Стоп», уход с экрана) рвёт и HTTP-запрос: мост по разрыву
  /// соединения гасит работу агента, поэтому команды не продолжают выполняться «в никуда»
  /// и не занимают единственный процесс pi с его контекстом.
  Stream<AgentEvent> prompt(String id, String text) async* {
    final Response<ResponseBody> res;
    try {
      res = await _http.post<ResponseBody>(
        '/sessions/$id/prompt',
        data: <String, dynamic>{'text': text},
        // тело читаем сами как поток байтов: Dio не должен пытаться разобрать SSE как JSON
        options: Options(responseType: ResponseType.stream),
      );
    } on DioException catch (e) {
      throw _error(e);
    }

    final body = res.data;
    if (body == null) throw const AgentApiException(0, 'Мост закрыл соединение, не прислав ответ');

    // `cast<List<int>>()` обязателен, а не косметика: `body.stream` — поток `Uint8List`, а
    // `utf8.decoder` объявлен над `List<int>`; без приведения код собирается, но падает в рантайме.
    // Декодер потоковый: русский текст занимает два байта на символ, и сетевой чанк может
    // разрезать символ или строку JSON посередине — склейку держит `LineSplitter`.
    final lines =
        body.stream.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring('data:'.length).trim();
      if (payload.isEmpty) continue;

      final Object? decoded;
      try {
        decoded = jsonDecode(payload);
      } catch (_) {
        continue; // битая порция — потеря куска ответа; исключение оборвало бы всю генерацию
      }
      if (decoded is! Map) continue;
      final event = _eventFromJson(decoded.cast<String, dynamic>());
      if (event != null) yield event;
    }
  }

  /// Останавливает генерацию: мост шлёт `abort` в pi и ждёт, пока сессия станет свободной.
  Future<void> abort(String id) async {
    await _send<Map<String, dynamic>>(() => _http.post('/sessions/$id/abort'));
  }

  /// Сжимает контекст сессии: длинный разговор иначе перестанет влезать в окно модели.
  Future<String> compact(String id) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.post('/sessions/$id/compact'),
      // сжатие — отдельный вызов модели: на локальном маке это десятки секунд, не секунды
      timeout: const Duration(minutes: 15),
    );
    return data?['summary']?.toString() ?? '';
  }

  /// Закрывает процесс pi (файл истории остаётся: разговор можно продолжить позже).
  ///
  /// Нужно, когда человек уходит из раздела: живой процесс держит контекст модели в памяти
  /// мака, а она тут дороже пары секунд на следующий запуск.
  Future<void> closeSession(String id) async {
    await _send<Map<String, dynamic>>(() => _http.delete('/sessions/$id'));
  }

  /// Описание сессии из ответа моста (`{"session": {...}}`).
  AgentSessionInfo _sessionOf(Map<String, dynamic>? data) {
    final raw = data?['session'];
    return AgentSessionInfo.fromJson(raw is Map ? raw.cast<String, dynamic>() : const {});
  }

  /// Разбор одного события потока; `null` — событие не про экран.
  AgentEvent? _eventFromJson(Map<String, dynamic> json) {
    final kind = json['type']?.toString();
    switch (kind) {
      case 'delta':
        final text = json['text'];
        return text is String && text.isNotEmpty ? AgentEvent(text: text) : null;
      case 'reasoning':
        final text = json['text'];
        return text is String && text.isNotEmpty ? AgentEvent(reasoning: text) : null;
      case 'status':
        final step = json['step'];
        return step is String && step.isNotEmpty ? AgentEvent(status: step) : null;
      case 'tool_call':
        return AgentEvent(
          toolCall: AgentTool(
            id: json['id']?.toString() ?? '',
            name: json['name']?.toString() ?? '',
            running: true,
          ),
        );
      case 'tool_start':
        return AgentEvent(
          toolStart: AgentTool(
            id: json['id']?.toString() ?? '',
            name: json['name']?.toString() ?? '',
            args: json['args'] is Map ? (json['args'] as Map).cast<String, dynamic>() : const {},
            running: true,
          ),
        );
      case 'tool_update':
        return AgentEvent(
          toolProgress: AgentTool(
            id: json['id']?.toString() ?? '',
            name: json['name']?.toString() ?? '',
            output: json['text']?.toString() ?? '',
            running: true,
          ),
        );
      case 'tool_end':
        return AgentEvent(
          toolEnd: AgentTool(
            id: json['id']?.toString() ?? '',
            name: json['name']?.toString() ?? '',
            output: json['text']?.toString() ?? '',
            isError: json['isError'] == true,
          ),
        );
      case 'ui':
        // Автоответ на диалог расширения: человек его не давал, поэтому он показывается в
        // переписке отдельной служебной строкой — иначе агент «что-то сделал сам» без следа.
        final title = json['title']?.toString() ?? '';
        final auto = json['auto']?.toString() ?? '';
        final text = ['Подтверждение', if (title.isNotEmpty) '«$title»', auto]
            .where((s) => s.isNotEmpty)
            .join(': ');
        return text.isEmpty ? null : AgentEvent(note: text);
      case 'usage':
        return AgentEvent(
          usage: AgentUsage(
            input: json['input'] is num ? (json['input'] as num).toInt() : 0,
            output: json['output'] is num ? (json['output'] as num).toInt() : 0,
            total: json['totalTokens'] is num ? (json['totalTokens'] as num).toInt() : 0,
          ),
        );
      case 'done':
        final raw = json['session'];
        return AgentEvent(
          done: true,
          session: raw is Map ? AgentSessionInfo.fromJson(raw.cast<String, dynamic>()) : null,
        );
      case 'error':
        return AgentEvent(done: true, error: json['message']?.toString() ?? 'агент не ответил');
      default:
        // `accepted`, `closed`, `compacted` и прочее состояние экрана не меняют: незнакомые
        // события пропускаем, чтобы новый мост не ломал старую сборку приложения.
        return null;
    }
  }

  /// Выполняет запрос и переводит сбой в [AgentApiException] с текстом для человека.
  Future<T?> _send<T>(
    Future<Response<T>> Function() request, {
    Duration? timeout,
  }) async {
    try {
      if (timeout == null) {
        final res = await request();
        return res.data;
      }
      final res = await request().timeout(timeout);
      return res.data;
    } on DioException catch (e) {
      throw _error(e);
    } on TimeoutException {
      throw AgentApiException(0, 'Мост не ответил за отведённое время.');
    }
  }

  /// Сбой клиента → ошибка раздела с причиной, которую уже сформулировал мост.
  ///
  /// Свои тексты — про то, что чинится на стороне мака и туннеля: у сетевого сбоя причина
  /// почти всегда в этом, а не в запросе, и человеку важно понять, куда смотреть.
  static AgentApiException _error(DioException e) {
    final status = e.response?.statusCode ?? 0;
    final data = e.response?.data;
    String? message;
    if (data is Map) {
      final m = data['message'];
      if (m is String && m.isNotEmpty) message = m;
      final body = data['error'];
      if (message == null && body is String && body.isNotEmpty) message = body;
    }
    message ??= switch (status) {
      401 => 'Мост отклонил токен: проверьте токен из ~/.pi-bridge.json в настройках раздела.',
      403 => 'Cloudflare не пропустил запрос: проверьте пару Access (Client Id и Secret).',
      409 => 'Сессия занята: дождитесь конца ответа или нажмите «Стоп».',
      _ => switch (e.type) {
          DioExceptionType.connectionError ||
          DioExceptionType.connectionTimeout ||
          DioExceptionType.receiveTimeout ||
          DioExceptionType.sendTimeout =>
            'Мост недоступен: мак спит, туннель отключён или адрес в настройках неверный.',
          DioExceptionType.cancel => 'Запрос отменён.',
          _ => status == 0 ? 'Мост не ответил.' : 'Мост ответил ошибкой $status.',
        },
    };
    return AgentApiException(status, message);
  }
}
