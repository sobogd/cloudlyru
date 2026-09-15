import 'package:path/path.dart' as p;

import '../device/media_rules.dart';
import 'mirror_models.dart';

/// Что делать в этом проходе.
class MirrorPlan {
  const MirrorPlan({
    required this.uploads,
    required this.renames,
    required this.deletes,
    required this.blocked,
    required this.blockedCount,
    this.unstable = 0,
  });

  /// Сколько файлов отложено: они ещё пишутся, вернёмся к ним через окно стабильности.
  final int unstable;

  /// Новые и изменившиеся файлы: их надо выгрузить.
  final List<LocalFile> uploads;

  /// Переименования: файл тот же (совпал inode), а путь другой.
  final List<(MirrorRow, LocalFile)> renames;

  /// Файлы, которых на телефоне больше нет: в облаке их надо убрать в корзину.
  final List<MirrorRow> deletes;

  /// Удаления приостановлены предохранителем.
  final bool blocked;

  /// Сколько удалений приостановлено, даже если они и не попали в `deletes`.
  final int blockedCount;
}

/// Правила двустороннего зеркала: сравнение снимка телефона с тем, что уже выгружено.
/// Чистые функции — ни файловой системы, ни сети: всё приходит аргументами, поэтому правила
/// проверяются тестами без устройства. Ошибка здесь стоит либо не уехавшего файла,
/// либо удаления чужого содержимого в облаке.
abstract final class MirrorRules {
  /// Файл, изменённый только что, ещё пишется: пусть устоится до следующего прохода.
  static const int stableMs = 20000;

  /// Порог «пропало слишком много». Удаления приходят не только от пользователя: отозванное
  /// разрешение, отвалившаяся карта памяти, автоочистка загрузок, чужой файловый менеджер.
  /// Без предохранителя любой из этих случаев выкашивает облако за один проход.
  static const int massDeleteMin = 20;
  static const int massDeleteMax = 500;
  static const double massDeleteShare = 0.25;

  /// Имя, которое обход не показывает (скрытое или служебное). Для сверки это не «файла нет»,
  /// а «правило показа»: такие строки не участвуют в удалениях.
  static bool excluded(String path) {
    final name = p.basename(path);
    return MediaRules.isHidden(name) || MediaRules.isJunk(name);
  }

  /// Файл устоялся: с последнего изменения прошло больше окна стабильности. Дата из будущего
  /// (кривые часы устройства, распакованный архив) тоже считается устоявшейся: писать файл
  /// «в будущем» нельзя, а вот застрять навсегда из-за такой даты он может.
  static bool isStable(int mtime, int now) =>
      mtime > now || mtime <= now - stableMs;

  /// Удаления допустимы только по полному и читаемому снимку: если папка не открылась или
  /// обход упёрся в предел, «файла нет» означает «мы его не увидели», а не «его удалили».
  static bool deletionsAllowed(LocalSnapshot snapshot) =>
      snapshot.unreadable == 0 && !snapshot.capped;

  /// Файл лежит внутри выбранной сейчас папки. Обязательная проверка перед удалениями: папку
  /// могли снять с выбора, и её файлов в снимке нет — без неё «файла нет в снимке» означало бы
  /// удаление всей папки в облаке, хотя пользователь всего лишь снял галочку.
  ///
  /// Функцией, а не отфильтрованной картой: на большой библиотеке лишняя копия таблицы — это
  /// ещё сотни мегабайт в момент прохода.
  static bool underRoots(String path, Iterable<String> roots) =>
      roots.any((root) => path == root || path.startsWith('$root/'));

  /// Слишком много пропало за один проход?
  ///
  /// [gone] — сколько записей облака выглядит удалёнными, [known] — сколько всего записей
  /// знает зеркало.
  static bool massDelete(int gone, int known) {
    if (gone >= massDeleteMax) return true;
    if (gone < massDeleteMin) return false;
    return known > 0 && gone / known > massDeleteShare;
  }

