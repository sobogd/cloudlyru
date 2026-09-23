/// REST-клиент облака: единственное место, где приложение ходит по HTTP в API сервера.
///
/// Набор ручек и формы ответов повторяют прежний веб-клиент (`web/src/api.ts`), удалённый из
/// репозитория коммитом 407a490: это исторический ориентир, а не источник истины — сверяться
/// нужно с контроллерами сервера (`src/**/*.controller.ts`). Вход отличается от веб-клиента:
/// приложение получает ту же cookie веб-сессии и дальше ходит ею.
///
/// Модели ответов живут в `models.dart`; здесь только то, что описывает сам обмен — ошибка
/// ([ApiException]), итог загрузки ([UploadResult]) и её состояние ([UploadInit],
/// [UploadStatus]).
///
/// Ручки, которые интерфейс пока не использует (осознанно, а не по забывчивости): подпись
/// такого списка нужна, чтобы следующий разработчик не выяснял это сверкой контроллеров.
/// `GET /originals/:sha` (оригинал по хэшу — просмотрщик берёт содержимое по id записи),
/// `POST|DELETE /albums/:id/items` (альбомы есть только ручками API, интерфейса у них нет),
/// `POST /mail/messages/:id/flagged` и `GET /mail/messages/:id/attachments/:attachmentId`
/// (поле `flagged` в моделях клиента не разбирается, вложение отдаёт само письмо).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'models.dart';

/// Ошибка обращения к API: HTTP-код, машинный код из тела и текст для человека.
///
/// Единый тип для всех неудачных запросов — и для ответов сервера с ошибкой, и для сетевых
/// сбоев (у них [status] равен 0). Экраны показывают [message], а [code] разбирают только там,
/// где от него зависит ветка поведения.
class ApiException implements Exception {
  /// Код HTTP; 0 — ответа не было вовсе (нет связи, таймаут, обрыв).
  final int status;
  /// Машинный код из тела ответа; пустая строка, если сервер его не прислал.
  final String code;
  /// Текст, который можно показать человеку.
  final String message;
  /// Сколько секунд сервер просил подождать до повтора: `retryAfterSec` из тела или заголовок
  /// `Retry-After` (см. `src/common/errors.ts`). `null` — срока сервер не назвал.
  final int? retryAfterSec;

  ApiException(this.status, this.code, this.message, {this.retryAfterSec});

  /// Повтор того же запроса имеет смысл: ответа не было (0), таймаут, 429 или 5xx — всё это
  /// проходит само. Ответ 4xx означает, что неверен сам запрос, и повтор его не изменит.
  bool get retryable => status == 0 || status == 408 || status == 429 || status >= 500;

  /// Для логов и отладочных подписей: только текст, без кода.
  @override
  String toString() => message;
}

/// Внутренний сигнал «прямая загрузка в S3 сейчас невозможна», а не ошибка для человека.
///
/// Возникает, когда сервер не выдаёт presigned-ссылки или S3 не отдал ETag. Ловится внутри
/// [CloudlyApi.uploadFile], который после этого повторяет загрузку через сервер, поэтому наружу
/// этот тип не выходит.
class DirectUnavailable implements Exception {
  /// Причина — её видно в подписи прогресса при переходе на загрузку через сервер.
  final String message;
  /// false — повторять бессмысленно: сервер таких ссылок не выдаёт вовсе (старая версия или
  /// выключенный режим S3), это повод сразу уйти в загрузку через сервер, а не долбить его.
  final bool retryable;
  DirectUnavailable(this.message, {this.retryable = true});
  @override
  String toString() => message;
}

/// Итог загрузки файла: чем она закончилась для вызывающего.
///
/// Признака «файл уже был» мало: сразу после загрузки нужен и id записи, чтобы открыть файл или
/// записать его в список выгруженного.
class UploadResult {
  /// id записи в облаке — тот же, что в листингах файлов.
  final String entryId;
  /// true — сервер нашёл точно такое же содержимое по sha256 и вторую копию не хранил.
  final bool deduped;
  UploadResult(this.entryId, this.deduped);
}

/// Ответ сервера на начало загрузки (`POST /uploads`): что делать дальше.
///
/// Возможны три исхода, и они различимы по полям: [deduped] — загружать нечего, содержимое уже
/// есть ([entryId]); [direct] — части льются прямо в S3 по presigned-ссылкам; иначе — части идут
/// через сервер. [uploadId] нужен на всех шагах, кроме дедупликации.
class UploadInit {
  /// Идентификатор начатой загрузки: по нему идут части, сборка и отмена.
  final String? uploadId;
  final bool deduped;
  /// Сервер умеет выдавать presigned-ссылки: загрузка пойдёт мимо него, прямо в S3.
  final bool direct;
  /// Размер части, назначенный сервером; [CloudlyApi.uploadFile] режет файл именно по нему.
  final int partSize;
  /// Потолок размера одной части в режиме relay (`chunkMaxBytes`); `null` — сервер его не
  /// назвал (старая версия). Меньше 5 МБ он быть не должен: столько S3 требует на часть.
  final int? chunkMaxBytes;
  /// Номер части, с которой начинать. У свежей сессии это 1, у продолженной — первая
  /// недостающая часть: сервер помнит, что уже принял.
  final int nextPart;
  /// Заполнен только при [deduped]: id уже существующей записи.
  final String? entryId;

  UploadInit({
    this.uploadId,
    required this.deduped,
    required this.direct,
    required this.partSize,
    this.chunkMaxBytes,
    this.nextPart = 1,
    this.entryId,
  });
}

/// Состояние начатой загрузки (`GET /uploads/:id`): им продолжается оборванная передача.
///
/// `nextPart` считает сервер и отдаёт именно первую *недостающую* часть, а не «сколько
/// принято»: части могли дойти не по порядку, и счётчик сдвинулся бы за дырку.
class UploadStatus {
  final String uploadId;
  /// Режим, в котором сессия заведена: прямо в S3 или через сервер. Доливать части нужно
  /// тем же способом — сервер сводит их в один multipart по номерам.
  final bool direct;
  /// Размер части, назначенный сервером этой сессии.
  final int partSize;
  /// Потолок размера части relay (`chunkMaxBytes`); `null` — сервер его не назвал.
  final int? chunkMaxBytes;
  /// Первая недостающая часть по мнению сервера: годится для прямой загрузки, где части
  /// регистрируются по номерам и могли прийти не по порядку.
  final int nextPart;
  /// Сколько частей уже принято.
  final int receivedParts;
  /// Размер и имя записи: по ним вызывающий сверяет сессию с файлом на диске, прежде чем
  /// доливать в неё байты.
  final int size;
  final String name;
  final String? folderId;

  UploadStatus({
    required this.uploadId,
    required this.direct,
    required this.partSize,
    this.chunkMaxBytes,
    required this.nextPart,
    required this.receivedParts,
    required this.size,
    required this.name,
    this.folderId,
  });

  /// Часть, с которой продолжать передачу.
  ///
  /// У relay-сессии берём `receivedParts + 1`, а не серверный [nextPart]: сервер считает
  /// «первую недостающую» по числу частей прямой загрузки (16 МБ), а relay-части у клиента
  /// меньше — тогда nextPart указывал бы на уже принятую часть, и загрузка повторно отправила
  /// бы сотни мегабайт. Relay-части идут строго по порядку (сервер отвергает «часть не по
  /// порядку»), поэтому принятых частей ровно `receivedParts` и следующая — `receivedParts + 1`.
  int get resumePart => direct ? nextPart : receivedParts + 1;
}

/// Приёмник результата потокового sha256: `crypto` отдаёт итоговый [Digest] именно в [add].
class _DigestSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest d) => digest = d;
  @override
  void close() {}
}

/// Клиент API облака: адрес сервера, cookie сессии и все ручки, которые нужны приложению.
///
/// Экземпляр живёт в состоянии приложения и пересоздаётся при смене адреса сервера и после
/// выхода. Экраны в сеть сами не ходят: они зовут методы отсюда и получают ошибки одним типом
/// [ApiException].
///
/// Cookie здесь не только ради авторизации: часть ручек сервер принимает исключительно от
/// веб-сессии (см. [session]). Клиент синхронизации с device-токеном — это отдельный клиент
/// (`sync/net/sync_api.dart`), а не этот.
class CloudlyApi {
  /// Адрес сервера без хвостового слэша.
  ///
  /// Поле неизменяемое, потому что Dio собирается один раз: смена адреса на лету поменяла бы
  /// только ссылки на содержимое, а запросы продолжали бы уходить на прежний сервер. Новый
  /// адрес — новый экземпляр клиента (`AppState` так и делает).
  final String serverUrl;

  /// Базовый адрес API (`…/api/v1`) — один на весь клиент: из него собраны и запросы
  /// (baseUrl у Dio), и ссылки на содержимое. Считается один раз в конструкторе.
  final String baseUrl;

  /// Cookie веб-сессии (`cl_session=…`) — ею ходит весь интерфейс приложения.
  ///
  /// Ручки, помеченные на сервере `@SessionOnly`, принимают только её и отвечают 403
  /// device-токену: почта (`/mail/accounts`, `/mail/sync`, `/mail/status`, `/mail/send`,
  /// `/mail/favicon`, `/mail/trash/purge`), безвозвратная очистка корзины файлов (`/trash/purge`)
  /// и управление app-токенами (`POST` и `DELETE /auth/tokens`). Список ведётся на сервере:
  /// добавили там новую такую ручку — дописать и здесь.
  String? session;

  /// Зовётся, когда сервер ответил 401: сессия протухла, и приложение должно вернуть человека
  /// на экран входа. Ставит владелец клиента (`AppState`): сам клиент только сообщает, потому
  /// что решение «выходить или переспросить» — не его.
  void Function()? onUnauthorized;

  /// Общий Dio: относительные пути от `/api/v1`, Cookie сессии в перехватчике.
  late final Dio _http;
  /// Dio для входа: cookie ещё нет, а `set-cookie` из ответа надо прочитать самому — поэтому без перехватчика.
  late final Dio _session;
  /// Dio для presigned-ссылок S3: абсолютные URL, без базового адреса и без Cookie (доступ — в самой ссылке).
  late final Dio _s3;

