import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../data/selection_rules.dart';
import '../device/media_rules.dart';
import '../device/native_fs.dart';
import 'mirror_models.dart';
import 'mirror_rules.dart';

/// Снимок выбранных папок раздела «Файлы» для сверки.
///
/// Отдельно от `DeviceFiles.scan`, хотя обход похож: у зеркала другие требования. Здесь нужны
/// папки (чтобы в облаке повторялась и пустая структура), номер файла в файловой системе (иначе
/// переименование неотличимо от удаления с повторной выгрузкой) и честный счётчик нечитаемых
/// папок — вместе с признаком неполного обхода он и решает, можно ли вообще удалять что-то
/// в облаке в этом проходе ([MirrorRules.deletionsAllowed]).
/// Сортировка не нужна: зеркало не показывает список, а сравнивает множества.
///
/// Создаётся движком на каждый проход (`MirrorEngine._pushLocal`); снимок живёт в памяти
/// прохода и целиком держится там же, поэтому и есть предел [hardMax].
class MirrorScanner {
  /// @param native мост к Android: нужен за номерами файлов, подменяется в тестах.
  MirrorScanner({NativeFs? native}) : _native = native ?? NativeFs();

  final NativeFs _native;

  /// Предел на всякий случай: снимок держится в памяти целиком.
  ///
  /// Источник числа — оценка памяти (строка пути, имя, размеры, номер файла на файл при
  /// потолке снимка), а не замер на устройстве: точное значение стоит подобрать по расходу
  /// памяти на телефоне с большой галереей.
  static const int hardMax = 200000;

  /// Сколько путей спрашивать у моста за один вызов: пачка не должна быть настолько большой,
  /// чтобы ответ не влез в сообщение канала.
  ///
  /// Источник числа — размер ответа канала (2000 чисел), а не замер: сколько `Os.stat` в пачке
  /// терпимо по времени, зависит от устройства и стоит измерить.
  static const int inodeBatch = 2000;

  /// Обойти выбранные папки и вернуть снимок для сверки.
  ///
  /// @param paths выбранные папки (подпапки внутри других выбранных отбрасываются правилами);
  ///        @param onProgress текст о ходе обхода — вызывается примерно раз на сто папок;
  ///        @param isCancelled опрос отмены: проверяется перед каждой папкой и каждым файлом.
  /// @return снимок файлов и папок вместе со счётчиком нечитаемых папок и признаком упора
  ///         в [hardMax]. Пишет только в память: диск читается, но не меняется, сеть не
  ///         трогается вовсе. Отменённый обход возвращает то, что успел собрать, и помечается
  ///         [LocalSnapshot.capped]: по обрезанному снимку удалять нельзя, иначе всё
  ///         несобранное выглядело бы удалённым. Номера файлов в таком снимке не спрашиваются
  ///         вовсе — второй проход начинается только у полного обхода.
  /// Нечитаемая папка не роняет обход: [LocalSnapshot.unreadable] растёт, а её содержимое
  /// в снимок не попадает.
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
    // отмена и предел — разные причины неполного снимка, но запрет на удаления у них общий
    var aborted = false;

