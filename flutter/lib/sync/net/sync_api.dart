import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../device/hasher.dart';

/// Ошибка сервера с кодом из тела ответа (409 stale_version, 429 и т.п.).
///
/// Единый вид ошибки для всего клиента синхронизации: сетевые сбои Dio тоже приводятся к ней
/// (со `status` 0), поэтому вызывающим достаточно ловить один тип. Пользуются ею все, кто ходит
/// в облако: движок зеркала, очередь выгрузки, проверка device-токена.
///
/// `status` 0 — ответа не было вовсе (обрыв, таймаут) **или** ответ пришёл не той формы
/// (см. [_mOrThrow]): и то и другое значит «повторить позже», а не «сервер сказал нет».
class SyncApiException implements Exception {
  /// [status] — код HTTP (0, если ответа не было вовсе); [code] — машинный код из тела ответа
  /// (`stale_version`, `in_trash`…), пустая строка, если сервер его не прислал; [message] —
  /// текст, который можно показать человеку.
  const SyncApiException(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  /// В интерфейс и логи уходит человеческий текст: код HTTP сам по себе ничего не объясняет.
  @override
  String toString() => message;
}

/// Прямой путь до хранилища не работает: presigned-ссылка не отвечает (сеть, VPN,
/// блокировщик) или сервер их вовсе не выдаёт.
///
/// Наследник [IOException] намеренно: для вызывающих это «попробовать иначе» (релеем через
/// сервер), а не «сервер сказал „нет“, повторять бессмысленно». Смешать эти случаи нельзя —
/// иначе либо лишний релей на каждую ошибку, либо вечное упрямство с мёртвым хостом.
class SyncDirectUnavailable implements IOException {
  /// [message] — причина, которую видно в итогах прохода и в логе: без имени хоста или кода
  /// ответа непонятно, что именно чинить.
  const SyncDirectUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Запись в облаке в том виде, в каком её видит зеркало.
///
/// Приходит метаданными файла ([SyncApi.entryMeta]) и содержимым папки ([SyncApi.children]);
/// по ней зеркало решает, что уже выгружено, а что надо тянуть или заливать. Строка журнала —
/// отдельный тип ([CloudChange]): там рядом с данными записи лежат ещё `seq` и операция.
class RemoteEntry {
  /// Все поля, кроме [clientMtime] и [folderId], обязательны: отсутствие имени или хэша
  /// означало бы запись, о которой нечего решить, и заполнять их пустышками нельзя.
  const RemoteEntry({
    required this.id,
    required this.name,
    required this.size,
    required this.mime,
    required this.sha256,
    this.clientMtime,
    this.folderId,
  });

  final String id;
  final String name;
  final int size;

  /// Mime, как его хранит сервер; пустая строка — тип неизвестен.
  final String mime;

  /// SHA-256 содержимого: по нему зеркало отличает «то же самое» от «изменилось» и не гоняет
  /// байты зря. Пустая строка — сервер хэша не знает (например, старая запись).
  final String sha256;

  /// Время изменения файла на устройстве, откуда он приехал (мс). null — сервер его не хранит.
  final int? clientMtime;

  /// Папка, в которой лежит запись — нужна для сопоставления при зеркале вниз.
  final String? folderId;
}

/// Содержимое папки: подпапки (имя → id) и записи.
///
/// Так отвечает `GET /folders/:id/children`, собранный из страниц. [folderIds] нужен зеркалу
/// вниз, чтобы не заводить папку, которая в облаке уже есть.
class FolderChildren {
  const FolderChildren(this.folderIds, this.entries);

  /// Имя подпапки → id. Имена уникальны внутри папки, поэтому карты достаточно.
  final Map<String, String> folderIds;

  /// Записи этой папки (только файлы, без подпапок).
  final List<RemoteEntry> entries;
}

/// Строка журнала изменений. Журнал append-only: клиент держит курсор по `seq` и применяет
/// строки по порядку, а снимок в строке избавляет от запросов за деталями.
class CloudChange {
  const CloudChange({
    required this.seq,
    required this.target,
    required this.op,
    required this.targetId,
    required this.name,
    required this.size,
    this.folderId,
    this.sha256,
    this.mime,
    this.clientMtime,
    this.deviceId,
    this.zone,
  });

  final int seq;

  /// entry | folder
  final String target;

  /// create | update | move | delete | restore (в старых строках встречается pin)
  final String op;
  final String targetId;

  /// родительская папка цели на момент события: по ней правка находится в зеркале
  final String? folderId;
  final String name;
  final String? sha256;
  final int size;
  final String? mime;
  final int? clientMtime;

  /// какое устройство сделало изменение; null — изменение из веба или от сервера
  final String? deviceId;

  /// Зона, в которой лежит цель (`PHOTOS`, `FILES`, `MAIL`); null — сервер её не прислал.
  ///
  /// Зеркалу зона не нужна (оно работает с папками), а ленте «Медиа» — нужна: по ней она
  /// понимает, касается ли правка её списка, и не гоняет полный проход из-за заливки
  /// обычного файла в «Файлы».
  final String? zone;
}

/// Страница журнала: `hasMore` — догонять сразу, не дожидаясь следующего прохода.
class ChangesPage {
  const ChangesPage({
    required this.nextSeq,
    required this.hasMore,
    required this.resetRequired,
    required this.changes,
  });

  /// Курсор для следующего запроса: пишется в базу после применения страницы, чтобы обрыв
  /// на середине не потерял строки.
  final int nextSeq;

  /// Строк больше, чем влезло в лимит: следующий запрос нужно делать сразу же.
  final bool hasMore;

  /// Курсор старше журнала (или впереди него): нужен полный проход по содержимому папки.
  final bool resetRequired;
  final List<CloudChange> changes;
}

/// Свои данные и системные папки: зеркалу нужен id этого устройства в журнале изменений.
///
/// Приходит от `GET /auth/me`; этим же запросом проверяется живость device-токена.
class MeInfo {
  const MeInfo({
    required this.login,
    this.photoFolderId,
    this.phoneFolderId,
    this.mirrorFolderId,
    this.deviceId,
  });

  /// Логин владельца токена; пустая строка — сервер его не отдал.
  final String login;

