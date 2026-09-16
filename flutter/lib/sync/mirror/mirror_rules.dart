import 'dart:convert';

import 'package:path/path.dart' as p;

import '../device/media_rules.dart';
import 'mirror_models.dart';

/// Что делать в этом проходе.
///
/// Результат [MirrorRules.plan]: движок выполняет его по частям (сначала переименования,
/// потом выгрузку, потом удаления) и по нему же показывает, сколько ждёт выгрузки.
class MirrorPlan {
  /// Заполняется только [MirrorRules.plan]: остальные поля — из готового плана.
  const MirrorPlan({
    required this.uploads,
    required this.renames,
    required this.deletes,
    required this.blocked,
    required this.blockedCount,
    this.unstable = 0,
  });

  /// Сколько файлов отложено: они ещё пишутся, вернёмся к ним через окно стабильности.
  ///
  /// Число, а не список: движку достаточно знать, что нужно назначить повторный проход.
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
///
/// Пользуется ими движок ([MirrorEngine._pushLocal] строит план и разбирает опустевшие папки),
/// а решения о том, что план допустим, принимает он же: сами правила ничего не записывают.
abstract final class MirrorRules {
  /// Файл, изменённый только что, ещё пишется: пусть устоится до следующего прохода.
  ///
  /// Двадцати секунд хватает, чтобы камера дописала снимок, а браузер — докачал файл:
  /// недописанный файл уехал бы в облако обрезанным, а через секунду стал бы «изменившимся»
  /// и поехал заново.
  static const int stableMs = 20000;

  /// Порог «пропало слишком много». Удаления приходят не только от пользователя: отозванное
  /// разрешение, отвалившаяся карта памяти, автоочистка загрузок, чужой файловый менеджер.
  /// Без предохранителя любой из этих случаев выкашивает облако за один проход.
  ///
  /// Три числа задают порог: до [massDeleteMin] пропажа считается обычной, от [massDeleteMax] —
  /// массовой при любом размере библиотеки, между ними смотрим долю [massDeleteShare].
  static const int massDeleteMin = 20;
  static const int massDeleteMax = 500;
  static const double massDeleteShare = 0.25;

  /// Предел имени файла: столько разрешают и сервер (`src/common/utils.ts`), и файловые системы
  /// Android. Считается в **байтах**, а не в символах: кириллическое имя в 200 символов — это
  /// уже больше 255 байт, и проверка по длине строки его пропустила бы.
  static const int maxNameBytes = 255;

  /// Сколько байт скачивание добавляет к имени: временный файл `.имя.<метка>.cloudly-tmp`
  /// (см. `SyncApi.downloadToFile`). Метка — шесть шестнадцатеричных знаков, по ней два
  /// одновременных писателя (приложение и фоновое задание) не пишут в один файл. Имя, для
  /// которого этот запас не помещается, скачать нельзя в принципе — упадёт файловая система
  /// (`ENAMETOOLONG`), поэтому такие имена отсеиваются здесь, а не в момент записи.
  static const int downloadSuffixBytes = '.cloudly-tmp'.length + 1 + 6 + 1;

  /// Суффикс резервной копии прежней версии: её оставляет то же скачивание, уводя старый файл
  /// в `<имя>.cloudly-old`. Зеркало отсеивает его само (и `MediaRules.isJunk` знает это имя):
  /// брошенный бэкап иначе уехал бы в облако как обычный файл, а сам файл на телефоне выглядел
  /// бы пропавшим.
  static const String backupSuffix = '.cloudly-old';

  /// Имя, которое обход не показывает (скрытое, служебное или оставленный скачиванием бэкап).
  /// Для сверки это не «файла нет», а «правило показа»: такие строки не участвуют в удалениях.
  ///
  /// Отсюда же следствие для скачивания: облачный файл с таким именем на телефон не тянется
  /// (`MirrorPull._reconcile`), иначе на следующем проходе он выглядел бы пропавшим.
  /// Решение принимается по имени, содержимое файла не читается.
  static bool ignored(String name) =>
      MediaRules.isHidden(name) ||
      MediaRules.isJunk(name) ||
      name.toLowerCase().endsWith(backupSuffix);

  /// То же по полному пути: решение принимается по имени файла.
  static bool excluded(String path) => ignored(p.basename(path));

  /// Файл устоялся: с последнего изменения прошло больше окна стабильности. Дата из будущего
  /// (кривые часы устройства, распакованный архив) тоже считается устоявшейся: писать файл
  /// «в будущем» нельзя, а вот застрять навсегда из-за такой даты он может.
  static bool isStable(int mtime, int now) =>
      mtime > now || mtime <= now - stableMs;

