import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../queue/queue_planner.dart';
import '../section.dart';

/// Состояние файла в очереди. Автоматического запуска нет: пользователь жмёт «play» сам.
enum QueueState {
  pending('PENDING'),
  running('RUNNING'),
  skipped('SKIPPED'),
  done('DONE'),
  failed('FAILED');

  const QueueState(this.storageKey);

  final String storageKey;

  static QueueState byKey(String? key) => QueueState.values.firstWhere(
    (s) => s.storageKey == key,
    orElse: () => QueueState.pending,
  );
}

/// Строка очереди: что выгружать, куда и что с этим уже произошло.
class QueueItem {
  const QueueItem({
    required this.id,
    required this.path,
    required this.relDir,
    required this.name,
    required this.size,
    required this.mtime,
    required this.section,
    required this.target,
    required this.state,
    required this.attempts,
    required this.createdAt,
    this.lastError,
    this.entryId,
    this.sha256,
  });

  final int id;
  final String path;
  final String relDir;
  final String name;
  final int size;
  final int mtime;
  final Section section;
  final String target;
  final QueueState state;
  final int attempts;

  /// Посчитанный хэш содержимого: пока файл не менялся, второй раз не считаем.
  final String? sha256;
  final String? lastError;
  final String? entryId;
  final int createdAt;
}

/// Локальное состояние очереди. Две таблицы:
///   • `uploaded` — что уже лежит в облаке, отдельно для каждой облачной папки: один и тот же
///                  файл может уехать и в «Файлы», и в «Фото», и «уже выгружено» в одной папке
///                  ничего не говорит про другую;
///   • `queue`    — сама очередь: файл + цель, состояние, попытки и текст последней ошибки.
///
/// Очередь переживает перезапуск и обновление приложения: выгрузка ручная, и терять
/// подготовленную работу при каждом запуске нельзя.
class QueueStore {
  QueueStore._(this._db);

  final Database _db;

  static const String _name = 'cloudly-queue.db';
  static const int _version = 3;