  /// Системные папки разделов: медиатека «Фото» и легаси-«Телефон». null — папки ещё нет.
  final String? photoFolderId;
  final String? phoneFolderId;

  /// Прежний корень зеркала устройства (`‹Имя устройства› - Файлы`). Эта сборка его не читает
  /// и не создаёт: папки облака для «Файлов» человек выбирает связками (см. `SyncLinks`).
  /// Поле остаётся, потому что его отдаёт сервер и им пользуются прежние сборки приложения.
  final String? mirrorFolderId;

  /// id этого устройства в журнале изменений: по нему зеркало отличает свои правки от чужих
  /// и не тянет обратно то, что только что выгрузило.
  final String? deviceId;
}

/// Что вернул сервер на попытку начать загрузку.
class SyncUploadInit {
  const SyncUploadInit({
    this.entryId = '',
    this.uploadId,
    this.deduped = false,
    this.direct = false,
    this.partSize = 16 * 1024 * 1024,
    this.nextPart = 1,
    this.stale = false,
    this.inTrash = false,
    this.nameTaken = false,
  });

  /// id записи в облаке — и он есть **только** у дедупа (`deduped`): там сервер новую загрузку
  /// не начинает и сразу возвращает готовую запись. В обычном ответе поля `entry` нет вовсе,
  /// id появится позже, из [SyncApi.complete]; пустая строка здесь значит «на этом шаге записи
  /// ещё нет», и подставлять её как готовый id нельзя.
  final String entryId;
  final String? uploadId;

  /// Сервер нашёл точно такое же содержимое и ничего принимать не стал: выгрузка окончена.
  final bool deduped;

  /// Лить части напрямую в хранилище по presigned-ссылке; false — только релеем через сервер.
  final bool direct;

  /// Размер части, назначенный сервером; 16 МиБ — запасное значение, если сервер его не назвал
  /// (столько же по умолчанию у сервера, где размер задаётся настройкой `UPLOAD_DIRECT_PART_MB`
  /// и может быть другим). Часть целиком держится в памяти при выгрузке, поэтому размер
  /// приходит от сервера, а не назначается клиентом.
  final int partSize;

  /// С какой части продолжать (1 — с начала).
  final int nextPart;

  /// 409 stale_version: на сервере другая версия — клиент делает конфликтную копию.
  final bool stale;

  /// 409 in_trash: имя занято записью из корзины — сами не воскрешаем.
  final bool inTrash;

  /// 409 «имя уже существует»: запись есть, движок сверит хэш и решит.
  final bool nameTaken;
}

/// Ответ GET /uploads/:id — с какой части продолжать и каким способом лить дальше.
///
/// Спрашивается после обрыва: сессия выгрузки живёт на сервере, поэтому клиент может
/// продолжить её следующим проходом, а не начинать файл заново.
class SyncUploadStatus {
  const SyncUploadStatus(this.nextPart, this.partSize, this.direct);

