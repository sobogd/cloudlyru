import '../section.dart';

/// Кандидат в очередь: файл, который надо выгрузить в конкретную облачную папку.
/// Отдельного типа для очереди намеренно нет — запись в базе отличается только состоянием,
/// а правила отбора работают с этим набором полей.
class Candidate {
  const Candidate({
    required this.path,
    required this.relDir,
    required this.name,
    required this.size,
    required this.mtime,
    required this.section,
    required this.target,
  });

  final String path;
  final String relDir;
  final String name;
  final int size;
  final int mtime;
  final Section section;

  /// id облачной папки: у «Фото» — медиатека (плоско).
  final String target;
}

/// Строка очереди в том виде, в каком она нужна правилу уборки (значения — как в базе).
class QueueRow {
  const QueueRow(this.id, this.path, this.target, this.section, this.state);

  final int id;
  final String path;
  final String target;
  final String section;
  final String state;
}

/// Что уже лежит в облаке: запись и слепок содержимого, по которому её выгружали.
class Uploaded {
  const Uploaded(this.entryId, this.size, this.mtime);

  final String entryId;
  final int size;
  final int mtime;
}

/// Ключ выгруженного: файл и облачная папка, в которую он лёг.
class UploadedKey {
  const UploadedKey(this.path, this.target);

  final String path;
  final String target;

  @override
  bool operator ==(Object other) =>
      other is UploadedKey && other.path == path && other.target == target;

  @override
  int get hashCode => Object.hash(path, target);

  @override
  String toString() => '$path → $target';
}

/// Правила наполнения очереди. Чистые функции: всё, что зависит от диска и базы, приходит
/// аргументами, поэтому логику проверяют тесты без устройства.
///
/// Хэш здесь не считается: очередь заполняется по размеру и дате изменения, иначе первый
/// проход по большой библиотеке читал бы все файлы целиком. Хэш нужен только в момент
/// выгрузки — для дедупа и для записи на сервере.
abstract final class QueuePlanner {
  /// Кого ставить в очередь: файл, которого нет в этой облачной папке, или тот, что изменился
  /// после выгрузки. Сравниваются размер и дата изменения — читать файлы на этапе наполнения
  /// очереди не нужно.
  ///
  /// Один и тот же файл из двух разделов даёт две записи с разными целями: папка может быть
  /// прикреплена и к «Файлам», и к «Фото», и тогда он нужен в обоих местах.
  ///
  /// Уже стоящий в очереди файл повторно в неё не попадает (в базе уникальность по паре
  /// «файл + цель»), поэтому проход можно запускать сколько угодно раз.
  static List<Candidate> plan(
    List<Candidate> candidates,
    Map<UploadedKey, Uploaded> uploaded,
  ) {
    final out = <Candidate>[];
    final seen = <UploadedKey>{};
    for (final candidate in candidates) {
      final key = UploadedKey(candidate.path, candidate.target);
      if (!seen.add(key)) continue;
      final there = uploaded[key];
      final alreadyThere =
          there != null && there.size == candidate.size && there.mtime == candidate.mtime;
      if (alreadyThere) continue;
      out.add(candidate);
    }
    return out;
  }

  /// Что из очереди больше не подлежит выгрузке и должно быть убрано: папку отключили
  /// от раздела, файла на телефоне уже нет, или он больше не подходит. Без этой уборки
  /// очередь копила бы мусор от каждого изменения выбора папок.
  ///
  /// Разделы, которые в этом проходе не сканировались (например, цель ещё неизвестна —
  /// не выполнен вход), не трогаются вовсе: иначе одна неполадка выкосила бы всю очередь.
  /// Запущенная выгрузка тоже не трогается — файл в этот момент льётся.
  static List<int> obsolete(
    List<QueueRow> rows,
    Set<UploadedKey> keep,
    Set<Section> scannedSections,
  ) =>
      rows
          .where((row) {
            final section = Section.byStorageKey(row.section);
            return section != null &&
                scannedSections.contains(section) &&
                row.state != 'RUNNING' &&
                !keep.contains(UploadedKey(row.path, row.target));
          })
          .map((row) => row.id)
          .toList();
}
