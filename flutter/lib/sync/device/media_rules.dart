import '../section.dart';

/// Правила отбора: что считается фото и видео, что попадает в раздел «Файлы», а что не стоит
/// показывать вообще. Здесь только чистые функции — весь отбор живёт тут, в интерфейсе его нет,
/// и именно эти функции проверяют тесты.
///
/// Разделение на медиа и файлы идёт по расширению, а не по папке: скриншоты лежат и в `DCIM`,
/// и в `Pictures/Screenshots`, а скачанные фотографии — в `Download` рядом с документами,
/// поэтому «папки для фото» и «папки для файлов» списком не разложить.
///
/// Пользуются этими правилами обход диска (`device_files.dart`), обход зеркала
/// (`mirror/mirror_scanner.dart`, `mirror/mirror_rules.dart`, `mirror/mirror_pull.dart`),
/// выгрузка (`queue/upload_runner.dart` — тип файла для сервера) и экран очереди
/// (`ui/queue_screen.dart` — иконка строки). Одно правило на всех и означает, что зеркало
/// и очередь видят одинаковый набор файлов.
abstract final class MediaRules {
  /// Фото: сюда же RAW и HEIC — камера телефона пишет именно так.
  static const Set<String> _image = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif', 'jxl',
    'dng', 'raw', 'cr2', 'cr3', 'nef', 'arw', 'orf', 'raf', 'rw2', 'pef', 'sr2',
    'tif', 'tiff', 'svg',
  };

  /// Видео: включает контейнеры камер и телефонов (`3gp`, `mts`) и то, что часто скачивают.
  /// Расширения сравниваются в нижнем регистре — камеры пишут и `JPG`, и `MP4`.
  static const Set<String> _video = {
    'mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', '3gp', '3g2', 'mpg', 'mpeg',
    'mts', 'm2ts', 'ts', 'wmv', 'flv',
  };

  /// Недописанное и служебное: в списках не показываем.
  ///
  /// `.cloudly-tmp` — наш собственный временный файл при скачивании, `.cloudly-old` — резервная
  /// копия прежней версии, которую скачивание оставляет на время подмены файла (см.
  /// `SyncApi.downloadToFile`; оба имени начинаются с точки, и суффикс здесь — вторая линия
  /// защиты). Это не мелочь: если процесс убили между двумя переименованиями, рядом с файлом
  /// остаётся `<имя>.cloudly-old` — без этих правил он попал бы в разделы и **уехал бы в облако
  /// как обычный файл**, а сам файл на телефоне выглядел бы пропавшим.
  static const List<String> _junkSuffix = [
    '.tmp',
    '.part',
    '.crdownload',
    '.cloudly-tmp',
    '.cloudly-old',
  ];

  /// Служебные каталоги: в дереве выбора их нет и при скане они не обходятся.
  static const Set<String> _skipNames = {'.thumbnails', '.trashed', 'LOST.DIR'};

  /// Расширение имени в нижнем регистре без точки; пустая строка — точки в имени нет
  /// (`README`) или имя кончается точкой. Считается от последней точки, поэтому
  /// `archive.tar.gz` даёт `gz` — для отбора медиа это верно, а составные расширения
  /// в правилах не участвуют.
  static String extension(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// Фото ли файл — по расширению из [_image].
  static bool isImage(String name) => _image.contains(extension(name));

  /// Видео ли файл — по расширению из [_video].
  static bool isVideo(String name) => _video.contains(extension(name));

  /// Фото и видео вместе — то, что показывается в разделе «Фото и видео».
  static bool isMedia(String name) => isImage(name) || isVideo(name);

  /// Куда попадает файл: медиа — в фото, всё остальное — в файлы.
  ///
  /// Разделы дополняют друг друга: один и тот же файл не может попасть в оба, и это то, ради
  /// чего раздел «Файлы» показывает документы, а не «всё, что не попало в фото».
  static bool matches(Section section, String name) =>
      section == Section.photos ? isMedia(name) : !isMedia(name);

  /// Имена на точку не показываем: это `.nomedia`, `.thumbnails`, чужой служебный мусор.
  static bool isHidden(String name) => name.startsWith('.');

  /// Недописанный или временный файл: определяется по суффиксу из [_junkSuffix], поэтому
  /// `video.mp4.part`, `video.mp4.cloudly-tmp` и `report.pdf.cloudly-old` отсеиваются, а
  /// `video.mp4` и `report.pdf` — нет. Сверка (`mirror/mirror_rules.dart`) смотрит на то же
  /// правило: имена, которые видит обход зеркала, обязаны отсеиваться и там, иначе брошенный
  /// бэкап уехал бы в облако как самостоятельный файл.
  static bool isJunk(String name) {
    final lower = name.toLowerCase();
    return _junkSuffix.any(lower.endsWith);
  }

  /// Служебные каталоги. `Android/data` и `Android/obb` — не файлы пользователя, а тысячи
  /// каталогов приложений: в раскрытом дереве они хоронят всё остальное.
  ///
  /// [parentName] — имя родительской папки: `data` и `obb` пропускаются только внутри
  /// `Android`, потому что папка с таким именем в другом месте — обычная папка пользователя.
  /// Имена, начинающиеся с точки, и [_skipNames] пропускаются независимо от родителя.
  static bool skipDir(String name, String parentName) {
    if (isHidden(name)) return true;
    if (_skipNames.contains(name)) return true;
    return parentName == 'Android' && (name == 'data' || name == 'obb');
  }

  /// Mime по расширению. Сервер сам решает, конвертировать ли медиа, но тип нужен при записи:
  /// по нему же файл уходит получателю и открывается просмотрщиком.
  ///
  /// Неизвестное расширение — `application/octet-stream` (не «пустой тип»): сервер и телефон
  /// так понимают «обычный файл», а пустой mime сломал бы открытие.
  static String mimeOf(String name) {
    switch (extension(name)) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'heic':
        return 'image/heic';
      case 'heif':
        return 'image/heif';
      case 'avif':
        return 'image/avif';
      case 'dng':
      case 'raw':
      case 'cr2':
      case 'cr3':
      case 'nef':
      case 'arw':
        return 'image/x-raw';
      case 'tif':
      case 'tiff':
        return 'image/tiff';
      case 'mp4':
      case 'm4v':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mkv':
        return 'video/x-matroska';
      case 'webm':
        return 'video/webm';
      case 'avi':
        return 'video/avi';
      case '3gp':
      case '3g2':
        return 'video/3gpp';
      case 'pdf':
        return 'application/pdf';
      case 'zip':
        return 'application/zip';
      case 'txt':
        return 'text/plain';
      case 'json':
        return 'application/json';
      default:
        return 'application/octet-stream';
    }
  }

  /// Подходит ли файл под запрос чужого приложения: `image/*`, `application/pdf`, `*/*`.
  ///
  /// Осталась от удалённой Activity выбора файла: она отвечала на `GET_CONTENT` чужого
  /// приложения, и по запрошенному типу надо было решить, что показывать в списке. В
  /// Flutter-приложении эта Activity не перенесена (см. `FLUTTER.md`), поэтому в рабочем коде
  /// функцию никто не зовёт — её проверяет только `test/sync/media_rules_test.dart`.
  ///
  /// [requested] — тип, который просит приложение (null или пустая строка — «любой»),
  /// [mime] — тип файла из [mimeOf]. Показывать в таком выборе видео, когда просили картинку,
  /// значит гарантированно получить отказ у получателя, поэтому:
  /// `*/*` и пустой запрос подходят всему; `тип/*` — совпадению по первой части; иначе нужно
  /// точное совпадение. Файл с пустым типом не подходит конкретному запросу, но подходит
  /// запросу «любой».
  static bool matchesRequest(String? requested, String mime) {
    final want = (requested ?? '').trim().toLowerCase();
    if (want.isEmpty || want == '*/*') return true;
    final have = mime.trim().toLowerCase();
    if (have.isEmpty) return false;
    if (want.endsWith('/*')) return have.startsWith(want.substring(0, want.length - 1));
    return have == want;
  }

  /// Размер в человеческом виде: «4.2 МБ» читается лучше, чем «4404019».
  ///
  /// Считается в двоичных единицах (1 КБ = 1024 Б) — так размер показывает и сам Android,
  /// и человек в проводнике. До 10 единиц — один знак после точки, дальше округление до целого:
  /// «12 МБ» информативнее, чем «11.7 МБ», а «4.2 МБ» — чем «4 МБ». Больше ТБ не бывает
  /// в файле на телефоне, поэтому список единиц на нём и кончается.
  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes Б';
    const units = ['КБ', 'МБ', 'ГБ', 'ТБ'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    final text = value < 10 ? value.toStringAsFixed(1) : value.toStringAsFixed(0);
    return '$text ${units[unit]}';
  }
}