  static Future<QueueStore> open({String? directory}) async {
    final path = p.join(directory ?? await getDatabasesPath(), _name);
    final db = await openDatabase(
      path,
      version: _version,
      // Своё соединение на каждый движок. В одном процессе живут два: приложение и фоновое
      // задание (SyncJobService). sqflite по умолчанию отдаёт одно соединение на путь, и тогда
      // закрытие базы в фоне закрывало её и в приложении — «database closed» на первом же
      // обращении после прохода
      singleInstance: false,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE uploaded(
            path TEXT NOT NULL,
            target TEXT NOT NULL,
            entry_id TEXT NOT NULL,
            size INTEGER NOT NULL,
            mtime INTEGER NOT NULL,
            sha256 TEXT,
            at INTEGER NOT NULL,
            PRIMARY KEY(path, target)
          )
        ''');
        await db.execute('''
          CREATE TABLE queue(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL,
            rel_dir TEXT NOT NULL,
            name TEXT NOT NULL,
            size INTEGER NOT NULL,
            mtime INTEGER NOT NULL,
            section TEXT NOT NULL,
            target TEXT NOT NULL,
            state TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            created_at INTEGER NOT NULL,
            started_at INTEGER,
            finished_at INTEGER,
            entry_id TEXT,
            sha256 TEXT
          )
        ''');
        await db.execute(
          'CREATE UNIQUE INDEX queue_unique ON queue(path, target)',
        );
        await db.execute('CREATE INDEX queue_state ON queue(state, id)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Очередь пересобирается проходом, а вот uploaded (что уже выгружено) терять нельзя.
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE uploaded ADD COLUMN sha256 TEXT');
        }
        if (oldVersion < 2) {
          // кэш хэша: считать SHA-256 заново на каждую попытку большого видео — минуты работы
          await db.execute('ALTER TABLE queue ADD COLUMN sha256 TEXT');
        }
      },
    );
    await _setBusyTimeout(db);
    return QueueStore._(db);
  }

  Future<void> close() => _db.close();

  // ===== что уже выгружено =====

  /// Ключ — файл и облачная папка: одна и та же запись может лежать в двух разделах.
  Future<Map<UploadedKey, Uploaded>> uploaded() async {
    final rows = await _db.query('uploaded');
    return {
      for (final r in rows)
        UploadedKey('${r['path']}', '${r['target']}'): Uploaded(
          '${r['entry_id']}',
          (r['size'] as int?) ?? 0,
          (r['mtime'] as int?) ?? 0,
        ),
    };
  }

  /// Что на телефоне соответствует этой записи облака: по ней применяются правки из веба.
  Future<List<(UploadedKey, Uploaded)>> uploadedByEntry(String entryId) async {
    final rows = await _db.query(
      'uploaded',
      where: 'entry_id = ?',
      whereArgs: [entryId],
    );
    return [
      for (final r in rows)
        (
          UploadedKey('${r['path']}', '${r['target']}'),
          Uploaded(
            '${r['entry_id']}',
            (r['size'] as int?) ?? 0,
            (r['mtime'] as int?) ?? 0,
          ),
        ),
    ];
  }

  /// Путь файла на телефоне изменился (переименование в вебе): переносим запись.
  Future<void> moveUploaded(String oldPath, String target, String newPath) =>
      _db.update(
        'uploaded',
        {'path': newPath},
        where: 'path = ? AND target = ?',
        whereArgs: [oldPath, target],
      );

  /// Запомнить новую версию содержимого: размер, дата и хэш после скачивания из облака.
  Future<void> refreshUploaded(
    String path,
    String target,
    int size,
    int mtime,
    String? sha256,
  ) => _db.update(
    'uploaded',
    {
      'size': size,
      'mtime': mtime,
      'sha256': ?sha256,
      'at': DateTime.now().millisecondsSinceEpoch,
    },
    where: 'path = ? AND target = ?',
    whereArgs: [path, target],
  );

  Future<String?> shaOfUploaded(String path, String target) async {
    final rows = await _db.query(
      'uploaded',
      columns: ['sha256'],
      where: 'path = ? AND target = ?',
      whereArgs: [path, target],
    );
    if (rows.isEmpty) return null;
    final v = rows.first['sha256'];
    return v == null ? null : '$v';
  }

  Future<void> markUploaded(
    String path,
    String target,
    String entryId,
    int size,
    int mtime, {
    String? sha256,
  }) => _db.insert('uploaded', {
    'path': path,
    'target': target,
    'entry_id': entryId,
    'size': size,
    'mtime': mtime,
    'sha256': ?sha256,
    'at': DateTime.now().millisecondsSinceEpoch,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  // ===== очередь =====

  /// Поставить кандидатов в очередь. Повторная постановка того же файла в ту же папку
  /// не плодит строку; уже выгруженный файл, который после этого изменился, снова становится
  /// ожидающим — иначе правка на телефоне никогда бы не доехала до облака.
  Future<int> enqueue(List<Candidate> items) async {
    if (items.isEmpty) return 0;
    var added = 0;
    // Какие пары «файл + цель» уже стоят в очереди: отдельный запрос на каждый файл — это
    // десятки тысяч запросов на фотоальбоме при каждом входе в раздел. Один запрос вместо них.
    final existing = <String>{};
    for (final r in await _db.query('queue', columns: ['path', 'target'])) {
      existing.add('${r['path']}\u0000${r['target']}');
    }
    await _db.transaction((txn) async {
      for (final item in items) {
        if (existing.contains('${item.path}\u0000${item.target}')) {
          await txn.rawUpdate(
            '''
            UPDATE queue SET rel_dir = ?, name = ?, size = ?, mtime = ?,
              state = CASE WHEN state IN ('DONE','SKIPPED') THEN 'PENDING' ELSE state END,
              last_error = CASE WHEN state IN ('DONE','SKIPPED') THEN NULL ELSE last_error END
            WHERE path = ? AND target = ?
            ''',
            [
              item.relDir,
              item.name,
              item.size,
              item.mtime,
              item.path,
              item.target,
            ],
          );
        } else {
          await txn.rawInsert(
            '''
            INSERT INTO queue(path, rel_dir, name, size, mtime, section, target, state, created_at)
            VALUES(?,?,?,?,?,?,?,?,?)
            ''',
            [
              item.path,
              item.relDir,
              item.name,
              item.size,
              item.mtime,
              item.section.storageKey,
              item.target,
              QueueState.pending.storageKey,
              DateTime.now().millisecondsSinceEpoch,
            ],
          );
          added += 1;
        }
      }
    });
    return added;
  }

  Future<List<QueueItem>> items({int limit = 2000}) async {
    final rows = await _db.rawQuery(
      '''
      SELECT * FROM queue
      ORDER BY CASE state WHEN 'RUNNING' THEN 0 WHEN 'PENDING' THEN 1 WHEN 'FAILED' THEN 2 ELSE 3 END, id
      LIMIT ?
      ''',
      [limit],
    );
    return rows.map(_readItem).toList();
  }

  Future<Map<QueueState, int>> counts() async {
    final rows = await _db.rawQuery(
      'SELECT state, COUNT(*) AS n FROM queue GROUP BY state',
    );
    return {
      for (final r in rows)
        QueueState.byKey('${r['state']}'): (r['n'] as int?) ?? 0,
    };
  }

  /// Ждут запуска: кнопка «play» и счётчик в шапке смотрят сюда.
  Future<int> waitingCount() async {
    final rows = await _db.rawQuery(
      "SELECT COUNT(*) AS n FROM queue WHERE state IN ('PENDING','FAILED')",
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<QueueItem?> item(int id) async {
    final rows = await _db.query(
      'queue',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _readItem(rows.first);
  }

  Future<void> markRunning(int id) => _update(id, {
    'state': QueueState.running.storageKey,
    'started_at': DateTime.now().millisecondsSinceEpoch,
    'last_error': null,
  });

  Future<void> markDone(int id, String entryId) => _update(id, {
    'state': QueueState.done.storageKey,
    'entry_id': entryId,
    'finished_at': DateTime.now().millisecondsSinceEpoch,
  });

  /// Содержимое уже было в облаке: байты не передавались, но запись там есть.
  Future<void> markSkipped(int id, String entryId) => _update(id, {
    'state': QueueState.skipped.storageKey,
    'entry_id': entryId,
    'finished_at': DateTime.now().millisecondsSinceEpoch,
  });

  Future<void> markFailed(int id, String error, int attempts) => _update(id, {
    'state': QueueState.failed.storageKey,
    'last_error': error.length > 500 ? error.substring(0, 500) : error,
    'attempts': attempts,
    'finished_at': DateTime.now().millisecondsSinceEpoch,
  });

  /// Вернуть в ожидание: кнопка повтора на строке с ошибкой.
  Future<void> markPending(int id) =>
      _update(id, {'state': QueueState.pending.storageKey, 'last_error': null});

  /// Запомнить посчитанный хэш: повторная попытка не должна перечитывать весь файл.
  Future<void> setSha(int id, String sha256) => _update(id, {'sha256': sha256});

  /// Снять зависшие «грузится». После перезапуска приложения ничего не может быть в работе,
  /// а строка осталась бы в этом состоянии навсегда.
  Future<int> resetRunning() => _db.update(
    'queue',
    {'state': QueueState.pending.storageKey, 'last_error': null},
    where: 'state = ?',
    whereArgs: [QueueState.running.storageKey],
  );

  /// Убрать из очереди то, чего больше не должно быть: папку отключили от раздела или файл
  /// с телефона исчез. Ключи, которые остались кандидатами, и незатронутые разделы
  /// остаются на месте.
  Future<int> prune(Set<UploadedKey> keep, Set<Section> scannedSections) async {
    if (scannedSections.isEmpty) return 0;
    final rows = await _db.query(
      'queue',
      columns: ['id', 'path', 'target', 'section', 'state'],
    );
    final doomed = QueuePlanner.obsolete(
      rows
          .map(
            (r) => QueueRow(
              (r['id'] as int?) ?? 0,
              '${r['path']}',
              '${r['target']}',
              '${r['section']}',
              '${r['state']}',
            ),
          )
          .toList(),
      keep,
      scannedSections,
    );
    if (doomed.isEmpty) return 0;
    await _db.transaction((txn) async {
      for (final id in doomed) {
        await txn.delete('queue', where: 'id = ?', whereArgs: [id]);
      }
    });
    return doomed.length;
  }

  /// Убрать выполненные строки: очередь не должна превращаться в летопись.
  Future<int> clearFinished() =>
      _db.delete('queue', where: "state IN ('DONE','SKIPPED')");

  Future<void> _update(int id, Map<String, Object?> values) =>
      _db.update('queue', values, where: 'id = ?', whereArgs: [id]);

  QueueItem _readItem(Map<String, Object?> r) => QueueItem(
    id: (r['id'] as int?) ?? 0,
    path: '${r['path']}',
    relDir: '${r['rel_dir']}',
    name: '${r['name']}',
    size: (r['size'] as int?) ?? 0,
    mtime: (r['mtime'] as int?) ?? 0,
    section: Section.byStorageKey('${r['section']}') ?? Section.files,
    target: '${r['target']}',
    state: QueueState.byKey('${r['state']}'),
    attempts: (r['attempts'] as int?) ?? 0,
    lastError: r['last_error'] == null ? null : '${r['last_error']}',
    entryId: r['entry_id'] == null ? null : '${r['entry_id']}',
    sha256: r['sha256'] == null ? null : '${r['sha256']}',
    createdAt: (r['created_at'] as int?) ?? 0,
  );
}

/// Два соединения к одному файлу (приложение и фоновое задание) — это нормально для SQLite,
/// но короткая параллельная запись может попасть в «database is locked». Пусть лучше подождёт.
///
/// PRAGMA ставится запросом, а не через `onConfigure`: там sqflite выполняет её как execSQL,
/// а Android такую строку не принимает и открытие базы падает целиком. Ошибка самой PRAGMA
/// при этом не критична — без неё возможен редкий «database is locked».
Future<void> _setBusyTimeout(Database db) async {
  try {
    await db.rawQuery('PRAGMA busy_timeout = 5000');
  } catch (_) {}
}
