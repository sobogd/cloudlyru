import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
/// Собирается поверх облачного клиента: адрес сервера и cookie веб-сессии
/// берутся у него замыканием, поэтому смена сервера в настройках применяется и здесь.
///
/// Прямого доступа к маку у приложения нет и быть не должно: агент работает на домашнем маке,
/// но запросы делает сервер (он видит мост через туннель), и в сборке приложения поэтому нет ни
/// адреса моста, ни порта туннеля, ни ключей.
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
      () => _get('/projects/health'),
    );
    return AgentHealth.fromJson(data ?? const {});
  }

  /// Что считается на маке и что закончилось, пока приложения не было.
  Future<AgentActivity> activity() async {
    final data = await _send<Map<String, dynamic>>(
      () => _get('/projects/activity'),
    );
    return AgentActivity.fromJson(data ?? const {});
  }

  /// Харнессы, стоящие на маке: pi и Claude Code — с версиями и признаком «есть».
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

  /// Модели харнесса: у pi — локальная и удалённые по API, у Claude Code — его собственные.
  ///
  /// Ключей от API в ответе нет — они остаются на маке; приходит только признак «ключ задан».
  Future<List<AgentModel>> models({String harness = 'pi'}) async =>
      (await catalog(harness: harness)).$1;

  /// Модели и уровни усилия харнесса одним запросом.
  ///
  /// Уровни усилия есть только у Claude Code (у pi — пустой список), но запрос тот же: мост
  /// отдаёт их тем же ответом `/models`, и второй запрос ради второй половины данных был бы
  /// лишним. Первый элемент пары — модели, второй — уровни усилия.
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

  /// Провайдеры, настроенные у pi на маке: свои и встроенные.
  ///
  /// Ключи сюда не приходят: только признак «задан» и длина. Сам ключ лежит на маке.
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
      () => _delete('/projects/providers/${Uri.encodeComponent(key)}'),
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

  /// Задаёт или убирает ключ встроенного провайдера (пустая строка — убрать).
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
      () => _get('/projects'),
    );
    final raw = data?['projects'];
    return <AgentProject>[
      if (raw is List)
        for (final p in raw)
          if (p is Map) AgentProject.fromJson(p.cast<String, dynamic>()),
    ];
  }

  /// Сессии: одной папки или всех проектов сразу.
  ///
  /// Без [path] мост обходит все разрешённые проекты и отдаёт один список разговоров обоих
  /// харнессов, свежие сверху (порядок моста). С [path] — разговоры одной папки. Раздел
  /// «Проекты» показывает список наоборот — от старых к новым.
  Future<List<AgentSession>> sessions([String? path]) async {
    final dir = (path ?? '').trim();
    final data = await _send<Map<String, dynamic>>(
      () => _get(
        '/projects/sessions',
        queryParameters: dir.isEmpty ? null : <String, dynamic>{'path': dir},
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
          // усилие не записывается в файл разговора, поэтому уезжает и для существующей сессии:
          // иначе возобновлённый процесс Claude Code взял бы умолчание модели
          if (effort != null && effort.isNotEmpty) 'effort': effort,
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
      () => _post(
        '/projects/sessions/$id/model',
        data: <String, dynamic>{'provider': split.$1, 'modelId': split.$2},
      ),
    );
    return _sessionOf(data);
  }

  /// Смена уровня усилия у сессии Claude Code; пустая строка — вернуться к умолчанию модели.
  ///
  /// Процесс при этом перезапускается с тем же разговором: уровень задаётся при запуске, а не
  /// меняется на ходу. У pi такого выбора нет — мост ответит отказом.
  Future<AgentSessionInfo> setEffort(String id, String effort) async {
    final data = await _send<Map<String, dynamic>>(
      () => _post(
        '/projects/sessions/$id/effort',
        data: <String, dynamic>{'effort': effort},
      ),
    );
    return _sessionOf(data);
  }

  /// Ставит сессии новое имя.
  ///
  /// Возвращает сохранённое имя: мост обрезает лишние пробелы и переводы строк, и показывать
  /// в списке надо ровно то, что записано на маке. Имя хранится в журнале сессии у самого
  /// харнесса, поэтому открытый процесс для переименования не нужен.
  Future<String> renameSession(String id, String name) async {
    final data = await _send<Map<String, dynamic>>(
      () => _post(
        '/projects/sessions/$id/name',
        data: <String, dynamic>{'name': name},
      ),
    );
    return data?['name']?.toString() ?? '';
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
      () => _get('/projects/sessions/$id'),
    );
    return _sessionOf(data);
  }

  /// Переписка сессии в виде элементов экрана.
  Future<List<AgentItem>> messages(String id) async {
    final data = await _send<Map<String, dynamic>>(
      () => _get('/projects/sessions/$id/messages'),
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
  /// Прерывание потока (кнопка «Стоп», уход с экрана) рвёт и HTTP-запрос: мост по обрыву
  /// работу агента НЕ гасит (останавливает только явный [abort]), но поток событий закрывает,
  /// и экран при возврате подключается к идущему прогону заново.
  ///
  /// [messageId] уходит на мост вместе с текстом: по нему он отличает повтор от нового
  /// вопроса, поэтому два осознанно отправленных одинаковых сообщения не теряются.
  Stream<AgentEvent> prompt(String id, String text, [String messageId = '']) async* {
    final Response<ResponseBody> res;
    try {
      res = await _http.post<ResponseBody>(
        '/projects/sessions/$id/prompt',
        data: <String, dynamic>{
          'text': text,
          if (messageId.isNotEmpty) 'id': messageId,
        },
        // тело читаем сами как поток байтов: Dio не должен пытаться разобрать SSE как JSON
        options: Options(responseType: ResponseType.stream),
      );
    } on DioException catch (e) {
      throw _error(e);
    }
    yield* _eventsFrom(res.data);
  }

  /// Ставит сообщение в очередь занятой сессии.
  ///
  /// Возвращает место сообщения в очереди и признак «такое же сообщение уже отправлено»: мост
  /// отсекает повторы, и тогда место указывает на уже отправленное сообщение, а второй раз
  /// агенту ничего не уходит. `position == 0` без `duplicate` означает, что сессия успела
  /// освободиться — тогда сообщение надо отправить обычным вопросом ([prompt]), иначе оно
  /// потерялось бы. [messageId] — тот же идентификатор, что у [prompt]: по нему мост отличает
  /// повтор от осознанно повторённого сообщения.
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
      () => _post('/projects/sessions/$id/abort'),
    );
  }

  /// Распознаёт записанную речь в текст голосового ввода.
  ///
  /// Тело — байты записи, а не JSON: сервер перекладывает их на локальный whisper.cpp на маке
  /// и возвращает готовый текст. Формат записи роли не играет — сервер на маке приводит вход
  /// через ffmpeg, — поэтому уходит ровно то, что записала платформа.
  Future<String> transcribe(Uint8List audio) async {
    final data = await _send<Map<String, dynamic>>(
      () => _post<Map<String, dynamic>>(
        '/projects/transcribe',
        data: audio,
        contentType: 'application/octet-stream',
        // whisper считает запись целиком: минута диктовки может занять заметно больше
        // пятнадцати секунд, поэтому у этой ручки свой таймаут
        timeout: const Duration(minutes: 2),
      ),
    );
    return data?['text']?.toString().trim() ?? '';
  }

  /// Сжимает контекст сессии: длинная работа иначе перестанет влезать в окно модели.
  Future<String> compact(String id) async {
    final data = await _send<Map<String, dynamic>>(
      () => _post('/projects/sessions/$id/compact'),
    );
    return data?['summary']?.toString() ?? '';
  }

  /// Удаляет сессию на маке: процесс гасится, файл истории стирается.
  ///
  /// Необратимо — в приложении это действие с подтверждением.
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
      case 'queued':
        final position = json['position'];
        return position is num ? AgentEvent(queued: position.toInt()) : null;
      case 'duplicate':
        // Мост отсекает повторные отправки того же вопроса: показываем это строкой в переписке,
        // иначе ответ на идущий прогон выглядел бы ответом на неотправленный повтор
        return const AgentEvent(
          note: 'этот вопрос уже отправлен — показываю идущий ответ',
        );
      case 'snapshot':
        // Снимок идущего прогона: экран заменяет им хвост переписки, поэтому куски ответа,
        // вышедшие между его снимком истории и подпиской, не теряются
        final item = json['item'];
        return item is Map
            ? AgentEvent(snapshot: AgentItem.fromJson(item.cast<String, dynamic>()))
            : null;
      case 'ping':
        // Пульс связи: содержимого нет, но по нему видно, что поток жив (см. сторож в
        // agent_controller.dart: без пульса тишина в 40 с означала бы обрыв)
        return const AgentEvent(ping: true);
      case 'idle':
        return const AgentEvent(idle: true);
      case 'queued_started':
        // Сообщение из очереди ушло агенту: подпись «в очереди» снимается, текст ответа
        // приходит следом обычными delta
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
      default:
        // `accepted`, `closed`, `compacted` и прочее состояние экрана не меняют: незнакомые
        // события пропускаем, чтобы новый мост не ломал старую сборку приложения.
        return null;
    }
  }

  /// Обычный GET с таймаутом чтения.
  ///
  /// Таймаут здесь принципиален: `BaseOptions` не задаёт его вовсе (поток ответа живёт
  /// минутами), а без него при отвалившемся туннеле экран крутит спиннер до серверного
  /// таймаута (20–120 с) и человек не может ни отменить, ни понять, что случилось.
  Future<Response<T>> _get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Duration timeout = _defaultTimeout,
  }) => _http.get<T>(path, queryParameters: queryParameters, options: _timeout(timeout));

  /// Обычный POST с телом и таймаутом.
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

  /// Обычный DELETE с таймаутом.
  Future<Response<T>> _delete<T>(String path, {Duration timeout = _defaultTimeout}) =>
      _http.delete<T>(path, options: _timeout(timeout));

  /// Настройки запроса с одним и тем же таймаутом на чтение и отправку.
  Options _timeout(Duration timeout) => Options(receiveTimeout: timeout, sendTimeout: timeout);

  /// Выполняет запрос и переводит сбой в [AgentApiException] с текстом сервера.
  Future<T?> _send<T>(Future<Response<T>> Function() request) async {
    try {
      final res = await request();
      return res.data;
    } on DioException catch (e) {
      throw _error(e);
    }
  }

  /// Сколько ждать ответа обычной ручки по умолчанию.
  ///
  /// 15 с — это с запасом больше, чем мост отвечает здоровым (проверка списка, открытие сессии),
  /// и заметно меньше серверного таймаута: человек быстрее видит причину и кнопку повтора.
  static const _defaultTimeout = Duration(seconds: 15);

  /// Сбой клиента → ошибка раздела с причиной, которую уже сформулировал сервер.
  ///
  /// Текст берём из тела ответа (`{statusCode, message, code}` от `AllExceptionsFilter`): сервер
  /// отдаёт причину моста как есть. Свои тексты остаются на случай, когда ответа нет вовсе, и
  /// они разные для разных причин: «нет связи» после пробуждения радио и «сервер не ответил
  /// вовремя» лечатся по-разному, и показывать одно вместо другого — врать человеку.
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
      // Сервер может отдать признак «подожди N секунд» — показываем его в тексте, иначе
      // отказ по частоте выглядит как обычная ошибка без объяснения
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
