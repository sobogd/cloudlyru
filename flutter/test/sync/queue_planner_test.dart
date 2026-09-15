import 'package:cloudly_flutter/sync/queue/queue_planner.dart';
import 'package:cloudly_flutter/sync/section.dart';
import 'package:flutter_test/flutter_test.dart';

/// Наполнение и уборка очереди: ошибка здесь означает либо потерянный файл (не поставили
/// в очередь), либо бесконечную перезаливку одного и того же. Обе крайности дорогие, поэтому
/// правила проверяются без устройства.
void main() {
  Candidate candidate({
    String path = '/s/Download/doc.pdf',
    String relDir = 'Download',
    int size = 100,
    int mtime = 1000,
    Section section = Section.files,
    String target = 'phone',
  }) => Candidate(
    path: path,
    relDir: relDir,
    name: path.substring(path.lastIndexOf('/') + 1),
    size: size,
    mtime: mtime,
    section: section,
    target: target,
  );

  QueueRow row(
    int id, {
    String path = '/s/Download/a.pdf',
    String target = 'phone',
    Section section = Section.files,
    String state = 'PENDING',
  }) => QueueRow(id, path, target, section.storageKey, state);

  const download = '/s/Download/a.pdf';

  group('QueuePlanner.plan', () {
    test('новый файл встаёт в очередь', () {
      final planned = QueuePlanner.plan([candidate()], const {});

      expect(planned.length, 1);
    });

    test('неизменившийся и уже выгруженный файл пропускается', () {
      final item = candidate();
      final planned = QueuePlanner.plan(
        [item],
        {
          UploadedKey(item.path, item.target): Uploaded(
            'entry',
            item.size,
            item.mtime,
          ),
        },
      );

      expect(planned, isEmpty);
    });

    test('изменившийся файл встаёт в очередь снова', () {
      final item = candidate(size: 200, mtime: 2000);
      final planned = QueuePlanner.plan(
        [item],
        {UploadedKey(item.path, item.target): Uploaded('entry', 100, 1000)},
      );

      // правка на телефоне должна доехать до облака, иначе перезаписи не будет никогда
      expect(planned.length, 1);
    });

    test('один файл для двух целей встаёт в очередь дважды', () {
      final planned = QueuePlanner.plan([
        candidate(target: 'phone'),
        candidate(target: 'photos', relDir: ''),
      ], const {});

      // папка прикреплена и к «Файлам», и к «Фото» — файл нужен в обоих местах
      expect(planned.length, 2);
      expect(planned.map((c) => c.target).toSet(), {'phone', 'photos'});
    });

    test('файл, выгруженный в другую цель, всё равно встаёт в очередь', () {
      final item = candidate(target: 'photos', relDir: '');
      final planned = QueuePlanner.plan(
        [item],
        {
          UploadedKey(item.path, 'phone'): Uploaded(
            'entry',
            item.size,
            item.mtime,
          ),
        },
      );

      // «уже в облаке» в разделе «Файлы» не значит, что файл есть в медиатеке
      expect(planned.length, 1);
    });

    test('один файл дважды за проход встаёт в очередь один раз', () {
      final planned = QueuePlanner.plan([candidate(), candidate()], const {});

      expect(planned.length, 1);
    });
  });

  group('QueuePlanner.obsolete', () {
    test('файл отключённой папки убирается', () {
      final doomed = QueuePlanner.obsolete(
        [row(1, path: '/s/Old/gone.pdf')],
        {UploadedKey(download, 'phone')},
        {Section.files},
      );

      expect(doomed, [1]);
    });

    test('файл, который всё ещё кандидат, остаётся', () {
      final doomed = QueuePlanner.obsolete(
        [row(1)],
        {UploadedKey(download, 'phone')},
        {Section.files},
      );

      expect(doomed, isEmpty);
    });

    test('нетронутый раздел не вычищается', () {
      // «Фото» в этом проходе не сканировался: цель неизвестна — трогать его нельзя
      final doomed = QueuePlanner.obsolete(
        [
          row(
            1,
            path: '/s/DCIM/IMG.jpg',
            target: 'photos',
            section: Section.photos,
          ),
        ],
        const {},
        {Section.files},
      );

      expect(doomed, isEmpty);
    });

    test('запущенная выгрузка не вычищается', () {
      final doomed = QueuePlanner.obsolete(
        [row(1, state: 'RUNNING')],
        const {},
        {Section.files},
      );

      expect(doomed, isEmpty);
    });

    test('запись «выгружено» из отключённой папки тоже убирается', () {
      // запись осталась как «выгружен» от прежнего выбора папок: в очереди ей делать нечего
      final doomed = QueuePlanner.obsolete(
        [row(1, path: '/s/Old/done.pdf', state: 'DONE')],
        const {},
        {Section.files},
      );

      expect(doomed, [1]);
    });

    // ── Дополнено сверх Kotlin-набора ────────────────────────────────────────
    // Проверено мутациями: эти ветки в Kotlin-наборе тоже ничем не прикрыты.

    test('изменившаяся только дата тоже встаёт в очередь', () {
      // сравнивать один размер мало: правка, не поменявшая размер, иначе не уехала бы
      final touched = candidate(size: 100, mtime: 2000);
      final planned = QueuePlanner.plan(
        [touched],
        {
          UploadedKey(touched.path, touched.target): Uploaded(
            'entry',
            100,
            1000,
          ),
        },
      );

      expect(planned.length, 1);
    });

    test('строка с незнакомым разделом не вычищается', () {
      // значение в базе может быть незнакомым (старая версия, правка руками):
      // это не повод молча выкинуть строку из очереди
      final doomed = QueuePlanner.obsolete(
        [QueueRow(1, '/s/Download/a.pdf', 'phone', 'WEIRD', 'PENDING')],
        const {},
        {Section.files},
      );

      expect(doomed, isEmpty);
    });
  });
}