  /// Собирает три HTTP-клиента под заданный адрес сервера.
  ///
  /// [session] можно передать сразу или выставить позже: экран входа получает cookie в рантайме
  /// и присваивает её в поле. Таймауты подобраны по виду запроса: короткие на подключение,
  /// длинные на отдачу содержимого.
  CloudlyApi({required this.serverUrl, this.session})
      : baseUrl = '${_normalize(serverUrl)}/api/v1' {
    _http = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 120),
    ));
    _http.interceptors.add(InterceptorsWrapper(
      onRequest: (o, h) {
        // Cookie ставим заголовком на каждый запрос, а не в BaseOptions: сессия появляется после
        // входа, то есть уже после создания клиента. Заголовки берём из [authHeaders] — там же,
        // откуда их берут картинки и скачивание: расходиться этим двум местам незачем.
        o.headers.addAll(authHeaders);
        o.headers['Accept'] = 'application/json';
        h.next(o);
      },
      onError: (e, h) {
        // 401 — сессия протухла или её нет (сервер отвечает так и на просроченную cookie).
        // Держать её дальше незачем: с ней не пройдёт ни одна ручка, включая картинки.
        // Владельца зовём один раз на переход «была сессия → нет»: иначе одно протухание
        // на десятке параллельных запросов дало бы десяток выходов на экран входа.
        if (e.response?.statusCode == 401) {
          final had = session != null && session!.isNotEmpty;
          session = null;
          if (had) onUnauthorized?.call();
        }
        h.next(e);
      },
    ));
    // Вход ждёт короткого ответа сервера, поэтому общие таймауты здесь уменьшены.
    _session = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30),
    ));
    // Ссылки S3 абсолютные, базового адреса нет. Секунды щедрые: часть может литься долго.
    _s3 = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 300),
      receiveTimeout: const Duration(seconds: 300),
    ));
  }

  /// Убирает пробелы по краям и хвостовые слэши.
  ///
  /// Адрес вводят руками и вставляют копированием, а лишний `/` склеил бы пути вида `//api/v1/...`.
  static String _normalize(String u) => u.trim().replaceAll(RegExp(r'/+$'), '');

  /// Заголовки с Cookie сессии — для тех, кто тянет содержимое мимо этого клиента.
  ///
  /// Нужны виджетам картинок, видеоплееру и скачиванию: у них нет своего доступа к полю
  /// [session], а превью и файлы закрыты авторизацией. Пустая карта — сессии ещё нет.
  Map<String, String> get authHeaders {
    final s = session;
    return (s != null && s.isNotEmpty) ? {'Cookie': s} : const {};
  }

  // ---------- базовые запросы ----------

  /// Один запрос к API: JSON-тело, произвольный метод, ошибки — в [ApiException].
  ///
  /// Возвращает уже разобранный JSON (`Map`, `List` или примитив); конкретную модель собирает
  /// вызывающий. У ответов без тела получается `null`.
  ///
  /// [receiveTimeout] переопределяет общие 60 с на ответ — им пользуются ручки, которые
  /// заведомо работают дольше (сборка загруженного объекта на сервере). [cancelToken] —
  /// для экранов, которые умеют отказаться от уже ненужного запроса.
  Future<dynamic> _req(
    String path, {
    String method = 'GET',
    Object? body,
    Duration? receiveTimeout,
    CancelToken? cancelToken,
  }) async {
    try {
      final res = await _http.request<dynamic>(
        path,
        data: body,
        cancelToken: cancelToken,
        options: Options(method: method, receiveTimeout: receiveTimeout),
      );
      return res.data;
    } on DioException catch (e) {
      throw _toException(e);
    }
  }

  /// Приводит [DioException] к [ApiException], доставая текст и код из тела ответа.
  ///
  /// Тело ошибки приходит и объектом, и строкой с JSON (зависит от того, кто её породил),
  /// поэтому разбираем оба случая. Если тела нет вовсе — это сетевой сбой, и текст берётся по
  /// его виду (см. [_netMessage]).
  ///
  /// Поля берутся через `'${…}'`, а не жёстким кастом: `message` бывает не строкой (массив
  /// сообщений ValidationPipe), и `as String?` уронил бы разбор ошибки TypeError'ом — то есть
  /// вместо ответа сервера человек увидел бы ошибку приведения типов.
  ApiException _toException(DioException e) {
    final status = e.response?.statusCode ?? 0;
    var code = '';
    var message = 'HTTP $status';
    int? retryAfterSec;
    final data = e.response?.data;
    void take(Map body) {
      message = '${body['message'] ?? message}';
      code = '${body['code'] ?? ''}';
      // Срок ожидания сервер отдаёт в теле (429): телефон по нему откладывает повтор.
      final sec = toNum(body['retryAfterSec'])?.toInt();
      if (sec != null && sec > 0) retryAfterSec = sec;
    }

    if (data is Map) {
      take(data.cast<String, dynamic>());
    } else if (data is String) {
      // Строковое тело — это либо JSON от Express, либо просто текст: пробуем разобрать,
      // а при неудаче показываем как есть.
      try {
        final obj = json.decode(data);
        if (obj is Map) take(obj.cast<String, dynamic>());
      } catch (_) {
        // Не JSON — значит обычный текст сообщения, отдаём его человеку без изменений.
        if (data.isNotEmpty) message = data;
      }
    }
    // Тот же срок в заголовке (HTTP-стандарт): тело бывает и без него — например, у ответа,
    // который отдал не наш обработчик ошибок.
    retryAfterSec ??= int.tryParse(e.response?.headers.value('retry-after') ?? '');
    // Ответа нет вовсе: код останется 0, а текст берём по виду сбоя — иначе было бы «HTTP 0».
    if (e.response == null) {
      message = _netMessage(e);
    }
    return ApiException(status, code, message, retryAfterSec: retryAfterSec);
  }

  /// Текст сетевого сбоя по-русски: у таймаутов и пропавшей связи он разный, остальное — как
  /// сообщил Dio.
  String _netMessage(DioException e) {
    switch (e.type) {
      // Три вида таймаута сведены в одну подпись: человеку важно, что ответа не дождались,
      // а не какой именно таймер сработал.
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'не дождался ответа сервера';
      case DioExceptionType.connectionError:
        return 'нет соединения с сервером (${e.message ?? ''})';
      default:
        return e.message ?? 'ошибка сети';
    }
  }

  /// Приводит ответ к объекту: не-Map (`null`, список, строка) даёт пустую карту.
  ///
  /// Так разбор модели не падает на неожиданной форме ответа — например, когда ручка вернула
  /// пустое тело.
  static Map<String, dynamic> _m(dynamic d) =>
      d is Map ? d.cast<String, dynamic>() : <String, dynamic>{};
  /// То же для списка объектов: не-список даёт пустой список, а не-объекты внутри отбрасываются.
  static List<Map<String, dynamic>> _lm(dynamic d) => d is List
      ? d.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
      : <Map<String, dynamic>>[];

  /// Время в UTC как ISO-строка — в такой форме сервер принимает `clientMtime`.
  /// `null` остаётся `null`: «времени нет» и «время нулевое» — разные вещи.
  static String? _isoOrNull(DateTime? t) => t?.toUtc().toIso8601String();

  // ---------- авторизация ----------

  /// Вход логином и паролем: возвращает готовую cookie веб-сессии.
  ///
  /// Ходит отдельным клиентом ([_session]), потому что cookie ещё нет, а `set-cookie` из ответа
  /// надо прочитать самому. Дальше этой cookie ходит весь интерфейс — ручки с `@SessionOnly`
  /// device-токену отвечают 403. Пароль нигде не сохраняется: на диск уходит только cookie.
  ///
  /// Ошибку не глотает: исключение поднимается в экран входа, который показывает текст под полями.
  ///
  /// Сбой приводится к [ApiException] тем же [_toException], что и остальные запросы: иначе
  /// наружу улетал бы сырой [DioException], чей `toString()` — многострочный английский дамп
  /// с `SocketException`, а экран входа показывает текст исключения как есть.
  Future<String> login(String login, String password, {String? client}) async {
    final Response<String> res;
    try {
      res = await _session.post<String>('/auth/login',
          // `client` — как приложение себя называет: по этой строке человек узнаёт свой вход
          // в списке сеансов (в настройках). Обычно это «Cloudly 1.0.0+94 · android».
          data: {'login': login, 'password': password, 'client': ?client},
          options: Options(responseType: ResponseType.plain));
    } on DioException catch (e) {
      throw _toException(e);
    }
    // Из заголовка берём только пару «имя=значение»: атрибуты (Path, HttpOnly, Max-Age) серверу
    // при следующем запросе не нужны, а несколько cookie склеиваем в одну строку.
    final cookie = (res.headers['set-cookie'] ?? const <String>[])
        .map((c) => c.split(';').first)
        .where((c) => c.isNotEmpty)
        .join('; ');
    // Пустой набор cookie означает, что сервер вход не подтвердил: без сессии все последующие
    // ручки ответят 401/403, поэтому лучше упасть здесь, пока на экране есть поля для повторной попытки.
    if (cookie.isEmpty) throw ApiException(0, '', 'сервер не выдал сессию');
    // Cookie живёт до истечения сессии на сервере; клиент этого срока не знает, поэтому о
    // протухшей сессии узнаёт по 401 — см. [onUnauthorized].
    return cookie;
  }

  /// Текущий пользователь: id, логин и id системных папок (`GET /auth/me`).
  Future<UserInfo> me() async => UserInfo.fromJson(_m(await _req('/auth/me')));

  /// Выход: просит сервер погасить веб-сессию (`POST /auth/logout`).
  ///
  /// Локальную cookie метод не стирает — это делает вызывающий, когда выход состоялся или когда
  /// сервер недоступен, но выходить всё равно надо.
  Future<void> logout() async {
    await _req('/auth/logout', method: 'POST');
  }

  /// Гасит все прочие входы в аккаунт, кроме этого (`POST /auth/sessions/revoke-others`).
  ///
  /// Возвращает число погашенных сессий: ноль — «других входов не было», и это тоже ответ,
  /// который надо показать человеку. Ручка доступна только веб-сессии (у неё на сервере
  /// `@SessionOnly`): device-токен синхронизации ею ничего погасить не может, поэтому вызов
  /// осмыслен только из интерфейса.
  Future<int> revokeOtherSessions() async {
    final d = _m(await _req('/auth/sessions/revoke-others', method: 'POST', body: {}));
    return toNum(d['sessionsRevoked'])?.toInt() ?? 0;
  }

  /// Меняет логин и/или пароль владельца (`POST /auth/credentials`).
  ///
  /// Текущий пароль обязателен: это доказательство, что данные аккаунта меняет владелец, а не
  /// тот, кто взял разблокированный телефон. Что не передано, то и не меняется — так одна форма
  /// закрывает три случая: только логин, только пароль или оба сразу.
  ///
  /// Возвращает новый логин (интерфейс показывает его, не дожидаясь `/auth/me`) и число
  /// погашенных прочих сессий: смена пароля гасит их на сервере, и об этом надо сказать человеку.
  /// Смена одного логина сессии не трогает.
  Future<({String login, int sessionsRevoked})> changeCredentials({
    required String currentPassword,
    String? login,
    String? newPassword,
  }) async {
    // Пустые поля не отправляем вовсе: на сервере «поля нет» значит «не менять», и отправленная
    // пустая строка читалась бы как попытка поставить пустой пароль.
    final d = _m(await _req('/auth/credentials', method: 'POST', body: {
      'currentPassword': currentPassword,
      if (login != null && login.isNotEmpty) 'login': login,
      if (newPassword != null && newPassword.isNotEmpty) 'newPassword': newPassword,
    }));
    return (
      login: d['login'] as String? ?? '',
      sessionsRevoked: toNum(d['sessionsRevoked'])?.toInt() ?? 0,
    );
  }

  /// Живые сеансы владельца: входы в приложение и браузер (`GET /auth/sessions`).
  ///
  /// Ручка только для веб-сессии, и это правильно: список входов — не то, что должен видеть
  /// украденный app-токен устройства.
  Future<List<AuthSessionRow>> listSessions() async =>
      _lm(await _req('/auth/sessions')).map(AuthSessionRow.fromJson).toList();

  /// Завершает один сеанс — кнопка рядом с конкретным входом в списке.
  ///
  /// Свой текущий сеанс так не завершить: сервер откажет, и это осознанно — для него есть
  /// «Выйти», который делает то же самое и ещё чистит cookie с локальными данными.
  Future<void> revokeSession(String id) async {
    await _req('/auth/sessions/${Uri.encodeComponent(id)}', method: 'DELETE');
  }

  /// Последняя опубликованная сборка Android-приложения (`GET /app/android`).
  ///
  /// Ручка без авторизации: проверка обновления должна работать и с отозванным токеном —
  /// приложение как раз может стоять со старым, а починиться ему нужно.
  ///
  /// Отсутствие сборки — это 404 с кодом `no_release` («сборка ещё не опубликована»), то есть
  /// нормальное состояние сервера, а не сбой проверки: вызывающий должен ветвить по
  /// `ApiException.code`, а не показывать это как ошибку.
  Future<AppRelease> latestApp() async =>
      AppRelease.fromJson(_m(await _req('/app/android')));

  /// Последняя опубликованная настольная сборка (`GET /app/macos`).
  ///
  /// Отдельная ручка, а не параметр у предыдущей: сборки платформ публикуются порознь, и на маке
  /// версия мобильной сборки означала бы предложение скачать APK. Ответ устроен так же, включая
  /// `no_release`, когда настольную сборку ещё не публиковали.
  Future<AppRelease> latestAppMacos() async =>
      AppRelease.fromJson(_m(await _req('/app/macos')));

  /// Список выпущенных app-токенов; самих токенов в нём нет — сервер отдаёт их только при выпуске.
  Future<List<ApiTokenRow>> listTokens() async =>
      _lm(await _req('/auth/tokens')).map(ApiTokenRow.fromJson).toList();

  /// Выпускает новый app-токен с меткой [label] и отдаёт ответ сервера целиком.
  ///
  /// В модель не разбираем: токен показывается один раз и больше не придёт, поэтому экран берёт
  /// его прямо из карты ответа.
  ///
  /// Нигде не вызывается: в настройках список токенов только для чтения.
  Future<Map<String, dynamic>> createToken(String label) async =>
      _m(await _req('/auth/tokens', method: 'POST', body: {'label': label}));

  /// Отзывает app-токен по id — дальше он не пройдёт авторизацию ни в REST, ни в WebDAV.
  ///
  /// Зовётся из панели «Приложения (WebDAV/Finder)» в настройках (кнопка рядом с токеном) и из
  /// `ensureDeviceToken`, когда прежний токен устройства оказался мёртв. Выход на телефоне гасит
  /// собственный device-токен другой ручкой (`DELETE /auth/me/token`).
  Future<void> revokeToken(String id) async {
    await _req('/auth/tokens/${Uri.encodeComponent(id)}', method: 'DELETE');
  }

  // ---------- папки/файлы ----------

  /// Одна страница содержимого папки; [parentId] — id папки, `null` — корень диска пользователя.
  ///
  /// Для корня отдельная ручка: сервер сам знает, какая папка у этого пользователя корневая.
  ///
  /// Сервер отдаёт содержимое страницами (1000 записей по умолчанию, до 5000 по [limit]) и в
  /// каждой странице сообщает, есть ли продолжение: [FolderView.hasMore] и
  /// [FolderView.nextAfter] — имя, с которого начинается следующая. Папка на 3000 файлов
  /// приходит тремя страницами, и вызывающий обязан пройти их сам, иначе покажет неполное
  /// содержимое без единого признака ошибки:
  ///
  /// ```dart
  /// var view = await api.listFolder(id);
  /// while (view.hasMore) {
  ///   view = await api.listFolder(id, after: view.nextAfter);
  ///   // приклеить view.folders и view.entries к уже показанному
  /// }
  /// ```
  ///
  /// [after] — курсор предыдущей страницы ([FolderView.nextAfter]); `null` — первая страница.
  /// Продолжение нумеруется по имени, а не по смещению: записи приходят в устойчивом порядке
  /// имён, и правка в середине папки не сдвигает уже показанное.
  Future<FolderView> listFolder(String? parentId,
      {String? after, int? limit, CancelToken? cancelToken}) async {
    final path = parentId == null
        ? '/folders'
        : '/folders/${Uri.encodeComponent(parentId)}/children';
    final query = <String>[
      if (after != null && after.isNotEmpty) 'after=${Uri.encodeQueryComponent(after)}',
      if (limit != null) 'limit=$limit',
    ];
    final j = _m(await _req(
      '$path${query.isEmpty ? '' : '?${query.join('&')}'}',
      cancelToken: cancelToken,
    ));
    return FolderView.fromJson(j);
  }

  /// Создаёт папку [name] внутри [parentId] (`null` — в корне) и возвращает её id.
  ///
  /// Пустая строка вместо id — если сервер не вернул его в ответе; вызывающий в этом случае
  /// просто перечитывает листинг.
  Future<String> mkdir(String name, String? parentId) async {
    final j = _m(await _req('/folders',
        method: 'POST', body: {'name': name, 'parentId': ?parentId}));
    return j['id'] as String? ?? '';
  }

  /// Переименовывает и/или переносит папку: содержимое и место в дереве по умолчанию не трогаются.
  ///
  /// [parentId] — новая папка-владелец; сервер принимает перенос этой же ручкой, а не парой
  /// «удалить и создать». (Интерфейс пока переносит папки буфером обмена — см. [setClipboard].)
  Future<void> renameFolder(String id, String name, {String? parentId}) async {
    await _req('/folders/${Uri.encodeComponent(id)}',
        method: 'PATCH', body: {'name': name, 'parentId': ?parentId});
  }

  /// Переименовывает и/или переносит файл — запись в дереве; содержимое в хранилище остаётся
  /// прежним, поэтому перенос не переписывает байты.
  ///
  /// [folderId] — новая папка, [clientMtime] — время файла с устройства: сервер хранит его
  /// отдельно от своего `updatedAt`, и без него mtime на сервере теряется.
  Future<void> renameFile(String id, String name,
      {String? folderId, DateTime? clientMtime}) async {
    await _req('/files/${Uri.encodeComponent(id)}', method: 'PATCH', body: {
      'name': name,
      'folderId': ?folderId,
      if (clientMtime != null) 'clientMtime': clientMtime.toUtc().toIso8601String(),
    });
  }

  /// Убирает папку в корзину: безвозвратно её удаляет только очистка корзины.
  Future<void> deleteFolder(String id) async => _req('/folders/$id', method: 'DELETE');

  /// Убирает файл в корзину.
  Future<void> deleteFile(String id) async => _req('/files/$id', method: 'DELETE');

  /// Метаданные файла: имя, размер, зона, хеш и разобранные метаданные содержимого.
  Future<FileMeta> fileMeta(String id) async =>
      FileMeta.fromJson(_m(await _req('/files/$id')));

  /// Метаданные папки: путь и счётчики того, что внутри.
  Future<FolderMeta> folderMeta(String id) async =>
      FolderMeta.fromJson(_m(await _req('/folders/$id/meta')));

  // ---------- буфер ----------

  /// Что сейчас лежит в буфере обмена; `null` — буфер пуст.
  ///
  /// Пустой буфер — обычное состояние, а не ошибка: по `null` экран просто не показывает
  /// пункт «Вставить».
  Future<ClipboardView?> clipboard() async {
    final d = await _req('/clipboard');
    if (d == null) return null;
    return ClipboardView.fromJson(_m(d));
  }

  /// Кладёт запись в буфер: [kind] — `file` или `folder`, [mode] — `copy` или `cut`.
  Future<void> setClipboard(String kind, String id, String mode) async {
    await _req('/clipboard', method: 'POST', body: {'kind': kind, 'id': id, 'mode': mode});
  }

  /// Очищает буфер («отменить копирование»).
  Future<void> clearClipboard() async => _req('/clipboard', method: 'DELETE');

  /// Вставляет содержимое буфера в папку [folderId].
  ///
  /// Возвращает ответ сервера как есть (`ok`, `action` — `copied`/`moved`, `name`): экрану
  /// достаточно знать, что вставка прошла, дальше он перечитывает листинг.
  Future<Map<String, dynamic>> pasteClipboard(String folderId) async =>
      _m(await _req('/clipboard/paste', method: 'POST', body: {'folderId': folderId}));

  // ---------- корзина ----------

  /// Содержимое корзины файлов: удалённые папки и файлы, каждая группа своим списком.
  Future<TrashView> trash() async => TrashView.fromJson(_m(await _req('/trash')));

  /// Возвращает запись из корзины на прежнее место; [kind] — `file` или `folder`.
  Future<void> restoreItem(String kind, String id) async =>
      _req('/trash/restore', method: 'POST', body: {'type': kind, 'id': id});

  /// Безвозвратно очищает корзину файлов.
  ///
  /// Ручка доступна только веб-сессии: устройство со своим токеном не должно уметь вычистить
  /// единственную точку восстановления одним запросом.
  Future<void> purgeTrash() async => _req('/trash/purge', method: 'POST', body: {});

  // ---------- заметки ----------

  /// Список заметок в порядке показа: приоритет (высокий → низкий), затем свежие правки.
  ///
  /// Порядок считает сервер — так он одинаков на всех устройствах, а клиенту остаётся только
  /// показать список как есть.
  Future<List<Note>> notes() async {
    final body = _m(await _req('/notes'));
    return body.lm('notes').map(Note.fromJson).toList();
  }

  /// Новая заметка. Возвращает вид, под которым её сохранил сервер: `id` нужен, чтобы редактор
  /// дальше правил именно её, а не создавал копию при каждом сохранении.
  Future<Note> createNote({required String text, required String priority}) async {
    final body = _m(await _req('/notes', method: 'POST', body: {'text': text, 'priority': priority}));
    return Note.fromJson(_m(body['note']));
  }

  /// Правка текста и/или приоритета заметки; сервер сам обновляет время последней правки.
  Future<Note> updateNote(String id, {required String text, required String priority}) async {
    final body = _m(await _req('/notes/$id', method: 'PATCH', body: {'text': text, 'priority': priority}));
    return Note.fromJson(_m(body['note']));
  }

  /// Удаление заметки — насовсем, без корзины.
  Future<void> deleteNote(String id) async => _req('/notes/$id', method: 'DELETE');

  // ---------- Mac ----------

  /// Состояние домашнего мака: CPU/RAM/диски/батарея, WARP, службы, безопасность.
  ///
  /// Сервер сам ходит к панели мака по reverse-SSH туннелю, поэтому приложение адреса
  /// туннеля не знает. Нет ответа — значит мак спит или туннель отключился (код ошибки
  /// `mac_unreachable`/`mac_timeout`).
  Future<Map<String, dynamic>> macStatus() async => _m(await _req('/mac/status'));

  /// История CPU/RAM за ~100 минут (семпл каждые 15 с) для графика.
  Future<Map<String, dynamic>> macHistory() async => _m(await _req('/mac/history'));

  /// Действие над маком из белого списка панели (`reboot`, `sleep`, `firewall-on`, …).
  Future<Map<String, dynamic>> macAction(String action) async =>
      _m(await _req('/mac/action', method: 'POST', body: {'action': action}));

  /// WARP: `connect` | `disconnect` | `reconnect` | `status`.
  Future<Map<String, dynamic>> macWarp(String op) async =>
      _m(await _req('/mac/warp', method: 'POST', body: {'op': op}));

  /// Состояние Claude (tangem) на маке: запущен ли агент, авторизован ли.
  Future<Map<String, dynamic>> macClaude() async => _m(await _req('/mac/claude'));

  /// Начинает вход в Claude: возвращает authorize URL, который человек открывает сам.
  Future<Map<String, dynamic>> macClaudeLogin() async =>
      _m(await _req('/mac/claude/login', method: 'POST', body: {}));

  /// Завершает вход в Claude кодом после авторизации.
  Future<Map<String, dynamic>> macClaudeCode(String code) async =>
      _m(await _req('/mac/claude/code', method: 'POST', body: {'code': code}));

  /// Дашборд GitHub Actions: настроенные workflow с последним запуском.
  Future<Map<String, dynamic>> macGithubActions({bool refresh = false}) async =>
      _m(await _req('/mac/github-actions${refresh ? '?refresh=1' : ''}'));

  /// Ветки и теги репозитория для формы запуска.
  Future<Map<String, dynamic>> macGithubRefs(String repo) async =>
      _m(await _req('/mac/github-actions/refs?repo=${Uri.encodeQueryComponent(repo)}'));

  /// Запуск workflow с веткой/тегом и inputs.
  Future<Map<String, dynamic>> macGithubRun(Map<String, dynamic> body) async =>
      _m(await _req('/mac/github-actions/run', method: 'POST', body: body));

  /// Перезапуск существующего запуска по run_id.
  Future<Map<String, dynamic>> macGithubRerun(int runId, String repo) async =>
      _m(await _req('/mac/github-actions/rerun',
          method: 'POST', body: {'run_id': runId, 'repo': repo}));

  /// Список `.env`-файлов под `~/work` на маке.
  Future<Map<String, dynamic>> macEnvs() async => _m(await _req('/mac/envs'));

  /// Содержимое одного `.env`-файла (отдаёт секреты — показывать только в разделе «Mac»).
  Future<Map<String, dynamic>> macEnvRead(String path) async =>
      _m(await _req('/mac/envs/read?path=${Uri.encodeQueryComponent(path)}'));

  /// Атомарная запись `.env`-файла (бэкап панель делает сама).
  Future<Map<String, dynamic>> macEnvWrite(String path, String content) async =>
      _m(await _req('/mac/envs/write',
          method: 'POST', body: {'path': path, 'content': content}));

  /// Открывает (или переиспользует) постоянную сессию `bash` на маке.
  Future<Map<String, dynamic>> macTermOpen() async =>
      _m(await _req('/mac/term/open', method: 'POST', body: {}));

  /// Хвост вывода терминала после смещения `after`.
  Future<Map<String, dynamic>> macTermPoll(int after) async =>
      _m(await _req('/mac/term/poll?after=$after'));

  /// Отправляет строку ввода в терминал.
  Future<Map<String, dynamic>> macTermInput(String data) async =>
      _m(await _req('/mac/term/input', method: 'POST', body: {'data': data}));

  /// Сбрасывает сессию терминала, начиная новую.
  Future<Map<String, dynamic>> macTermReset() async =>
      _m(await _req('/mac/term/reset', method: 'POST', body: {}));

  // ---------- медиа ----------

  /// Сколько кадров в медиатеке. Галерея им не пользуется: её список курсорный, и полной
  /// высоты прокрутки у него нет. Число нужно прогреву миниатюр — по нему считается ход работы.
  Future<int> mediaCount({CancelToken? cancelToken}) async =>
      toNum(await _req('/media/count', cancelToken: cancelToken))?.toInt() ?? 0;

  /// Порция кадров ленты: [offset] — с какого начинать, [limit] — сколько отдать.
  ///
  /// Тоже только для прогрева миниатюр (`ThumbCache.warmLibrary`): он идёт по всей библиотеке
  /// страницами и нумерует их сам. Листание галереи ходит в [mediaFeed] — там адресом кадра
  /// служит он сам, а не номер, который сдвигается при каждой загрузке фото.
  Future<List<MediaItem>> mediaRange(int offset, int limit, {CancelToken? cancelToken}) async =>
      _lm(await _req('/media/range?offset=$offset&limit=$limit', cancelToken: cancelToken))
          .map(MediaItem.fromJson)
          .toList();

  /// Страница курсорной ленты — так галерея листает кадры.
  ///
  /// Направление задаётся одним из курсоров: [before] — кадры старше него (прокрутка в
  /// прошлое), [after] — новее (прокрутка к свежему). Оба сразу не передаются. Курсор с
  /// `at = null` адресует хвост ленты — кадры без даты съёмки, они идут после всех
  /// датированных (см. [MediaCursor]). Курсора нет — приходит начало ленты.
  ///
  /// [ids] — выборка конкретных записей без курсора: так синхронизация забирает изменившееся
  /// по журналу одним запросом. Список сервер режет до 500 id (`MEDIA_FEED_IDS_MAX`).
  ///
  /// Порядок кадров в ответе всегда ленты (свежие → старые), независимо от направления.
  Future<MediaFeedPage> mediaFeed({
    MediaCursor? before,
    MediaCursor? after,
    int limit = 200,
    List<String>? ids,
    CancelToken? cancelToken,
  }) async {
    final q = <String>['limit=$limit'];
    if (ids != null && ids.isNotEmpty) {
      q.add('ids=${Uri.encodeQueryComponent(ids.join(','))}');
    } else if (before != null) {
      // Пустой `before` — не «нет курсора», а курсор без даты: сервер различает эти случаи.
      q.add('before=${Uri.encodeQueryComponent(before.at ?? '')}');
      q.add('beforeId=${Uri.encodeQueryComponent(before.id)}');
    } else if (after != null) {
      q.add('after=${Uri.encodeQueryComponent(after.at ?? '')}');
      q.add('afterId=${Uri.encodeQueryComponent(after.id)}');
    }
    return MediaFeedPage.fromJson(_m(await _req('/media/feed?${q.join('&')}', cancelToken: cancelToken)));
  }

  /// Месяцы медиатеки со счётчиками кадров — из них строится таймлайн.
  ///
  /// [tzOffsetMin] — сдвиг пояса клиента в минутах на восток от UTC (Москва: `180`). Сервер
  /// считает бакет месяца как `capturedAt + tz`, поэтому без этого параметра кадр, снятый
  /// вечером последнего числа месяца, попадает в следующий бакет. Сервер ограничивает сдвиг
  /// диапазоном ±14 часов.
  Future<List<MediaMonthBucket>> mediaMonths({int? tzOffsetMin, CancelToken? cancelToken}) async {
    final tz = tzOffsetMin == null ? '' : '?tz=$tzOffsetMin';
    return _lm(await _req('/media/months$tz', cancelToken: cancelToken))
        .map(MediaMonthBucket.fromJson)
        .toList();
  }

  /// Байты превью для списка (квадрат-миниатюра) по хэшу содержимого.
  ///
  /// Отдельно от [previewUrl]: адрес нужен виджетам, которые умеют ходить в сеть сами
  /// (`CachedNetworkImage`), а этот метод — локальному хранилищу миниатюр, которое качает
  /// файл само и потом показывает его с диска. `w` — переключатель «сетка или полный экран»
  /// (см. [previewUrl]); здесь всегда сетка, то есть `w = 512`.
  ///
  /// Ошибки — как у остальных ручек: 404 значит «превью для этого файла нет» (ещё не собрано,
  /// собрать нельзя, либо чужой файл), и вызывающий обязан отличать его от сетевого сбоя:
  /// повторять 404 бессмысленно, а сбой — нужно.
  Future<Uint8List> previewBytes(String sha, {int w = 512, CancelToken? cancelToken}) async {
    try {
      final res = await _http.get<List<int>>(
        '/previews/${Uri.encodeComponent(sha)}?w=$w',
        cancelToken: cancelToken,
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(res.data ?? const []);
    } on DioException catch (e) {
      throw _toException(e);
    }
  }

  /// Состояния сборки превью для перечисленных кадров.
  ///
  /// Галерея зовёт это по видимым клеткам, у которых превью ещё не собрано: состояние приходит
  /// и вместе с кадром, но к моменту показа превью обычно только в очереди, и без перезапроса
  /// клетка оставалась бы серой. Список сервер режет до 500 id (`MEDIA_STATUS_MAX`), признака
  /// усечения в ответе нет — больше 500 за раз слать нельзя.
  Future<List<MediaStatusItem>> mediaStatus(List<String> entryIds) async =>
      _lm(await _req('/media/status', method: 'POST', body: {'entryIds': entryIds}))
          .map(MediaStatusItem.fromJson)
          .toList();

  /// Полные метаданные кадра: для просмотрщика и карточки параметров.
  Future<MediaInfo> mediaInfo(String entryId) async =>
      MediaInfo.fromJson(_m(await _req('/media/${Uri.encodeComponent(entryId)}')));

  /// Точки для карты (кадры с координатами и собранным превью); разбирает их экран карты.
  Future<Map<String, dynamic>> mediaMap({CancelToken? cancelToken}) async =>
      _m(await _req('/media/map', cancelToken: cancelToken));

  // ---------- очередь превью ----------

  /// Состояние очереди превью: счётчики, оценка срока по видам задач и место на диске сервера.
  Future<QueueStatus> queueStatus() async =>
      QueueStatus.fromJson(_m(await _req('/queue/status')));

  /// Ставит задачу сборки превью для одного файла в очередь заново — после ошибки или отмены.
  Future<void> retryPreview(String entryId) async =>
      _req('/queue/retry', method: 'POST', body: {'entryId': entryId});

  /// Ставит в очередь пересчёт превью тем файлам, у которых их нет.
  ///
  /// Ходит только по базе и отвечает сразу: сама сборка идёт в очереди, состояние видно в
  /// [queueStatus].
  Future<Map<String, dynamic>> rebuildPreviews() async =>
      _m(await _req('/queue/rebuild', method: 'POST', body: {}));

  /// Убирает из очереди все строки задач — и ожидающие, и упавшие.
  ///
  /// Это очистка списка, а не откат превью: уже собранное лежит на самом файле и остаётся на
  /// месте. Задача, которая считается прямо сейчас, не прерывается.
  Future<Map<String, dynamic>> clearQueue() async =>
      _m(await _req('/queue/clear', method: 'POST', body: {}));

  /// Ставит очередь на паузу или снимает её: сама задача в работе не прерывается.
  Future<void> setQueuePaused(bool paused) async =>
      _req('/queue/pause', method: 'POST', body: {'paused': paused});

  /// Последние ошибки очереди: по [limit] записей, начиная с [offset].
  ///
  /// Сервер режет список сам (`take` ограничен двумя сотнями), поэтому экран листает его
  /// страницами и показывает общее число из [QueueErrorPage.total].
  Future<QueueErrorPage> queueErrors({int limit = 50, int offset = 0}) async =>
      QueueErrorPage.fromJson(
        _m(await _req('/queue/errors?limit=$limit&offset=$offset')),
      );

  /// Возвращает в очередь все упавшие задачи сразу — то же, что «повторить», но пачкой.
  ///
  /// Ответ сервера — `{retried: N}`; число возвращаем как есть, потому что экран показывает
  /// его в сообщении («возвращено 12 задач»), а своей модели для одного числа не заводим.
  Future<int> retryQueueErrors() async =>
      toNum(_m(await _req('/queue/errors/retry', method: 'POST', body: {}))['retried'])
              ?.toInt() ??
          0;

  // ---------- разархивирование ----------

  /// Запускает разархивирование файла-архива; работа идёт на сервере, ответ приходит сразу.
  Future<UnzipJob> startUnzip(String entryId) async =>
      UnzipJob.fromJson(_m(await _req('/unzip', method: 'POST', body: {'entryId': entryId})));

  /// Текущее состояние задачи разархивирования по её id — им обновляется прогресс.
  Future<UnzipJob> unzipStatus(String id) async =>
      UnzipJob.fromJson(_m(await _req('/unzip/$id')));

  /// Последняя задача разархивирования для файла, или `null`, если её не было.
  ///
  /// Нужна после перезапуска экрана: открыть деталку и снова показать прогресс, не зная id задачи.
  Future<UnzipJob?> latestUnzip(String entryId) async {
    final d = await _req('/unzip?entryId=${Uri.encodeComponent(entryId)}');
    // null — обычный случай (файл ещё не распаковывали), а не ошибка.
    if (d == null) return null;
    return UnzipJob.fromJson(_m(d));
  }

  /// Отменяет разархивирование: уже распакованные файлы остаются, задача помечается отменённой.
  Future<UnzipJob> cancelUnzip(String id) async =>
      UnzipJob.fromJson(_m(await _req('/unzip/$id/cancel', method: 'POST')));

  // ---------- почта ----------

  /// Подключённые почтовые аккаунты с состоянием синхронизации.
  Future<List<MailAccountRow>> mailAccounts() async =>
      _lm(await _req('/mail/accounts')).map(MailAccountRow.fromJson).toList();

  /// Просит сервер забрать почту сейчас, не дожидаясь расписания.
  ///
  /// Ответ приходит сразу, а проход идёт в фоне — результат смотрят по [mailStatus].
  Future<Map<String, dynamic>> mailSync() async =>
      _m(await _req('/mail/sync', method: 'POST'));

  /// Сколько писем в папке [box]; [account] ограничивает одним аккаунтом.
  ///
  /// Число нужно, чтобы список знал полную высоту прокрутки и не тянул сразу все письма.
  Future<int> mailCount(String box, {String? account, CancelToken? cancelToken}) async {
    // Значения параметров кодируем: в `box`/`account` может приехать адрес почты с `&` или `+`,
    // и без кодирования сервер получил бы другой параметр или неизвестную папку.
    final a = (account == null || account.isEmpty)
        ? ''
        : '&account=${Uri.encodeQueryComponent(account)}';
    return toNum(await _req(
      '/mail/count?box=${Uri.encodeQueryComponent(box)}$a',
      cancelToken: cancelToken,
    ))?.toInt() ?? 0;
  }

  /// Порция писем папки [box] — [offset] и [limit], как в медиатеке.
  Future<List<MailListItem>> mailRange(String box, int offset, int limit,
      {String? account, CancelToken? cancelToken}) async {
    final a = (account == null || account.isEmpty)
        ? ''
        : '&account=${Uri.encodeQueryComponent(account)}';
    return _lm(await _req(
      '/mail/range?box=${Uri.encodeQueryComponent(box)}&offset=$offset&limit=$limit$a',
      cancelToken: cancelToken,
    )).map(MailListItem.fromJson).toList();
  }

  /// Месяцы ленты почты со счётчиками писем.
  Future<List<MailMonthBucket>> mailMonths(String box,
      {String? account, CancelToken? cancelToken}) async {
    final a = (account == null || account.isEmpty)
        ? ''
        : '&account=${Uri.encodeQueryComponent(account)}';
    return _lm(await _req(
      '/mail/months?box=${Uri.encodeQueryComponent(box)}$a',
      cancelToken: cancelToken,
    )).map(MailMonthBucket.fromJson).toList();
  }

  /// Поиск по письмам папки [box]: ищем по всему телу письма, а не только по теме.
  ///
  /// Область поиска — открытая папка (это решение владельца), порядок — по дате от свежих
  /// к старым. Ответ — [MailSearchPage]: страница строк той же формы, что и у ленты, плюс
  /// `total` (сколько всего нашлось) и `pending` (сколько писем папки ещё не в поисковом
  /// индексе — сервер разбирает старый архив фоном).
  ///
  /// [cancelToken] нужен не для красоты: поиск идёт по мере набора текста, и без отмены
  /// ответы на прежние запросы приходили бы после новых и перебивали выдачу.
  Future<MailSearchPage> mailSearch(
    String box,
    String q, {
    int offset = 0,
    int limit = 50,
    String? account,
    CancelToken? cancelToken,
  }) async {
    final a = (account == null || account.isEmpty)
        ? ''
        : '&account=${Uri.encodeQueryComponent(account)}';
    return MailSearchPage.fromJson(_m(await _req(
      '/mail/search?box=${Uri.encodeQueryComponent(box)}&q=${Uri.encodeQueryComponent(q)}'
      '&offset=$offset&limit=$limit$a',
      cancelToken: cancelToken,
    )));
  }

  /// Письмо целиком: шапка, вложения и текстовая версия тела.
  Future<MailMessageView> mailMessage(String id, {CancelToken? cancelToken}) async =>
      MailMessageView.fromJson(
          _m(await _req('/mail/messages/${Uri.encodeComponent(id)}', cancelToken: cancelToken)));

  /// Тело письма для показа — всегда полная разметка вместе с картинками по ссылке.
  ///
  /// Ручка умеет и другое: `images=0` заставляет сервер вырезать внешние картинки (они же
  /// трекеры, по которым отправитель узнаёт, что письмо открыли), а `text=1` — отдать текстовую
  /// версию вместо разметки. Клиент не пользуется ни тем, ни другим: письмо показывается так,
  /// как его сверстали, а переключателя «текст или html» на экране нет по решению владельца.
  /// Флаги у сервера остаются: ими пользуются другие потребители API.
  Future<Map<String, dynamic>> mailBody(String id) async =>
      _m(await _req('/mail/messages/$id/body?images=1'));

  /// Перевод письма на русский локальной моделью на маке.
  ///
  /// Ответ приходит целиком, а не потоком: на маке перевод идёт десятки секунд, а длинное
  /// письмо — несколькими вызовами подряд. Поэтому таймаут на ответ здесь щедрый, а не общие
  /// 60 секунд. Повторный вызов обслужит кэш на сервере — модель второй раз не зовётся.
  Future<Map<String, dynamic>> mailTranslate(String id) async => _m(await _req(
        '/mail/messages/${Uri.encodeComponent(id)}/translate',
        method: 'POST',
        body: const <String, dynamic>{},
        // Потолок на весь перевод; на сервере такой же на один вызов модели (LLM_TIMEOUT_MS).
        receiveTimeout: const Duration(minutes: 10),
      ));

  /// Помечает письмо прочитанным или непрочитанным.
  Future<void> mailSetSeen(String id, bool seen) async =>
      _req('/mail/messages/$id/seen', method: 'POST', body: {'seen': seen});

  /// Убирает письмо в корзину почты — она отдельная от корзины файлов.
  Future<void> mailDelete(String id) async => _req('/mail/messages/$id', method: 'DELETE');

  /// Убирает в корзину почты пачку писем — то же, что [mailDelete], для списка с галочками.
  ///
  /// Одним запросом, а не циклом по [mailDelete]: сервер по списку id делает одно обновление,
  /// а N отдельных DELETE — это N транзакций и N перечитываний ленты.
  Future<void> mailDeleteMany(List<String> ids) async =>
      _req('/mail/messages/bulk-delete', method: 'POST', body: {'ids': ids});

  /// Отправляет письмо; тело запроса собирает экран (адресаты, текст, вложения).
  ///
  /// Возвращает ответ сервера как есть: модели для результата отправки нет.
  Future<Map<String, dynamic>> mailSend(Map<String, dynamic> body) async =>
      _m(await _req('/mail/send', method: 'POST', body: body));

  /// Заготовка ответа или пересылки: [mode] — `reply`, `replyAll` или `forward`.
  ///
  /// Адресатов, тему и цитату собирает сервер, чтобы письмо выглядело одинаково во всех
  /// почтовых клиентах.
  Future<MailReplyContext> mailReplyContext(String id, String mode) async =>
      MailReplyContext.fromJson(_m(await _req(
          '/mail/messages/${Uri.encodeComponent(id)}/reply-context?mode=${Uri.encodeQueryComponent(mode)}')));

  /// Возвращает письмо из корзины почты обратно в его папку.
  Future<void> mailRestore(String id) async =>
      _req('/mail/messages/$id/restore', method: 'POST', body: {});

  /// Удаляет письмо навсегда — только из корзины, вместе с вложениями и исходным `.eml`.
  Future<void> mailPurgeMessage(String id) async =>
      _req('/mail/messages/$id/purge', method: 'POST', body: {});

  /// Удаляет навсегда пачку писем — то же, что [mailPurgeMessage], для списка с галочками.
  ///
  /// Ручка сервера доступна только веб-сессии (как и одиночная очистка): безвозвратное удаление
  /// от имени device-токена не предусмотрено.
  Future<void> mailPurgeMany(List<String> ids) async =>
      _req('/mail/messages/bulk-purge', method: 'POST', body: {'ids': ids});

  /// Очищает корзину почты целиком; доступна только веб-сессии.
  Future<Map<String, dynamic>> mailPurgeTrash() async =>
      _m(await _req('/mail/trash/purge', method: 'POST', body: {}));

  // ---------- URL превью/скачивания ----------

  // Ссылки ниже ведут на закрытые ручки: запрос по ним нужно сопровождать [authHeaders], иначе
  // сервер ответит 401. Это касается картинок, видео и скачивания.
  /// Ссылка на содержимое файла; отдаётся как вложение (скачиванием).
  String fileUrl(String id) => '$baseUrl/files/$id/content';
  /// Ссылка на содержимое для показа внутри приложения (inline) — по ней файл открывает просмотрщик.
  String fileInlineUrl(String id) => '$baseUrl/files/$id/inline';
  /// Миниатюра записи: её показывают списки файлов и метки на карте.
  ///
  /// Адрес привязан к записи, а не к содержимому: при замене файла тем же именем id не меняется,
  /// а картинка за тем же адресом приходит уже другая. Кэш изображений об этом не знает, поэтому
  /// там, где содержимое записи может смениться, надёжнее [previewUrl] с sha256 (или свой
  /// `cacheKey` у виджета).
  String thumbUrl(String entryId) => '$baseUrl/files/$entryId/thumb';
  /// Превью по хешу содержимого.
  ///
  /// `w` — переключатель, а не размер: всё, что меньше 1080, отдаёт одну и ту же квадратную
  /// миниатюру для сетки (её собирает очередь), а 1080 и выше — полноразмерное превью для показа
  /// на весь экран. Значения между этими двумя размерами ничего не меняют, поэтому 512 —
  /// просто «сетка», и он же серверный по умолчанию.
  String previewUrl(String sha, {int w = 512}) => '$baseUrl/previews/$sha?w=$w';
  /// Страница PDF картинкой (нумерация с единицы); за пределами числа страниц сервер ответит 404.
  String pdfPageUrl(String sha, int page) => '$baseUrl/previews/$sha?page=$page';
  /// Видео-превью для полного экрана; `original` — играть сам оригинал.
  ///
  /// Оригинал нужен как запасной вариант: превью собирается в одном кодеке, а устройство может
  /// его не декодировать, тогда как исходное видео оно проигрывает.
  String videoPreviewUrl(String sha, {bool original = false}) =>
      '$baseUrl/video-preview/$sha${original ? '?src=original' : ''}';
  /// Логотип домена отправителя: его тянет и кэширует сервер, поэтому клиент в интернет не ходит.
  String faviconUrl(String domain) =>
      '$baseUrl/mail/favicon?domain=${Uri.encodeComponent(domain)}';
  /// Исходное письмо файлом `.eml`.
  String mailRawUrl(String id) => '$baseUrl/mail/messages/$id/raw';

  // ---------- загрузка ----------

  /// Размер части при загрузке через сервер (relay), если сервер не назвал свой потолок.
  ///
  /// 5 МиБ — это серверный минимум (`MIN_RELAY_PART_BYTES` в `src/uploads/uploads.service.ts`):
  /// часть короче S3 не принимает нигде, кроме последней. Столько же остаётся нашим потолком,
  /// когда сервер разрешает больше: часть целиком лежит в памяти телефона.
  static const int _relayPartBytes = 5 * 1024 * 1024;
  /// Размер порции при подсчёте sha256: файл хешируется потоково, целиком в память не читается.
  static const int _hashChunkBytes = 8 * 1024 * 1024;
  /// Сколько раз повторяем часть (и `complete`) при сбое.
  ///
  /// Сбой отдельной части на мобильной сети — обычное дело, а начинать из-за него всю загрузку
  /// заново не нужно.
  static const int _partAttempts = 3;
  /// Сколько раз повторяем `complete`: он идемпотентен, а терять уже переданное нельзя.
  static const int _completeAttempts = 3;
  /// Сколько ждёт ответ на `complete`.
  ///
  /// Сборка объекта идёт дольше обычного запроса: при прямой загрузке сервер считает sha256,
  /// читая объект из S3, и перекладывает его server-side copy — на многогигабайтном видео это
  /// минуты (в `src/s3/s3.service.ts` отмечено, что из-за этого запрос вылезал за 300 с nginx).
  /// Общий таймаут в 60 с здесь давал бы «не дождался ответа сервера» на уже загруженном файле.
  static const Duration _completeTimeout = Duration(minutes: 5);

  /// Потолок числа частей у S3: больше 10 000 он multipart не собирает.
  ///
  /// Считаем заранее и отказываемся до передачи байтов: иначе отказ пришёл бы на `complete`,
  /// когда всё уже залито (сервер проверяет этот лимит только для прямой загрузки).
  static const int _maxParts = 10000;

  /// Пауза между повторами, мс; умножается на номер попытки (700, 1400), чтобы не долбить сеть,
  /// которая только что отказала.
  static const int _retryBackoffMs = 700;

  /// Размер части, если сервер не прислал свой в ответе на начало загрузки (старая версия сервера).
  static const int _defaultPartBytes = 16 * 1024 * 1024;

  /// MIME-тип по расширению имени файла.
  ///
  /// Тип — не украшение: сервер по нему решает, какая задача конвертации ставится
  /// (`mediaKindOf`), попадёт ли файл в ленту «Медиа» и «Фото» (`captureAny` создаёт `MediaMeta`
  /// для любого `image/*` и для видео из `VIDEO_MIMES`) и с каким `Content-Type` он отдаётся
  /// телефону. Поэтому список повторяет серверные `IMAGE_MIMES`/`VIDEO_MIMES`
  /// (`src/media/media.service.ts`) и `KNOWN_MIMES` (`src/common/mime.ts`) — иначе `.avif`
  /// уезжал бы как `application/octet-stream` и не получал ни превью, ни места в медиатеке.
  ///
  /// Чего здесь намеренно нет: `.svg` (картинка-документ, её разметка исполняется — правильнее
  /// оставить её неизвестным типом) и редкие расширения без устоявшегося типа: они уходят как
  /// `application/octet-stream`, то есть как обычный файл, и это безопасно.
  String guessMime(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return _mimeByExt[ext] ?? 'application/octet-stream';
  }

  /// Соответствие «расширение → MIME» для [guessMime]. Вынесено из метода, чтобы список было
  /// видно целиком и он не собирался заново на каждый файл.
  static const Map<String, String> _mimeByExt = {
    // Картинки: список сервера плюс RAW камер, которые сервер тоже разбирает (EXIF из
    // TIFF-производных) — без строки MediaMeta они не появляются в «Фото» вовсе.
    'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'jpe': 'image/jpeg', 'png': 'image/png',
    'gif': 'image/gif', 'webp': 'image/webp', 'avif': 'image/avif', 'bmp': 'image/bmp',
    'jxl': 'image/jxl', 'heic': 'image/heic', 'heif': 'image/heif', 'tif': 'image/tiff',
    'tiff': 'image/tiff', 'dng': 'image/x-adobe-dng', 'cr2': 'image/x-canon-cr2',
    'nef': 'image/x-nikon-nef', 'arw': 'image/x-sony-arw', 'orf': 'image/x-olympus-orf',
    'rw2': 'image/x-panasonic-rw2', 'raf': 'image/x-fuji-raf',
    // Видео: те же типы, что в `VIDEO_MIMES`, плюс контейнеры старых телефонов и камер
    // (`video/3gpp` сервер пока не конвертирует — см. `mediaKindOf`, — но тип должен быть
    // верным: по нему файл отдаётся телефону).
    'mp4': 'video/mp4', 'm4v': 'video/x-m4v', 'mov': 'video/quicktime', 'webm': 'video/webm',
    'mkv': 'video/x-matroska', 'avi': 'video/avi', 'ogv': 'video/ogg', 'mpg': 'video/mpeg',
    'mpeg': 'video/mpeg', 'mpe': 'video/mpeg', 'm2v': 'video/mpeg', '3gp': 'video/3gpp',
    '3g2': 'video/3gpp2', 'ts': 'video/mp2t', 'm2ts': 'video/mp2t', 'wmv': 'video/x-ms-wmv',
    'flv': 'video/x-flv',
    // Документы и архивы: типы из `KNOWN_MIMES`, чтобы сервер не сводил их к
    // `application/octet-stream` и телефон открывал файл своим приложением.
    'pdf': 'application/pdf', 'txt': 'text/plain', 'md': 'text/markdown', 'csv': 'text/csv',
    'json': 'application/json', 'rtf': 'application/rtf', 'ics': 'text/calendar',
    'vcf': 'text/vcard', 'eml': 'message/rfc822', 'zip': 'application/zip',
    'rar': 'application/x-rar-compressed', '7z': 'application/x-7z-compressed',
    'gz': 'application/gzip', 'tar': 'application/x-tar', 'epub': 'application/epub+zip',
    'mobi': 'application/x-mobipocket-ebook', 'apk': 'application/vnd.android.package-archive',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'odt': 'application/vnd.oasis.opendocument.text',
    'ods': 'application/vnd.oasis.opendocument.spreadsheet',
  };

  /// Считает sha256 файла потоково, не загружая его в память целиком.
  ///
  /// Хеш нужен до начала загрузки: по нему сервер решает, не лежит ли точно такое содержимое у
  /// него уже. [onProgress] получает проценты по мере чтения — ими показывается фаза «считаю хеш».
  ///
  /// Возвращает hex-строку; у пустого файла это sha256 пустых данных (`e3b0c442…`) — сервер
  /// принимает такие файлы осознанно («Загрузки» телефона полны пустых файлов).
  Future<String> hashFile(String path, {void Function(int pct)? onProgress}) async {
    final f = File(path);
    final len = await f.length();
    final raf = await f.open();
    final out = _DigestSink();
    final sink = sha256.startChunkedConversion(out);
    // Закрываем дескриптор в finally: при ошибке чтения он иначе остался бы открытым.
    try {
      var off = 0;
      while (off < len) {
        // Читаем порциями: файл может быть на гигабайты, целиком в память его не взять.
        final want = math.min(_hashChunkBytes, len - off);
        await raf.setPosition(off);
        final bytes = await raf.read(want);
        // Файл мог укоротиться между подсчётом размера и чтением — тогда просто заканчиваем.
        if (bytes.isEmpty) break;
        sink.add(bytes);
        off += bytes.length;
        // Проценты считаем по фактически прочитанному: за один проход читается не весь файл.
        onProgress?.call((off * 100 / len).round());
      }
      // close() отдаёт дайджест и у пустого файла: он считается по нулю добавленных данных,
      // а не остаётся пустым.
      sink.close();
      return out.digest?.toString() ?? '';
    } finally {
      await raf.close();
    }
  }

  /// Начинает загрузку: сообщает серверу имя, размер, тип и хеш, а в ответ узнаёт, что делать
  /// дальше — дедупликация, прямая загрузка в S3 или части через сервер.
  ///
  /// [mode] — `direct` или `relay`; второй нужен, когда прямая загрузка не удалась. [folderId] —
  /// куда положить файл (`null` — в корень).
  ///
  /// [replace] и [replaceTrashed] разрешают занять имя, которое уже занято: без них сервер
  /// отвечает 409 `conflict` (имя занято живой записью) или 409 `in_trash` (файл с таким именем
  /// лежит в корзине), и загрузить файл с таким именем нечем. [clientMtime] — время файла с
  /// устройства: сервер хранит его отдельно от своего `updatedAt`, и синхронизация им пользуется.
  Future<UploadInit> _initUpload(
    String name,
    int size,
    String mime,
    String sha256hex,
    String mode, {
    String? folderId,
    bool replace = false,
    bool replaceTrashed = false,
    String? clientMtime,
  }) async {
    final d = await _req('/uploads', method: 'POST', body: {
      'name': name,
      'size': size,
      'mime': mime,
      'sha256': sha256hex,
      'mode': mode,
      'folderId': ?folderId,
      // Флаги шлём только когда их просят: в теле это часть контракта, а не значение по умолчанию.
      if (replace) 'replace': true,
      if (replaceTrashed) 'replaceTrashed': true,
      'clientMtime': ?clientMtime,
    });
    final j = _m(d);
    final deduped = j['deduped'] == true;
    return UploadInit(
      uploadId: j['uploadId'] as String?,
      deduped: deduped,
      direct: j['direct'] == true,
      // Размер части, назначенный сервером; запасное значение — на случай сервера, который его
      // не присылает.
      partSize: toNum(j['partSize'])?.toInt() ?? _defaultPartBytes,
      // Потолок части у relay: у сервера он свой (`UPLOAD_CHUNK_MAX_MB`), и заливать больше
      // нельзя — на каждый чанк придёт 413 `payload_too_large`.
      chunkMaxBytes: toNum(j['chunkMaxBytes'])?.toInt(),
      nextPart: toNum(j['nextPart'])?.toInt() ?? 1,
      entryId: _m(j['entry'] ?? const {})['id'] as String?,
    );
  }

  /// Состояние начатой загрузки (`GET /uploads/:id`) — им продолжается оборванная передача.
  ///
  /// Вызывается, когда у загрузки уже есть `uploadId` (его отдаёт [uploadFile] через `onSession`),
  /// а передача прервалась: сервер помнит принятые части и говорит, с какой продолжать
  /// ([UploadStatus.nextPart]). Если сессии уже нет, приходит 404 — это не ошибка, а повод
  /// начать загрузку заново.
  Future<UploadStatus> uploadStatus(String uploadId) async =>
      _status(_m(await _req('/uploads/${Uri.encodeComponent(uploadId)}')));

  /// Состояние сессии или `null`, если её больше нет: продолжать нечего, но и падать не за что.
  Future<UploadStatus?> _statusOrNull(String uploadId) async {
    try {
      return await uploadStatus(uploadId);
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// Разбирает ответ `GET /uploads/:id` (та же форма, что у `POST /uploads`).
  UploadStatus _status(Map<String, dynamic> j) => UploadStatus(
        uploadId: '${j['uploadId'] ?? ''}',
        direct: j['direct'] == true,
        partSize: toNum(j['partSize'])?.toInt() ?? _defaultPartBytes,
        chunkMaxBytes: toNum(j['chunkMaxBytes'])?.toInt(),
        nextPart: toNum(j['nextPart'])?.toInt() ?? 1,
        receivedParts: toNum(j['receivedParts'])?.toInt() ?? 0,
        size: toNum(j['size'])?.toInt() ?? 0,
        name: '${j['name'] ?? ''}',
        folderId: j['folderId'] is String ? j['folderId'] as String : null,
      );

  /// Сообщает серверу, что загрузку бросаем: иначе недособранная запись висела бы у него как
  /// незавершённая до очистки.
  ///
  /// Ошибку глотаем: метод зовут в том числе из обработчика другой ошибки, и его собственный сбой
  /// не должен подменять исходную причину.
  Future<void> _abortUpload(String uploadId) async {
    try {
      await _http.delete('/uploads/${Uri.encodeComponent(uploadId)}');
      // Глушим намеренно: см. документацию метода — этот вызов идёт по пути обработки другой ошибки.
    } catch (_) {}
  }

  /// Просит presigned-ссылку на одну часть и возвращает её.
  ///
  /// 404 и 405 означают, что сервер таких ссылок не выдаёт (старая версия или выключенный режим):
  /// это не сбой запроса, а повод перейти на загрузку через сервер — отсюда [DirectUnavailable].
  Future<String> _presignPart(String uploadId, int part) async {
    try {
      final j = _m(await _req('/uploads/$uploadId/url/$part'));
      return j['url'] as String? ?? '';
    } on ApiException catch (e) {
      // Сервер не умеет выдавать ссылки: это не ошибка запроса, а сигнал переключиться на relay.
      // Повторять такую попытку незачем — ссылок не появится.
      if (e.status == 404 || e.status == 405) {
        throw DirectUnavailable('сервер не поддерживает прямую загрузку в S3', retryable: false);
      }
      rethrow;
    }
  }

  /// Отправляет одну часть прямо в S3 по presigned-ссылке и возвращает её ETag.
  ///
  /// ETag обязателен: без него сервер не соберёт объект из частей, поэтому его отсутствие тоже
  /// считается недоступностью прямой загрузки. Любой сетевой сбой приводится к
  /// [DirectUnavailable], чтобы вызывающий мог переключиться на загрузку через сервер.
  Future<String> _putPartDirect(String url, Uint8List bytes,
      {void Function(int loaded)? onBytes}) async {
    try {
      final res = await _s3.put<List<int>>(url, data: bytes,
          options: Options(
            contentType: 'application/octet-stream',
            responseType: ResponseType.plain,
          ),
          onSendProgress: (sent, total) => onBytes?.call(sent));
      final etag = res.headers.value('etag');
      if (etag == null || etag.isEmpty) throw DirectUnavailable('S3 не отдал ETag');
      // S3 отдаёт ETag в кавычках, а для сборки объекта он нужен без них.
      return etag.replaceAll('"', '');
    } on DirectUnavailable {
      rethrow;
    } on DioException catch (e) {
      throw DirectUnavailable('сеть до S3: ${e.message}');
    } catch (e) {
      // Причина важна для разбора жалоб «загрузка падает в relay»: без неё в подписи остаётся
      // только «не удалось», и непонятно, был это отказ S3 или ошибка разбора ответа.
      throw DirectUnavailable('прямая загрузка в S3 не удалась: $e');
    }
  }

  /// Сообщает серверу, что часть уже лежит в S3: без этого он про неё не знает и объект не
  /// соберёт.
  Future<void> _registerPart(String uploadId, int part, String etag, int size) async {
    await _req('/uploads/${Uri.encodeComponent(uploadId)}/parts/$part',
        method: 'PUT', body: {'etag': etag, 'size': size});
  }

  /// Отправляет часть через сервер (режим relay) — обычным телом запроса, без S3.
  ///
  /// Тело — байты, а не JSON, поэтому запрос идёт мимо [_req]: тот ставит JSON-заголовки.
  /// Ошибку приводим тем же [_toException], чтобы вызывающий разбирал её как [ApiException]
  /// (по ней решается, повторять часть или нет).
  Future<void> _relayChunk(String uploadId, int part, Uint8List bytes) async {
    try {
      await _http.put('/uploads/${Uri.encodeComponent(uploadId)}/chunks/$part',
          data: bytes,
          options: Options(contentType: 'application/octet-stream', responseType: ResponseType.plain));
    } on DioException catch (e) {
      throw _toException(e);
    }
  }

  /// Завершает загрузку: сервер собирает объект из частей и проверяет итоговый sha256.
  ///
  /// Возвращает id записи и признак дедупликации: при сборке может выясниться, что такое
  /// содержимое уже есть, и тогда новая копия не создаётся.
  ///
  /// Сбой здесь повторяем, и это важно: сервер сделал `complete` идемпотентным (результат
  /// сохраняется в сессии) именно ради повтора после потерянного ответа. Повторять тем более
  /// необходимо, что к этому моменту все байты уже доехали: отказ из-за таймаута означал бы
  /// «видео не загрузилось» на полностью переданном файле.
  Future<UploadResult> _complete(String uploadId, String sha256hex) async {
    ApiException? last;
    for (var attempt = 1; attempt <= _completeAttempts; attempt++) {
      try {
        final j = _m(await _req('/uploads/${Uri.encodeComponent(uploadId)}/complete',
            method: 'POST',
            body: {'sha256': sha256hex},
            receiveTimeout: _completeTimeout));
        final entry = _m(j['entry'] ?? const {});
        final id = entry['id'];
        // Пустой id — расхождение с контрактом: с ним запись в дереве не открыть, и лучше
        // сказать это прямо, чем вернуть «загружено» с пустым идентификатором.
        if (id is! String || id.isEmpty) {
          throw ApiException(0, 'upload_entry_missing', 'сервер не вернул запись о загруженном файле');
        }
        return UploadResult(id, j['deduped'] == true);
      } on ApiException catch (e) {
        last = e;
        if (!e.retryable || attempt == _completeAttempts) rethrow;
        await Future.delayed(_retryDelay(attempt, e));
      }
    }
    // Сюда не дойти: последняя попытка либо вернула результат, либо бросила.
    throw last ?? ApiException(0, '', 'загрузка не завершилась');
  }

  /// Читает кусок файла `[start, end)` в память.
  ///
  /// Файл каждый раз открывается заново: держать дескриптор на время долгой загрузки не стоит,
  /// а в `finally` он закрывается даже при ошибке чтения.
  ///
  /// Читается ровно `end - start` байт: короткий кусок уехал бы как часть меньшего размера, и
  /// расхождение вскрылось бы только на `complete` («в S3 N байт, ожидалось M»), когда вся
  /// передача уже потеряна.
  Future<Uint8List> _readRange(String path, int start, int end) async {
    final want = end - start;
    final raf = await File(path).open();
    // Закрываем всегда: без этого на каждой попытке оставался бы открытый дескриптор.
    try {
      await raf.setPosition(start);
      final buf = BytesBuilder(copy: false);
      // `read` может вернуть меньше запрошенного — дочитываем, пока не наберём кусок целиком.
      while (buf.length < want) {
        final chunk = await raf.read(want - buf.length);
        if (chunk.isEmpty) break;
        buf.add(chunk);
      }
      final bytes = buf.takeBytes();
      if (bytes.length != want) {
        throw ApiException(0, 'file_short_read',
            'файл на диске короче, чем ожидалось: прочитано ${bytes.length} из $want байт');
      }
      return bytes;
    } finally {
      await raf.close();
    }
  }

  /// Загружает файл в облако: считает хеш, договаривается с сервером и передаёт части.
  ///
  /// [folderId] — куда положить (`null` — в корень), [name] — имя для записи в облаке, если оно
  /// должно отличаться от имени файла на диске (очередь выгрузки передаёт здесь имя из задания).
  /// [onProgress] получает проценты, фазу (`hash`, `upload`, `relay`, `verify`) и пояснение для
  /// подписи — номер части или причину перехода на загрузку через сервер.
  ///
  /// [replace] и [replaceTrashed] — решение человека по конфликту имён: без них сервер отвечает
  /// 409 `conflict` (имя занято) или 409 `in_trash` (файл с таким именем лежит в корзине), и
  /// загрузить файл с этим именем нельзя ничем. Разбирать конфликт — дело вызывающего: коды
  /// приходят в [ApiException.code]. [clientMtime] — время файла с устройства, его сервер
  /// хранит отдельно от своего `updatedAt`.
  ///
  /// [resumeUploadId] продолжает оборванную загрузку: сессию сверяем с файлом (имя и размер) и
  /// её содержимым (sha256 считается заново — файл мог измениться), после чего части идут с
  /// `nextPart`, который помнит сервер. [onSession] отдаёт id начатой сессии — его и нужно
  /// сохранить, чтобы потом передать в [resumeUploadId].
  ///
  /// Возвращает id записи в облаке; если сервер нашёл такое же содержимое по sha256, загрузка не
  /// начинается вовсе и возвращается существующая запись с `deduped: true`.
  ///
  /// Побочные эффекты: чтение файла с диска и запись частей в облако. Начатая сессия отменяется
  /// на сервере только тогда, когда повторять нечего (сервер ответил 4xx или файл не прочитался):
  /// при обрыве связи она остаётся живой, чтобы загрузку можно было продолжить.
  Future<UploadResult> uploadFile(
    String path, {
    String? folderId,
    String? name,
    bool replace = false,
    bool replaceTrashed = false,
    DateTime? clientMtime,
    String? resumeUploadId,
    void Function(String uploadId)? onSession,
    void Function(int pct, String phase, String? note)? onProgress,
  }) async {
    // Имя берём из пути, если своё не передали: последний сегмент пути и есть имя файла.
    final fileName = name ?? path.split('/').last;
    final mime = guessMime(fileName);
    final f = File(path);
    final size = await f.length();

    // Докачка: вызывающий сохранил id сессии от прошлой попытки. Доливать в неё можно только
    // тот же самый файл, поэтому сверяем имя и размер из сессии, а содержимое проверяем хешем:
    // файл мог измениться, и тогда части «прошлой версии» склеились бы с новыми.
    if (resumeUploadId != null && resumeUploadId.isNotEmpty) {
      final st = await _statusOrNull(resumeUploadId);
      if (st != null && st.size == size && st.name == fileName) {
        final sha = await hashFile(path, onProgress: (p) => onProgress?.call(p, 'hash', null));
        final from = st.resumePart;
        onProgress?.call(0, 'upload', 'продолжаю с части $from');
        // Режим берём из сессии: сервер сводит части в один multipart по номерам, и менять
        // способ передачи на середине нельзя.
        final resumeInit = UploadInit(
          uploadId: st.uploadId,
          deduped: false,
          direct: st.direct,
          partSize: st.partSize,
          chunkMaxBytes: st.chunkMaxBytes,
          nextPart: from,
        );
        return _transfer(
          init: resumeInit,
          path: path,
          fileName: fileName,
          size: size,
          mime: mime,
          sha256hex: sha,
          folderId: folderId,
          replace: replace,
          replaceTrashed: replaceTrashed,
          clientMtime: clientMtime,
          onSession: onSession,
          onProgress: onProgress,
        );
      }
      // Сессии нет, или она про другой файл — начинаем заново, как если бы id не передавали.
    }

    // Хеш считается до первого запроса: по нему сервер решает, не лежит ли такое содержимое у него уже.
    final sha256hex = await hashFile(path, onProgress: (p) => onProgress?.call(p, 'hash', null));
    // Прогресс сбрасываем в ноль: подсчёт хеша показывал свои проценты, и без сброса полоса пошла бы назад.
    onProgress?.call(0, 'upload', null);

    final init = await _initUpload(fileName, size, mime, sha256hex, 'direct',
        folderId: folderId,
        replace: replace,
        replaceTrashed: replaceTrashed,
        clientMtime: _isoOrNull(clientMtime));
    // Дедупликация: содержимое уже есть на сервере — загружать нечего, отдаём готовую запись.
    if (init.deduped && init.entryId != null) {
      return UploadResult(init.entryId!, true);
    }
    // Если загрузка нужна, id обязан быть. Проверяем это явно: `!` превратил бы расхождение
    // с контрактом сервера в TypeError без объяснения, а человек увидел бы в очереди загрузки
    // «Null check operator used on a null value» вместо причины.
    final uploadId = init.uploadId;
    if (uploadId == null || uploadId.isEmpty) {
      throw ApiException(0, 'upload_id_missing', 'сервер начал загрузку, но не вернул её id');
    }

    return _transfer(
      init: init,
      path: path,
      fileName: fileName,
      size: size,
      mime: mime,
      sha256hex: sha256hex,
      folderId: folderId,
      replace: replace,
      replaceTrashed: replaceTrashed,
      clientMtime: clientMtime,
      onSession: onSession,
      onProgress: onProgress,
    );
  }

  /// Ведёт начатую сессию до `complete`: части прямо в S3 или через сервер, отмена сессии на
  /// терминальной ошибке и повтор `complete` (он идемпотентен).
  ///
  /// Начинает с части [UploadInit.nextPart]: у свежей сессии это 1, у продолженной — номер,
  /// который назвал сервер. [onSession] сообщает id каждой начатой сессии, включая ту, что
  /// заведена после перехода с прямой загрузки на relay.
  Future<UploadResult> _transfer({
    required UploadInit init,
    required String path,
    required String fileName,
    required int size,
    required String mime,
    required String sha256hex,
    required String? folderId,
    required bool replace,
    required bool replaceTrashed,
    required DateTime? clientMtime,
    void Function(String uploadId)? onSession,
    void Function(int pct, String phase, String? note)? onProgress,
  }) async {
    var uploadId = init.uploadId!;
    final startPart = init.nextPart;
    // Отдаём id наружу: без него оборванную загрузку не продолжить (см. [resumeUploadId]).
    // Зовём и при смене сессии (переход direct → relay): продолжать придётся именно её.
    onSession?.call(uploadId);
    // С этого места загрузка на сервере начата: ошибка ниже либо отменяет её, либо оставляет
    // живой для продолжения — см. catch в конце.
    try {
      if (size > 0) {
        if (init.direct) {
          // Прямая загрузка может сорваться на любом шаге. Тогда начинаем ту же загрузку заново
          // в режиме relay: серверу нужен новый uploadId под другой режим, а старую попытку
          // отменяем, чтобы её части не остались висеть.
          try {
            await _uploadDirect(path, uploadId, init.partSize, size, onProgress,
                startPart: startPart);
          } on DirectUnavailable catch (e) {
            await _abortUpload(uploadId);
            final relay = await _initUpload(fileName, size, mime, sha256hex, 'relay',
                folderId: folderId,
                replace: replace,
                replaceTrashed: replaceTrashed,
                clientMtime: _isoOrNull(clientMtime));
            // Вторая попытка тоже может упереться в дедупликацию: пока лились части,
            // такой файл мог загрузить другой клиент.
            if (relay.deduped && relay.entryId != null) return UploadResult(relay.entryId!, true);
            final relayId = relay.uploadId;
            if (relayId == null || relayId.isEmpty) {
              throw ApiException(0, 'upload_id_missing', 'сервер начал загрузку, но не вернул её id');
            }
            uploadId = relayId;
            onSession?.call(uploadId);
            onProgress?.call(0, 'relay', e.message);
            await _uploadRelay(path, uploadId, size, _relayChunkBytes(relay), onProgress);
          }
        } else {
          await _uploadRelay(path, uploadId, size, _relayChunkBytes(init), onProgress,
              startPart: startPart);
        }
      }
      // Пустой файл (size == 0) частей не шлёт вовсе: сервер такой случай знает и на `complete`
      // без частей кладёт пустой объект одним PUT, а часть нулевой длины в S3 не нужна.
      //
      // Сборка объекта идёт на сервере и занимает время — показываем её отдельной фазой.
      onProgress?.call(100, 'verify', null);
      return await _complete(uploadId, sha256hex);
    } catch (e) {
      // Сессию отменяем только тогда, когда повторять нечего: сервер сказал, что запрос неверен
      // (не сошёлся sha256, части не дошли, имя занято) или сломалось чтение файла с диска.
      // Таймаут, обрыв связи и 5xx — наоборот, повод не терять переданное: сессию сервер держит
      // ещё часы, `complete` идемпотентен, а продолженная загрузка начинается с `nextPart`.
      if (!(e is ApiException && e.retryable)) await _abortUpload(uploadId);
      rethrow;
    }
  }

  /// Размер чанка для relay: свой бюджет памяти или серверный потолок — что меньше.
  ///
  /// Меньше 5 МиБ брать нельзя (S3 не примет такую часть, кроме последней), поэтому сервер,
  /// у которого потолок ниже, — это его неверная настройка, и человеку нужно сказать об этом
  /// прямо, а не получать 413 на каждом чанке.
  int _relayChunkBytes(UploadInit init) {
    final max = init.chunkMaxBytes;
    if (max == null || max <= 0) return _relayPartBytes;
    if (max < _relayPartBytes) {
      throw ApiException(
        413,
        'payload_too_large',
        'сервер принимает части не больше ${max ~/ (1024 * 1024)} МБ, а S3 не принимает части '
            'меньше 5 МБ — поднимите UPLOAD_CHUNK_MAX_MB на сервере',
      );
    }
    return math.min(max, _relayPartBytes);
  }

  /// Передаёт файл частями прямо в S3, повторяя неудачные части.
  ///
  /// Сбой отдельной части загрузку не срывает: до [_partAttempts] попыток с растущей паузой, и
  /// только после них наверх уходит [DirectUnavailable] — тогда вызывающий переходит на
  /// загрузку через сервер.
  ///
  /// [startPart] — с какой части продолжать: у продолженной сессии сервер помнит принятое, и
  /// передавать заново то, что уже лежит в S3, незачем.
  Future<void> _uploadDirect(String path, String uploadId, int partSize, int size,
      void Function(int pct, String phase, String? note)? onProgress,
      {int startPart = 1}) async {
    // Частей считаем хотя бы одну — индекс в `loaded` начинается с единицы. Пустой файл сюда не
    // доходит вовсе (см. [_transfer]), но арифметика всё равно защищена от нуля: при `size == 0`
    // вышло бы `0 / 0` = NaN, а `NaN.floor()` бросает UnsupportedError — и человек увидел бы
    // в очереди загрузки «Unsupported operation: NaN» вместо строки о файле.
    final total = math.max(1, (size / partSize).ceil());
    // loaded[part] — сколько байт ушло по этой части. Прогресс складывается из частей, потому что
    // внутри части Dio сообщает только её собственный счётчик, а не общий.
    final loaded = List<int>.filled(total + 1, 0);
    void report(String? note) {
      var sum = 0;
      for (final n in loaded) {
        sum += n;
      }
      // min(100, …) — страховка от округления вверх на последней части, а проверка на пустой
      // файл — от деления на ноль: 0/0 даёт NaN, и `NaN.floor()` бросает UnsupportedError.
      onProgress?.call(
          size <= 0 ? 100 : math.min(100, (sum * 100 / size).floor()), 'upload', note);
    }

    // Продолжение: уже принятые части считаем переданными, иначе полоса прогресса начиналась бы
    // с нуля на почти законченной загрузке.
    for (var part = 1; part < startPart && part <= total; part++) {
      final from = (part - 1) * partSize;
      loaded[part] = math.min(partSize, size - from);
    }

    for (var part = math.max(1, startPart); part <= total; part++) {
      final start = (part - 1) * partSize;
      // Конец не дальше размера файла: последняя часть обычно короче остальных.
      final end = math.min(size, start + partSize);
      report('часть $part из $total');
      final bytes = await _readRange(path, start, end);
      var lastErr = '';
      var ok = false;
      for (var attempt = 1; attempt <= _partAttempts; attempt++) {
        try {
          // Ссылку берём на каждую попытку заново: presigned-адрес живёт четверть часа, и повтор
          // по просроченной ссылке получил бы 403 вместо загрузки.
          final url = await _presignPart(uploadId, part);
          final etag = await _putPartDirect(url, bytes, onBytes: (n) {
            loaded[part] = n;
            report('часть $part из $total');
          });
          await _registerPart(uploadId, part, etag, bytes.length);
          // Ставим фактический размер части: onSendProgress мог не дойти до её конца.
          loaded[part] = bytes.length;
          report('часть $part из $total');
          ok = true;
          break;
        } on DirectUnavailable catch (e) {
          // «Сервер вовсе не выдаёт ссылок» — это не сбой части, а повод уйти в relay целиком.
          if (!e.retryable) rethrow;
          lastErr = e.message;
          if (attempt < _partAttempts) {
            report('$lastErr — повторяю (попытка ${attempt + 1})');
            await Future.delayed(_retryDelay(attempt, null));
          }
        } on ApiException catch (e) {
          // Пресайн и регистрация части ходят через сервер: 500 или обрыв связи — такой же повод
          // повторить часть, как и сбой заливки в S3. Терминальное «часть не та» — не повод.
          if (!e.retryable) rethrow;
          lastErr = e.message;
          if (attempt < _partAttempts) {
            report('$lastErr — повторяю (попытка ${attempt + 1})');
            await Future.delayed(_retryDelay(attempt, e));
          }
        }
      }
      // Все попытки исчерпаны: наверх уходит последняя причина, а не общее «не получилось».
      if (!ok) throw DirectUnavailable(lastErr.isEmpty ? 'часть $part не загрузилась' : lastErr);
    }
  }

  /// Передаёт файл частями через сервер: каждая часть — отдельный запрос с телом.
  ///
  /// Повтор части здесь идемпотентен: сервер считает повторно присланную часть дубликатом
  /// (`duplicate: true` в ответе), поэтому обрыв на середине не требует начинать заново.
  /// [startPart] — с какой части продолжать оборванную передачу (её номер считает сервер и
  /// отдаёт в [uploadStatus]).
  Future<void> _uploadRelay(String path, String uploadId, int size, int partBytes,
      void Function(int pct, String phase, String? note)? onProgress,
      {int startPart = 1}) async {
    // Минимум одна часть: части считаем от размера чанка, а начинаем с той, которую просит
    // продолжить сервер.
    final parts = math.max(1, (size / partBytes).ceil());
    if (parts > _maxParts) {
      // S3 не собирает multipart больше 10 000 частей: отказ пришёл бы уже после того, как всё
      // залито, поэтому отказываемся до первой части.
      throw ApiException(
        413,
        'payload_too_large',
        'файл разбивается на $parts частей, а S3 собирает не больше $_maxParts — '
            'поднимите UPLOAD_CHUNK_MAX_MB на сервере',
      );
    }
    for (var part = math.max(1, startPart); part <= parts; part++) {
      final start = (part - 1) * partBytes;
      final end = math.min(size, start + partBytes);
      final bytes = await _readRange(path, start, end);
      // Части идут по порядку, а сборка объекта начинается только на /complete.
      await _relayChunkWithRetry(uploadId, part, bytes, parts, onProgress);
      onProgress?.call(((part / parts) * 100).round(), 'relay', 'часть $part из $parts');
    }
  }

  /// Отправляет одну часть через сервер, повторяя транзиентные сбои.
  ///
  /// Повтор той же самой части безопасен: сервер отвечает на неё как на дубликат, а не как на
  /// «часть не по порядку».
  Future<void> _relayChunkWithRetry(String uploadId, int part, Uint8List bytes, int parts,
      void Function(int pct, String phase, String? note)? onProgress) async {
    for (var attempt = 1; ; attempt++) {
      try {
        await _relayChunk(uploadId, part, bytes);
        return;
      } on ApiException catch (e) {
        // Терминальное (сессия истекла после рестарта сервера, файл не тот) — повторять нечем.
        if (!e.retryable || attempt >= _partAttempts) rethrow;
        onProgress?.call(((part - 1) / parts * 100).round(), 'relay',
            '${e.message} — повторяю часть $part (попытка ${attempt + 1})');
        await Future.delayed(_retryDelay(attempt, e));
      }
    }
  }

  /// Пауза перед повтором: названный сервером срок ([ApiException.retryAfterSec] у 429) важнее
  /// нашей лесенки — долбить сервер, который просил подождать, бессмысленно.
  Duration _retryDelay(int attempt, ApiException? e) {
    final sec = e?.retryAfterSec;
    if (sec != null && sec > 0) return Duration(seconds: math.min(sec, 120));
    return Duration(milliseconds: _retryBackoffMs * attempt);
  }
}
