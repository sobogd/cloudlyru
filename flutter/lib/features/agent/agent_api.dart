import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../api/cloudly_api.dart';
import 'agent_types.dart';

/// Ошибка обращения к разделу «Проекты».
///
/// Отдельный тип, а не [ApiException] облака, ради одного различия: «мост недоступен» — это
/// состояние раздела (мак спит, туннель отключился), а не сбой запроса, и человеку тут нечего
/// повторять. Всё остальное — обычные сбои с кодом и текстом сервера.
class AgentApiException implements Exception {
  /// Ошибка с кодом HTTP (0 — ответа не было) и текстом для человека.
  const AgentApiException(this.status, this.message, {this.code});

  /// Код HTTP; 0 — ответа не было вовсе (нет связи, таймаут).
  final int status;

  /// Готовая причина для экрана: её формулирует сервер (а он — мост).
  final String message;

  /// Машиночитаемый код ответа сервера: по нему различаются «занято» и «мост недоступен».
  final String? code;

  /// Мост не отвечает: мак спит или туннель отключился. Повторять бессмысленно.
  bool get bridgeUnavailable =>
      code == 'bridge_unavailable' || status == 502 || status == 503;

  /// Сессия занята: в ней уже идёт генерация.
  bool get busy => code == 'busy' || status == 409;

  @override
  String toString() => message;
}

