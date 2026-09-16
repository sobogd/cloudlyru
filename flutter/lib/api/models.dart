/// Модели ответов REST-API: один класс — одна форма ответа, разбор — фабрики `fromJson`.
///
/// Состав и имена полей повторяют то, что отдают контроллеры сервера (`src/**/*.controller.ts`).
/// Прежний веб-клиент (`web/src/api.ts`) удалён из репозитория коммитом 407a490; совпадение с его
/// TS-интерфейсами — исторический ориентир, а не источник истины.
///
/// Здесь только разбор и хранение значений: ни один класс не ходит в сеть и не знает про
/// интерфейс — этим занимаются `cloudly_api.dart` и экраны.
///
/// Даты — строки ISO-8601 в том виде, как их отдал сервер (обычно UTC): в моделях нет ни одного
/// `DateTime`, потому что пересчёт в местный пояс нужен только на показе, а делает его
/// `util/format.dart`. Одно представление на все поля — сортируя строки, помни, что ISO-8601
/// сравнивается лексикографически верно.
///
/// Числовые поля моделей не-null: если сервер поля не прислал, разбор подставляет `0` (см. [JsonX]).
/// Для счётчиков и размеров это осознанный компромисс — разбор не должен ронять экран из-за одного
/// поля, — но вызывающий, у которого `0` выглядит правдоподобно (остаток очереди, версия сборки,
/// размер файла), обязан учитывать, что «сервер не сказал» и «сервер сказал ноль» тут неотличимы.
library;

/// Приводит значение из JSON к числу: `num` — как есть, строку с числом — разбором, всё
/// остальное — `null`.
///
/// Общая точка разбора чисел для всех моделей ниже: `as num` уронил бы разбор целого ответа
/// из-за одного поля. Строковая ветка — страховка на расхождение типа: сервер отдаёт числа
/// числами, и в обычном ответе она не срабатывает.
num? toNum(Object? v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v);
  return null;
}

/// Приведение к bool мягче, чем `== true`: строка `'true'` тоже считается истиной — та же
/// страховка на расхождение типа, что и в [toNum]. Всё прочее, включая `'false'`, — `false`.
bool _toBool(Object? v) => v == true || v == 'true';

/// Чтение полей JSON-объекта с приведением типа — рабочая лошадка всех `fromJson` ниже.
///
/// Соглашение об именах: буква — тип значения, суффикс `N` — «может отсутствовать». Без
/// суффикса всегда возвращается значение по умолчанию (`''`, `0`, `false`), с ним — `null`.
/// Буквы: `s` — строка, `i` — int, `d` — double, `b` — bool, `m` — вложенный объект,
/// `l`/`lm`/`ls` — список как есть / список объектов / список строк.
///
/// Числа идут через [toNum], поэтому строки с числами разбираются наравне с числами, а
/// неподходящий тип (объект там, где ждали строку) не роняет разбор, а даёт значение по
/// умолчанию: одна испорченная запись не должна ломать весь экран.
///
/// Проверка типа — через `is`, а не `as`: `as String?` при строке-значении не бросает, но
/// `as Map?` на строке бросил бы `TypeError`, а он уходит наружу из `fromJson` и роняет разбор
/// всего ответа, а не одного поля.
extension JsonX on Map<String, dynamic> {
  String s(String k) => this[k] is String ? this[k] as String : '';
  String? sN(String k) => this[k] is String ? this[k] as String : null;
  int i(String k) => toNum(this[k])?.toInt() ?? 0;
  int? iN(String k) => toNum(this[k])?.toInt();
  double d(String k) => toNum(this[k])?.toDouble() ?? 0;
  double? dN(String k) => toNum(this[k])?.toDouble();
  bool b(String k) => _toBool(this[k]);
  /// Три состояния вместо двух: `true`/`'true'` — истина, `false` — ложь, поля нет — `null`.
  /// Строка `'false'` и любой другой тип тоже дают `null`: это «значение непонятное», а не «нет».
  /// Нужен там, где «нет данных» и «нет» — разные вещи: например, `diskLow` в состоянии
  /// очереди, которое сервер может не измерить.
  bool? bN(String k) => this[k] is bool ? this[k] as bool : (_toBool(this[k]) ? true : null);
  Map<String, dynamic>? m(String k) =>
      this[k] is Map ? (this[k] as Map).cast<String, dynamic>() : null;
  List<dynamic>? l(String k) => this[k] is List ? this[k] as List : null;
  List<Map<String, dynamic>> lm(String k) => (l(k) ?? const [])
      .whereType<Map>()
      .map((e) => e.cast<String, dynamic>())
      .toList();
  List<String> ls(String k) => (l(k) ?? const []).whereType<String>().toList();
}

// ===== auth =====

/// Кто вошёл: логин, корень диска и id системных папок пользователя.
///
/// Отдаётся ручкой `/auth/me` при старте. По этим id разделы приложения находят свои папки,
/// вместо того чтобы искать их по именам в дереве.
class UserInfo {
  final String id;
  final String login;
  // Системные папки, которые сервер заводит сам: корень диска, «Фото», «Телефон» и корень
  // зеркала устройства для синхронизации. Разделы ходят именно по ним.
  final String? rootFolderId;
  final String? photoFolderId;
  final String? phoneFolderId;
  final String? mirrorFolderId;
  // Заполнен только при входе по Bearer-токену — гард кладёт id устройства в запрос. Веб-сессии
  // он не нужен: там устройство одно, телефон.
  final String? deviceId;

  UserInfo({
    required this.id,
    required this.login,
    this.rootFolderId,
    this.photoFolderId,
    this.phoneFolderId,
    this.mirrorFolderId,
    this.deviceId,
  });

  /// Разбор ответа `/auth/me`.
  factory UserInfo.fromJson(Map<String, dynamic> j) => UserInfo(
        id: j.s('id'),
        login: j.s('login'),
        rootFolderId: j.sN('rootFolderId'),
        photoFolderId: j.sN('photoFolderId'),
        phoneFolderId: j.sN('phoneFolderId'),
        mirrorFolderId: j.sN('mirrorFolderId'),
        deviceId: j.sN('deviceId'),
      );
}

// ===== folders/files =====

/// Одна запись в листинге папки — и папка, и файл: сервер отдаёт их одной формой.
///
/// Поэтому у папки пусты [size], [mime], [sha256] и [clientMtime]: размера, типа и хеша
/// содержимого у неё нет, а отдельный признак «это папка» не нужен — папки приходят своим
/// списком (см. [FolderView]).
class FolderEntry {
  final String id;
  final String name;
  /// Время создания записи (ISO-8601), одинаковое у файла и у папки.
  final String? createdAt;
  /// Время последнего изменения: у папки — когда в ней в последний раз что-то меняли.
  final String? updatedAt;
  // Заполнены только у файлов; у папки остаются пустыми.
  /// Размер содержимого в байтах.
  final int? size;
  final String? mime;
  /// Хеш содержимого: у листинга он есть, поэтому деталку файла (`/files/:id`) ради хеша
  /// запрашивать не нужно.
  final String? sha256;
  /// Исходное время изменения файла на устройстве, откуда его залили (ISO-8601): клиент
  /// синхронизации восстанавливает по нему mtime скачанного файла. Пусто, если файл заливали
  /// без этого поля (ручная загрузка из браузера, письмо).
  final String? clientMtime;