  /// План прохода.
  ///
  /// [local] — снимок выбранных папок телефона, [known] — что уже выгружено (ключ — путь файла
  /// на телефоне), [now] — текущее время: по нему видно, устоялся ли файл, [deletionsAllowed] —
  /// можно ли в этом проходе удалять в облаке, [confirmed] — пользователь подтвердил удаление,
  /// приостановленное предохранителем, [inScope] — лежит ли путь внутри выбранной сейчас папки.
  static MirrorPlan plan({
    required List<LocalFile> local,
    required Map<String, MirrorRow> known,
    required int now,
    required bool deletionsAllowed,
    bool confirmed = false,
    bool Function(String)? inScope,
  }) {
    final scope = inScope ?? (String _) => true;
    final byPath = {for (final f in local) f.path: f};
    final uploads = <LocalFile>[];
    final renames = <(MirrorRow, LocalFile)>[];
    final renamedFrom = <String>{};
    var unstable = 0;

    // Записи, чьих файлов на телефоне нет: либо удалены, либо переехали (ниже это видно по
    // inode). Служебные и скрытые имена сюда не попадают: обход их не показывает — значит
    // «файла нет» означает «правило показа», а не «удалён». Иначе облачный `.nomedia` уезжал бы
    // в корзину на следующем же проходе после того, как его скачали.
    final lost = known.values
        .where(
          (row) =>
              !byPath.containsKey(row.path) &&
              scope(row.path) &&
              !excluded(row.path),
        )
        .toList();
    final byInode = <int, MirrorRow>{};
    for (final row in lost) {
      if (row.inode > 0) byInode[row.inode] = row;
    }

    for (final file in local) {
      final row = known[file.path];
      if (row != null) {
        // известный путь: выгружаем заново только если содержимое изменилось
        final changed = row.size != file.size || row.mtime != file.mtime;
        if (changed) {
          if (isStable(file.mtime, now)) {
            uploads.add(file);
          } else {
            unstable += 1;
          }
        }
        continue;
      }
      // пути в известных нет: либо файл новый, либо он переименован.
      // Переименование признаём только при совпадении inode, размера И даты: одного inode
      // мало — ядро отдаёт освободившийся номер новому файлу, и тогда «удалил A, создал B»
      // выглядело бы переименованием, а облачная запись A перезаписывалась бы содержимым B.
      final moved = file.inode > 0 ? byInode[file.inode] : null;
      if (moved != null &&
          !renamedFrom.contains(moved.path) &&
          moved.size == file.size &&
          moved.mtime == file.mtime) {
        renamedFrom.add(moved.path);
        renames.add((moved, file));
        continue;
      }
      if (isStable(file.mtime, now)) {
        uploads.add(file);
      } else {
        unstable += 1;
      }
    }

    final gone = lost.where((row) => !renamedFrom.contains(row.path)).toList();
    final blocked =
        gone.isNotEmpty &&
        (!deletionsAllowed ||
            (massDelete(gone.length, known.length) && !confirmed));
    return MirrorPlan(
      unstable: unstable,
      uploads: uploads,
      renames: renames,
      deletes: blocked ? const [] : gone,
      blocked: blocked,
      blockedCount: gone.length,
    );
  }

  /// Папки облака, которые опустели после переименования или удаления на телефоне.
  ///
  /// Зеркало удаляет в облаке только файлы: папка, из которой файлы перенесли, остаётся
  /// навсегда — после переименования дерева в облаке копится хвост из пустых папок.
  /// Их и отбираем здесь, по трём обязательным условиям:
  ///   • папка заведена самим зеркалом (есть пара «папка облака ↔ путь на телефоне»);
  ///   • на телефоне её больше нет — иначе она просто на месте;
  ///   • она внутри выбранных сейчас папок: папку сняли с выбора — не наше дело.
  ///
  /// Корень зеркала не трогаем никогда: он и есть адрес, по которому всё лежит.
  /// Порядок — от глубоких к поверхностным: тогда родитель, опустевший после удаления детей,
  /// уходит в том же проходе, а не следующим.
  ///
  /// Проверка «в облаке пусто» сюда не входит: она требует запроса, и делается уже при удалении.
  static List<String> emptyFolderCandidates({
    required Map<String, String> dirs,
    required Set<String> aliveLocally,
    required Iterable<String> roots,
    required Set<String> rootCloudIds,
  }) {
    final out = <String>[];
    for (final entry in dirs.entries) {
      if (rootCloudIds.contains(entry.key)) continue;
      if (aliveLocally.contains(entry.value)) continue;
      if (!underRoots(entry.value, roots)) continue;
      out.add(entry.value);
    }
    out.sort((a, b) => b.length.compareTo(a.length));
    return out;
  }

  /// Имя конфликтной копии: содержимое обеих сторон сохраняется, никто не затирается молча.
  /// Так же поступает Google Drive — «конфликтующая копия» вместо тихой потери одной из версий.
  static String conflictName(String name, int at) {
    final t = DateTime.fromMillisecondsSinceEpoch(at);
    final stamp =
        '${t.year.toString().padLeft(4, '0')}-'
        '${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}.'
        '${t.minute.toString().padLeft(2, '0')}';
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    return '$base (конфликт $stamp)$ext';
  }

  /// Имя временного файла при скачивании: сканирование такие имена не подхватывает.
  static String tempName(String name) => '.$name.cloudly-tmp';
}
