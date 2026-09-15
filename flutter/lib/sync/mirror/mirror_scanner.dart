import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../data/selection_rules.dart';
import '../device/media_rules.dart';
import '../device/native_fs.dart';
import 'mirror_models.dart';

/// Снимок выбранных папок раздела «Файлы» для сверки.
///
/// Отдельно от `DeviceFiles.scan`, хотя обход похож: у зеркала другие требования. Здесь нужны
/// папки (чтобы в облаке повторялась и пустая структура), номер файла в файловой системе (иначе
/// переименование неотличимо от удаления с повторной выгрузкой) и честный счётчик нечитаемых
/// папок — по нему принимается решение, можно ли вообще удалять что-то в облаке в этом проходе.
/// Сортировка не нужна: зеркало не показывает список, а сравнивает множества.
class MirrorScanner {
  MirrorScanner({NativeFs? native}) : _native = native ?? NativeFs();

  final NativeFs _native;

  /// Предел на всякий случай: снимок держится в памяти целиком.
  static const int hardMax = 200000;

  /// Сколько путей спрашивать у моста за один вызов: пачка не должна быть настолько большой,
  /// чтобы ответ не влез в сообщение канала.
  static const int inodeBatch = 2000;

  Future<LocalSnapshot> snapshot(
    Iterable<String> paths, {
    void Function(String)? onProgress,
    bool Function()? isCancelled,
  }) async {
    // Номера файлов спрашиваем пачками (см. [NativeFs.inodes]): по одному вызову моста на файл
    // проход по десяткам тысяч файлов растягивается на десятки секунд
    final gathered = <_Gathered>[];
    final dirs = <LocalDir>[];
    final progress = onProgress ?? (String _) {};
    final cancelled = isCancelled ?? () => false;
    var unreadable = 0;
    var visited = 0;
    var capped = false;

    for (final root in SelectionRules.scanRoots(paths.toSet())) {
      if (capped || cancelled()) break;
      final rootName = p.basename(root);
      final queue = <(String, String)>[(root, rootName)];
      while (queue.isNotEmpty && !capped) {
        if (cancelled()) break;
        final (dir, relDir) = queue.removeLast();
        List<FileSystemEntity> children;
        try {
          children = await Directory(dir).list(followLinks: false).toList();
        } on FileSystemException {
          // не читается: это не «пусто». Проход из-за этого удалять не будет
          unreadable += 1;
          continue;
        }
        dirs.add(LocalDir(dir, relDir));
        visited += 1;
        if (visited % 100 == 0) {
          progress('просмотрено папок: $visited, файлов: ${gathered.length}');
        }
        final parentName = p.basename(dir);
        for (final child in children) {
          if (cancelled()) break;
          final name = p.basename(child.path);
          // Символическая ссылка уводит за пределы выбранной папки: содержимое чужого каталога
          // уехало бы в облако как «файлы выбранной папки». Не ходим по ссылкам.
          if (child is Link) continue;
          if (child is Directory) {
            if (MediaRules.skipDir(name, parentName)) continue;
            queue.add((child.path, '$relDir/$name'));
            continue;
          }
          if (child is! File) continue;
          if (MediaRules.isHidden(name) || MediaRules.isJunk(name)) continue;
          final stat = await child.stat();
          gathered.add(_Gathered(
            path: child.path,
            name: name,
            dir: dir,
            relDir: relDir,
            root: root,
            size: stat.size,
            mtime: stat.modified.millisecondsSinceEpoch,
          ));
          if (gathered.length >= hardMax) {
            capped = true;
            break;
          }
        }
      }
    }

    final files = <LocalFile>[];
    for (var start = 0; start < gathered.length; start += inodeBatch) {
      if (cancelled()) break;
      final chunk = gathered.sublist(start, math.min(start + inodeBatch, gathered.length));
      final inodes = await _native.inodes([for (final g in chunk) g.path]);
      for (var i = 0; i < chunk.length; i++) {
        final g = chunk[i];
        files.add(LocalFile(
          path: g.path,
          name: g.name,
          dir: g.dir,
          relDir: g.relDir,
          root: g.root,
          size: g.size,
          mtime: g.mtime,
          inode: i < inodes.length ? inodes[i] : 0,
        ));
      }
    }

    return LocalSnapshot(
      files: files,
      dirs: dirs,
      unreadable: unreadable,
      capped: capped,
    );
  }
}

/// Файл, найденный обходом, до того как узнан его номер в файловой системе.
class _Gathered {
  const _Gathered({
    required this.path,
    required this.name,
    required this.dir,
    required this.relDir,
    required this.root,
    required this.size,
    required this.mtime,
  });

  final String path;
  final String name;
  final String dir;
  final String relDir;
  final String root;
  final int size;
  final int mtime;
}