/// Клиент раздела «Проекты» — ручек `/projects/*` сервера приложения.
///
/// Собирается поверх облачного клиента, как раздел «Чат»: адрес сервера и cookie веб-сессии
/// берутся у него замыканием, поэтому смена сервера в настройках применяется и здесь.
///
/// Прямого доступа к маку у приложения нет и быть не должно: агент работает на домашнем маке,
/// но запросы делает сервер (он видит мост через туннель), и в сборке приложения поэтому нет ни
/// адреса моста, ни порта туннеля, ни ключей — как и у чата.
class AgentApi {
  /// Клиент раздела поверх облачного: адрес и сессия — из него.
  AgentApi(this.cloudly) {
    _http = Dio(
      BaseOptions(
        baseUrl: cloudly.baseUrl,
        connectTimeout: const Duration(seconds: 20),
        // Ответ приходит потоком, и между порциями бывают минуты: агент читает файлы, выполняет
        // команды, а локальная модель думает молча. Таймаут на чтение поэтому не задаём —
        // прерывает ответ кнопка «Стоп» или уход с экрана.
        receiveTimeout: Duration.zero,
      ),
    );
    _http.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          o.headers.addAll(cloudly.authHeaders);
          o.headers['Accept'] = 'application/json';
          h.next(o);
        },
      ),
    );
  }

  /// Облачный клиент, у которого взяты адрес и сессия.
  final CloudlyApi cloudly;

  /// HTTP-клиент раздела.
  late final Dio _http;

  /// Состояние моста: версия pi, выбранная модель, разрешённые корни.
  Future<AgentHealth> health() async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.get('/projects/health'),
    );
    return AgentHealth.fromJson(data ?? const {});
  }

  /// Убирает старые сессии проекта, оставляя свежие.
  ///
  /// Условия складываются: `olderThanDays` — что считать старым, `keep` — сколько самых свежих
  /// не трогать вовсе. Хотя бы одно нужно: без него мост откажет, чтобы «убрать старое» не
  /// превратилось в «удалить всё». Возвращает, сколько сессий удалено.
  Future<int> purgeSessions({
    required String path,
    required String harness,
    int? olderThanDays,
    int? keep,
  }) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.post('/projects/sessions/purge', data: <String, dynamic>{
        'path': path,
        'harness': harness,
        // null-aware элементы: условие писать не нужно, поле просто не попадёт в тело
        'olderThanDays': ?olderThanDays,
        'keep': ?keep,
      }),
    );
    return data?['deleted'] is num ? (data!['deleted'] as num).toInt() : 0;
  }

  /// Харнессы, стоящие на маке: pi и Claude Code — с версиями и признаком «есть».
  Future<List<AgentHarness>> harnesses() async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.get('/projects/harnesses'),
    );
    final raw = data?['harnesses'];
    return <AgentHarness>[
      if (raw is List)
        for (final h in raw)
          if (h is Map) AgentHarness.fromJson(h.cast<String, dynamic>()),
    ];
  }

  /// Модели харнесса: у pi — локальная и удалённые по API, у Claude Code — его собственные.
  ///
  /// Ключей от API в ответе нет — они остаются на маке; приходит только признак «ключ задан».
  Future<List<AgentModel>> models({String harness = 'pi'}) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.get(
        '/projects/models',
        queryParameters: <String, dynamic>{'harness': harness},
      ),
    );
    final raw = data?['models'];
    return <AgentModel>[
      if (raw is List)
        for (final m in raw)
          if (m is Map) AgentModel.fromJson(m.cast<String, dynamic>()),
    ];
  }

  /// Провайдеры, настроенные у pi на маке: свои и встроенные.
  ///
  /// Ключи сюда не приходят: только признак «задан» и длина. Сам ключ лежит на маке.
  Future<List<AgentProvider>> providers() async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.get('/projects/providers'),
    );
    final raw = data?['providers'];
    return <AgentProvider>[
      if (raw is List)
        for (final p in raw)
          if (p is Map) AgentProvider.fromJson(p.cast<String, dynamic>()),
    ];
  }

  /// Создаёт или изменяет своего провайдера (адрес, API, ключ, модели) и отдаёт список заново.
  ///
  /// Пустой [apiKey] при изменении означает «оставить прежний ключ»: сохранённый ключ
  /// приложение не показывает, поэтому правка адреса или названия ключа не требует.
  Future<List<AgentProvider>> saveProvider({
    required String key,
    required String name,
    required String baseUrl,
    required String api,
    required String apiKey,
    required List<AgentModel> models,
  }) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.post(
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
              },
          ],
        },
      ),
    );
    return _providersOf(data);
  }

  /// Удаляет своего провайдера.
  Future<List<AgentProvider>> deleteProvider(String key) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.delete('/projects/providers/${Uri.encodeComponent(key)}'),
    );
    return _providersOf(data);
  }

  /// Проверяет адрес и ключ провайдера и возвращает его список моделей.
  ///
  /// [provider] нужен, чтобы проверить уже сохранённого провайдера, не вводя ключ заново:
  /// тогда ключ берётся на маке.
  Future<List<AgentModel>> probeProvider({
    required String baseUrl,
    String provider = '',
    String apiKey = '',
  }) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.post(
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

  /// Задаёт или убирает ключ встроенного провайдера (пустая строка — убрать).
  Future<List<AgentProvider>> saveProviderKey(
    String provider,
    String apiKey,
  ) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.post(
        '/projects/providers/key',
        data: <String, dynamic>{'provider': provider, 'apiKey': apiKey},
      ),
    );
    return _providersOf(data);
  }

  /// Список провайдеров из ответа сервера.
  List<AgentProvider> _providersOf(Map<String, dynamic>? data) {
    final raw = data?['providers'];
    return <AgentProvider>[
      if (raw is List)
        for (final p in raw)
          if (p is Map) AgentProvider.fromJson(p.cast<String, dynamic>()),
    ];
  }

  /// Проекты: папки внутри разрешённых корней, в которых можно работать.
  Future<List<AgentProject>> projects() async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.get('/projects'),
    );
    final raw = data?['projects'];
    return <AgentProject>[
      if (raw is List)
        for (final p in raw)
          if (p is Map) AgentProject.fromJson(p.cast<String, dynamic>()),
    ];
  }

  /// Сессии проекта, свежие сверху: их сервер берёт у моста, а мост — из файлов pi.
  Future<List<AgentSession>> sessions(String path) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.get(
        '/projects/sessions',
        queryParameters: <String, dynamic>{'path': path},
      ),
    );
    final raw = data?['sessions'];
    return <AgentSession>[
      if (raw is List)
        for (final s in raw)
          if (s is Map) AgentSession.fromJson(s.cast<String, dynamic>()),
    ];
  }

  /// Открывает сессию в папке проекта: сервер просит мост поднять процесс pi в этой папке
  /// (или продолжить сессию [sessionId], если она уже есть в истории).
  ///
  /// [modelKey] задаёт модель для новой сессии в виде `провайдер/идентификатор`: у pi моделей
  /// может быть несколько (локальная и удалённая по API), и выбрать её можно до начала разговора.
  Future<AgentSessionInfo> openSession(
    String path, {
    String harness = 'pi',
    String? sessionId,
    String? modelKey,
  }) async {
    final split = _splitModel(modelKey);
    final data = await _send<Map<String, dynamic>>(
      () => _http.post(
        '/projects/sessions',
        data: <String, dynamic>{
          'path': path,
          'harness': harness,
          if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
          if (split != null) 'provider': split.$1,
          if (split != null) 'model': split.$2,
        },
      ),
    );
    return _sessionOf(data);
  }

  /// Смена модели у открытой сессии: разговор продолжается, меняется только тот, кто считает.
  Future<AgentSessionInfo> setModel(String id, String modelKey) async {
    final split = _splitModel(modelKey);
    if (split == null) throw const AgentApiException(0, 'модель не выбрана');
    final data = await _send<Map<String, dynamic>>(
      () => _http.post(
        '/projects/sessions/$id/model',
        data: <String, dynamic>{'provider': split.$1, 'modelId': split.$2},
      ),
    );
    return _sessionOf(data);
  }

  /// Разбирает `провайдер/идентификатор` в пару; `null` — строка пустая или без провайдера.
  ///
  /// Делим по первому слэшу: у моделей llama.cpp идентификатор сам содержит слэш
  /// (`qwen/qwen3.5-9b`), поэтому «последний слэш» здесь был бы ошибкой.
  (String, String)? _splitModel(String? key) {
    final text = (key ?? '').trim();
    if (text.isEmpty) return null;
    final cut = text.indexOf('/');
    if (cut <= 0 || cut == text.length - 1) return null;
    return (text.substring(0, cut), text.substring(cut + 1));
  }

  /// Состояние сессии: модель, занятость, расход контекста.
  ///
  /// Нужно после сжатия контекста и смены модели: числа в шапке экрана должны быть свежими, а
  /// из потока ответа они приходят только к концу прогона.
  Future<AgentSessionInfo> session(String id) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.get('/projects/sessions/$id'),
    );
    return _sessionOf(data);
  }

  /// Переписка сессии в виде элементов экрана.
  Future<List<AgentItem>> messages(String id) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.get('/projects/sessions/$id/messages'),
    );
    final raw = data?['items'];
    return <AgentItem>[
      if (raw is List)
        for (final m in raw)
          if (m is Map) AgentItem.fromJson(m.cast<String, dynamic>()),
    ];
  }

  /// Отправляет сообщение агенту и отдаёт поток событий ответа.
  ///
  /// Прерывание потока (кнопка «Стоп», уход с экрана) рвёт и HTTP-запрос: сервер по разрыву
  /// соединения гасит работу агента на маке, поэтому команды не продолжают выполняться «в
  /// никуда» и не занимают единственный процесс pi с его контекстом.
  Stream<AgentEvent> prompt(String id, String text) async* {
    final Response<ResponseBody> res;
    try {
      res = await _http.post<ResponseBody>(
        '/projects/sessions/$id/prompt',
        data: <String, dynamic>{'text': text},
        // тело читаем сами как поток байтов: Dio не должен пытаться разобрать SSE как JSON
        options: Options(responseType: ResponseType.stream),
      );
    } on DioException catch (e) {
      throw _error(e);
    }
    yield* _eventsFrom(res.data);
  }

  /// Подключается к уже идущему прогону агента и отдаёт его события.
  ///
  /// Так экран показывает ответ, который пишется прямо сейчас (его начали с другого устройства
  /// или экран открыли заново во время работы), вместо отказа «сессия занята». Если прогона нет,
  /// сервер сразу присылает событие `idle`, и поток закрывается — ничего не происходит.
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

  /// Разбирает поток SSE сервера в события экрана.
  ///
  /// `cast<List<int>>()` обязателен, а не косметика: `body.stream` — поток `Uint8List`, а
  /// `utf8.decoder` объявлен над `List<int>`; без приведения код собирается, но падает в рантайме.
  /// Декодер потоковый: русский текст занимает два байта на символ, и сетевой чанк может
  /// разрезать символ или строку JSON посередине — склейку держит `LineSplitter`.
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
        continue; // битая порция — потеря куска ответа; исключение оборвало бы всю генерацию
      }
      if (decoded is! Map) continue;
      final event = _eventFromJson(decoded.cast<String, dynamic>());
      if (event != null) yield event;
    }
  }

  /// Останавливает генерацию: сервер просит мост прервать работу агента.
  Future<void> abort(String id) async {
    await _send<Map<String, dynamic>>(
      () => _http.post('/projects/sessions/$id/abort'),
    );
  }

  /// Сжимает контекст сессии: длинная работа иначе перестанет влезать в окно модели.
  Future<String> compact(String id) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.post('/projects/sessions/$id/compact'),
    );
    return data?['summary']?.toString() ?? '';
  }

  /// Закрывает процесс pi на маке, оставляя историю: освобождает память под контекст модели.
  ///
  /// Нужно, когда человек уходит из раздела, а также по явной кнопке: живой процесс держит
  /// контекст модели в памяти мака, и продолжение разговора потом поднимает его заново из файла.
  Future<void> closeSession(String id) async {
    await _send<Map<String, dynamic>>(
      () => _http.post('/projects/sessions/$id/close'),
    );
  }

  /// Удаляет сессию на маке: процесс гасится, файл истории стирается.
  ///
  /// Необратимо — в приложении это отдельное действие с подтверждением, а не то же самое, что
  /// «закрыть».
  Future<int> deleteSession(String id) async {
    final data = await _send<Map<String, dynamic>>(
      () => _http.delete('/projects/sessions/$id'),
    );
    return data?['deleted'] is num ? (data!['deleted'] as num).toInt() : 0;
  }

  /// Описание сессии из ответа сервера (`{"session": {...}}`).
  AgentSessionInfo _sessionOf(Map<String, dynamic>? data) {
    final raw = data?['session'];
    return AgentSessionInfo.fromJson(
      raw is Map ? raw.cast<String, dynamic>() : const {},
    );
  }

  /// Разбор одного события потока; `null` — событие не про экран.
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
        // Автоответ на диалог расширения: человек его не давал, поэтому он показывается в
        // переписке отдельной служебной строкой — иначе агент «что-то сделал сам» без следа.
        final title = json['title']?.toString() ?? '';
        final auto = json['auto']?.toString() ?? '';
        final text = [
          'Подтверждение',
          if (title.isNotEmpty) '«$title»',
          auto,
        ].where((s) => s.isNotEmpty).join(': ');
        return text.isEmpty ? null : AgentEvent(note: text);
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
      default:
        // `accepted`, `closed`, `compacted` и прочее состояние экрана не меняют: незнакомые
        // события пропускаем, чтобы новый мост не ломал старую сборку приложения.
        return null;
    }
  }

  /// Выполняет запрос и переводит сбой в [AgentApiException] с текстом сервера.
  Future<T?> _send<T>(Future<Response<T>> Function() request) async {
    try {
      final res = await request();
      return res.data;
    } on DioException catch (e) {
      throw _error(e);
    }
  }

  /// Сбой клиента → ошибка раздела с причиной, которую уже сформулировал сервер.
  ///
  /// Текст берём из тела ответа (`{statusCode, message, code}` от `AllExceptionsFilter`): сервер
  /// отдаёт причину моста как есть. Свои тексты остаются на случай, когда ответа нет вовсе.
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
    }
    message ??= switch (e.type) {
      DioExceptionType.connectionError ||
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout =>
        'Нет связи с сервером. Проверьте интернет и повторите.',
      DioExceptionType.cancel => 'Запрос отменён.',
      _ =>
        status == 0
            ? 'Не удалось обратиться к серверу.'
            : 'Сервер ответил ошибкой $status.',
    };
    return AgentApiException(status, message, code: code);
  }
}