  /// Файл на телефоне отличается от того, что уже выгружено.
  ///
  /// Цена ошибки здесь несимметрична, и это объясняет, почему сравнение вообще такое дешёвое:
  /// ложное «изменилось» стоит лишнего хэша и одного запроса (сервер дедуплицирует по sha256),
  /// а ложное «не изменилось» — тихого расхождения навсегда, которое никто не заметит.
  ///
  /// Сравниваются размер, дата и — когда оба известны — номер файла в файловой системе.
  /// Пара «размер + дата» слепа к подмене содержимого с сохранением обоих (`cp -p`, `rsync -a`,
  /// распаковка архива с датами, восстановление из бэкапа): такой файл считался бы неизменным
  /// и не уехал бы в облако никогда. Номер файла эту подмену видит. Ноль в [MirrorRow.inode] —
  /// «номер неизвестен» (мост не ответил): тогда решают только размер и дата.
  static bool changed(MirrorRow row, LocalFile file) =>
      row.size != file.size ||
      row.mtime != file.mtime ||
      (row.inode > 0 && file.inode > 0 && row.inode != file.inode);

  /// Удаления допустимы только по полному и читаемому снимку: если папка не открылась или
  /// обход упёрся в предел, «файла нет» означает «мы его не увидели», а не «его удалили».
  ///
  /// [LocalSnapshot.capped] выставляется и при отменённом обходе (см. [MirrorScanner.snapshot]):
  /// обрезанный снимок для удалений так же неполон, как снимок с нечитаемой папкой.
  static bool deletionsAllowed(LocalSnapshot snapshot) =>
      snapshot.unreadable == 0 && !snapshot.capped;

  /// Файл лежит внутри выбранной сейчас папки. Обязательная проверка перед удалениями: папку
  /// могли снять с выбора, и её файлов в снимке нет — без неё «файла нет в снимке» означало бы
  /// удаление всей папки в облаке, хотя пользователь всего лишь снял галочку.
  ///
  /// Сам корень тоже считается «внутри»: он адрес, по которому лежит содержимое, и решение
  /// «папки больше нет» принимается по содержимому, а не по самому адресу.
  ///
  /// Функцией, а не отфильтрованной картой: на большой библиотеке лишняя копия таблицы — это
  /// ещё сотни мегабайт в момент прохода.
  static bool underRoots(String path, Iterable<String> roots) =>
      roots.any((root) => path == root || path.startsWith('$root/'));

  /// Путь лежит **строго** внутри папки [dir], а не совпадает с ней.
  ///
  /// Нужен там, где поддерево берётся из базы по префиксу пути: сам поиск в хранилище идёт
  /// через `LIKE` без экранирования, а в шаблоне `_` — любой символ, `%` — любая строка.
  /// У папки `my_photos` в выборку попадает и `myXphotos`: без этой перепроверки удаление
  /// одной папки утащило бы файлы соседней, отличающейся одной буквой.
  static bool inside(String path, String dir) =>
      path != dir && path.startsWith(dir.endsWith('/') ? dir : '$dir/');

  /// Путь лежит **строго** внутри выбранной папки, а не совпадает с ней.
  ///
  /// Нужен там, где удаляется поддерево: корень зеркала — это выбранная человеком папка,
  /// и снести её целиком клиент не имеет права ни при каком событии в журнале. Раньше инвариант
  /// «корень не трогаем» держался только защитой на сервере; здесь он проверяется и на клиенте.
  static bool insideRoots(String path, Iterable<String> roots) =>
      roots.any((root) => inside(path, root));

  /// Том, который, скорее всего, не различает регистр и срезает концевые точки и пробелы, —
  /// то есть карта памяти (FAT/exFAT). Внутренняя память Android — ext4/f2fs, там это допустимо.
  ///
  /// Определяется по пути: мост к Android такого метода не отдаёт. Карта памяти монтируется
  /// как `/storage/<том>` (где `<том>` — не `emulated`) или как `/mnt/media_rw/<том>`.
  /// Ошибка в сторону «считаем картой» стоит лишнего предупреждения, в обратную — имени,
  /// которое на диске молча изменится (верхний регистр, срезанная точка). Точный тип тома
  /// должен спрашивать мост — это помечено в отчёте по ревью.
  static bool removableVolume(String path) {
    final parts = p.split(path);
    if (parts.length < 3) return false;
    // p.split('/storage/emulated/0/Download') → ['/', 'storage', 'emulated', '0', 'Download']
    if (parts[1] == 'storage') return parts[2] != 'emulated';
    return parts[1] == 'mnt' && parts[2] == 'media_rw';
  }