  FolderEntry({
    required this.id,
    required this.name,
    this.createdAt,
    this.updatedAt,
    this.size,
    this.mime,
    this.sha256,
    this.clientMtime,
  });

  /// Разбор элемента из списков `folders` и `entries` ответа `/folders/:id/children`.
  factory FolderEntry.fromJson(Map<String, dynamic> j) => FolderEntry(
        id: j.s('id'),
        name: j.s('name'),
        createdAt: j.sN('createdAt'),
        updatedAt: j.sN('updatedAt'),
        size: j.iN('size'),
        mime: j.sN('mime'),
        sha256: j.sN('sha256'),
        clientMtime: j.sN('clientMtime'),
      );
}

/// Содержимое папки: что внутри и в какой папке мы находимся.
///
/// Папки и файлы приходят двумя списками, а не одним с признаком типа: интерфейс показывает их
/// отдельными группами, и порядок внутри каждой задаёт сервер.
///
/// Сервер отдаёт листинг страницами по 1000 записей на каждый список (`after` — keyset-пагинация
/// по имени, потолок страницы 5000, см. `src/folders/folders.service.ts`): большие папки вроде
/// «Фото» целиком в один ответ не влезают. Поэтому у ответа есть [hasMore] и [nextAfter], и
/// вызывающий обязан догружать страницы запросом с `?after=`, пока [hasMore] не станет `false` —
/// иначе папка с 3000 файлов молча покажет только первые 1000.
class FolderView {
  /// id показанной папки; у корня диска — id корневой папки пользователя.
  final String parentId;
  final List<FolderEntry> folders;
  final List<FolderEntry> entries;
  /// Есть ли за этой страницей ещё записи — `true` означает, что показанное содержимое неполное.
  /// Сервер отдаёт поле всегда; `false` при его отсутствии — «продолжения нет».
  final bool hasMore;
  /// Имя последней записи страницы: с него начинается следующая (`?after=[nextAfter]`).
  /// `null`, когда [hasMore] — `false`.
  final String? nextAfter;

  FolderView({
    required this.parentId,
    required this.folders,
    required this.entries,
    this.hasMore = false,
    this.nextAfter,
  });

  /// Разбор ответа `/folders` (корень) и `/folders/:id/children`.
  factory FolderView.fromJson(Map<String, dynamic> j) => FolderView(
        parentId: j.s('parentId'),
        folders: j.lm('folders').map(FolderEntry.fromJson).toList(),
        entries: j.lm('entries').map(FolderEntry.fromJson).toList(),
        hasMore: j.b('hasMore'),
        nextAfter: j.sN('nextAfter'),
      );
}

/// Метаданные содержимого файла, разобранные сервером: EXIF для фото, ffprobe для видео.
///
/// Разбор делается один раз и лежит на сервере. [raw] — исходный разбор целиком: из него
/// карточка метаданных берёт теги, для которых нет отдельных полей (объектив, ISO, выдержка).
class FileMedia {
  // Время съёмки и координаты — как их отдал разбор: строка ISO без пересчёта пояса (см. fmtMediaDate).
  final String? capturedAt;
  final double? latitude;
  final double? longitude;
  final String? make;
  final String? model;
  final int? width;
  final int? height;
  final Map<String, dynamic>? raw;

  FileMedia({
    this.capturedAt,
    this.latitude,
    this.longitude,
    this.make,
    this.model,
    this.width,
    this.height,
    this.raw,
  });

  /// Разбор блока `media` в метаданных файла.
  factory FileMedia.fromJson(Map<String, dynamic> j) => FileMedia(
        capturedAt: j.sN('capturedAt'),
        latitude: j.dN('latitude'),
        longitude: j.dN('longitude'),
        make: j.sN('make'),
        model: j.sN('model'),
        width: j.iN('width'),
        height: j.iN('height'),
        raw: j.m('raw'),
      );
}

/// Письмо, из которого файл попал в облако вложением.
///
/// Нужно, чтобы в деталке файла показать источник и дать ссылку обратно в письмо. У обычных
/// файлов этого блока в ответе нет.
class FileMailOrigin {
  final String id;
  final String? subject;
  final String? fromName;
  final String? fromAddr;
  // Время самого письма, а не файла: у вложения своей даты создания может не быть.
  final String? sortAt;
  final String? box;

  FileMailOrigin({
    required this.id,
    this.subject,
    this.fromName,
    this.fromAddr,
    this.sortAt,
    this.box,
  });

  /// Разбор блока `mail` в метаданных файла.
  factory FileMailOrigin.fromJson(Map<String, dynamic> j) => FileMailOrigin(
        id: j.s('id'),
        subject: j.sN('subject'),
        fromName: j.sN('fromName'),
        fromAddr: j.sN('fromAddr'),
        sortAt: j.sN('sortAt'),
        box: j.sN('box'),
      );
}

/// Метаданные одного файла для деталки и просмотрщика (ручка `/files/:id`): имя, размер, тип,
/// хеш содержимого и всё, что удалось разобрать из самого файла.
class FileMeta {
  final String id;
  final String name;
  /// Время появления записи в облаке (ISO-8601) — то же, что показывает деталка как «Создан».
  final String? createdAt;
  /// Время последнего изменения записи в облаке, а не содержимого (ISO-8601): им подписывается
  /// «Изменён» в деталке. Пусто, если сервер поле не прислал.
  final String? updatedAt;
  /// Исходное время изменения файла на устройстве, откуда его залили (ISO-8601); пусто у файлов,
  /// залитых без него (браузер, вложение письма).
  final String? clientMtime;
  /// id папки, в которой лежит запись. Модель его разбирает, но интерфейс пока не показывает:
  /// по дереву приложение ходит id-шниками листинга, а не этим полем.
  final String? folderId;
  // Зона дерева: FILES — обычный диск, PHOTOS — медиатека «Фото» (лента и превью), MAIL —
  // скрытая зона вложений писем. От зоны зависит и видимость файла, и сборка превью. В
  // интерфейсе зона не показывается: деталка доступна только по прямой ссылке и знает своё
  // место, а листинг папок скрытые зоны и так не отдаёт.
  final String zone;
  // Человекочитаемый путь («Фото/2024/март»), а не id: его и показывает деталка.
  final String path;
  // Заполнено, только если файл — вложение письма.
  final FileMailOrigin? mail;
  /// Размер содержимого в байтах. `0` — либо пустой файл, либо сервер не прислал размер.
  final int size;
  final String mime;
  final String? ext;
  // Ключ содержимого и превью в хранилище: по нему строятся ссылки `/previews/:sha`.
  final String sha256;
  // Число страниц PDF; пусто у остальных файлов — по нему ограничен постраничный просмотр.
  final int? pageCount;
  // Разобранные метаданные содержимого; пусто, если разбор ещё не делали.
  final FileMedia? media;

