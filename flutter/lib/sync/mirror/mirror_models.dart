/// Модели двустороннего зеркала. Отдельно от моделей очереди: у очереди смысл «что выгрузить
/// руками», у зеркала — «чем телефон и облако отличаются прямо сейчас», и состояния тут свои.
library;

import '../device/native_stat.dart';

/// Файл на телефоне в том виде, в каком его видит сверка.
///
/// [id] — ключ файла в файловой системе (том и номер в нём): по нему переименование
/// отличается от «удалил и залил заново», а подмена содержимого с сохранением размера и
/// даты — от «не менялся». Без него переименование папки с гигабайтами видео стоило бы
/// повторной выгрузки всего содержимого.
///
/// Собирается [MirrorScanner], дальше живёт только в памяти: в базу такая строка не попадает,
/// там лежит [MirrorRow] — то, что уже выгружено.
class LocalFile {
  const LocalFile({
    required this.path,
    required this.name,
    required this.dir,
    required this.size,
    required this.mtime,
    required this.id,
  });

  /// Полный путь в файловой системе телефона.
  final String path;

  /// Имя файла: под ним запись лежит и в облаке.
  final String name;

  /// Папка, в которой файл лежит сейчас: по ней находится папка облака при выгрузке.
  final String dir;

  /// Размер и дата изменения на момент обхода: по этой паре (вместе с [id]) сверка решает,
  /// «тот же файл» или «изменился» — содержимое при этом не читается.
  final int size;
  final int mtime;

  /// Ключ файла: том и номер в нём (см. [FileId]).
  final FileId id;
}

/// Папка телефона. Нужна, чтобы в облаке повторялась и пустая структура, а не только места
/// с файлами.
class LocalDir {
  /// @param path полный путь в файловой системе, @param relDir — путь внутри связанной папки
  ///        без её имени: у `Download/Telegram` при связке на `Download` это `Telegram`.
  ///        Ровно этот путь зеркало и повторяет в облаке.
  const LocalDir(this.path, this.relDir);

  final String path;
  final String relDir;
}

/// Снимок связанных папок.
///
/// [unreadable] и [capped] — часть контракта «можно ли удалять», а не справочные числа:
/// решения по ним принимает [MirrorRules.deletionsAllowed], и по неполному снимку удаления
/// в облако не отправляются вовсе.
///
/// [unreadable] — сколько папок не удалось прочитать. Нечитаемая папка — это не пустая папка:
/// «файла нет в снимке» означало бы «его удалили», хотя мы его просто не увидели.
///
/// [capped] — обход неполный: упёрся в предел [MirrorScanner.hardMax] **или был отменён**
/// (прерванный обход — тот же случай «мы не всё увидели», и сканер выставляет здесь `true»).
///
/// Собирается [MirrorScanner.snapshot] и живёт ровно один проход; в базу из него уходят
/// только числа (см. `MirrorStore.setLocalTotals`).
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
///
/// Хранится в базе зеркала; потеря строки означает, что сверка сочтёт файл новым, а его
/// облачную копию — лишней (см. [MirrorStore]).
class MirrorRow {
  const MirrorRow({
    required this.path,
    required this.cloudFolderId,
    required this.entryId,
    required this.id,
    required this.size,
    required this.mtime,
    this.sha256,
  });

  /// Путь файла на телефоне: он же ключ строки в базе.
  final String path;

  /// Папка облака, в которой лежит запись: по ней находится запись, когда файл переехал.
  final String cloudFolderId;

  /// Идентификатор записи в облаке: им делаются переименование и удаление.
  final String entryId;

  /// Ключ файла на телефоне (том и номер в нём); [FileId.unknown] — «номера нет».
  ///
  /// В базе лежит двумя колонками (`dev`, `inode`): строки, заведённые до их появления,
  /// приходят с нулём в томе — по такому ключу переименование не распознаётся, и файл
  /// один раз уедет заново. Это разовая плата за переход, а не постоянное поведение.
  final FileId id;

  /// Размер и дата файла на телефоне на момент выгрузки. По этой паре (без чтения
  /// содержимого) сверка решает, менять ли запись в облаке.
  final int size;
  final int mtime;

  /// Слепок содержимого, по которому делалась запись. Может быть пустым: строки, заведённые
  /// без подсчитанного хэша, скачивание всё равно пропустить не дают — там сравнивается хэш
  /// облака со строкой.
  final String? sha256;

  /// Копия с другим путём и/или папкой облака.
  ///
  /// Меняются только эти два поля: запись в облаке ([entryId]), ключ файла и слепок
  /// остаются прежними — переименование на телефоне не должно выглядеть как новая выгрузка.
  MirrorRow copyWith({String? path, String? cloudFolderId}) => MirrorRow(
    path: path ?? this.path,
    cloudFolderId: cloudFolderId ?? this.cloudFolderId,
    entryId: entryId,
    id: id,
    size: size,
    mtime: mtime,
    sha256: sha256,
  );
}

/// Незавершённая выгрузка: сессия на сервере и слепок файла, по которому она начата.
/// Нужна, чтобы после обрыва продолжить с принятой части, а не лить файл заново.
///
/// Лежит в базе до конца выгрузки: строку снимает тот, кто её завёл (`MirrorEngine._upload`),
/// в том числе когда сессия на сервере уже не годится.
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

  /// Сессия выгрузки на сервере: ею запрашивается состояние принятых частей.
  final String uploadId;

  /// Папка облака, в которую льётся файл: сменилась — сессия не подходит.
  final String folderId;

  /// Слепок файла на момент начала выгрузки. Совпасть должны все три поля: размер, дата и
  /// хэш — иначе содержимое успело измениться и продолжать с принятой части нельзя.
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
///
/// Пары лежат в базе зеркала: при пропаже папки сверка всё равно знает, куда возвращать
/// содержимое, а вторая пара на тот же путь не заводится (см. `MirrorStore.putRoot`).
class MirrorRoot {
  /// @param localPath путь выбранной папки на телефоне, @param cloudId папка зеркала в облаке,
  ///        @param cloudPath её имя для отчётов и прогресса.
  const MirrorRoot(this.localPath, this.cloudId, this.cloudPath);

  final String localPath;
  final String cloudId;
  final String cloudPath;
}
