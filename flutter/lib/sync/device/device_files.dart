import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/selection_rules.dart';
import 'media_rules.dart';
import 'native_fs.dart';

/// Узел дерева папок: путь, короткое имя, глубина для отступа.
class FolderNode {
  const FolderNode(this.path, this.name, this.depth, this.hasChildren);

  final String path;
  final String name;
  final int depth;
  final bool hasChildren;
}

/// Файл на телефоне.
///
/// [relDir] — путь папки относительно родителя выбранной папки, вместе с её именем: выбрали
/// `Download` — файл из `Download/Telegram` получит `Download/Telegram`. Именно так строится
/// структура в облаке: выбранная папка становится папкой внутри корня раздела, и это видно,
/// откуда файл приехал.
class DeviceFile {
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
  final int mtime;
  final bool media;
}

/// Итог обхода выбранных папок.
///
/// [total] может быть больше, чем отдано (см. `limit`), а [unreadable] — это честный счётчик
/// нечитаемых папок: молчаливый ноль выглядел бы как пустота.
class ScanResult {
  const ScanResult({
    required this.files,
    required this.dirs,
    required this.total,
    required this.unreadable,
    this.capped = false,
  });

  final List<DeviceFile> files;
  final int dirs;
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
class DeviceFiles {
  DeviceFiles({NativeFs? native}) : _native = native ?? NativeFs();

  final NativeFs _native;

  /// Предел на всякий случай: 20 000 файлов в списке всё равно никто не листает.
  static const int hardMax = 20000;

  /// Корни выбора: внутренняя память и карты памяти.
  Future<List<RootFolder>> roots() => _native.storageRoots();

  /// Прямые подпапки: нужны и дереву, и раскрытию выбранного предка при снятии галочки.
  Future<List<String>> subdirs(String path) async {
    final out = <String>[];
    final dir = Directory(path);
    List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } on FileSystemException {
      return out;
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
    return out;
  }

  /// Обход дерева в порядке отображения (родитель, затем его подпапки). Отдаёт узлы по мере
  /// обхода: дерево на телефоне большое, ждать полного обхода перед первым экраном нельзя.
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
      final children = await subdirs(task.path);
      if (cancelled()) return;
      yield FolderNode(task.path, task.name, task.depth, children.isNotEmpty);
      for (final child in children.reversed) {
        stack.add(_NodeTask(child, p.basename(child), task.depth + 1));
      }
    }
  }

  /// Файлы выбранных папок. Обход идёт в фоне и умеет останавливаться: на телефоне десятки
  /// тысяч файлов, и держать из-за них интерфейс нельзя.
  ///
  /// [limit] — сколько файлов вернуть (для списка раздела); 0 — без предела.
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
    var unreadable = 0;
    var capped = false;

    progress('сканирую папки…');
    for (final root in SelectionRules.scanRoots(paths.toSet())) {
      if (capped || cancelled()) break;
      final rootName = p.basename(root);
      // стек обхода: папка и её путь относительно родителя выбранной папки
      final queue = <_ScanTask>[_ScanTask(root, rootName)];
      while (queue.isNotEmpty && !capped) {
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
        if (dirs % 50 == 0) {
          progress('просмотрено папок: $dirs, найдено файлов: ${found.length}');
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
            capped = true;
            break;
          }
        }
      }
    }

    found.sort((a, b) {
      final byDate = b.mtime.compareTo(a.mtime);
      return byDate != 0 ? byDate : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    progress('папок: $dirs, файлов: ${found.length}');
    return ScanResult(
      files: limit >= 1 && limit < found.length ? found.sublist(0, limit) : found,
      dirs: dirs,
      total: found.length,
      unreadable: unreadable,
      capped: capped,
    );
  }
}

class _NodeTask {
  const _NodeTask(this.path, this.name, this.depth);

  final String path;
  final String name;
  final int depth;
}

class _ScanTask {
  const _ScanTask(this.path, this.relDir);

  final String path;
  final String relDir;
}