  FileMeta({
    required this.id,
    required this.name,
    this.createdAt,
    this.updatedAt,
    this.clientMtime,
    this.folderId,
    required this.zone,
    required this.path,
    this.mail,
    required this.size,
    required this.mime,
    this.ext,
    required this.sha256,
    this.pageCount,
    this.media,
  });

  /// Разбор ответа `/files/:id`.
  ///
  /// Вложенные блоки достаём по одному разу через [JsonX.m]: он возвращает `null` для не-объекта,
  /// поэтому испорченный блок теряет только своё поле, а не роняет разбор всего ответа.
  factory FileMeta.fromJson(Map<String, dynamic> j) {
    final mail = j.m('mail');
    final media = j.m('media');
    return FileMeta(
      id: j.s('id'),
      name: j.s('name'),
      createdAt: j.sN('createdAt'),
      updatedAt: j.sN('updatedAt'),
      clientMtime: j.sN('clientMtime'),
      folderId: j.sN('folderId'),
      zone: j.s('zone'),
      path: j.s('path'),
      mail: mail == null ? null : FileMailOrigin.fromJson(mail),
      size: j.i('size'),
      mime: j.s('mime'),
      ext: j.sN('ext'),
      sha256: j.s('sha256'),
      pageCount: j.iN('pageCount'),
      media: media == null ? null : FileMedia.fromJson(media),
    );
  }
}

// ===== буфер копирования/вырезания =====

/// Что сейчас лежит в буфере обмена файлового менеджера («скопировать» или «вырезать»).
///
/// Буфер хранится на сервере у пользователя, поэтому его видят все его клиенты. После
/// «вырезать» запись остаётся на месте до вставки — тогда сервер её и удаляет.
class ClipboardView {
  /// Что положили в буфер: `file` или `folder`. Папку можно только вырезать — копирование
  /// папок сервер запрещает (`POST /clipboard` отвечает ошибкой).
  final String kind;
  /// Что с записью сделают при вставке: `copy` (цель остаётся на месте) или `cut` (её удалит
  /// сервер после успешной вставки).
  final String mode;
  final String id;
  final String name;
  // Запись ещё жива. Её могли удалить или уже вставить в другом клиенте, поэтому перед
  // вставкой наличие проверяют по этому признаку.
  final bool available;
  /// Когда запись положили в буфер (ISO-8601). Интерфейс это поле не показывает: в панели
  /// вставки важно «что», а не «когда», — но контракт ответа его содержит.
  final String? at;

  ClipboardView({
    required this.kind,
    required this.mode,
    required this.id,
    required this.name,
    required this.available,
    this.at,
  });

  /// Разбор ответа `/clipboard`.
  factory ClipboardView.fromJson(Map<String, dynamic> j) => ClipboardView(
        kind: j.s('kind'),
        mode: j.s('mode'),
        id: j.s('id'),
        name: j.s('name'),
        available: j.b('available'),
        at: j.sN('at'),
      );
}

/// Метаданные папки для её карточки: имя, путь, время изменения и что внутри.
class FolderMeta {
  final String id;
  final String name;
  /// Зона дерева: `FILES`, `PHOTOS` или `MAIL` (см. [FileMeta.zone]). Карточка папки зону не
  /// показывает: в неё попадают только папки видимых зон.
  final String zone;
  final String path;
  // Счётчики для подписи «папок: 3 · файлов: 12» — сервер считает их сам, клиент не обходит дерево.
  final int folders;
  final int entries;
  /// Время создания папки (ISO-8601); пусто, если сервер не прислал.
  final String? createdAt;
  /// Время последнего изменения содержимого папки (ISO-8601); пусто, если сервер не прислал.
  final String? updatedAt;

  FolderMeta({
    required this.id,
    required this.name,
    required this.zone,
    required this.path,
    required this.folders,
    required this.entries,
    this.createdAt,
    this.updatedAt,
  });

  /// Разбор ответа `/folders/:id/meta`.
  factory FolderMeta.fromJson(Map<String, dynamic> j) => FolderMeta(
        id: j.s('id'),
        name: j.s('name'),
        zone: j.s('zone'),
        path: j.s('path'),
        folders: j.i('folders'),
        entries: j.i('entries'),
        createdAt: j.sN('createdAt'),
        updatedAt: j.sN('updatedAt'),
      );
}

// ===== trash =====

/// Одна запись в корзине файлов — удалённая папка или файл.
class TrashItem {
  final String id;
  final String name;
  // Время удаления: по нему считается очистка «старше N дней».
  final String? deletedAt;
  final String kind; // folder | file
  final int? size;

  TrashItem({required this.id, required this.name, this.deletedAt, required this.kind, this.size});

  /// Разбор элемента ответа `/trash`.
  factory TrashItem.fromJson(Map<String, dynamic> j) => TrashItem(
        id: j.s('id'),
        name: j.s('name'),
        deletedAt: j.sN('deletedAt'),
        kind: j.s('kind'),
        size: j.iN('size'),
      );
}

/// Вся корзина файлов: папки и файлы отдельными списками, как и в листинге папки.
class TrashView {
  final List<TrashItem> folders;
  final List<TrashItem> entries;

  TrashView({required this.folders, required this.entries});

  /// Разбор ответа `/trash`.
  factory TrashView.fromJson(Map<String, dynamic> j) => TrashView(
        folders: j.lm('folders').map(TrashItem.fromJson).toList(),
        entries: j.lm('entries').map(TrashItem.fromJson).toList(),
      );
}

// ===== app-токены =====

/// Строка списка app-токенов (device-токенов) в настройках.
///
/// Сам токен сервер показывает один раз при выпуске и больше не отдаёт: здесь только метка,
/// выданная область доступа и следы использования.
class ApiTokenRow {
  final String id;
  final String label;
  // Область доступа, выданная токену.
  final String scope;
  // Пусто, если токеном ещё не пользовались — в списке это подпись «не использовался».
  final String? lastUsedAt;
  final String? createdAt;
  /// Срок жизни токена (ISO-8601): после него сервер токен не принимает, продления нет.
  /// Сервер отдаёт поле всегда — `null` здесь означает, что поля не было в ответе, а не
  /// «токен бессрочный». Панель токенов срок пока не выводит.
  final String? expiresAt;

  ApiTokenRow({
    required this.id,
    required this.label,
    required this.scope,
    this.lastUsedAt,
    this.createdAt,
    this.expiresAt,
  });

  /// Разбор элемента ответа `/auth/tokens`.
  factory ApiTokenRow.fromJson(Map<String, dynamic> j) => ApiTokenRow(
        id: j.s('id'),
        label: j.s('label'),
        scope: j.s('scope'),
        lastUsedAt: j.sN('lastUsedAt'),
        createdAt: j.sN('createdAt'),
        expiresAt: j.sN('expiresAt'),
      );
}

