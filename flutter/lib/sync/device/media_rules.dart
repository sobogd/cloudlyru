import '../section.dart';

/// Правила отбора: что считается фото и видео, что попадает в раздел «Файлы», а что не стоит
/// показывать вообще. Здесь только чистые функции — весь отбор живёт тут, в интерфейсе его нет,
/// и именно эти функции проверяют тесты.
///
/// Разделение на медиа и файлы идёт по расширению, а не по папке: скриншоты лежат и в `DCIM`,
/// и в `Pictures/Screenshots`, а скачанные фотографии — в `Download` рядом с документами,
/// поэтому «папки для фото» и «папки для файлов» списком не разложить.
abstract final class MediaRules {
  /// Фото: сюда же RAW и HEIC — камера телефона пишет именно так.
  static const Set<String> _image = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif', 'jxl',
    'dng', 'raw', 'cr2', 'cr3', 'nef', 'arw', 'orf', 'raf', 'rw2', 'pef', 'sr2',
    'tif', 'tiff', 'svg',
  };

  static const Set<String> _video = {
    'mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', '3gp', '3g2', 'mpg', 'mpeg',
    'mts', 'm2ts', 'ts', 'wmv', 'flv',
  };

  /// Недописанное и служебное: в списках не показываем.
  static const List<String> _junkSuffix = ['.tmp', '.part', '.crdownload', '.cloudly-tmp'];

  /// Служебные каталоги: в дереве выбора их нет и при скане они не обходятся.
  static const Set<String> _skipNames = {'.thumbnails', '.trashed', 'LOST.DIR'};

  static String extension(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  static bool isImage(String name) => _image.contains(extension(name));

  static bool isVideo(String name) => _video.contains(extension(name));

  /// Фото и видео вместе — то, что показывается в разделе «Фото и видео».
  static bool isMedia(String name) => isImage(name) || isVideo(name);

  /// Куда попадает файл: медиа — в фото, всё остальное — в файлы.
  static bool matches(Section section, String name) =>
      section == Section.photos ? isMedia(name) : !isMedia(name);

  /// Имена на точку не показываем: это `.nomedia`, `.thumbnails`, чужой служебный мусор.
  static bool isHidden(String name) => name.startsWith('.');

  static bool isJunk(String name) {
    final lower = name.toLowerCase();
    return _junkSuffix.any(lower.endsWith);
  }

  /// Служебные каталоги. `Android/data` и `Android/obb` — не файлы пользователя, а тысячи
  /// каталогов приложений: в раскрытом дереве они хоронят всё остальное.
  static bool skipDir(String name, String parentName) {
    if (isHidden(name)) return true;
    if (_skipNames.contains(name)) return true;
    return parentName == 'Android' && (name == 'data' || name == 'obb');
  }

  /// Mime по расширению. Сервер сам решает, конвертировать ли медиа, но тип нужен при записи:
  /// по нему же файл уходит получателю и открывается просмотрщиком.
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

  /// Подходит ли файл под запрос чужого приложения. Приложение, которое просит файл, указывает
  /// тип: картинки, PDF, видео или вообще любой. Показывать в таком выборе видео, когда просили
  /// картинку, — значит гарантированно получить отказ у получателя.
  static bool matchesRequest(String? requested, String mime) {
    final want = (requested ?? '').trim().toLowerCase();
    if (want.isEmpty || want == '*/*') return true;
    final have = mime.trim().toLowerCase();
    if (have.isEmpty) return false;
    if (want.endsWith('/*')) return have.startsWith(want.substring(0, want.length - 1));
    return have == want;
  }

  /// Размер в человеческом виде: «4.2 МБ» читается лучше, чем «4404019».
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