  /// Различает ли том регистр в именах: на карте памяти — нет.
  static bool caseInsensitive(String path) => removableVolume(path);

  /// Это один и тот же путь на этом томе: сравнивать без регистра нужно там, где том его
  /// не различает, — иначе облачное `A.txt` и локальное `a.txt` считались бы разными файлами,
  /// а `File.exists()` на такой карте отвечает «да» на любое написание.
  static bool samePath(
    String a,
    String b, {
    required bool caseInsensitive,
  }) {
    if (a == b) return true;
    return caseInsensitive && a.toLowerCase() == b.toLowerCase();
  }

  /// Что не так с именем на этом томе, словами для человека; `null` — имя подходит.
  ///
  /// Проверки по факту, а не «на всякий случай»: на внутренней памяти Android символы
  /// `\\ : * ? " < > |` допустимы, и запрещать их там значило бы запрещать обычные имена.
  /// Длина считается в байтах, причём с запасом под временный файл скачивания: имя без этого
  /// запаса не скачать, как бы хорошо оно ни выглядело.
  static String? nameProblem(String name, {required bool removable}) {
    if (name.isEmpty) return 'пустое имя';
    if (name.contains('/') || name.contains('\u0000')) {
      return 'в имени недопустимый символ';
    }
    if (utf8.encode(name).length + downloadSuffixBytes > maxNameBytes) {
      return 'имя длиннее ${maxNameBytes - downloadSuffixBytes} байт';
    }
    if (removable && RegExp(r'[\\:*?"<>|]').hasMatch(name)) {
      return 'символы \\ : * ? " < > | на карте памяти недопустимы';
    }
    if (removable && (name.endsWith('.') || name.endsWith(' '))) {
      return 'имя оканчивается точкой или пробелом — карта памяти их срезает';
    }
    return null;
  }

  /// Обрезать строку до [bytes] байт, не разрывая символ: имя в байтах, а не в символах,
  /// и обрезка посреди UTF-8 дала бы на диске мусор вместо имени.
  static String fitBytes(String text, int bytes) {
    if (utf8.encode(text).length <= bytes) return text;
    final out = StringBuffer();
    var used = 0;
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      final size = utf8.encode(ch).length;
      if (used + size > bytes) break;
      out.write(ch);
      used += size;
    }
    return out.toString();
  }