// ===== медиа =====

/// Кадр в ленте «Медиа» — сокращённая форма для сетки и таймлайна.
///
/// Полные метаданные кадра — [MediaInfo], здесь только то, по чему строится плитка: имя, тип,
/// размер, хеш превью и состояние его сборки.
class MediaItem {
  /// id записи файла в дереве (не хеш): по нему запрашиваются метаданные и содержимое.
  final String entryId;
  final String name;
  // Время съёмки; пусто — кадр попадает в бакет «Без даты».
  final String? capturedAt;
  final String mime;
  final String? sha256;
  // Готовность превью: 'done' — плитка показывает картинку, 'none' — превью ещё не собрано
  // (задача ждёт в очереди или её только что поставили), 'impossible' — превью для этого файла
  // не будет вовсе.
  final String previewState;
  // Состояние задачи сборки ('pending'/'processing'/'failed'), пусто если задачи нет: по нему
  // лента отличает «ещё не начинали» от «упало». Поле есть в модели, потому что его отдаёт
  // `/media/range`, но сетка медиа его не показывает: `previewState` для плитки достаточно, а
  // различать «ждёт» и «собрать нельзя» интерфейс пока не умеет.
  final String? jobState;
  /// Размер содержимого в байтах. `0` — либо пустой файл, либо сервер не прислал размер.
  final int size;
  /// Пояс съёмки в минутах на восток от UTC (Москва: `180`), либо `null`.
  ///
  /// Нужен потому, что [capturedAt] — уже пересчитанный UTC-момент: чтобы показать «время как
  /// в файле», к нему надо прибавить этот сдвиг (см. `fmtMediaDate`). `null` означает, что пояса
  /// в тегах не было — тогда показываем время в поясе устройства.
  final int? tzOffsetMin;

  MediaItem({
    required this.entryId,
    required this.name,
    this.capturedAt,
    required this.mime,
    this.sha256,
    required this.previewState,
    this.jobState,
    required this.size,
    this.tzOffsetMin,
  });

  /// Копия кадра с изменёнными полями.
  ///
  /// Нужна там, где по кадру приходит не весь кадр, а часть: опрос `/media/status` отдаёт только
  /// состояние превью, а показать его надо на той же плитке, что уже на экране.
  MediaItem copyWith({String? previewState, String? jobState}) => MediaItem(
        entryId: entryId,
        name: name,
        capturedAt: capturedAt,
        mime: mime,
        sha256: sha256,
        previewState: previewState ?? this.previewState,
        jobState: jobState ?? this.jobState,
        size: size,
        tzOffsetMin: tzOffsetMin,
      );

  /// Разбор элемента ответа `/media/range` и `/media/feed`.
  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
        entryId: j.s('entryId'),
        name: j.s('name'),
        capturedAt: j.sN('capturedAt'),
        mime: j.s('mime'),
        sha256: j.sN('sha256'),
        previewState: j.s('previewState'),
        jobState: j.sN('jobState'),
        size: j.i('size'),
        tzOffsetMin: j.iN('tzOffsetMin'),
      );
}

/// Позиция кадра в ленте — курсор листания (ручка `/media/feed`).
///
/// Пара `(at, id)` адресует точку ленты ровно так же, как её упорядочивает сервер
/// (`capturedAt DESC NULLS LAST, id DESC`): [at] — момент съёмки в UTC, [id] — id записи,
/// который разрывает ничьи по одинаковому моменту и адресует хвост ленты без даты.
///
/// Курсор, а не номер кадра: библиотека живая (приложение само выгружает фото с телефона),
/// и между двумя запросами состав ленты меняется — по номеру на уже показанном месте
/// оказался бы чужой кадр.
class MediaCursor {
  /// Момент съёмки в UTC (ISO); `null` — кадр без даты, такие идут в конце ленты.
  final String? at;
  /// id записи (он же `entryId` кадра). Пустая строка допустима только у курсора без даты и
  /// означает его край: «с начала хвоста» при листании вниз и «к самым старым датированным
  /// кадрам» при листании вверх.
  final String id;

  const MediaCursor({required this.at, required this.id});

  /// Курсор кадра ленты — по нему начинается страница «старше этого кадра» или «новее него».
  factory MediaCursor.of(MediaItem item) => MediaCursor(at: item.capturedAt, id: item.entryId);

  /// Разбор сохранённого вида `at|id` (мета синхронизации: там курсор лежит строкой).
  ///
  /// Разделитель — вертикальная черта: момента съёмки в нём быть не может (ISO её не содержит),
  /// а id записи — uuid. Строка без разделителя считается испорченной и даёт `null`: продолжать
  /// наполнение с непонятного места хуже, чем начать его заново.
  static MediaCursor? decode(String? raw) {
    if (raw == null) return null;
    final i = raw.indexOf('|');
    if (i < 0) return null;
    final at = raw.substring(0, i);
    return MediaCursor(at: at.isEmpty ? null : at, id: raw.substring(i + 1));
  }

  /// Сохранённый вид `at|id` (см. [decode]).
  String encode() => '${at ?? ''}|$id';

  /// Сравнение по значению: курсоры сверяются, чтобы не запрашивать одну и ту же страницу дважды.
  @override
  bool operator ==(Object other) =>
      other is MediaCursor && other.at == at && other.id == id;

  @override
  int get hashCode => Object.hash(at, id);

  @override
  String toString() => encode();
}

/// Страница курсорной ленты `GET /media/feed`: кадры в порядке ленты и признак продолжения.
class MediaFeedPage {
  /// Кадры от свежих к старым — в том же порядке, что и вся лента.
  final List<MediaItem> items;
  /// Есть ли кадры дальше по направлению запроса: для `before` — старше последнего
  /// отданного, для `after` — новее первого. `false` — направление исчерпано.
  final bool hasMore;

  MediaFeedPage({required this.items, required this.hasMore});

  /// Разбор ответа `/media/feed`.
  factory MediaFeedPage.fromJson(Map<String, dynamic> j) => MediaFeedPage(
        items: j.lm('items').map(MediaItem.fromJson).toList(),
        hasMore: j.b('hasMore'),
      );
}

/// Месяц в таймлайне «Медиа»: сколько кадров на него приходится.
class MediaMonthBucket {
  // Ключ «ГГГГ-ММ»; пусто — бакет «Без даты» для кадров без времени съёмки.
  final String? month;
  final int count;

  MediaMonthBucket({this.month, required this.count});

  /// Разбор элемента ответа `/media/months`.
  factory MediaMonthBucket.fromJson(Map<String, dynamic> j) =>
      MediaMonthBucket(month: j.sN('month'), count: j.i('count'));
}