  final int nextPart;
  final int partSize;
  final bool direct;
}

/// Клиент REST API облака для синхронизации. Авторизация — device-токен в Bearer: корень
/// зеркала сервер заводит именно устройству, а веб-сессия его не получает вовсе.
///
/// Отдельный клиент, а не общий [CloudlyApi], намеренно: сессионная cookie в запросе
/// перебивает токен (гард проверяет её первой), и вместе с ней `deviceId` в ответе был бы
/// пустым — зеркало осталось бы без своего корня.
class SyncApi {
  /// [serverUrl] — адрес сервера в любом виде («с пробелами», «со слэшем на конце»): он
  /// приводится к каноническому в [_normalize]; [token] — device-токен, который уйдёт
  /// в заголовок `Authorization` каждого запроса.
  ///
  /// Бросает [StateError], если после нормализации адрес пуст: без адреса синхронизации некуда
  /// ходить, и лучше сказать это словами, чем показать человеку ошибку Dio о кривом URL.
  SyncApi({required String serverUrl, required this.token})
    : serverUrl = _normalize(serverUrl) {
    // Пустой адрес — не «странный URL» от Dio, а понятная причина: синхронизации некуда ходить
    if (this.serverUrl.isEmpty) {
      throw StateError('не задан адрес сервера');
    }
    // Подстановка именно через `${…}`: `$this.serverUrl` Dart читает как «объект целиком»,
    // и адресом становится «Instance of 'SyncApi'.serverUrl» — Dio такое отвергает.
    _http = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        // Таймауты разведены по смыслу операции: запрос метаданных должен падать быстро,
        // а выгрузка большого файла (send) и скачивание — нет, иначе связь на телефоне
        // обрывала бы работу на каждой второй попытке
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 60),
        sendTimeout: const Duration(seconds: 120),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      ),
    );
    // Свой клиент без Authorization: ссылка уже подписана, лишние заголовки ломают подпись
    _s3 = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        // У хранилища запас больше, чем у своего сервера: части по 16 МиБ уходят долго
        receiveTimeout: const Duration(seconds: 300),
        sendTimeout: const Duration(seconds: 300),
      ),
    );
  }

  /// Адрес сервера без хвостовых слэшей: из него собирается [baseUrl].
  final String serverUrl;

  /// Device-токен этого устройства (см. `device_token.dart`).
  final String token;

  /// Клиент к API сервера (с токеном) и клиент к хранилищу (без заголовков).
  late final Dio _http;
  late final Dio _s3;

  /// Базовый адрес API: один на все запросы. Вынесен в поле, чтобы его можно было проверить
  /// тестом — ошибка в нём роняет всю синхронизацию разом, а видно её только на телефоне.
  String get baseUrl => '$serverUrl/api/v1';

  /// Сколько страниц содержимого папки готовы пройти за один вызов [children].
  ///
  /// Тысяча страниц по тысяче записей — это миллион файлов в одной папке, дальше начинается
  /// уже не «большая папка», а сервер, отдающий один и тот же курсор. Обрыв по этому пределу —
  /// ошибка: молча вернуть неполный список значило бы показать зеркалу «этих файлов больше нет».
  static const int _maxFolderPages = 1000;

  /// Сколько ждём установки соединения и сколько — заголовков ответа на скачивании.
  ///
  /// Значения те же, что у `connectTimeout`/`receiveTimeout` Dio на этом же клиенте (20 и 60 с):
  /// два разных поведения на одном сервере сбивали бы с толку при разборе жалоб.
  static const int _connectTimeoutMs = 20 * 1000;

  /// Сколько ждём заголовки ответа после отправки запроса на скачивание.
  static const int _headerTimeoutMs = 60 * 1000;

  /// Сколько ждём следующий кусок тела. Не «весь файл»: таймер перезапускается на каждом
  /// принятом куске, поэтому медленная, но живая сеть скачивание не рвёт, а зависший сервер
  /// обрывается (подробнее — в [_downloadInto]).
  static const Duration _bodyIdleTimeout = Duration(seconds: 60);

  /// Метка писателя: отличает временные файлы скачивания друг от друга.
  ///
  /// Временный файл лежит рядом с целью, а скачивать могут одновременно двое: мгновенный режим
  /// в движке приложения и фоновое задание системы — у них разные изоляты, и замок «один проход
  /// за раз» (`MirrorEngine._busy`) о соседе не знает. Без метки оба писали бы в один файл,
  /// и в целевое имя могло бы уехать их перемешанное содержимое.
  ///
  /// Метка одна на изолят (`static final` ленив и живёт в глобальных переменных изолята):
  /// внутри одного изолята имя временного файла одинаковое, поэтому докачка после обрыва
  /// продолжается с того же файла, а между изолятами имена разные. Шесть шестнадцатеричных
  /// знаков — 16 миллионов вариантов: совпадение двух одновременных писателей практически
  /// исключено.
  ///
  /// **Цена — длина имени.** Временное имя длиннее базового на 20 байт
  /// (`'.'` + метка + `'.cloudly-tmp'`). Такой же запас учитывает
  /// `MirrorRules.downloadSuffixBytes`: имя, которому его не хватает, зеркало не пытается
  /// скачать вовсе — иначе оно упало бы уже на файловой системе (`ENAMETOOLONG`).
  static final String _writerTag = (Random().nextInt(0xFFFFFF) | 0x100000)
      .toRadixString(16);

  /// Канонический адрес сервера: пробелы по краям и хвостовые слэши убираются здесь, один раз.
  /// Иначе `baseUrl` получил бы `//api/v1`, а такой адрес Dio уже не собирает.
  static String _normalize(String u) => u.trim().replaceAll(RegExp(r'/+$'), '');

  /// Проверка токена и адреса сервера: заодно отдаёт корень зеркала этого устройства.
  ///
  /// Возвращает [MeInfo]; при отозванном токене бросает [SyncApiException] со статусом 401/403 —
  /// по этому признаку `device_token.dart` решает, что нужен новый токен.
  Future<MeInfo> meInfo() async {
    final o = _mOrThrow(await _req('/auth/me'), 'свои данные');
    return MeInfo(
      login: '${o['login'] ?? ''}',
      photoFolderId: _sOrNull(o['photoFolderId']),
      phoneFolderId: _sOrNull(o['phoneFolderId']),
      mirrorFolderId: _sOrNull(o['mirrorFolderId']),
      deviceId: _sOrNull(o['deviceId']),
    );
  }

  /// Только системные папки: очередь наполняется и без корня зеркала.
  ///
  /// Отдельного запроса нет намеренно — это тот же `GET /auth/me`, что и [meInfo], просто
  /// названный по делу: очередь не должна знать, что «системные папки» и «свои данные»
  /// приходят одним ответом.
  Future<MeInfo> systemFolders() => meInfo();

  /// Отозвать токен, которым пришёл запрос. Нужно при выходе: без этого серверный токен
  /// остаётся живым до истечения срока и даёт полный доступ к облаку.
  Future<void> revokeOwnToken() => _req('/auth/me/token', method: 'DELETE');

  /// Текущая голова журнала. Нужна, чтобы включить зеркало «с этого момента».
  ///
  /// Возвращает 0, если поля `seq` в ответе нет: курсор с нулём означает «догоняй всё», и это
  /// безопаснее выдуманного числа. Ответ не картой — ошибка ([_mOrThrow]): тут пустой ответ
  /// означал бы «журнал с начала», то есть лишний полный разбор, а не пропуск изменений.
  Future<int> syncHead() async {
    final o = _mOrThrow(await _req('/sync/head'), 'голова журнала');
    return _toInt(o['seq']);
  }

  /// Изменения дерева после курсора: клиент применяет их по порядку и двигает курсор.
  ///
  /// [since] — последний применённый `seq` (0 — с начала журнала); [limit] — сколько строк
  /// брать за раз, по умолчанию 200: строки несут снимок цели, и большая страница была бы
  /// тяжёлой, хотя догонять всё равно придётся страницами.
  ///
  /// Возвращает [ChangesPage]. При обрыве связи бросает [SyncApiException] — вызывающий
  /// (зеркало вниз) оставляет прежний курсор и повторит запрос следующим проходом.
  ///
  /// Ключи `changes` и `nextSeq` обязательны: без них ответ означает не «изменений нет»,
  /// а другой формат, и молча вернуть пустую страницу значило бы не догнать журнал никогда
  /// (курсор остался бы на месте, а лога не было бы вовсе).
  Future<ChangesPage> changes(int since, {int limit = 200}) async {
    final o = _mOrThrow(
      await _req('/sync/changes?since=$since&limit=$limit'),
      'журнал изменений',
    );
    final raw = _need(o, 'changes', 'журнал изменений');
    final page = _need(o, 'nextSeq', 'журнал изменений');
    return ChangesPage(
      nextSeq: _toInt(page, fallback: since),
      hasMore: o['hasMore'] == true,
      resetRequired: o['resetRequired'] == true,
      changes: (raw as List? ?? const []).whereType<Map>().map((c) {
        final m = c.cast<String, dynamic>();
        return CloudChange(
          seq: _toInt(m['seq']),
          target: '${m['target'] ?? ''}',
          op: '${m['op'] ?? ''}',
          targetId: '${m['targetId'] ?? ''}',
          folderId: _sOrNull(m['folderId']),
          name: '${m['name'] ?? ''}',
          sha256: _sOrNull(m['sha256']),
          size: _toInt(m['size']),
          mime: _sOrNull(m['mime']),
          clientMtime: _isoOrNull(m['clientMtime']),
          deviceId: _sOrNull(m['deviceId']),
          zone: _sOrNull(m['zone']),
        );
      }).toList(),
    );
  }

  /// Идемпотентный mkdir: возвращает id папки по пути от корня.
  ///
  /// [path] — путь папки внутри корня зеркала (`Download/Telegram`), [parentId] — родитель,
  /// уже известный серверу (null — путь считается от корня токена).
  ///
  /// Возвращает id папки. Отсутствие поля `id` в ответе — ошибка, а не пустая строка:
  /// пустой id вызывающие принимают за «папку завести не удалось», и это верное решение,
  /// но без объяснения в отчёте — почему именно не удалось.
  Future<String> ensurePath(String path, String? parentId) async {
    final j = _mOrThrow(
      await _req(
        '/folders/ensure-path',
        method: 'POST',
        body: {'path': path, 'parentId': ?parentId},
      ),
      'заведение папки',
    );
    return '${_need(j, 'id', 'заведение папки') ?? ''}';
  }

  /// Метаданные папки: имя.
  ///
  /// Нужно там, где папка известна только по id (например, системная папка раздела), а показать
  /// её надо человеку. Отсутствие поля `name` — ошибка формата: пустое имя папки в дереве
  /// выглядело бы как «папка без названия», а не как сломанный ответ.
  Future<String> folderMeta(String folderId) async {
    final o = _mOrThrow(await _req('/folders/$folderId/meta'), 'метаданные папки');
    return '${_need(o, 'name', 'метаданные папки') ?? ''}';
  }

  /// Содержимое папки одной страницей: сервер отдаёт порциями по 1000 записей.
  ///
  /// [after] — курсор предыдущей страницы (имя, на котором остановились), null — первая
  /// страница. Имя, а не номер: записи приходят в устойчивом порядке имён, и по имени сервер
  /// продолжает с того же места.
  ///
  /// Возвращает страницу и курсор следующей (`null` — страниц больше нет). Ошибку сервера
  /// не глотает: [SyncApiException] уходит наверх в [children].
  ///
  /// Списки `folders` и `entries` обязательны, а при `hasMore` обязателен и `nextAfter`:
  /// пропавший ключ иначе выглядел бы пустой папкой, а пустая папка — это довод в пользу
  /// удалений в облаке (от них спасает только предохранитель массового удаления).
  Future<(FolderChildren, String?)> _childrenPage(
    String folderId,
    String? after,
  ) async {
    final suffix = (after == null || after.isEmpty)
        ? ''
        : '?after=${Uri.encodeQueryComponent(after)}';
    final o = _mOrThrow(
      await _req('/folders/$folderId/children$suffix'),
      'содержимое папки',
    );
    final rawFolders = _need(o, 'folders', 'содержимое папки');
    final rawEntries = _need(o, 'entries', 'содержимое папки');
    final folders = <String, String>{};
    for (final f in (rawFolders as List? ?? const []).whereType<Map>()) {
      final name = _sOrNull(f['name']);
      final id = _sOrNull(f['id']);
      if (name == null || id == null) continue;
      folders[name] = id;
    }
    final entries = (rawEntries as List? ?? const []).whereType<Map>().map((e) {
      return RemoteEntry(
        id: '${e['id']}',
        name: '${e['name']}',
        size: _toInt(e['size']),
        mime: '${e['mime'] ?? ''}',
        sha256: '${e['sha256'] ?? ''}',
        clientMtime: _isoOrNull(e['clientMtime']),
      );
    }).toList();
    if (o['hasMore'] != true) return (FolderChildren(folders, entries), null);
    final next = _sOrNull(_need(o, 'nextAfter', 'содержимое папки'));
    if (next == null) {
      throw const SyncApiException(
        0,
        '',
        'содержимое папки: сервер обещал продолжение (hasMore) без курсора nextAfter',
      );
    }
    return (FolderChildren(folders, entries), next);
  }

  /// Всё содержимое папки, с обходом страниц: большая папка приходит порциями,
  /// и без этого зеркало видело бы только первую тысячу записей.
  ///
  /// Обрыв по предохранителю — ошибка, а не «папка кончилась»: тысяча страниц по тысяче
  /// записей означает, что сервер отдаёт один и тот же курсор, и молча вернуть миллион записей
  /// как содержимое папки нельзя. Пустая папка была бы воспринята как «всё удалено».
  Future<FolderChildren> children(String folderId) async {
    final folders = <String, String>{};
    final entries = <RemoteEntry>[];
    String? after;
    var pages = 0;
    while (true) {
      if (pages++ >= _maxFolderPages) {
        throw const SyncApiException(
          0,
          '',
          'содержимое папки: сервер отдаёт страницы без конца — обход остановлен',
        );
      }
      final (page, next) = await _childrenPage(folderId, after);
      folders.addAll(page.folderIds);
      entries.addAll(page.entries);
      if (next == null) break;
      after = next;
    }
    return FolderChildren(folders, entries);
  }

  /// Метаданные файла: имя, размер, тип, хэш.
  ///
  /// [entryId] — id записи из журнала или из содержимого папки. Возвращает [RemoteEntry]
  /// с заполненным [RemoteEntry.folderId]: по нему зеркало кладёт скачанное в нужную папку.
  /// Отсутствующие необязательные поля ответа становятся пустыми строками, а не null: так
  /// вызывающему не приходится различать «нет значения» и «пустое значение». А вот `id` и `name`
  /// обязательны: без них запись не с чем сопоставить на телефоне.
  Future<RemoteEntry> entryMeta(String entryId) async {
    final e = _mOrThrow(await _req('/files/$entryId'), 'метаданные файла');
    return RemoteEntry(
      id: '${_need(e, 'id', 'метаданные файла') ?? ''}',
      name: '${_need(e, 'name', 'метаданные файла') ?? ''}',
      size: _toInt(e['size']),
      mime: '${e['mime'] ?? ''}',
      sha256: '${e['sha256'] ?? ''}',
      clientMtime: _isoOrNull(e['clientMtime']),
      folderId: _sOrNull(e['folderId']),
    );
  }

  /// Начать загрузку. `expectedSha256` — оптимистичная блокировка: сервер откажет (409
  /// stale_version), если на его стороне уже другая версия файла.
  ///
  /// [folderId] и [name] — куда и под каким именем; [size], [mime], [sha256] (null — сервер
  /// посчитает сам) и [clientMtime] описывают файл; [replace] — заменить существующую запись
  /// с тем же именем; [mode] `direct` — лить части в хранилище, иначе релеем через сервер;
  /// [replaceTrashed] — разрешить занять имя записи из корзины (по умолчанию не воскрешаем).
  ///
  /// Возвращает [SyncUploadInit]. На 409 не бросает: расхождение версий, имя в корзине и занятое
  /// имя приходят флагами ([SyncUploadInit.stale], [SyncUploadInit.inTrash],
  /// [SyncUploadInit.nameTaken]) — это не ошибка, а развилка, которую решает движок. Остальные
  /// отказы сервера и обрыв связи уходят как [SyncApiException].
  Future<SyncUploadInit> initUpload({
    required String folderId,
    required String name,
    required int size,
    required String mime,
    required String? sha256,
    required bool replace,
    required int clientMtime,
    String? expectedSha256,
    String mode = 'direct',
    bool replaceTrashed = false,
  }) async {
    final body = <String, dynamic>{
      'folderId': folderId,
      'name': name,
      'size': size,
      'mime': mime,
      'mode': mode,
      'replace': replace,
      'clientMtime': isoOf(clientMtime),
      'sha256': ?sha256,
      // Блокировка версии имеет смысл только при замене существующей записи: при создании
      // новой сверять версию не с чем
      if (replace && expectedSha256 != null) 'expectedSha256': expectedSha256,
      if (replaceTrashed) 'replaceTrashed': true,
    };
    try {
      final o = _mOrThrow(
        await _req('/uploads', method: 'POST', body: body),
        'начало выгрузки',
      );
      final entryId = _sOrNull((o['entry'] as Map?)?['id']);
      final uploadId = _sOrNull(o['uploadId']);
      // Ни сессии, ни дедупа в ответе быть не может: вызывающие читают это как «файл уже
      // в облаке» и помечают строку выгруженной (по пустому `entryId`!). Лучше ошибка
      // с объяснением, чем запись «выгружено» у файла, которого в облаке нет
      if (uploadId == null && o['deduped'] != true) {
        throw const SyncApiException(
          0,
          '',
          'начало выгрузки: в ответе нет ни uploadId, ни deduped',
        );
      }
      return SyncUploadInit(
        entryId: entryId ?? '',
        uploadId: uploadId,
        deduped: o['deduped'] == true,
        direct: o['direct'] == true,
        partSize: _toInt(o['partSize'], fallback: 16 * 1024 * 1024),
        nextPart: _toInt(o['nextPart'], fallback: 1),
      );
    } on SyncApiException catch (e) {
      if (e.status != 409) rethrow;
      // 409 бывает трёх видов: расхождение версий, имя в корзине, имя просто занято
      return SyncUploadInit(
        stale: e.code == 'stale_version',
        inTrash: e.code == 'in_trash',
        nameTaken: e.code != 'stale_version' && e.code != 'in_trash',
      );
    }
  }

  /// Состояние сессии: с какой части продолжать после обрыва и каким способом лить.
  ///
  /// Отсутствующие в ответе поля заменяются на «начать с первой части» и 16 МиБ: обрыв ответа
  /// не должен превращаться в попытку залить часть с отрицательным номером.
  Future<SyncUploadStatus> uploadStatus(String uploadId) async {
    final o = _mOrThrow(await _req('/uploads/$uploadId'), 'состояние выгрузки');
    return SyncUploadStatus(
      _toInt(o['nextPart'], fallback: 1),
      _toInt(o['partSize'], fallback: 16 * 1024 * 1024),
      // Прямую загрузку считаем доступной, если сервер прямо не сказал обратного: так
      // выгрузка не теряет скорость из-за отсутствующего поля в ответе
      o['direct'] != false,
    );
  }

  /// Presigned-ссылка на одну часть: по ней часть уходит прямо в хранилище, минуя сервер.
  ///
  /// Бросает [SyncDirectUnavailable], если ссылки нет или сервер не умеет их выдавать
  /// (404/405): для вызывающих это «попробовать релеем», а не отказ сервера. Прочие ошибки
  /// уходят как [SyncApiException].
  ///
  /// Здесь намеренно терпимый разбор ([_m], а не [_mOrThrow]): неожиданный формат ответа
  /// означает «прямой путь не вышел», и выгрузка пойдёт релеем. Строгая ошибка формата
  /// оставила бы файл невыгруженным там, где выход есть.
  Future<String> partUrl(String uploadId, int part) async {
    try {
      final url =
          '${_m(await _req('/uploads/$uploadId/url/$part'))['url'] ?? ''}';
      if (url.isEmpty) {
        throw const SyncDirectUnavailable('сервер не выдал ссылку на часть');
      }
      return url;
    } on SyncApiException catch (e) {
      if (e.status == 404 || e.status == 405) {
        throw const SyncDirectUnavailable(
          'сервер не поддерживает прямую загрузку',
        );
      }
      rethrow;
    }
  }

  /// Сообщить серверу, что часть принята: [etag] и [size] он запоминает, чтобы собрать файл
  /// целиком. Без этого шага залитая часть для сервера не существует.
  Future<void> registerPart(String uploadId, int part, String etag, int size) =>
      _req(
        '/uploads/$uploadId/parts/$part',
        method: 'PUT',
        body: {'etag': etag, 'size': size},
      );

  /// Заливка части через сервер: нужно, когда хранилище с телефона недоступно.
  ///
  /// [bytes] — содержимое части целиком в памяти: части ходят по 16 МиБ, и держать больше
  /// в памяти телефона нельзя. Ошибка сети приходит [SyncApiException] (через [_toException]) —
  /// вызывающий повторяет часть, а не весь файл.
  Future<void> relayChunk(String uploadId, int part, Uint8List bytes) async {
    try {
      await _http.put(
        '/uploads/$uploadId/chunks/$part',
        data: bytes,
        options: Options(
          contentType: 'application/octet-stream',
          responseType: ResponseType.plain,
        ),
      );
    } on DioException catch (e) {
      throw _toException(e);
    }
  }

  /// Закрыть сессию выгрузки: сервер собирает части и заводит запись.
  ///
  /// [sha256] — хэш целого файла: сервер сверяет с ним собранное и отвергает выгрузку, если
  /// содержимое не сошлось. Возвращает id записи; пустая строка — сервер отдал ответ без
  /// `entry.id`, и записывать это как «файл выгружен» нельзя (проверяет вызывающий).
  Future<String> complete(String uploadId, String sha256) async {
    final o = _mOrThrow(
      await _req(
        '/uploads/$uploadId/complete',
        method: 'POST',
        body: {'sha256': sha256},
      ),
      'завершение выгрузки',
    );
    return _sOrNull((o['entry'] as Map?)?['id']) ?? '';
  }

  /// Бросить незаконченную выгрузку, чтобы не копились мёртвые сессии и части.
  ///
  /// Исключений не бросает намеренно: это уборка после неудачи, и падать на уборке значит
  /// потерять исходную ошибку. Если сервер не ответил, сессия останется мусором на его стороне.
  Future<void> abort(String uploadId) async {
    try {
      await _http.delete('/uploads/$uploadId');
    } catch (_) {}
  }

  /// Заливка одной части напрямую в хранилище по presigned-ссылке.
  ///
  /// [presignedUrl] — ссылка от [partUrl], [bytes] — содержимое части. Возвращает ETag части
  /// без кавычек: в таком виде его ждёт [registerPart].
  ///
  /// Бросает [SyncDirectUnavailable], если хранилище не ответило или не отдало ETag, — в имени
  /// хоста видно, кто именно не отвечает; вызывающий после этого переходит на релей. Остальные
  /// ошибки Dio тоже приходят как [SyncDirectUnavailable]: для прямой загрузки любой сбой
  /// означает «этим путём не вышло», а не «сервер сказал нет».
  Future<String> putPartToS3(String presignedUrl, Uint8List bytes) async {
    final host = Uri.tryParse(presignedUrl)?.host ?? 'S3';
    try {
      final res = await _s3.put<List<int>>(
        presignedUrl,
        data: bytes,
        options: Options(
          contentType: 'application/octet-stream',
          responseType: ResponseType.plain,
        ),
      );
      final etag = res.headers.value('etag');
      if (etag == null || etag.isEmpty) {
        throw SyncDirectUnavailable('$host не отдал ETag');
      }
      return etag.replaceAll('"', '');
    } on DioException catch (e) {
      // в сообщении должно быть видно, какой именно хост не отвечает
      throw SyncDirectUnavailable('$host: ${e.message ?? 'ошибка сети'}');
    }
  }

  /// Удалить файл в облаке: так зеркало убирает то, что исчезло на телефоне.
  ///
  /// Запись уезжает в корзину сервера — восстановить её человек может сам, и на этом основан
  /// предохранитель массовых удалений в движке.
  Future<void> deleteFile(String entryId) =>
      _req('/files/$entryId', method: 'DELETE');

  /// Перенести файл в другую папку и заодно переименовать: сервер считает это одной операцией.
  Future<void> moveFile(String entryId, String folderId, String name) => _req(
    '/files/$entryId',
    method: 'PATCH',
    body: {'folderId': folderId, 'name': name},
  );

  /// Переименование без переноса: сервер считает это отдельной операцией.
  Future<void> renameFile(String entryId, String name) =>
      _req('/files/$entryId', method: 'PATCH', body: {'name': name});

  /// Удалить папку в облаке: зеркало зовёт это, когда папка опустела и на телефоне её больше нет.
  Future<void> deleteFolder(String folderId) =>
      _req('/folders/$folderId', method: 'DELETE');

  /// Переименовать папку: путь в облаке повторяет путь на телефоне, поэтому переименование
  /// на телефоне приезжает сюда, а не превращается в «удалил и залил заново».
  Future<void> renameFolder(String folderId, String name) =>
      _req('/folders/$folderId', method: 'PATCH', body: {'name': name});

  /// Скачивание записи в файл с докачкой: оборвавшийся на середине файл не начинается заново.
  /// Пишем во временное имя рядом и переименовываем только после успеха — иначе сканирование
  /// подхватило бы недописанный файл. `expectedSha256` приходит из журнала: если содержимое
  /// не сошлось, файл не оставляем.
  ///
  /// [entryId] — что качать, [dest] — куда (родительская папка должна существовать: зеркало
  /// заводит её заранее), [expectedSha256] — хэш, с которым сверяется результат (null или
  /// пустая строка — сверять не с чем, файл принимается как есть).
  ///
  /// ## Про докачку: сервер не проверяет версию объекта
  ///
  /// `Range` уходит прямо в хранилище (`src/common/http-object.ts`), без `If-Range` и ETag,
  /// поэтому сервер продолжит файл с запрошенного смещения, даже если на его стороне содержимое
  /// уже другое. Уповать при докачке можно только на [expectedSha256], а он приходит не всегда
  /// (`mirror/mirror_pull.dart` принимает `String? sha256`): если хэша нет, склеенный из двух
  /// версий файл останется на телефоне — и на следующем проходе уедет в облако как новая версия.
  /// Полностью закрыть это можно только сверкой ETag/`If-Range` на сервере.
  ///
  /// Побочные эффекты: пишет временный `.имя.<метка>.cloudly-tmp` (имя скрытое, и суффикс
  /// `.cloudly-tmp` входит в служебные имена `MediaRules.isJunk`), при успехе переименовывает
  /// его в [dest], а прежний файл на время уводит в скрытое `.имя.cloudly-old` и удаляет после
  /// успеха. Обе служебные имена начинаются с точки и оканчиваются своим суффиксом: если
  /// процесс убьют между двумя переименованиями, мусор не попадёт ни в разделы, ни в облако.
  /// Ничего не возвращает: успех — это существующий файл на месте [dest].
  ///
  /// При ошибке временный файл удаляется (не оставляет мусора в выбранной папке) и наружу
  /// уходит последняя ошибка — [SyncApiException] или [FileSystemException]. Три попытки с
  /// растущей паузой, и повторяется только то, что имеет смысл повторять: обрыв связи
  /// (`status` 0 — ответа не было) и сбой сервера (5xx). Отказ по существу (4xx: 401 — токен,
  /// 404 — записи нет, 409 — расхождение) выходит из цикла сразу.
  Future<void> downloadToFile(
    String entryId,
    File dest, {
    String? expectedSha256,
  }) async {
    final tmp = File(
      p.join(
        dest.parent.path,
        '.${p.basename(dest.path)}.$_writerTag.cloudly-tmp',
      ),
    );
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final from = await tmp.exists() ? await tmp.length() : 0;
        await _downloadInto(entryId, tmp, from);
        if (expectedSha256 != null && expectedSha256.isNotEmpty) {
          final have = await Hasher.sha256(tmp);
          if (have.toLowerCase() != expectedSha256.toLowerCase()) {
            // огрызок с чужим содержимым копить нельзя: следующая попытка начнётся с нуля,
            // иначе к нему приклеится ещё кусок и файл так и останется испорченным
            await tmp.delete();
            throw const FileSystemException(
              'содержимое не сошлось с хэшем из журнала',
            );
          }
        }
        // прежний файл не удаляем, а уводим в сторону: если переименование не удастся,
        // на месте останется рабочая версия, а не пустота (иначе зеркало сочло бы файл
        // удалённым и унесло бы облачную копию в корзину)
        final backup = File(
          p.join(dest.parent.path, '.${p.basename(dest.path)}.cloudly-old'),
        );
        if (await dest.exists()) {
          if (await backup.exists()) await backup.delete();
          await dest.rename(backup.path);
        }
        try {
          await tmp.rename(dest.path);
        } catch (_) {
          if (await backup.exists()) await backup.rename(dest.path);
          rethrow;
        }
        if (await backup.exists()) await backup.delete();
        return;
      } catch (e) {
        lastError = e;
        // Повторяем обрыв связи и сбой сервера. Раньше здесь стояло `status < 500`, и под это
        // условие попадал `status` 0 (ответа не было вовсе): на мобильной сети — самый частый
        // случай — повтор не делался ни разу, хотя именно он и был нужен
        if (e is SyncApiException && e.status >= 400 && e.status < 500) break;
        // Пауза растёт с каждой попыткой: мгновенный повтор на мобильной сети обычно попадает
        // в тот же обрыв, а короткое ожидание даёт соединению восстановиться
        await Future<void>.delayed(Duration(milliseconds: 700 * (attempt + 1)));
      }
    }
    if (await tmp.exists()) {
      try {
        await tmp.delete();
      } catch (_) {}
    }
    throw lastError ?? const FileSystemException('скачивание не удалось');
  }

  /// Скачивание с докачкой: `from` — с какого байта продолжать (сервер умеет Range).
  ///
  /// Отдельный `HttpClient`, а не Dio: здесь нужен настоящий поток в файл без буферизации всего
  /// тела в памяти — файлы бывают на гигабайты. Клиент закрывается в `finally`, соединение не
  /// остаётся висеть. Отказ сервера приходит [SyncApiException] с кодом статуса.
  ///
  /// ## Таймауты: их здесь три, и все нужны
  ///
  /// `connectionTimeout` покрывает только установку соединения; `HttpClient.idleTimeout` —
  /// это время жизни **простаивающего соединения в пуле**, а не ожидание тела ответа (частая
  /// ошибка: с ним скачивание «висит вечно», потому что соединение-то не простаивает, оно
  /// открыто и молчит). Поэтому:
  ///
  /// * [_headerTimeoutMs] — ждём заголовки ответа после отправки запроса;
  /// * [_bodyIdleTimeout] — ждём **каждый следующий кусок** тела: таймер перезапускается
  ///   на каждом принятом куске, поэтому медленная, но живая сеть не рвётся, а зависший
  ///   сервер обрывается. Общего дедлайна на весь файл нет намеренно: гигабайтное видео
  ///   по мобильной сети качается дольше любого разумного фиксированного срока;
  /// * по истечении любого из них клиент закрывается принудительно (`close(force: true)`),
  ///   и ожидание чтения завершается ошибкой, а не длится вечно.
  ///
  /// Без этого зависший сервер вешал проход навсегда: в приложении — «выгружаю…» без конца,
  /// в фоне — движок уничтожался посередине записи файла по предохранителю задания.
  Future<void> _downloadInto(String entryId, File target, int from) async {
    final client = HttpClient()
      ..connectionTimeout = Duration(milliseconds: _connectTimeoutMs)
      // Не «ожидание тела» (см. выше), а время жизни простаивающего соединения в пуле:
      // клиент здесь на одно скачивание, и значение нужно лишь чтобы он не держал сокет
      ..idleTimeout = const Duration(minutes: 5);
    Timer? idle;
    try {
      final req = await client.getUrl(
        Uri.parse('$serverUrl/api/v1/files/$entryId/content'),
      );
      req.headers.set('Authorization', 'Bearer $token');
      // Сжатие выключено намеренно: с ним смещения байт в ответе не совпадают с позициями
      // в файле, и докачка по Range дописала бы кусок не туда
      req.headers.set('Accept-Encoding', 'identity');
      if (from > 0) req.headers.set('Range', 'bytes=$from-');
      final res = await req.close().timeout(
        Duration(milliseconds: _headerTimeoutMs),
        onTimeout: () {
          client.close(force: true);
          throw SyncApiException(
            0,
            '',
            'сервер не ответил заголовками за ${_headerTimeoutMs ~/ 1000} с',
          );
        },
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw _httpStatus(res.statusCode);
      }
      // 206 — сервер продолжил с запрошенного места. Если он ответил 200, значит Range
      // проигнорирован и пришло всё содержимое: дописывать его к огрызку нельзя, пишем заново.
      final resumed = from > 0 && res.statusCode == 206;
      final sink = target.openWrite(
        mode: resumed ? FileMode.append : FileMode.write,
      );
      try {
        // Сторож на каждый кусок: `timeout` не годится (он ограничил бы всё тело целиком),
        // а брошенное чтение после закрытия клиента завершается ошибкой само
        idle = Timer(_bodyIdleTimeout, () => client.close(force: true));
        await res.forEach((chunk) {
          idle?.cancel();
          idle = Timer(_bodyIdleTimeout, () => client.close(force: true));
          sink.add(chunk);
        });
      } finally {
        idle?.cancel();
        await sink.flush();
        await sink.close();
      }
    } on HttpException catch (e) {
      // Оборванное соединение (в том числе наше принудительное закрытие) — это не «сервер
      // сказал нет», а «скачать не вышло»: вызывающий повторит попытку
      throw SyncApiException(
        0,
        '',
        'скачивание оборвалось: ${e.message.isEmpty ? 'соединение закрыто' : e.message}',
      );
    } finally {
      idle?.cancel();
      client.close(force: true);
    }
  }

  // ---------- внутреннее ----------

  /// Единственная точка выхода в сеть для API сервера: [path] — путь от [baseUrl], [method] —
  /// HTTP-метод, [body] — тело (объект Dio сериализует в JSON сам).
  ///
  /// Возвращает разобранный ответ как есть — разбирать его в типы умеют только публичные методы.
  /// Любая неудача Dio превращается в [SyncApiException] через [_toException]: сбой сети и отказ
  /// сервера выглядят одинаково для вызывающих, различает их только `status`.
  Future<dynamic> _req(
    String path, {
    String method = 'GET',
    Object? body,
  }) async {
    try {
      final res = await _http.request<dynamic>(
        path,
        data: body,
        options: Options(method: method),
      );
      return res.data;
    } on DioException catch (e) {
      throw _toException(e);
    }
  }

  /// Привести ошибку Dio к [SyncApiException]: код статуса, машинный код и человеческий текст.
  ///
  /// Тело ответа разбирается в двух видах — уже разобранная карта и строка с JSON: сервер
  /// отвечает по-разному в зависимости от того, какой обработчик ошибки сработал. Если ответа
  /// не было вовсе, текст берётся из типа сбоя Dio — «не дождался ответа сервера» или «нет
  /// соединения с сервером» говорит человеку больше, чем `status 0`. Исключений не бросает:
  /// это последний рубеж, где ошибка становится понятной.
  SyncApiException _toException(DioException e) {
    final status = e.response?.statusCode ?? 0;
    var code = '';
    var message = 'HTTP $status';
    final data = e.response?.data;
    if (data is Map) {
      message = '${data['message'] ?? message}';
      code = '${data['code'] ?? ''}';
    } else if (data is String && data.isNotEmpty) {
      try {
        final obj = json.decode(data);
        if (obj is Map) {
          message = '${obj['message'] ?? message}';
          code = '${obj['code'] ?? ''}';
        }
      } catch (_) {
        message = data;
      }
    }
    if (e.response == null) {
      message = switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => 'не дождался ответа сервера',
        DioExceptionType.connectionError => 'нет соединения с сервером',
        _ => e.message ?? 'ошибка сети',
      };
    }
    return SyncApiException(status, code, message);
  }

  /// Ответ сервера как карта. Не карта (список, строка, null) — пустая карта: дальше все поля
  /// читаются через `?? дефолт`, поэтому «ответ не той формы» даёт пустые значения, а не падение
  /// с приведением типа посреди прохода. Так разбираются ответы, у которых пустота допустима
  /// (например, тело ошибки), — там, где пустой ответ означал бы неверное решение, стоит
  /// [_mOrThrow].
  static Map<String, dynamic> _m(dynamic d) =>
      d is Map ? d.cast<String, dynamic>() : <String, dynamic>{};

  /// Ответ, который обязан быть картой.
  ///
  /// «Пусто» и «не тот формат» нельзя путать: переименованное поле или ответ прокси с чужим
  /// `Content-Type` иначе выглядели бы как пустая папка или как «изменений нет» — зеркало
  /// приняло бы это за факт и дошло до решений об удалениях, а в логе не осталось бы ничего.
  /// Поэтому неожиданный формат — исключение с объяснением, а не тихий ноль.
  static Map<String, dynamic> _mOrThrow(dynamic d, String what) {
    if (d is Map) return d.cast<String, dynamic>();
    throw SyncApiException(
      0,
      '',
      '$what: сервер ответил не картой (${d.runtimeType})',
    );
  }

  /// Поле, которое обязано быть в ответе. Отсутствие — не «пустое значение», а другой формат
  /// ответа: у пустой строки и у пропавшего поля разные последствия, и различить их нужно здесь.
  static dynamic _need(Map<String, dynamic> o, String key, String what) {
    if (!o.containsKey(key)) {
      throw SyncApiException(0, '', '$what: в ответе нет поля «$key»');
    }
    return o[key];
  }

  /// Ошибка по коду ответа на скачивании.
  ///
  /// Код сам по себе ничего не объясняет ни человеку, ни логу, а 401/403 — это ещё и особый
  /// случай для вызывающих: движок по такому статусу помечает отчёт как `authFailed`
  /// (`FailureStreak`), а `SyncController` считает клиент негодным и показывает `tokenError`.
  /// Поэтому статус здесь сохраняется как есть, а текст говорит, что случилось.
  static SyncApiException _httpStatus(int status) => SyncApiException(
    status,
    '',
    switch (status) {
      401 || 403 => 'токен устройства не принят (HTTP $status) — нужен новый',
      404 => 'записи нет в облаке (HTTP 404)',
      _ => 'HTTP $status',
    },
  );

  /// В JSON null и пустая строка значат одно и то же: id нет.
  static String? _sOrNull(dynamic v) {
    if (v == null) return null;
    final s = '$v';
    return s.isEmpty || s == 'null' ? null : s;
  }

  /// `seq` сервер отдаёт строкой: без приведения курсор молча сделался бы нулём.
  static int _toInt(dynamic v, {int fallback = 0}) {
    if (v == null) return fallback;
    if (v is int) return v;
    return int.tryParse('$v') ?? fallback;
  }

  /// ISO-8601 из сервера → миллисекунды (для сравнения с локальным mtime).
  static int? _isoOrNull(dynamic v) {
    final s = _sOrNull(v);
    if (s == null) return null;
    return DateTime.tryParse(s)?.millisecondsSinceEpoch;
  }
}

/// ISO-8601 из миллисекунд: сервер ждёт дату файла в этом виде.
///
/// Всегда UTC и всегда с `Z` на конце: локальная зона телефона не должна попадать в поле,
/// по которому сервер и зеркало сравнивают время файлов. Обратное преобразование — `_isoOrNull`.
String isoOf(int millis) =>
    DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toIso8601String();
