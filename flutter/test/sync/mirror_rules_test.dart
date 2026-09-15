import 'package:cloudly_flutter/sync/mirror/mirror_models.dart';
import 'package:cloudly_flutter/sync/mirror/mirror_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// Сверка зеркала: ошибка здесь означает либо потерянный файл, либо удаление чужого содержимого
/// в облаке. Обе крайности дорогие, поэтому правила проверяются без устройства.
void main() {
  const now = 1000000;

  String afterLastSlash(String path) =>
      path.substring(path.lastIndexOf('/') + 1);

  String beforeLastSlash(String path) =>
      path.substring(0, path.lastIndexOf('/'));

  LocalFile local({
    String path = '/s/Download/doc.pdf',
    int size = 100,
    int mtime = now - 60000,
    int inode = 42,
  }) => LocalFile(
    path: path,
    name: afterLastSlash(path),
    dir: beforeLastSlash(path),
    relDir: 'Download',
    root: '/s/Download',
    size: size,
    mtime: mtime,
    inode: inode,
  );

  MirrorRow row({
    String path = '/s/Download/doc.pdf',
    String entryId = 'entry-1',
    int size = 100,
    int mtime = now - 60000,
    int inode = 42,
    String? sha256 = 'aa',
  }) => MirrorRow(
    path: path,
    cloudFolderId: 'cloud-dir',
    entryId: entryId,
    inode: inode,
    size: size,
    mtime: mtime,
    sha256: sha256,
  );

  LocalSnapshot snapshot(
    List<LocalFile> files, {
    int unreadable = 0,
    bool capped = false,
  }) => LocalSnapshot(
    files: files,
    dirs: const [LocalDir('/s/Download', 'Download')],
    unreadable: unreadable,
    capped: capped,
  );

  group('MirrorRules', () {
    test('новый файл выгружается', () {
      final plan = MirrorRules.plan(
        local: [local()],
        known: const {},
        now: now,
        deletionsAllowed: true,
      );

      expect(plan.uploads.map((f) => f.path), ['/s/Download/doc.pdf']);
      expect(plan.renames, isEmpty);
      expect(plan.deletes, isEmpty);
    });

    test('файл, который ещё пишут, ждёт', () {
      // файл изменился только что: его ещё пишут, выгружать нельзя
      final fresh = local(mtime: now - 1000);
      final plan = MirrorRules.plan(
        local: [fresh],
        known: const {},
        now: now,
        deletionsAllowed: true,
      );

      expect(plan.uploads, isEmpty);
    });

    test('неизменившийся файл не выгружается повторно', () {
      final plan = MirrorRules.plan(
        local: [local()],
        known: {'/s/Download/doc.pdf': row()},
        now: now,
        deletionsAllowed: true,
      );

      expect(plan.uploads, isEmpty);
      expect(plan.deletes, isEmpty);
    });

    test('изменившееся содержимое выгружается снова', () {
      final edited = local(size: 200);
      final plan = MirrorRules.plan(
        local: [edited],
        known: {'/s/Download/doc.pdf': row()},
        now: now,
        deletionsAllowed: true,
      );

      expect(plan.uploads.map((f) => f.path), ['/s/Download/doc.pdf']);
      expect(plan.deletes, isEmpty);
    });

    test('переименование — это не удаление с выгрузкой', () {
      // тот же inode, другой путь: байты передавать не нужно, содержимое в облаке уже есть
      final moved = local(path: '/s/Download/отчёт.pdf', inode: 42);
      final plan = MirrorRules.plan(
        local: [moved],
        known: {'/s/Download/doc.pdf': row()},
        now: now,
        deletionsAllowed: true,
      );

      expect(plan.renames.length, 1);
      expect(plan.renames.first.$1.path, '/s/Download/doc.pdf');
      expect(plan.renames.first.$2.path, '/s/Download/отчёт.pdf');
      expect(plan.uploads, isEmpty);
      expect(plan.deletes, isEmpty);
    });

    test('переименование вместе с правкой — не переименование', () {
      // переименование и правка разом: размер разошёлся, значит это не переименование,
      // а «пропал старый + появился новый» — так облачное содержимое не перезаписывается
      final moved = local(path: '/s/Download/отчёт.pdf', size: 200, inode: 42);
      final plan = MirrorRules.plan(
        local: [moved],
        known: {'/s/Download/doc.pdf': row()},
        now: now,
        deletionsAllowed: true,
      );

      expect(plan.renames, isEmpty);
      expect(plan.uploads.map((f) => f.path), ['/s/Download/отчёт.pdf']);
      expect(plan.deletes.map((r) => r.entryId), ['entry-1']);
    });

    test('переиспользованный inode с другой датой — не переименование', () {
      // ядро отдало освободившийся inode новому файлу: размер совпал, дата нет — не переименование
      final fresh = local(
        path: '/s/Download/new.pdf',
        size: 100,
        mtime: now - 5000,
        inode: 42,
      );
      final plan = MirrorRules.plan(
        local: [fresh],
        known: {'/s/Download/doc.pdf': row()},
        now: now,
        deletionsAllowed: true,
      );

      expect(plan.renames, isEmpty);
      expect(plan.deletes.map((r) => r.entryId), ['entry-1']);
    });

    test('скрытые и служебные строки в облаке не удаляются никогда', () {
      // обход такие имена не показывает: «файла нет в снимке» — это правило показа, а не удаление
      final known = {
        '/s/Download/.nomedia': row(
          path: '/s/Download/.nomedia',
          entryId: 'hidden',
        ),
        '/s/Download/movie.mp4.part': row(
          path: '/s/Download/movie.mp4.part',
          entryId: 'junk',
        ),
        '/s/Download/doc.pdf': row(
          path: '/s/Download/doc.pdf',
          entryId: 'real',
        ),
      };
      final plan = MirrorRules.plan(
        local: [local()],
        known: known,
        now: now,
        deletionsAllowed: true,
      );

      expect(
        plan.deletes.where((r) => r.entryId == 'hidden' || r.entryId == 'junk'),
        isEmpty,
      );
      expect(plan.deletes, isEmpty);
    });

    test('дата из будущего считается устоявшейся', () {
      // файл из архива с датой в будущем не должен застрять навсегда
      expect(MirrorRules.isStable(now + 5000, now), isTrue);
    });

    test('пропавший файл удаляется в облаке', () {
      final plan = MirrorRules.plan(
        local: const [],
        known: {'/s/Download/doc.pdf': row()},
        now: now,
        deletionsAllowed: true,
      );

      expect(plan.deletes.map((r) => r.entryId), ['entry-1']);
      expect(plan.blocked, isFalse);
    });

    test('неизвестный inode откатывается к «удалить и выгрузить»', () {
      // inode узнать не удалось: переименование неотличимо от «удалили и создали»
      final fresh = local(path: '/s/Download/отчёт.pdf', inode: 0);
      final plan = MirrorRules.plan(
        local: [fresh],
        known: {'/s/Download/doc.pdf': row(inode: 0)},
        now: now,
        deletionsAllowed: true,
      );

      expect(plan.renames, isEmpty);
      expect(plan.uploads.map((f) => f.path), ['/s/Download/отчёт.pdf']);
      expect(plan.deletes.map((r) => r.entryId), ['entry-1']);
    });

    test('нечитаемая папка запрещает удаления', () {
      // папка не читается — «файла нет» означает «мы его не увидели», а не «его удалили»
      final snap = snapshot(const [], unreadable: 3);

      expect(MirrorRules.deletionsAllowed(snap), isFalse);
      // и обратная сторона: по чистому снимку удаления разрешены — иначе облако
      // никогда бы ничего не убирало, а тесты видели бы только запрет
      expect(MirrorRules.deletionsAllowed(snapshot(const [])), isTrue);

      final plan = MirrorRules.plan(
        local: snap.files,
        known: {'/s/Download/doc.pdf': row()},
        now: now,
        deletionsAllowed: false,
      );

      expect(plan.deletes, isEmpty);
      expect(plan.blocked, isTrue);
      expect(plan.blockedCount, 1);
    });

    test('неполный обход запрещает удаления', () {
      expect(
        MirrorRules.deletionsAllowed(snapshot(const [], capped: true)),
        isFalse,
      );
    });

    test('массовое удаление требует подтверждения', () {
      // пропало 30 из 100 — четверть и больше порога: удалять нельзя без подтверждения
      expect(MirrorRules.massDelete(30, 100), isTrue);

      final known = {
        for (var i = 1; i <= 100; i++)
          '/s/Download/f$i': row(path: '/s/Download/f$i'),
      };
      final plan = MirrorRules.plan(
        local: const [],
        known: known,
        now: now,
        deletionsAllowed: true,
      );

      expect(plan.deletes, isEmpty);
      expect(plan.blocked, isTrue);
      expect(plan.blockedCount, 100);
    });

    test('малая доля от большой библиотеки — это нормально', () {
      // 25 файлов из 1000 — обычное дело (чистка загрузок), предохранитель не мешает
      expect(MirrorRules.massDelete(25, 1000), isFalse);
    });

    test('огромное удаление блокируется даже в маленькой библиотеке', () {
      expect(MirrorRules.massDelete(MirrorRules.massDeleteMax, 100000), isTrue);
    });

    test('подтверждённое удаление проходит', () {
      final known = {
        for (var i = 1; i <= 100; i++)
          '/s/Download/f$i': row(path: '/s/Download/f$i', entryId: 'e$i'),
      };
      final plan = MirrorRules.plan(
        local: const [],
        known: known,
        now: now,
        deletionsAllowed: true,
        confirmed: true,
      );

      expect(plan.deletes.length, 100);
      expect(plan.blocked, isFalse);
    });

    test('пустая библиотека не срабатывает на предохранителе', () {
      expect(MirrorRules.massDelete(0, 0), isFalse);

      final plan = MirrorRules.plan(
        local: const [],
        known: const {},
        now: now,
        deletionsAllowed: true,
      );

      expect(plan.deletes, isEmpty);
      expect(plan.blocked, isFalse);
    });

    test('конфликтная копия сохраняет обе версии', () {
      final name = MirrorRules.conflictName('отчёт.pdf', 1700000000000);

      expect(name.startsWith('отчёт (конфликт '), isTrue);
      expect(name.endsWith('.pdf'), isTrue);
      // файл без расширения тоже получает осмысленное имя
      expect(
        MirrorRules.conflictName(
          'README',
          1700000000000,
        ).startsWith('README (конфликт '),
        isTrue,
      );
    });

    test('метка конфликта держит формат «yyyy-MM-dd HH.mm»', () {
      // формат — часть имени файла в облаке: смена вида ломает узнаваемость копий
      final at = DateTime(2024, 3, 7, 9, 5).millisecondsSinceEpoch;

      expect(
        MirrorRules.conflictName('отчёт.pdf', at),
        'отчёт (конфликт 2024-03-07 09.05).pdf',
      );
      expect(
        MirrorRules.conflictName('README', at),
        'README (конфликт 2024-03-07 09.05)',
      );
    });

    test('строки снятой с выбора папки не трогаются', () {
      // папку сняли с выбора: её файлов в снимке нет, и удалять их в облаке нельзя —
      // пользователь всего лишь снял галочку, а не удалил данные
      final known = {
        '/s/Download/doc.pdf': row(
          path: '/s/Download/doc.pdf',
          entryId: 'in-mirror',
        ),
        '/s/DCIM/old.jpg': row(
          path: '/s/DCIM/old.jpg',
          entryId: 'not-selected',
        ),
      };
      bool inRoots(String path) =>
          MirrorRules.underRoots(path, ['/s/Download']);

      expect(inRoots('/s/Download/doc.pdf'), isTrue);
      expect(inRoots('/s/DCIM/old.jpg'), isFalse);

      final plan = MirrorRules.plan(
        local: const [],
        known: known,
        now: now,
        deletionsAllowed: true,
        inScope: inRoots,
      );

      expect(plan.deletes.map((r) => r.entryId), ['in-mirror']);
    });

    test('окно стабильности', () {
      expect(MirrorRules.isStable(now - MirrorRules.stableMs, now), isTrue);
      expect(
        MirrorRules.isStable(now - MirrorRules.stableMs + 1, now),
        isFalse,
      );
    });

    // ── Дополнено сверх Kotlin-набора ────────────────────────────────────────
    // Проверено мутациями (правило ломается нарочно — тесты обязаны упасть): эти ветки
    // в Kotlin-наборе тоже ничем не прикрыты, а цена ошибки здесь — потерянная правка
    // или дважды переписанная облачная запись.

    test('правка одной даты — тоже изменение', () {
      // размер тот же, дата другая: сверять только размер мало — правка не уехала бы
      final touched = local(mtime: now - 30000);
      final plan = MirrorRules.plan(
        local: [touched],
        known: {'/s/Download/doc.pdf': row(mtime: now - 60000)},
        now: now,
        deletionsAllowed: true,
      );

      expect(plan.uploads.map((f) => f.path), ['/s/Download/doc.pdf']);
    });

    test('один inode не даёт двух переименований', () {
      // два файла с одним inode: переименованием признаём только первое совпадение,
      // иначе одна облачная запись переписывалась бы дважды
      final plan = MirrorRules.plan(
        local: [
          local(path: '/s/Download/a.pdf'),
          local(path: '/s/Download/b.pdf'),
        ],
        known: {'/s/Download/doc.pdf': row()},
        now: now,
        deletionsAllowed: true,
      );

      expect(plan.renames.length, 1);
      expect(plan.renames.first.$2.path, '/s/Download/a.pdf');
      expect(plan.uploads.map((f) => f.path), ['/s/Download/b.pdf']);
      expect(plan.deletes, isEmpty);
    });
  });

  group('MirrorRules.emptyFolderCandidates', () {
    test('папка, которой нет на телефоне, уходит в уборку', () {
      final out = MirrorRules.emptyFolderCandidates(
        dirs: {'cloud-old': '/s/Download/Старое имя'},
        aliveLocally: {'/s/Download/Новое имя'},
        roots: ['/s/Download'],
        rootCloudIds: {'cloud-root'},
      );
      expect(out, ['/s/Download/Старое имя']);
    });

    test('корень зеркала не убирается никогда', () {
      // корень — это адрес, по которому лежит всё зеркало: удалить его значит осиротить папку
      final out = MirrorRules.emptyFolderCandidates(
        dirs: {'cloud-root': '/s/Download'},
        aliveLocally: const {},
        roots: ['/s/Download'],
        rootCloudIds: {'cloud-root'},
      );
      expect(out, isEmpty);
    });

    test('папка, которая на месте, не трогается', () {
      final out = MirrorRules.emptyFolderCandidates(
        dirs: {'cloud-a': '/s/Download/Отчёты'},
        aliveLocally: {'/s/Download/Отчёты'},
        roots: ['/s/Download'],
        rootCloudIds: {'cloud-root'},
      );
      expect(out, isEmpty);
    });

    test('папка снятая с выбора не трогается', () {
      // её нет в снимке только потому, что галочку сняли: удалять в облаке нечего
      final out = MirrorRules.emptyFolderCandidates(
        dirs: {'cloud-b': '/s/Pictures/Старое'},
        aliveLocally: const {},
        roots: ['/s/Download'],
        rootCloudIds: const {},
      );
      expect(out, isEmpty);
    });

    test('глубокие папки идут первыми', () {
      // тогда родитель, опустевший после удаления детей, уходит в том же проходе
      final out = MirrorRules.emptyFolderCandidates(
        dirs: {
          'cloud-top': '/s/Download/Старое',
          'cloud-deep': '/s/Download/Старое/Глубже',
          'cloud-deeper': '/s/Download/Старое/Глубже/Ещё',
        },
        aliveLocally: const {},
        roots: ['/s/Download'],
        rootCloudIds: const {},
      );
      expect(out, [
        '/s/Download/Старое/Глубже/Ещё',
        '/s/Download/Старое/Глубже',
        '/s/Download/Старое',
      ]);
    });
  });
}