/// Состояние сборки превью для одного кадра — ответ на точечный опрос `/media/status`.
///
/// Галерея переспрашивает так видимые кадры, у которых превью ещё не собрано: состояние
/// приходит вместе с кадром, но к моменту показа превью часто только в очереди. Сервер режет
/// список id до 500 (`MEDIA_STATUS_MAX`) и оставшиеся молча игнорирует — клиент помнит об этом
/// сам (`GalleryController` шлёт не больше 500 id за раз).
class MediaStatusItem {
  /// id записи файла в дереве.
  final String entryId;
  /// Готовность превью: `none` | `done` | `impossible` (см. [MediaItem.previewState]).
  final String previewState;
  /// Состояние последней задачи сборки: `pending` | `processing` | `failed`, `null` — задачи нет.
  final String? jobState;

  MediaStatusItem({required this.entryId, required this.previewState, this.jobState});

  /// Разбор элемента ответа `/media/status`.
  factory MediaStatusItem.fromJson(Map<String, dynamic> j) => MediaStatusItem(
        entryId: j.s('entryId'),
        previewState: j.s('previewState'),
        jobState: j.sN('jobState'),
      );
}

/// Полные метаданные кадра для просмотрщика и карточки параметров (ручка `/media/:entryId`).
///
/// Кроме общих полей файла здесь фото- и видеопараметры: камера, объектив, экспозиция, размер
/// кадра, длительность. Пустое поле означает, что тега не было в самом файле.
class MediaInfo {
  final String entryId;
  final String name;
  final String mime;
  /// Размер содержимого в байтах.
  final int size;
  final String sha256;
  /// Время съёмки (ISO-8601, как его отдал разбор EXIF).
  final String? capturedAt;
  /// Пояс съёмки в минутах на восток от UTC (см. [MediaItem.tzOffsetMin]).
  final int? tzOffsetMin;
  /// Размер кадра в пикселях.
  final int? width;
  final int? height;
  final String? make;
  final String? model;
  /// Координаты съёмки в градусах WGS-84; сервер округляет их до 5 знаков.
  final double? latitude;
  final double? longitude;
  final String? lens;
  /// Диафрагма как число: `1.8` — это `f/1.8` на выводе.
  final double? fNumber;
  /// Выдержка строкой из EXIF: «1/120» или «2.5».
  final String? exposureTime;
  /// Светочувствительность EXIF.
  final int? iso;
  /// Фокусное расстояние, мм.
  final double? focalLength;
  // Фокусное расстояние в пересчёте на 35-мм кадр — по нему сравнивают кадры с разными матрицами.
  final double? focalLength35;
  /// Длительность видео в секундах. Сервер отдаёт её числом с дробной частью (ffprobe), здесь
  /// значение округлено до целой секунды — показ идёт через `fmtDuration(int)`.
  final int? durationSec;
  /// Частота кадров, кадров в секунду.
  final double? fps;
  final String? videoCodec;

  MediaInfo({
    required this.entryId,
    required this.name,
    required this.mime,
    required this.size,
    required this.sha256,
    this.capturedAt,
    this.tzOffsetMin,
    this.width,
    this.height,
    this.make,
    this.model,
    this.latitude,
    this.longitude,
    this.lens,
    this.fNumber,
    this.exposureTime,
    this.iso,
    this.focalLength,
    this.focalLength35,
    this.durationSec,
    this.fps,
    this.videoCodec,
  });

  /// Разбор ответа `/media/:entryId`.
  factory MediaInfo.fromJson(Map<String, dynamic> j) => MediaInfo(
        entryId: j.s('entryId'),
        name: j.s('name'),
        mime: j.s('mime'),
        size: j.i('size'),
        sha256: j.s('sha256'),
        capturedAt: j.sN('capturedAt'),
        tzOffsetMin: j.iN('tzOffsetMin'),
        width: j.iN('width'),
        height: j.iN('height'),
        make: j.sN('make'),
        model: j.sN('model'),
        latitude: j.dN('latitude'),
        longitude: j.dN('longitude'),
        lens: j.sN('lens'),
        fNumber: j.dN('fNumber'),
        exposureTime: j.sN('exposureTime'),
        iso: j.iN('iso'),
        focalLength: j.dN('focalLength'),
        focalLength35: j.dN('focalLength35'),
        durationSec: toNum(j['durationSec'])?.round(),
        fps: j.dN('fps'),
        videoCodec: j.sN('videoCodec'),
      );
}

/// Точка на карте: кадр и его координаты.
class MapPoint {
  final String entryId;
  final double lat;
  final double lon;

  MapPoint({required this.entryId, required this.lat, required this.lon});

  /// Разбор элемента `points` из ответа `/media/map`.
  factory MapPoint.fromJson(Map<String, dynamic> j) =>
      MapPoint(entryId: j.s('entryId'), lat: j.d('lat'), lon: j.d('lon'));
}

// ===== очередь превью =====

/// Оценка срока по виду задачи (с сервера): медианная длительность задачи за последние
/// часы и срок на остаток. null — статистики ещё нет, тогда оценку не показываем.
class QueueEstimate {
  /// Медианная длительность одной задачи этого вида, секунды.
  final int? avgSec;
  /// Сколько ждать остаток задач этого вида, секунды: сервер уже поделил оценку на число
  /// параллельных слотов, то есть это срок до конца очереди, а не до одной задачи.
  /// `null` — статистики нет, оценку показывать нечем.
  final int? etaSec;
  /// Сколько задач попало в статистику. Экрану очереди не нужен: он показывает только [etaSec];
  /// поле осталось потому, что сервер его отдаёт и по нему видно, насколько оценке верить.
  final int samples;

  QueueEstimate({this.avgSec, this.etaSec, this.samples = 0});

  factory QueueEstimate.fromJson(Map<String, dynamic> j) => QueueEstimate(
        avgSec: j.iN('avgSec'),
        etaSec: j.iN('etaSec'),
        samples: j.i('samples'),
      );
}

/// Состояние очереди сборки превью — то, что рисует экран очереди в настройках.
///
/// Кроме счётчиков задач здесь две вещи, которые знает только сервер: оценка срока по видам
/// задач ([estimates]) и свободное место на его диске ([diskFree]).
class QueueStatus {
  /// Очередь на паузе: новые задачи не берутся, пока её не снимут.
  final bool paused;
  /// Сколько задач ждёт или уже выполняется — всё, что осталось сделать, в штуках.
  /// Сервер считает это как «в очереди» + «в работе» (`queue.controller.ts`) и отдаёт поле
  /// всегда; отсутствие поля в ответе разбор превратит в `0`, то есть в «очередь пуста».
  final int remaining;
  /// Сколько задач выполняется прямо сейчас. Экран очереди это поле не показывает: [remaining]
  /// уже включает его в себя.
  final int processing;
  /// Сколько задач упало и осталось в очереди со статусом ошибки (их можно повторить).
  final int errors;
  // Сколько задач каждого вида ('photo', 'video', 'pdf') ждёт очереди: ключи задаёт сервер.
  final Map<String, int> remainingByKind;
  /// Оценка срока по видам задач: ключ — вид ('photo', 'video', 'pdf'). Вид без статистики в
  /// ответе отсутствует.
  final Map<String, QueueEstimate> estimates;
  // Свободно на диске сервера, в байтах; пусто, если измерить не удалось.
  final int? diskFree;
  // Сервер считает, что места мало. Пусто при неудачном измерении — тогда предупреждения нет.
  final bool? diskLow;

