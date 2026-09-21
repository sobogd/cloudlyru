import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/selection_rules.dart';
import 'media_rules.dart';
import 'native_fs.dart';

/// Узел дерева папок: путь, короткое имя, глубина для отступа.
///
/// Это строка экрана выбора папок (`ui/folder_tree_screen.dart`), а не запись о папке на диске:
/// [hasChildren] известен не всегда (см. `_canExpand` на экране), [depth] нужен только чтобы
/// нарисовать отступ, а [name] — подпись под галочкой.
class FolderNode {
  const FolderNode(this.path, this.name, this.depth, this.hasChildren);

  /// Абсолютный путь на телефоне — он же ключ выбора в настройках раздела.
  final String path;

  /// Короткое имя (последний сегмент пути) — то, что читает человек.
  final String name;

  /// Уровень вложенности от корня: 0 — корень тома. На экране превращается в отступ, поэтому
  /// считается при построении узлов, а не при отрисовке.
  final int depth;

  /// Есть ли подпапки. Для узлов, чьи подпапки ещё не прочитаны, ставится `false` — экран
  /// в этом случае считает, что раскрывать есть что, и не убирает стрелку.
  final bool hasChildren;
}

/// Файл на телефоне.
///
/// [relDir] — путь папки относительно родителя выбранной папки, вместе с её именем: выбрали
/// `Download` — файл из `Download/Telegram` получит `Download/Telegram`. Именно так строится
/// структура в облаке: выбранная папка становится папкой внутри корня раздела, и это видно,
/// откуда файл приехал.
///
/// Абсолютный [path] нужен, чтобы открыть файл, [root] — чтобы понять, из какого выбранного
/// корня он пришёл (корней может быть несколько: внутренняя память и карта памяти), [media] —
/// только для иконки в списке: раздел определяется папкой, а не типом файла.
class DeviceFile {
  /// [path] и [name] — где файл лежит и как зовётся; [dir] — папка файла; [relDir] — путь
  /// папки внутри выбранного корня; [root] — выбранный корень; [size] и [mtime] — из `stat`
  /// на момент обхода; [media] — фото или видео по расширению.
  const DeviceFile({
    required this.path,
    required this.name,
    required this.dir,
    required this.relDir,
    required this.root,
    required this.size,
    required this.mtime,
    required this.media,
  });

  final String path;
  final String name;
  final String dir;
  final String relDir;
  final String root;
  final int size;

  /// Время изменения файла на телефоне (мс с эпохи): по нему файл сравнивается с версией
  /// в облаке и по нему же список сортируется «свежие сверху».
  final int mtime;

  final bool media;
}

/// Итог обхода выбранных папок.
///
/// [total] может быть больше, чем отдано (см. `limit` и `DeviceFiles.hardMax`), а [unreadable] —
/// это честный счётчик нечитаемых папок: молчаливый ноль выглядел бы как пустота.
class ScanResult {
  /// [files] — найденные файлы (возможно, усечённые по `limit` или по `hardMax`), [dirs] —
  /// сколько папок удалось прочитать, [total] — сколько файлов нашлось всего (в том числе
  /// сверх [DeviceFiles.hardMax]), [unreadable] — сколько папок не открылось, [capped] — обход
  /// упёрся в [DeviceFiles.hardMax], поэтому в [files] попала только часть найденного.
  const ScanResult({
    required this.files,
    required this.dirs,
    required this.total,
    required this.unreadable,
    this.capped = false,
  });

  final List<DeviceFile> files;

  /// Число прочитанных папок: по нему видно, что обход вообще шёл (0 при непустом выборе
  /// означает, что ни одна папка не открылась).
  final int dirs;

  /// Сколько файлов нашлось всего — до усечения по `limit`. Показывается человеку как «всего»,
  /// чтобы список из двухсот строк не выглядел всей очередью. Обход при этом продолжается
  /// и после [DeviceFiles.hardMax] (уже без чтения `stat`), поэтому при [capped] это настоящее
  /// число файлов, а не размер усечённого списка.
  final int total;

