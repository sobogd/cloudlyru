/// Модели двустороннего зеркала. Отдельно от моделей очереди: у очереди смысл «что выгрузить
/// руками», у зеркала — «чем телефон и облако отличаются прямо сейчас», и состояния тут свои.
library;

/// Файл на телефоне в том виде, в каком его видит сверка.
///
/// [relDir] — путь относительно родителя выбранной папки вместе с её именем: выбран
/// `Download` — файл из `Download/Telegram` даст `Download/Telegram`. Так же строится
/// структура в облаке внутри корня зеркала.
///
/// [inode] — номер файла в файловой системе: по нему переименование отличается от
/// «удалил и залил заново». Без него переименование папки с гигабайтами видео стоило бы
/// повторной выгрузки всего содержимого.
class LocalFile {
  const LocalFile({
    required this.path,
    required this.name,
    required this.dir,
    required this.relDir,
    required this.root,
    required this.size,
    required this.mtime,
    required this.inode,
  });

  final String path;
  final String name;
  final String dir;
  final String relDir;
  final String root;
  final int size;
  final int mtime;
  final int inode;

  LocalFile copyWith({
    String? path,
    String? dir,
    int? size,
    int? mtime,
    int? inode,
  }) => LocalFile(
    path: path ?? this.path,
    name: name,
    dir: dir ?? this.dir,
    relDir: relDir,
    root: root,
    size: size ?? this.size,
    mtime: mtime ?? this.mtime,
    inode: inode ?? this.inode,
  );
}

/// Папка телефона. Нужна, чтобы в облаке повторялась и пустая структура, а не только места
/// с файлами.
class LocalDir {
  const LocalDir(this.path, this.relDir);

  final String path;
  final String relDir;
}

/// Снимок выбранных папок.
///
/// [unreadable] — сколько папок не удалось прочитать. Нечитаемая папка — это не пустая
/// папка: при ошибке чтения удаления в облако не отправляются вовсе.
///
/// [capped] — обход упёрся в предел: часть дерева не пройдена, и решение об удалениях
/// принимать по неполному снимку нельзя.
class LocalSnapshot {
  const LocalSnapshot({
    required this.files,
    required this.dirs,
    required this.unreadable,
    required this.capped,
  });

  final List<LocalFile> files;
  final List<LocalDir> dirs;
  final int unreadable;
  final bool capped;
}

/// Строка «что уже выгружено»: файл телефона, его запись в облаке и слепок содержимого,
/// по которому запись делалась.
class MirrorRow {
  const MirrorRow({
    required this.path,
    required this.cloudFolderId,
    required this.entryId,
    required this.inode,
    required this.size,
    required this.mtime,
    this.sha256,
  });

  final String path;
  final String cloudFolderId;
  final String entryId;
  final int inode;
  final int size;
  final int mtime;
  final String? sha256;

  MirrorRow copyWith({String? path, String? cloudFolderId}) => MirrorRow(
    path: path ?? this.path,
    cloudFolderId: cloudFolderId ?? this.cloudFolderId,
    entryId: entryId,
    inode: inode,
    size: size,
    mtime: mtime,
    sha256: sha256,
  );
}

/// Незавершённая выгрузка: сессия на сервере и слепок файла, по которому она начата.
/// Нужна, чтобы после обрыва продолжить с принятой части, а не лить файл заново.
class UploadSessionRow {
  const UploadSessionRow({
    required this.path,
    required this.uploadId,
    required this.folderId,
    required this.size,
    required this.mtime,
    required this.sha256,
  });

  final String path;
  final String uploadId;
  final String folderId;
  final int size;
  final int mtime;
  final String sha256;
}

/// Сколько файлов и байт: одна пара чисел для итогов и прогресса.
class Totals {
  const Totals(this.files, this.bytes);

  final int files;
  final int bytes;
}

/// Выбранная папка телефона и её папка в облаке — пара, заведённая один раз.
class MirrorRoot {
  const MirrorRoot(this.localPath, this.cloudId, this.cloudPath);

  final String localPath;
  final String cloudId;
  final String cloudPath;
}