  QueueStatus({
    required this.paused,
    required this.remaining,
    required this.processing,
    required this.errors,
    required this.remainingByKind,
    this.estimates = const {},
    this.diskFree,
    this.diskLow,
  });

  /// Разбор ответа `/queue/status`.
  ///
  /// Вложенные объекты разбираются терпимо: значение, которое не является объектом, теряет свою
  /// строку в карте, но не роняет разбор всего статуса очереди.
  factory QueueStatus.fromJson(Map<String, dynamic> j) => QueueStatus(
        paused: j.b('paused'),
        remaining: j.i('remaining'),
        processing: j.i('processing'),
        errors: j.i('errors'),
        remainingByKind: (j.m('remainingByKind') ?? const {})
            .map((k, v) => MapEntry(k, toNum(v)?.toInt() ?? 0)),
        estimates: {
          for (final e in (j.m('estimates') ?? const {}).entries)
            if (e.value is Map)
              e.key: QueueEstimate.fromJson((e.value as Map).cast<String, dynamic>()),
        },
        diskFree: j.iN('diskFree'),
        diskLow: j.bN('diskLow'),
      );
}

/// Строка списка последних ошибок очереди превью.
class QueueErrorRow {
  final String id;
  // Вид задачи, на которой упало.
  final String kind;
  // Текст ошибки с сервера: он уже человекочитаемый, поэтому показываем как есть.
  final String error;
  // Сколько попыток задача уже сделала.
  final int attempts;
  // Когда задача закончилась неудачей.
  final String? finishedAt;
  // Файл, на котором упало; пусто, если запись файла уже удалена.
  final String? entryId;
  final String? name;

  QueueErrorRow({
    required this.id,
    required this.kind,
    required this.error,
    required this.attempts,
    this.finishedAt,
    this.entryId,
    this.name,
  });

  /// Разбор элемента ответа `/queue/errors` (сам список разбирает экран настроек).
  factory QueueErrorRow.fromJson(Map<String, dynamic> j) => QueueErrorRow(
        id: j.s('id'),
        kind: j.s('kind'),
        error: j.s('error'),
        attempts: j.i('attempts'),
        finishedAt: j.sN('finishedAt'),
        entryId: j.sN('entryId'),
        name: j.sN('name'),
      );
}

/// Страница упавших задач: сервер отдаёт её вместе с общим числом.
///
/// Число нужно отдельно от [items]: список листается порциями (см. `queueErrors`), и по длине
/// страницы нельзя понять, сколько ошибок всего — а по [total] экран считает число страниц.
class QueueErrorPage {
  /// Сколько всего упавших задач у пользователя (не только в этой странице).
  final int total;
  /// Строки текущей страницы, свежие сверху.
  final List<QueueErrorRow> items;

  QueueErrorPage({required this.total, required this.items});

  /// Разбор ответа `/queue/errors`. Мусор в `items` (не список) читается как пустая страница,
  /// а не как ошибка: показать нечего — это не сбой разбора.
  factory QueueErrorPage.fromJson(Map<String, dynamic> j) => QueueErrorPage(
        total: j.i('total'),
        items: j.lm('items').map(QueueErrorRow.fromJson).toList(),
      );
}

// ===== разархивирование =====

/// Задача разархивирования архива: прогресс и итог.
///
/// Прогресс считается сервером по числу записей архива ([doneEntries] из [totalEntries]), а не
/// по байтам: в архиве бывают тысячи мелких файлов, и по байтам полоса стояла бы почти до конца.
class UnzipJob {
  final String id;
  final String entryId;
  final String state;
  final int totalEntries;
  final int doneEntries;
  final int totalBytes;
  final int doneBytes;
  final int skippedEntries;
  // Имя записи, которую распаковывают прямо сейчас — подпись под полосой прогресса.
  final String? currentName;
  // Текст ошибки, если задача упала или её отменили.
  final String? error;
  // Папка, в которую распаковывается: сервер заводит её сам при старте задачи.
  final String? targetFolderId;
  // Готовность в процентах, как её посчитал сервер.
  final int percent;
  final String? createdAt;
  final String? startedAt;
  final String? finishedAt;

  UnzipJob({
    required this.id,
    required this.entryId,
    required this.state,
    required this.totalEntries,
    required this.doneEntries,
    required this.totalBytes,
    required this.doneBytes,
    required this.skippedEntries,
    this.currentName,
    this.error,
    this.targetFolderId,
    required this.percent,
    this.createdAt,
    this.startedAt,
    this.finishedAt,
  });

  /// Разбор ответа `/unzip`, `/unzip/:id` и результата отмены.
  factory UnzipJob.fromJson(Map<String, dynamic> j) => UnzipJob(
        id: j.s('id'),
        entryId: j.s('entryId'),
        state: j.s('state'),
        totalEntries: j.i('totalEntries'),
        doneEntries: j.i('doneEntries'),
        totalBytes: j.i('totalBytes'),
        doneBytes: j.i('doneBytes'),
        skippedEntries: j.i('skippedEntries'),
        currentName: j.sN('currentName'),
        error: j.sN('error'),
        targetFolderId: j.sN('targetFolderId'),
        percent: j.i('percent'),
        createdAt: j.sN('createdAt'),
        startedAt: j.sN('startedAt'),
        finishedAt: j.sN('finishedAt'),
      );
}

// ===== почта =====

/// Счётчики писем аккаунта для строки в настройках: сколько во входящих и в отправленных.
class MailCounts {
  /// Писем во входящих (без корзины).
  final int inbox;
  /// Писем в отправленных.
  final int sent;
  MailCounts({required this.inbox, required this.sent});
  /// Разбор блока `counts` аккаунта.
  factory MailCounts.fromJson(Map<String, dynamic> j) =>
      MailCounts(inbox: j.i('inbox'), sent: j.i('sent'));
}

/// Подключённый почтовый аккаунт целиком — строка списка `GET /mail/accounts`.
///
/// Это единственная ручка, которая отдаёт [kind], [label], [counts] и [createdAt]: у `/mail/status`
/// поля короче (только id, адрес, состояние и время синхронизации), и разбирать его этой моделью
/// нельзя — отсутствующие поля молча стали бы `''` и `0`.
///
/// Пароля здесь нет и быть не может — он остался на сервере.
class MailAccountRow {
  final String id;
  // Тип подключения, как его называет сервер.
  final String kind;
  /// Человекочитаемое имя подключения (например, «Яндекс.Почта»): сервер выводит его из [kind].
  final String label;
  final String email;
  /// Включена ли синхронизация аккаунта в приложении.
  final bool enabled;
  /// Состояние синхронизации: `idle` | `syncing` | `error`; расшифровку для человека даёт экран
  /// настроек.
  final String status;
  /// Текст последней ошибки синхронизации, если она была.
  final String? statusError;
  /// Когда аккаунт последний раз успешно синхронизировался (ISO-8601); пусто — ни разу.
  final String? lastSyncAt;
  /// Когда аккаунт подключили (ISO-8601).
  final String? createdAt;
  /// Число писем по папкам — считается сервером по этому пользователю.
  final MailCounts counts;