    for (final root in SelectionRules.scanRoots(paths.toSet())) {
      if (capped || cancelled()) break;
      // обход в глубину: относительный путь копится от связанной папки и её имени не включает.
      // Связанная папка — это и есть папка в облаке, которую выбрал человек: её содержимое
      // лежит в ней самой, а не во вложенной папке с тем же именем (см. `SyncLinks`)
      final queue = <(String, String)>[(root, '')];
      while (queue.isNotEmpty && !capped) {
        if (cancelled()) {
          aborted = true;
          break;
        }
        final (dir, relDir) = queue.removeLast();
        List<FileSystemEntity> children;
        try {
          children = await Directory(dir).list(followLinks: false).toList();
        } on FileSystemException {
          // не читается: это не «пусто». Проход из-за этого удалять не будет
          unreadable += 1;
          continue;
        }
        // Сама связанная папка в снимок папок не попадает: в облаке она уже есть — человек
        // её и выбрал. Заводить по ней папку значило бы создать вложенную тёзку
        if (relDir.isNotEmpty) {
          // папка попадает в снимок целиком, независимо от содержимого: пустая структура тоже
          // должна доехать до облака
          dirs.add(LocalDir(dir, relDir));
        }
        visited += 1;
        if (visited % 100 == 0) {
          progress('просмотрено папок: $visited, файлов: ${gathered.length}');
        }
        final parentName = p.basename(dir);
        for (final child in children) {
          if (cancelled()) {
            aborted = true;
            break;
          }
          final name = p.basename(child.path);
          // Символическая ссылка уводит за пределы выбранной папки: содержимое чужого каталога
          // уехало бы в облако как «файлы выбранной папки». Не ходим по ссылкам.
          if (child is Link) continue;
          if (child is Directory) {
            if (MediaRules.skipDir(name, parentName) || MirrorRules.ignored(name)) {
              continue;
            }
            // у первой вложенной папки пути ещё нет: относительный путь связанной папки пуст
            queue.add((child.path, relDir.isEmpty ? name : '$relDir/$name'));
            continue;
          }
          if (child is! File) continue;
          // скрытое и служебное сверка не показывает вовсе; такие же имена не удаляются
          // в облаке (см. MirrorRules.excluded)
          if (MirrorRules.ignored(name)) continue;
          final stat = await child.stat();
          // файл исчез между листингом и stat: `stat` не бросает, а отвечает «не найден»
          // с размером -1. Такой фантом в снимке выглядел бы файлом, который «ждёт выгрузки»
          if (stat.type == FileSystemEntityType.notFound || stat.size < 0) continue;
          gathered.add(
            _Gathered(
              path: child.path,
              name: name,
              dir: dir,
              size: stat.size,
              mtime: stat.modified.millisecondsSinceEpoch,
            ),
          );
          if (gathered.length >= hardMax) {
            // предел выбран по памяти снимка, а не по времени: часть дерева осталась
            // непройденной, и по такому снимку удалять нельзя (см. deletionsAllowed)
            capped = true;
            break;
          }
        }
      }
    }

    // Второй проход — за номерами файлов: обход диска отдельно, мост отдельно, чтобы
    // пачка путей уходила одним вызовом, а не по одному на файл.
    // Отменённый обход второго прохода не делает: снимок всё равно неполный, а номера файлов
    // никому не понадобятся — удалять по нему нельзя, а план выгрузки движок не строит
    final files = <LocalFile>[];
    if (!aborted) {
      for (var start = 0; start < gathered.length; start += inodeBatch) {
        if (cancelled()) {
          aborted = true;
          break;
        }
        final chunk = gathered.sublist(
          start,
          math.min(start + inodeBatch, gathered.length),
        );
        final inodes = await _native.inodes([for (final g in chunk) g.path]);
        for (var i = 0; i < chunk.length; i++) {
          final g = chunk[i];
          files.add(
            LocalFile(
              path: g.path,
              name: g.name,
              dir: g.dir,
              size: g.size,
              mtime: g.mtime,
              // 0 — «номер неизвестен»: тогда переименование не распознаётся и файл уедет
              // заново. Ответ моста может быть короче запроса, и это не роняет снимок
              inode: i < inodes.length ? inodes[i] : 0,
            ),
          );
        }
      }
    }

    return LocalSnapshot(
      files: files,
      dirs: dirs,
      unreadable: unreadable,
      capped: capped || aborted,
    );
  }
}

/// Файл, найденный обходом, до того как узнан его номер в файловой системе.
///
/// Промежуточная запись на время обхода: размер и дата берутся из `stat`, потому что
/// спрашивать их у моста вместе с номером файла — лишний обмен на каждый файл.
class _Gathered {
  const _Gathered({
    required this.path,
    required this.name,
    required this.dir,
    required this.size,
    required this.mtime,
  });

  final String path;
  final String name;
  final String dir;
  final int size;
  final int mtime;
}