  final int unreadable;
  final bool capped;
}

/// Чтение телефона: дерево папок для экрана выбора и файлы для разделов и очереди.
/// Работает обычными путями — у приложения есть доступ ко всем файлам, поэтому ни SAF,
/// ни медиатека не нужны: видно ровно то, что лежит на диске.
///
/// Отбора по расширению здесь нет: раздел определяется тем, к какой папке прикреплена
/// папка телефона, а не типом файла. Медиа-признак остаётся только для иконки в списке.
///
/// Пользуются им экран выбора папок (`ui/folder_tree_screen.dart`), сборка очереди
/// (`queue/queue_builder.dart`, `queue/queue_refresher.dart`), а через них — наполнение
/// очереди. Обход зеркала — отдельный код (`mirror/mirror_scanner.dart`): у зеркала другие
/// требования к данным.
class DeviceFiles {
  /// [native] — доступ к тому, чего нет в обычном Dart: отсюда берутся корни томов. По
  /// умолчанию создаётся свой; параметр нужен, чтобы передать уже существующий (в фоне его
  /// создают один раз и используют и в зеркале, и в очереди).
  DeviceFiles({NativeFs? native}) : _native = native ?? NativeFs();

  final NativeFs _native;

  /// Предел числа файлов, которые обход отдаёт списком: 20 000.
  ///
  /// Число держит в памяти разумный объём (запись о файле — это путь, имя и четыре числа).
  /// **Предел ограничивает именно список, а не «всё, что будет выгружено»**: им пользуется
  /// очередь (`queue/queue_builder.dart`), поэтому файлы сверх предела в очередь не попадают —
  /// и это не мелочь, о которой можно молчать. Уперевшись в предел, обход:
  ///
  /// * ставит [ScanResult.capped] — вызывающие обязаны сказать об этом человеку
  ///   (очередь пишет это в свой текст, экран очереди его показывает);
  /// * **продолжает идти** и считает оставшиеся файлы, не читая `stat`: [ScanResult.total]
  ///   остаётся настоящим числом файлов, поэтому «учтены первые N из M» можно сказать точно.
  ///   Стоит это только обхода каталогов (без `stat` каждого файла) — плата за честный счёт.
  static const int hardMax = 20000;

  /// Корни выбора: внутренняя память и карты памяти.
  ///
  /// Просто переадресация в [NativeFs] — здесь её держат, чтобы вызывающие не знали о нём
  /// и работали только с [DeviceFiles]. На iOS корни — это папки, выбранные в «Файлах»:
  /// обойти там нечего, за пределы песочницы приложение не пускают.
  Future<List<RootFolder>> roots() => _native.storageRoots();

  /// Показать системный выбор папки (только iOS) и вернуть выбранную.
  ///
  /// Переадресация в [NativeFs] по той же причине, что и [roots]: экран выбора папок не должен
  /// знать, что на одной из платформ папку нельзя обойти, а можно только выбрать в «Файлах».
  Future<RootFolder?> pickFolder() => _native.pickFolder();

  /// Забыть выбранную в «Файлах» папку (только iOS): доступ к ней закрывается.
  Future<void> forgetFolder(String path) => _native.forgetFolder(path);