  MailAccountRow({
    required this.id,
    required this.kind,
    required this.label,
    required this.email,
    required this.enabled,
    required this.status,
    this.statusError,
    this.lastSyncAt,
    this.createdAt,
    required this.counts,
  });

  /// Разбор ответа `/mail/accounts`.
  factory MailAccountRow.fromJson(Map<String, dynamic> j) => MailAccountRow(
        id: j.s('id'),
        kind: j.s('kind'),
        label: j.s('label'),
        email: j.s('email'),
        enabled: j.b('enabled'),
        status: j.s('status'),
        statusError: j.sN('statusError'),
        lastSyncAt: j.sN('lastSyncAt'),
        createdAt: j.sN('createdAt'),
        counts: MailCounts.fromJson(j.m('counts') ?? const {}),
      );
}

/// Письмо в списке ленты: шапка, начало тела и признаки — без тела целиком и без вложений.
class MailListItem {
  final String id;
  /// Папка письма: `inbox`, `sent`, `trash` и т.п. (сервер отдаёт строкой).
  final String box;
  /// Аккаунт, в который письмо пришло; пусто у писем, аккаунт которых не определился,
  /// поэтому фильтр «по аккаунту» нельзя строить на пустой строке.
  final String accountId;
  // Почта аккаунта: показывается в списке, когда аккаунтов несколько.
  final String accountEmail;
  final String? subject;
  final String? fromName;
  final String? fromAddr;
  // Начало тела письма — вторая строка строки списка.
  final String preview;
  // Время, по которому лента отсортирована; в корзине сервер сортирует по времени удаления.
  final String? sortAt;
  /// Письмо прочитано.
  final bool seen;
  /// Пользовательская метка «важное» — единственная метка, которую сервер хранит и умеет
  /// переключать (`POST /mail/messages/:id/flagged`). Интерфейс её пока не показывает; поле
  /// есть, чтобы состояние флага не терялось при разборе.
  final bool flagged;
  /// У письма есть вложения: сколько их, видно только в [MailMessageView].
  final bool hasAttachments;
  /// Размер письма в байтах.
  final int size;
  // Сколько писем в цепочке (1 — одиночное) — из этого получается бейдж цепочки.
  final int threadCount;

  MailListItem({
    required this.id,
    required this.box,
    required this.accountId,
    required this.accountEmail,
    this.subject,
    this.fromName,
    this.fromAddr,
    required this.preview,
    this.sortAt,
    required this.seen,
    required this.flagged,
    required this.hasAttachments,
    required this.size,
    required this.threadCount,
  });

  /// Разбор элемента ответа `/mail/range`.
  factory MailListItem.fromJson(Map<String, dynamic> j) => MailListItem(
        id: j.s('id'),
        box: j.s('box'),
        accountId: j.s('accountId'),
        accountEmail: j.s('accountEmail'),
        subject: j.sN('subject'),
        fromName: j.sN('fromName'),
        fromAddr: j.sN('fromAddr'),
        preview: j.s('preview'),
        sortAt: j.sN('sortAt'),
        seen: j.b('seen'),
        flagged: j.b('flagged'),
        hasAttachments: j.b('hasAttachments'),
        size: j.i('size'),
        threadCount: j.i('threadCount'),
      );
}

/// Вложение письма.
///
/// Сервер хранит вложения обычными файлами, поэтому у вложения есть [entryId]: по нему его можно
/// открыть, скачать или выбрать для пересылки.
class MailAttachment {
  final String id;
  // Файл в облаке: по нему строятся ссылки на содержимое и миниатюру.
  final String entryId;
  // [filename] — имя из письма, [name] — имя записи в облаке (его видно в деталке вложения).
  final String filename;
  final String name;
  final String mime;
  final int size;
  // Вложение встроено в тело письма (обычно картинка с contentId), а не приложено отдельно.
  final bool inline;
  /// Идентификатор для ссылки `cid:` внутри разметки письма. Разметку показывает WebView, он
  /// разрешает `cid:` сам, поэтому приложению поле не нужно — модель его хранит как часть
  /// контракта ответа.
  final String? contentId;

  MailAttachment({
    required this.id,
    required this.entryId,
    required this.filename,
    required this.name,
    required this.mime,
    required this.size,
    required this.inline,
    this.contentId,
  });

  /// Разбор элемента `attachments` в ответе `/mail/messages/:id`.
  factory MailAttachment.fromJson(Map<String, dynamic> j) => MailAttachment(
        id: j.s('id'),
        entryId: j.s('entryId'),
        filename: j.s('filename'),
        name: j.s('name'),
        mime: j.s('mime'),
        size: j.i('size'),
        inline: j.b('inline'),
        contentId: j.sN('contentId'),
      );
}

/// Письмо целиком: шапка, тело и вложения (ручка `/mail/messages/:id`).
///
/// Разметку тела экран запрашивает отдельно ([bodyText] — только текстовая версия), а заголовки
/// [messageId]/[inReplyTo]/[refs] нужны, чтобы ответ встал в цепочку, а не начал новую.
class MailMessageView {
  final String id;
  final String box;
  final String accountId;
  final String accountEmail;
  final String? subject;
  final String? fromName;
  final String? fromAddr;
  final String? sortAt;
  /// Письмо прочитано.
  final bool seen;
  /// Пользовательская метка «важное» (см. [MailListItem.flagged]): интерфейс её пока не
  /// показывает, но модель хранит, чтобы состояние флага не терялось.
  final bool flagged;
  /// У письма есть вложения — они приходят в [attachments].
  final bool hasAttachments;
  /// Размер письма в байтах.
  final int size;
  /// Сколько писем в цепочке (1 — одиночное) — из этого получается бейдж цепочки.
  final int threadCount;
  // Получатели из заголовков письма: нужны для карточки и для ответа «всем».
  final List<String> toAddrs;
  final List<String> ccAddrs;
  // Адрес для ответа, если он отличается от отправителя (рассылки и автоответчики).
  final String? replyTo;
  // Заголовок Message-ID письма — основа для цепочки ответов.
  final String? messageId;
  // Заголовок In-Reply-To: на какое письмо отвечали.
  final String? inReplyTo;
  // Цепочка References: по ней почтовые клиенты собирают ветку переписки.
  final List<String> refs;
  // Время отправки и время получения из заголовков; в списке показывается sortAt.
  final String? sentAt;
  final String? receivedAt;
  // Текстовая версия тела, если она есть в письме.
  final String? bodyText;
  final List<MailAttachment> attachments;

