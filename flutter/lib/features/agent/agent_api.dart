import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../api/cloudly_api.dart';
import 'agent_types.dart';

class AgentApiException implements Exception {
  const AgentApiException(this.status, this.message, {this.code});

  final int status;

  final String message;

  final String? code;

  bool get bridgeUnavailable =>
      code == 'bridge_unavailable' || status == 502 || status == 503;

  bool get busy => code == 'busy' || status == 409;

  @override
  String toString() => message;
}

class AgentApi {
  AgentApi(this._cloudly) {
    _http = Dio(
      BaseOptions(
        baseUrl: _cloudly().baseUrl,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: Duration.zero,
      ),
    );
    _http.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          final cloudly = _cloudly();
          o.baseUrl = cloudly.baseUrl;
          o.headers.addAll(cloudly.authHeaders);
          o.headers['Accept'] = 'application/json';
          h.next(o);
        },
      ),
    );
  }

  final CloudlyApi Function() _cloudly;

  late final Dio _http;

  Future<AgentHealth> health() async {
    final data = await _send<Map<String, dynamic>>(
      () => _get('/projects/health'),
    );
    return AgentHealth.fromJson(data ?? const {});
  }

  Future<AgentActivity> activity() async {
    final data = await _send<Map<String, dynamic>>(
      () => _get('/projects/activity'),
    );
    return AgentActivity.fromJson(data ?? const {});
  }

  Future<List<AgentHarness>> harnesses() async {
    final data = await _send<Map<String, dynamic>>(
      () => _get('/projects/harnesses'),
    );
    final raw = data?['harnesses'];
    return <AgentHarness>[
      if (raw is List)
        for (final h in raw)
          if (h is Map) AgentHarness.fromJson(h.cast<String, dynamic>()),
    ];
  }

  Future<List<AgentModel>> models({String harness = 'pi'}) async =>
      (await catalog(harness: harness)).$1;

  Future<(List<AgentModel>, List<AgentEffort>)> catalog({
    String harness = 'pi',
  }) async {
    final data = await _send<Map<String, dynamic>>(
      () => _get(
        '/projects/models',
        queryParameters: <String, dynamic>{'harness': harness},
      ),
    );
    final raw = data?['models'];
    final rawEfforts = data?['efforts'];
    final models = <AgentModel>[
      if (raw is List)
        for (final m in raw)
          if (m is Map) AgentModel.fromJson(m.cast<String, dynamic>()),
    ];
    final efforts = <AgentEffort>[
      if (rawEfforts is List)
        for (final e in rawEfforts)
          if (e is Map) AgentEffort.fromJson(e.cast<String, dynamic>()),
    ];
    return (models, efforts);
  }

  Future<List<AgentProvider>> providers() async {
    final data = await _send<Map<String, dynamic>>(
      () => _get('/projects/providers'),
    );
    final raw = data?['providers'];
    return <AgentProvider>[
      if (raw is List)
        for (final p in raw)
          if (p is Map) AgentProvider.fromJson(p.cast<String, dynamic>()),
    ];
  }

  Future<List<AgentProvider>> saveProvider({
    required String key,
    required String name,
    required String baseUrl,
    required String api,
    required String apiKey,
    required List<AgentModel> models,
  }) async {
    final data = await _send<Map<String, dynamic>>(
      () => _post(
        '/projects/providers',
        data: <String, dynamic>{
          'key': key,
          'name': name,
          'baseUrl': baseUrl,
          'api': api,
          'apiKey': apiKey,
          'models': <Map<String, dynamic>>[
            for (final m in models)
              <String, dynamic>{
                'id': m.id,
                'name': m.name,
                if (m.contextWindow != null) 'contextWindow': m.contextWindow,
                if (m.maxTokens != null) 'maxTokens': m.maxTokens,
                'thinking': m.thinking,
                if (m.images) 'images': true,
                if (m.samplingParams.isNotEmpty)
                  'samplingParams': m.samplingParams,
              },
          ],
        },
      ),
    );
    return _providersOf(data);
  }

  Future<List<AgentProvider>> deleteProvider(String key) async {
    final data = await _send<Map<String, dynamic>>(
      () => _delete('/projects/providers/${Uri.encodeComponent(key)}'),
    );
    return _providersOf(data);
  }

  Future<List<AgentModel>> probeProvider({
    required String baseUrl,
    String provider = '',
    String apiKey = '',
  }) async {
    final data = await _send<Map<String, dynamic>>(
      () => _post(
        '/projects/providers/probe',
        data: <String, dynamic>{
          'baseUrl': baseUrl,
          if (provider.isNotEmpty) 'provider': provider,
          if (apiKey.isNotEmpty) 'apiKey': apiKey,
        },
      ),
    );
    final raw = data?['models'];
    return <AgentModel>[
      if (raw is List)
        for (final m in raw)
          if (m is Map) AgentModel.fromJson(m.cast<String, dynamic>()),
    ];
  }

  Future<List<AgentProvider>> saveProviderKey(
    String provider,
    String apiKey,
  ) async {
    final data = await _send<Map<String, dynamic>>(
      () => _post(
        '/projects/providers/key',
        data: <String, dynamic>{'provider': provider, 'apiKey': apiKey},
      ),
    );
    return _providersOf(data);
  }

  List<AgentProvider> _providersOf(Map<String, dynamic>? data) {
    final raw = data?['providers'];
    return <AgentProvider>[
      if (raw is List)
        for (final p in raw)
          if (p is Map) AgentProvider.fromJson(p.cast<String, dynamic>()),
    ];
  }

  Future<List<AgentProject>> projects() async {
    final data = await _send<Map<String, dynamic>>(
      () => _get('/projects'),
    );
    final raw = data?['projects'];
    return <AgentProject>[
      if (raw is List)
        for (final p in raw)
          if (p is Map) AgentProject.fromJson(p.cast<String, dynamic>()),
    ];
  }

  Future<List<AgentSession>> sessions([String? path, String? harness]) async {
    final dir = (path ?? '').trim();
    final h = (harness ?? '').trim();
    final query = <String, dynamic>{
      if (dir.isNotEmpty) 'path': dir,
      if (h.isNotEmpty) 'harness': h,
    };
    final data = await _send<Map<String, dynamic>>(
      () => _get(
        '/projects/sessions',
        queryParameters: query.isEmpty ? null : query,
      ),
    );
    final raw = data?['sessions'];
    return <AgentSession>[
      if (raw is List)
        for (final s in raw)
          if (s is Map) AgentSession.fromJson(s.cast<String, dynamic>()),
    ];
  }

  Future<AgentSessionInfo> openSession(
    String path, {
    String harness = 'pi',
    String? sessionId,
    String? modelKey,
    String? effort,
  }) async {
    final split = _splitModel(modelKey);
    final data = await _send<Map<String, dynamic>>(
      () => _post(
        '/projects/sessions',
        data: <String, dynamic>{
          'path': path,
          'harness': harness,
          if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
          if (split != null) 'provider': split.$1,
          if (split != null) 'model': split.$2,
          if (effort != null && effort.isNotEmpty) 'effort': effort,
        },
      ),
    );
    return _sessionOf(data);
  }

  Future<AgentSessionInfo> setModel(String id, String modelKey) async {
    final split = _splitModel(modelKey);
    if (split == null) throw const AgentApiException(0, 'модель не выбрана');
    final data = await _send<Map<String, dynamic>>(
      () => _post(
        '/projects/sessions/$id/model',
        data: <String, dynamic>{'provider': split.$1, 'modelId': split.$2},
      ),
    );
    return _sessionOf(data);
  }

  Future<AgentSessionInfo> setEffort(String id, String effort) async {
    final data = await _send<Map<String, dynamic>>(
      () => _post(
        '/projects/sessions/$id/effort',
        data: <String, dynamic>{'effort': effort},
      ),
    );
    return _sessionOf(data);
  }

  Future<String> renameSession(String id, String name) async {
    final data = await _send<Map<String, dynamic>>(
      () => _post(
        '/projects/sessions/$id/name',
        data: <String, dynamic>{'name': name},
      ),
    );
    return data?['name']?.toString() ?? '';
  }

  (String, String)? _splitModel(String? key) {
    final text = (key ?? '').trim();
    if (text.isEmpty) return null;
    final cut = text.indexOf('/');
    if (cut <= 0 || cut == text.length - 1) return null;
    return (text.substring(0, cut), text.substring(cut + 1));
  }

  Future<AgentSessionInfo> session(String id) async {
    final data = await _send<Map<String, dynamic>>(
      () => _get('/projects/sessions/$id'),
    );
    return _sessionOf(data);
  }

  Future<AgentHistoryPage> messagesPage(
    String id, {
    int limit = 200,
    int? before,
  }) async {
    final data = await _send<Map<String, dynamic>>(
      () => _get(
        '/projects/sessions/$id/messages',
        queryParameters: <String, dynamic>{
          'limit': '$limit',
          if (before != null) 'before': '$before',
        },
      ),
    );
    final raw = data?['items'];
    return AgentHistoryPage(
      items: <AgentItem>[
        if (raw is List)
          for (final m in raw)
            if (m is Map) AgentItem.fromJson(m.cast<String, dynamic>()),
      ],
      total: data?['total'] is num ? (data!['total'] as num).toInt() : 0,
      hasMore: data?['hasMore'] == true,
    );
  }

  Stream<AgentEvent> prompt(String id, String text, [String messageId = '']) async* {
    final Response<ResponseBody> res;
    try {
      res = await _http.post<ResponseBody>(
        '/projects/sessions/$id/prompt',
        data: <String, dynamic>{
          'text': text,
          if (messageId.isNotEmpty) 'id': messageId,
        },
        options: Options(responseType: ResponseType.stream),
      );
    } on DioException catch (e) {
      throw _error(e);
    }
    yield* _eventsFrom(res.data);
  }

  Future<({int position, bool duplicate})> queueMessage(
    String id,
    String text, [
    String messageId = '',
  ]) async {
    final data = await _send<Map<String, dynamic>>(
      () => _post(
        '/projects/sessions/$id/queue',
        data: <String, dynamic>{
          'text': text,
          if (messageId.isNotEmpty) 'id': messageId,
        },
      ),
    );
    return (
      position: data?['position'] is num ? (data!['position'] as num).toInt() : 0,
      duplicate: data?['duplicate'] == true,
    );
  }

  Stream<AgentEvent> running(String id) async* {
    final Response<ResponseBody> res;
    try {
      res = await _http.get<ResponseBody>(
        '/projects/sessions/$id/events',
        options: Options(responseType: ResponseType.stream),
      );
    } on DioException catch (e) {
      throw _error(e);
    }
    yield* _eventsFrom(res.data);
  }

  Stream<AgentEvent> _eventsFrom(ResponseBody? body) async* {
    if (body == null) {
      throw const AgentApiException(
        0,
        'Сервер закрыл соединение, не прислав ответ',
      );
    }
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
        continue;
      }
      if (decoded is! Map) continue;
      final event = _eventFromJson(decoded.cast<String, dynamic>());
      if (event != null) yield event;
    }
  }

  Future<void> abort(String id) async {
    await _send<Map<String, dynamic>>(
      () => _post('/projects/sessions/$id/abort'),
    );
  }

  Future<String> transcribe(Uint8List audio) async {
    final data = await _send<Map<String, dynamic>>(
      () => _post<Map<String, dynamic>>(
        '/projects/transcribe',
        data: audio,
        contentType: 'application/octet-stream',
        timeout: const Duration(minutes: 2),
      ),
    );
    return data?['text']?.toString().trim() ?? '';
  }

  Future<String> compact(String id) async {
    final data = await _send<Map<String, dynamic>>(
      () => _post('/projects/sessions/$id/compact'),
    );
    return data?['summary']?.toString() ?? '';
  }

  Future<AgentDeleteResult> deleteSession(String id) async {
    final data = await _send<Map<String, dynamic>>(
      () => _delete('/projects/sessions/$id'),
    );
    return AgentDeleteResult(
      deleted: data?['deleted'] is num ? (data!['deleted'] as num).toInt() : 0,
      restored: data?['restored'] is num
          ? (data!['restored'] as num).toInt()
          : 0,
    );
  }

  AgentSessionInfo _sessionOf(Map<String, dynamic>? data) {
    final raw = data?['session'];
    return AgentSessionInfo.fromJson(
      raw is Map ? raw.cast<String, dynamic>() : const {},
    );
  }

  AgentEvent? _eventFromJson(Map<String, dynamic> json) {
    final kind = json['type']?.toString();
    switch (kind) {
      case 'delta':
        final text = json['text'];
        return text is String && text.isNotEmpty
            ? AgentEvent(text: text)
            : null;
      case 'reasoning':
        final text = json['text'];
        return text is String && text.isNotEmpty
            ? AgentEvent(reasoning: text)
            : null;
      case 'status':
        final step = json['step'];
        return step is String && step.isNotEmpty
            ? AgentEvent(status: step)
            : null;
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
            args: json['args'] is Map
                ? (json['args'] as Map).cast<String, dynamic>()
                : const {},
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
        final title = json['title']?.toString() ?? '';
        final auto = json['auto']?.toString() ?? '';
        final text = [
          'Подтверждение',
          if (title.isNotEmpty) '«$title»',
          auto,
        ].where((s) => s.isNotEmpty).join(': ');
        return text.isEmpty ? null : AgentEvent(note: text);
      case 'queued':
        final position = json['position'];
        return position is num ? AgentEvent(queued: position.toInt()) : null;
      case 'duplicate':
        return const AgentEvent(
          note: 'этот вопрос уже отправлен — показываю идущий ответ',
        );
      case 'snapshot':
        final item = json['item'];
        return item is Map
            ? AgentEvent(snapshot: AgentItem.fromJson(item.cast<String, dynamic>()))
            : null;
      case 'ping':
        return const AgentEvent(ping: true);
      case 'idle':
        return const AgentEvent(idle: true);
      case 'queued_started':
        return const AgentEvent(queuedStarted: true);
      case 'usage':
        return AgentEvent(
          usage: AgentUsage(
            input: json['input'] is num ? (json['input'] as num).toInt() : 0,
            output: json['output'] is num ? (json['output'] as num).toInt() : 0,
            total: json['totalTokens'] is num
                ? (json['totalTokens'] as num).toInt()
                : 0,
          ),
        );
      case 'done':
        final raw = json['session'];
        return AgentEvent(
          done: true,
          session: raw is Map
              ? AgentSessionInfo.fromJson(raw.cast<String, dynamic>())
              : null,
        );
      case 'error':
        return AgentEvent(
          done: true,
          error: json['message']?.toString() ?? 'агент не ответил',
        );
      case 'compacted':
        return const AgentEvent(compacted: true);
      default:
        return null;
    }
  }

  Future<Response<T>> _get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Duration timeout = _defaultTimeout,
  }) => _http.get<T>(path, queryParameters: queryParameters, options: _timeout(timeout));

  Future<Response<T>> _post<T>(
    String path, {
    Object? data,
    String? contentType,
    Duration timeout = _defaultTimeout,
  }) => _http.post<T>(
    path,
    data: data,
    options: Options(
      contentType: contentType,
      receiveTimeout: timeout,
      sendTimeout: timeout,
    ),
  );

  Future<Response<T>> _delete<T>(String path, {Duration timeout = _defaultTimeout}) =>
      _http.delete<T>(path, options: _timeout(timeout));

  Options _timeout(Duration timeout) => Options(receiveTimeout: timeout, sendTimeout: timeout);

  Future<T?> _send<T>(Future<Response<T>> Function() request) async {
    try {
      final res = await request();
      return res.data;
    } on DioException catch (e) {
      throw _error(e);
    }
  }

  static const _defaultTimeout = Duration(seconds: 15);

  static AgentApiException _error(DioException e) {
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
      final retry = data['retryAfterSec'];
      if (retry is num && retry > 0) {
        message = '${message ?? 'Слишком часто'} — повтор через ${retry.toInt()} с';
      }
    }
    message ??= switch (e.type) {
      DioExceptionType.connectionError =>
        'Нет связи с сервером. Проверьте интернет и повторите.',
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout =>
        'Сервер не ответил вовремя. Попробуйте ещё раз.',
      DioExceptionType.cancel => 'Запрос отменён.',
      _ =>
        status == 0
            ? 'Не удалось обратиться к серверу.'
            : 'Сервер ответил ошибкой $status.',
    };
    return AgentApiException(status, message, code: code);
  }
}