  /// Слишком много пропало за один проход?
  ///
  /// [gone] — сколько записей облака выглядит удалёнными, [known] — сколько записей зеркала
  /// относится к тем же папкам (знаменатель, а не размер всей таблицы: при маленькой выборке
  /// доля от всей библиотеки занижалась бы во столько раз, во сколько библиотека больше
  /// выборки, и предохранитель «пропало слишком много» не срабатывал бы вовсе).
  ///
  /// Три числа задают порог. До [massDeleteMin] пропажа считается обычной: маленькая библиотека
  /// не должна блокироваться из-за десятка законно удалённых файлов. От [massDeleteMax] —
  /// массовой при любом размере библиотеки: столько файлов за один проход не удаляют случайно.
  /// Между ними смотрим долю [massDeleteShare] от [known] — четверть содержимого за проход.
  ///
  /// При пустом зеркале доли нет вовсе — пропадать нечему.
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
  /// приостановленное предохранителем, [inScope] — лежит ли путь внутри выбранной сейчас папки,
  /// [knownInScope] — сколько строк зеркала относится к этим же папкам (знаменатель
  /// предохранителя, см. [massDelete]).
  ///
  /// [knownInScope] — функция, а не число: она нужна только когда пропало много, а её подсчёт
  /// на большой библиотеке — это проход по всем строкам.
  ///
  /// Возвращает план, ничего не выполняя: ни файлов, ни сети, ни базы — поэтому его и можно
  /// проверить тестами. Судьбу приостановленных удалений видно по [MirrorPlan.deletes]
  /// (пусто) и [MirrorPlan.blockedCount] (сколько их было).
  static MirrorPlan plan({
    required List<LocalFile> local,
    required Map<String, MirrorRow> known,
    required int now,
    required bool deletionsAllowed,
    bool confirmed = false,
    bool Function(String)? inScope,
    int Function()? knownInScope,
  }) {
    // по умолчанию всё в области выбора: тесты и вызовы без папок не должны ничего отсеивать
    final scope = inScope ?? (String _) => true;
    final byPath = {for (final f in local) f.path: f};
    final uploads = <LocalFile>[];
    final renames = <(MirrorRow, LocalFile)>[];
    // строки, уже объяснённые переименованием: одна запись облака не может «переехать» дважды
    final renamedFrom = <String>{};
    var unstable = 0;

    // Записи, чьих файлов на телефоне нет: либо удалены, либо переехали (ниже это видно по
    // inode). Служебные и скрытые имена сюда не попадают: обход их не показывает — значит
    // «файла нет» означает «правило показа», а не «удалён». Иначе облачный `.nomedia` уезжал бы
    // в корзину на следующем же проходе после того, как его скачали.
    //
    // known — строки всех папок, поэтому отсечение по области выбора обязательно: папку
    // сняли с выбора, файлов в снимке нет, и без scope сверка удалила бы их в облаке.
    final lost = known.values
        .where(
          (row) =>
              !byPath.containsKey(row.path) &&
              scope(row.path) &&
              !excluded(row.path),
        )
        .toList();
    // номер файла — единственный признак, по которому переименование отличается от
    // «удалил и залил заново». Нулевые (мост не ответил) в карту не берём: по ним нельзя
    // утверждать, что это тот же файл
    final byInode = <int, MirrorRow>{};
    for (final row in lost) {
      if (row.inode > 0) byInode[row.inode] = row;
    }

    for (final file in local) {
      final row = known[file.path];
      if (row != null) {
        // известный путь: выгружаем заново только если содержимое изменилось
        if (changed(row, file)) {
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

    // удаления — это ровно те пропавшие записи, которые не объяснились переименованием
    final gone = lost.where((row) => !renamedFrom.contains(row.path)).toList();
    // приостанавливаем по двум разным причинам: либо по снимку удалять нельзя вообще,
    // либо пропало слишком много и пользователь ещё не подтвердил (подтверждение живёт
    // один проход). Доля считается по строкам текущих корней, а не по всей таблице
    final blocked =
        gone.isNotEmpty &&
        (!deletionsAllowed ||
            (massDelete(gone.length, knownInScope?.call() ?? known.length) &&
                !confirmed));
    return MirrorPlan(
      unstable: unstable,
      uploads: uploads,
      renames: renames,
      // при блокировке список пуст — движок не выполнит ни одного удаления, но число
      // приостановленных уходит в отчёт
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
  /// Корни зеркалируемых папок исключаются отдельно: они тоже заведены парами ([rootCloudIds]),
  /// и без этого условия корень попал бы в кандидаты, как только его файлы переехали. Сам
  /// корень зеркала (`<Имя устройства> - Файлы`) парой не заводится вовсе, поэтому кандидатом
  /// стать не может; на сервере у него есть и своя защита.
  ///
  /// Порядок — от длинных путей к коротким: родитель есть префикс ребёнка, то есть строка
  /// короче, и опустевший после удаления детей родитель уходит в том же проходе, а не следующим.
  /// Это сортировка по длине строки, а не по глубине: у путей одинаковой длины порядок
  /// произвольный, и на результат он не влияет — «пусто ли в облаке» проверяется перед каждым
  /// удалением отдельно.
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
  ///
  /// @param name имя, которое занято, @param at момент пометки: из него делается отметка
  ///        «конфликт ГГГГ-ММ-ДД ЧЧ.ММ». Расширение остаётся на месте, чтобы файл открывался
  ///        тем же просмотрщиком; у имени без расширения (или начинающегося с точки) пометка
  ///        дописывается в конец.
  ///
  /// Пометка занимает около 36 байт, поэтому длинное базовое имя обрезается: имя с пометкой
  /// обязано влезть в [maxNameBytes], иначе переименование упадёт с ENAMETOOLONG, конфликтная
  /// копия не сохранится и запись останется несогласованной до изменения файла.
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
    final suffix = ' (конфликт $stamp)';
    final room =
        maxNameBytes -
        utf8.encode(suffix).length -
        utf8.encode(ext).length -
        _conflictCounterBytes;
    return '${fitBytes(base, room)}$suffix$ext';
  }

  /// Запас под « (999)», который [uniqueName] может дописать к базовому имени.
  static const int _conflictCounterBytes = ' (999)'.length;

  /// Свободное имя, близкое к [desired]: если такое занято, добавляется « (2)», « (3)» и так
  /// далее. Нужно там, где имя строится для файла в уже существующей папке (конфликтная копия):
  /// [UploadPlan.freeName] делает то же самое, но сравнивает имена посимвольно, а на карте
  /// памяти `фото.jpg` и `Фото.JPG` — один и тот же файл.
  ///
  /// [taken] — занятые имена; [caseInsensitive] — не различает ли том регистр
  /// (см. [caseInsensitive]). Результат обрезается по байтам так, чтобы имя с суффиксом влезло
  /// в [maxNameBytes]. К серверу и диску функция не обращается.
  static String uniqueName(
    String desired,
    Set<String> taken, {
    required bool caseInsensitive,
  }) {
    String fold(String s) => caseInsensitive ? s.toLowerCase() : s;
    final busy = {for (final t in taken) fold(t)};
    if (!busy.contains(fold(desired))) return desired;
    final dot = desired.lastIndexOf('.');
    final rawBase = dot > 0 ? desired.substring(0, dot) : desired;
    final ext = dot > 0 ? desired.substring(dot) : '';
    final base = fitBytes(
      rawBase,
      maxNameBytes - utf8.encode(ext).length - _conflictCounterBytes,
    );
    for (var i = 2; i < 1000; i++) {
      final candidate = '$base ($i)$ext';
      if (!busy.contains(fold(candidate))) return candidate;
    }
    return '$base (${DateTime.now().millisecondsSinceEpoch})$ext';
  }

  /// Что делать со строкой зеркала, если путь в облаке разошёлся с записанным.
  ///
  /// [pathDiffers] — облако переименовало или перенесло запись, [samePathOnVolume] — пути
  /// различаются только регистром на томе, который регистр не различает, [fileAtOldPath] —
  /// файл по записанному пути есть, [fileAtNewPath] — по новому пути что-то есть.
  ///
  /// Возвращает решение, ничего не выполняя: файловая система и база остаются вызывающему.
  static MirrorMoveAction decideMove({
    required bool pathDiffers,
    required bool samePathOnVolume,
    required bool fileAtOldPath,
    required bool fileAtNewPath,
  }) {
    if (!pathDiffers) return MirrorMoveAction.none;
    // на карте памяти `A.txt` и `a.txt` — один файл: переставлять нечего, но строку надо
    // привести к написанию облака
    if (samePathOnVolume) return MirrorMoveAction.rename;
    if (fileAtOldPath && !fileAtNewPath) return MirrorMoveAction.rename;
    if (!fileAtOldPath) return MirrorMoveAction.forget;
    return MirrorMoveAction.none;
  }

  /// Что делать с записью облака по её пути на телефоне.
  ///
  /// [known] — строка зеркала есть, [contentMatches] — хэш облака совпал со слепком строки,
  /// [localExists] — файл на телефоне есть, [excludedName] — имя служебное или скрытое,
  /// [rowMatchesLocal] — размер, дата и номер файла совпали со строкой (файл с прошлой сверки
  /// не менялся), [looksLikeSource] — строки нет, но размер и дата совпали с датой источника.
  ///
  /// Порядок решений важен: сначала «содержимое уже наше», потом «файла нет», потом «это тот же
  /// файл», и только в конце конфликт — так локальная правка не затирается молча.
  static MirrorRecordAction decideRecord({
    required bool known,
    required bool contentMatches,
    required bool localExists,
    required bool excludedName,
    required bool rowMatchesLocal,
    required bool looksLikeSource,
  }) {
    if (known && contentMatches) return MirrorRecordAction.keep;
    if (!localExists) {
      // служебные и скрытые имена сканер не обходит: тянуть их к себе — значит завести строку,
      // которой на следующем проходе «не будет», и унести облачный файл в корзину
      return excludedName ? MirrorRecordAction.keep : MirrorRecordAction.download;
    }
    if (looksLikeSource) return MirrorRecordAction.adopt;
    if (rowMatchesLocal) return MirrorRecordAction.download;
    return MirrorRecordAction.conflict;
  }
}

/// Что делать со строкой зеркала, чей путь разошёлся с облачным (см. [MirrorRules.decideMove]).
enum MirrorMoveAction {
  /// Ничего: пути совпадают либо по новому пути уже что-то лежит — разберётся решение
  /// по содержимому.
  none,

  /// Переставить файл (или только переписать строку, если том не различает регистр).
  rename,

  /// Строку забыть: по старому пути файла нет, значит описывать нечего. Дальше запись
  /// обрабатывается как новая — иначе в таблице остались бы две строки с одной записью облака,
  /// и фаза «телефон → облако» унесла бы только что скачанный файл в корзину.
  forget,
}

/// Что делать с записью облака на телефоне (см. [MirrorRules.decideRecord]).
enum MirrorRecordAction {
  /// Ничего: содержимое облака уже лежит на телефоне.
  keep,

  /// Скачать облачную версию по этому пути.
  download,

  /// Строки нет, а файл на телефоне — тот же самый (совпали размер и дата источника):
  /// завести строку, не скачивая.
  adopt,

  /// Менялось и там, и тут: локальную версию отодвинуть копией, затем скачать облачную.
  conflict,
}