  MailMessageView({
    required this.id,
    required this.box,
    required this.accountId,
    required this.accountEmail,
    this.subject,
    this.fromName,
    this.fromAddr,
    this.sortAt,
    required this.seen,
    required this.flagged,
    required this.hasAttachments,
    required this.size,
    required this.threadCount,
    required this.toAddrs,
    required this.ccAddrs,
    this.replyTo,
    this.messageId,
    this.inReplyTo,
    required this.refs,
    this.sentAt,
    this.receivedAt,
    this.bodyText,
    required this.attachments,
  });

  /// Разбор ответа `/mail/messages/:id`.
  factory MailMessageView.fromJson(Map<String, dynamic> j) => MailMessageView(
        id: j.s('id'),
        box: j.s('box'),
        accountId: j.s('accountId'),
        accountEmail: j.s('accountEmail'),
        subject: j.sN('subject'),
        fromName: j.sN('fromName'),
        fromAddr: j.sN('fromAddr'),
        sortAt: j.sN('sortAt'),
        seen: j.b('seen'),
        flagged: j.b('flagged'),
        hasAttachments: j.b('hasAttachments'),
        size: j.i('size'),
        threadCount: j.i('threadCount'),
        toAddrs: j.ls('toAddrs'),
        ccAddrs: j.ls('ccAddrs'),
        replyTo: j.sN('replyTo'),
        messageId: j.sN('messageId'),
        inReplyTo: j.sN('inReplyTo'),
        refs: j.ls('refs'),
        sentAt: j.sN('sentAt'),
        receivedAt: j.sN('receivedAt'),
        bodyText: j.sN('bodyText'),
        attachments: j.lm('attachments').map(MailAttachment.fromJson).toList(),
      );
}

/// Месяц в ленте почты: сколько писем в нём.
class MailMonthBucket {
  final String month;
  final int count;

  MailMonthBucket({required this.month, required this.count});

  /// Разбор элемента ответа `/mail/months`.
  factory MailMonthBucket.fromJson(Map<String, dynamic> j) =>
      MailMonthBucket(month: j.s('month'), count: j.i('count'));
}

/// Вложение, уже выбранное для ответа или пересылки.
///
/// Приходит вместе с заготовкой письма: имя и размер нужны, чтобы показать вложение в форме до
/// отправки. Вложения, встроенные в тело (`inline`), сюда не попадают.
class MailReplyAttachment {
  final String entryId;
  final String filename;
  final int size;

  MailReplyAttachment({required this.entryId, required this.filename, required this.size});

  /// Разбор элемента `attachments` в заготовке письма.
  factory MailReplyAttachment.fromJson(Map<String, dynamic> j) => MailReplyAttachment(
        entryId: j.s('entryId'),
        filename: j.s('filename'),
        size: j.i('size'),
      );
}

/// Заготовка ответа или пересылки, собранная сервером: адресаты, тема и тело с цитатой.
///
/// Собирается на сервере, чтобы цитата выглядела одинаково во всех почтовых клиентах, а не так,
/// как её склеил бы телефон.
///
/// Это форма ответа, а не тело отправки: `POST /mail/send` ждёт другие имена полей (`text` вместо
/// [body], `attachEntryIds` вместо [attachments]) и разбирает их на сервере. Поэтому `toJson`
/// у модели нет — тело запроса собирает экран отправки, и его контракт описан там.
class MailReplyContext {
  final String accountId;
  final String to;
  final String cc;
  final String subject;
  final String body;
  // Письмо, на которое отвечаем: по нему сервер расставит заголовки цепочки при отправке.
  final String? inReplyToId;
  final List<MailReplyAttachment> attachments;

  MailReplyContext({
    required this.accountId,
    required this.to,
    required this.cc,
    required this.subject,
    required this.body,
    this.inReplyToId,
    required this.attachments,
  });

  /// Разбор ответа `/mail/messages/:id/reply-context`.
  factory MailReplyContext.fromJson(Map<String, dynamic> j) => MailReplyContext(
        accountId: j.s('accountId'),
        to: j.s('to'),
        cc: j.s('cc'),
        subject: j.s('subject'),
        body: j.s('body'),
        inReplyToId: j.sN('inReplyToId'),
        attachments: j.lm('attachments').map(MailReplyAttachment.fromJson).toList(),
      );
}

// ===== релиз приложения (обновление по кнопке) =====

/// Опубликованная сборка приложения — для обновления по кнопке.
///
/// Отдаётся ручками `/app/android` (мобильная сборка) и `/app/macos` (настольная) без
/// авторизации: приложение может стоять с отозванным токеном, а обновиться ему всё равно нужно.
/// Ответ у обеих ручек одинаковый, отличается только файл: APK и архив с `Cloudly.app`.
class AppRelease {
  /// Идентификатор пакета сборки (`ru.cloudly.sync`). В интерфейсе не показывается:
  /// обновление ставится поверх своего же пакета, сравнивать его не с чем.
  final String applicationId;
  /// Номер сборки — по нему приложение понимает, что есть обновление, сравнивая со своим:
  /// на Android это `versionCode` из манифеста, на macOS — `CFBundleVersion`.
  ///
  /// `0` означает «версия неизвестна»: так сервер отдаёт сборку, у которой нет описания
  /// (`latest.json`), — скачать её можно, но обновлением такая сборка не считается. Именно
  /// поэтому `0` здесь безопасный дефолт: он совпадает с серверным смыслом «версии нет».
  final int versionCode;
  /// Имя версии для показа («1.4.2»); у сборки без описания — пустая строка.
  final String versionName;
  /// Размер файла сборки в байтах (для подписи в настройках).
  final int size;
  // Хеш файла: по нему проверяется скачанное, чтобы не установить битую сборку.
  final String sha256;
  /// Минимальная версия Android, заявленная сборкой; в интерфейсе не показывается — установку
  /// всё равно решает система. У настольной сборки не заполняется.
  final int minSdk;
  /// Когда сборка собрана (ISO-8601). `null`, если описания сборки нет: сервер в этом случае
  /// отдаёт пустую строку, и разбор превращает её в `null`, чтобы проверка «есть ли дата»
  /// не путала «пусто» с «дата есть».
  final String? builtAt;
  // Прямая ссылка на APK.
  final String url;

  AppRelease({
    required this.applicationId,
    required this.versionCode,
    required this.versionName,
    required this.size,
    required this.sha256,
    required this.minSdk,
    this.builtAt,
    required this.url,
  });

  /// Разбор ответа `/app/android`.
  factory AppRelease.fromJson(Map<String, dynamic> j) {
    final builtAt = j.sN('builtAt');
    return AppRelease(
      applicationId: j.s('applicationId'),
      versionCode: toNum(j['versionCode'])?.toInt() ?? 0,
      versionName: j.s('versionName'),
      size: toNum(j['size'])?.toInt() ?? 0,
      sha256: j.s('sha256'),
      minSdk: toNum(j['minSdk'])?.toInt() ?? 0,
      builtAt: builtAt == null || builtAt.isEmpty ? null : builtAt,
      url: j.s('url'),
    );
  }
}