  /// Прямые подпапки и признак «папку не удалось прочитать».
  ///
  /// [path] — папка, чьи подпапки нужны. Возвращает абсолютные пути, отсортированные по имени
  /// без учёта регистра (так же выглядят и строки дерева); файлы и служебные каталоги
  /// ([MediaRules.skipDir]) отброшены.
  ///
  /// `unreadable: true` вместо исключения: на телефоне всегда найдутся папки без доступа,
  /// и падать из-за них в интерфейсе нельзя. Но и притворяться, что папка пуста, нельзя тоже —
  /// «нет доступа» и «пусто» для человека разные вещи, поэтому признак отдаётся наружу
  /// (им пользуется дерево выбора: у такой папки в строке написано, что она не открылась).
  /// Символические ссылки не разворачиваются (`followLinks: false`) — иначе ссылка на родителя
  /// зациклила бы обход.
  Future<({List<String> paths, bool unreadable})> subdirs(String path) async {
    final out = <String>[];
    final dir = Directory(path);
    List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } on FileSystemException {
      return (paths: out, unreadable: true);
    }
    final parentName = p.basename(path);
    for (final child in children) {
      if (child is! Directory) continue;
      final name = p.basename(child.path);
      if (MediaRules.skipDir(name, parentName)) continue;
      out.add(child.path);
    }
    out.sort((a, b) =>
        p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()));
    return (paths: out, unreadable: false);
  }

  /// Обход дерева в порядке отображения (родитель, затем его подпапки). Отдаёт узлы по мере
  /// обхода: дерево на телефоне большое, ждать полного обхода перед первым экраном нельзя.
  ///
  /// [roots] — с чего начинать (корни томов), [isCancelled] — проверка отмены, её спрашивают
  /// перед чтением каждой папки: на экране поиска она смотрит на закрытие экрана и кнопку
  /// «стоп». Возвращает поток узлов — им пользуется только поиск по папкам; дерево на экране
  /// строится лениво, подпапками при раскрытии.
  ///
  /// Ничего не бросает на нечитаемых папках: [subdirs] отдаёт для них пустой список и признак
  /// отказа, узел всё равно попадает в поток, и человек видит папку, к которой нет доступа.
  Stream<FolderNode> walkTree(
    List<RootFolder> roots, {
    bool Function()? isCancelled,
  }) async* {
    final cancelled = isCancelled ?? () => false;
    // Обход стеком, а не рекурсией: узлы отдаются по мере обхода (родитель, затем его
    // подпапки), и остановиться можно на любом шаге, не дожидаясь конца дерева.
    final stack = <_NodeTask>[
      for (final root in roots.reversed) _NodeTask(root.path, root.name, 0),
    ];
    while (stack.isNotEmpty) {
      if (cancelled()) return;
      final task = stack.removeLast();
      final kids = await subdirs(task.path);
      if (cancelled()) return;
      yield FolderNode(task.path, task.name, task.depth, kids.paths.isNotEmpty);
      for (final child in kids.paths.reversed) {
        stack.add(_NodeTask(child, p.basename(child), task.depth + 1));
      }
    }
  }

  /// Файлы выбранных папок. Обход идёт в фоне и умеет останавливаться: на телефоне десятки
  /// тысяч файлов, и держать из-за них интерфейс нельзя.
  ///
  /// [limit] — сколько файлов вернуть (для списка раздела); 0 — без предела.
  ///
  /// [paths] — выбранные папки раздела; из них берутся только «корни» ([SelectionRules.scanRoots]):
  /// обходить выбранную папку и её же выбранную подпапку значило бы найти одни и те же файлы
  /// дважды. [onProgress] — куда сообщать о ходе обхода (строка для интерфейса),
  /// [isCancelled] — проверка отмены, спрашивается перед каждой папкой и каждым файлом.
  ///
  /// Возвращает [ScanResult]: список отсортирован по времени изменения (свежие сверху), при
  /// равном времени — по имени без учёта регистра. Список усечён по [limit], но [ScanResult.total]
  /// хранит полное число найденного; [ScanResult.capped] — в список попало не всё (обход упёрся
  /// в [hardMax]). После предела обход продолжается и продолжает считать файлы, но не читает
  /// их `stat`: так [ScanResult.total] остаётся настоящим числом, а не размером усечённого списка,
  /// и вызывающий может честно сказать «учтены первые N из M».
  /// Нечитаемая папка увеличивает [ScanResult.unreadable] и не прерывает обход: пропуск виден,
  /// а не спрятан. Исключений не бросает.
  Future<ScanResult> scan(
    Iterable<String> paths, {
    int limit = 0,
    void Function(String)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final found = <DeviceFile>[];
    final progress = onProgress ?? (String _) {};
    final cancelled = isCancelled ?? () => false;
    var dirs = 0;
    var total = 0;
    var unreadable = 0;
    var capped = false;

    progress('сканирую папки…');
    for (final root in SelectionRules.scanRoots(paths.toSet())) {
      if (cancelled()) break;
      final rootName = p.basename(root);
      // стек обхода: папка и её путь относительно родителя выбранной папки
      // relDir начинается с имени самой выбранной папки: в облаке она станет папкой внутри
      // корня раздела, и по этому пути видно, откуда файл приехал
      final queue = <_ScanTask>[_ScanTask(root, rootName)];
      // Обход идёт до конца даже после hardMax: за пределом файлы только считаются (см. док
      // метода). Остановить его может лишь отмена — тогда и счёт неполный, и вызывающий
      // об этом узнаёт по своему же признаку отмены
      while (queue.isNotEmpty) {
        if (cancelled()) break;
        final task = queue.removeLast();
        List<FileSystemEntity> children;
        try {
          children = await Directory(task.path).list(followLinks: false).toList();
        } on FileSystemException {
          // каталог не читается: это не «пусто», и в итоге это должно быть видно
          unreadable += 1;
          continue;
        }
        dirs += 1;
        // Прогресс раз в 50 папок: на каждом шаге это был бы поток сообщений в интерфейс,
        // а реже — выглядело бы так, будто обход встал
        if (dirs % 50 == 0) {
          progress('просмотрено папок: $dirs, найдено файлов: $total');
        }
        for (final child in children) {
          if (cancelled()) break;
          final name = p.basename(child.path);
          if (child is Directory) {
            if (MediaRules.skipDir(name, p.basename(task.path))) continue;
            queue.add(_ScanTask(child.path, '${task.relDir}/$name'));
            continue;
          }
          if (child is! File) continue;
          if (MediaRules.isHidden(name) || MediaRules.isJunk(name)) continue;
          total += 1;
          // Предел: дальше файлы только считаются. `stat` за пределом не читается — это и есть
          // та работа, ради экономии которой предел и поставлен
          if (capped) continue;
          final stat = await child.stat();
          found.add(DeviceFile(
            path: child.path,
            name: name,
            dir: task.path,
            relDir: task.relDir,
            root: root,
            size: stat.size,
            mtime: stat.modified.millisecondsSinceEpoch,
            media: MediaRules.isMedia(name),
          ));
          if (found.length >= hardMax) {
            // Уперлись в предел: в список попало не всё, и `capped` говорит об этом в итоге —
            // неполный список не должен выглядеть как «файлов больше нет»
            capped = true;
          }
        }
      }
    }

    found.sort((a, b) {
      final byDate = b.mtime.compareTo(a.mtime);
      return byDate != 0 ? byDate : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    progress('папок: $dirs, файлов: $total');
    return ScanResult(
      files: limit >= 1 && limit < found.length ? found.sublist(0, limit) : found,
      dirs: dirs,
      total: total,
      unreadable: unreadable,
      capped: capped,
    );
  }
}

/// Задача обхода дерева: что раскрыть следующим. Стек таких задач и заменяет рекурсию —
/// обход отдаёт узлы по мере чтения, и остановиться можно между двумя папками.
class _NodeTask {
  const _NodeTask(this.path, this.name, this.depth);

  final String path;
  final String name;
  final int depth;
}

/// Задача обхода файлов: папка и путь, которым она станет в облаке.
///
/// [relDir] несётся вместе с папкой, а не вычисляется при добавлении файла: путь берётся от
/// выбранного корня и накапливается по мере спуска, поэтому префикс не зависит от глубины
/// и от того, сколько корней обходится за один проход.
class _ScanTask {
  const _ScanTask(this.path, this.relDir);

  final String path;
  final String relDir;
}
