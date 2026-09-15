import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../mirror/mirror_models.dart';

/// Локальное состояние зеркала. Пять таблиц:
///   • `roots`   — пары «выбранная папка телефона ↔ папка в облаке»: пара заводится один раз,
///                 иначе при пропаже папки сверка не знает, куда возвращать содержимое;
///   • `dirs`    — соответствие облачных папок и путей на телефоне: по нему правка из журнала
///                 (там известен только folderId) находится в файловой системе;
///   • `files`   — что уже выгружено: запись в облаке, inode, размер, дата и хэш;
///   • `uploads` — незавершённые выгрузки: продолжить с принятой части, а не лить заново;
///   • `meta`    — курсор журнала, итоги обходов и итог последнего прохода.
///
/// Отдельная база, а не таблицы очереди: очередь руками собирают и чистят, а состояние зеркала
/// терять нельзя — без него удаление не отличить от «ещё не видели» и облако поедет вразнос.
class MirrorStore {
  MirrorStore._(this._db);

  final Database _db;

  static const String _name = 'cloudly-mirror.db';
  static const int _version = 2;

  /// Курсор журнала: с какого seq продолжать догон облака.
  static const String keyCursor = 'changes_cursor';

  /// Сколько удалений приостановлено предохранителем и почему (для экрана настроек).
  static const String keyBlocked = 'blocked_deletes';

  /// Пользователь подтвердил удаление: следующий проход выполнит его один раз.
  static const String keyConfirmed = 'delete_confirmed';

  /// Итог последнего прохода в человеческом виде.
  static const String keyReport = 'last_report';

  /// Итоги обхода диска и очередь выгрузки: по ним интерфейс считает прогресс.
  static const String keyLocalFiles = 'local_files';
  static const String keyLocalBytes = 'local_bytes';
  static const String keyWaitFiles = 'wait_files';
  static const String keyWaitBytes = 'wait_bytes';

  /// Флаг «проходы выключены» из прежних сборок. Выключателя больше нет — синхронизация
  /// всегда включена, — а ключ остался, чтобы снять его при старте: иначе у тех, кто когда-то
  /// выключил автоматику, она молчала бы навсегда и вернуть её было бы нечем.
  static const String keyPaused = 'paused';

  /// Когда вернуться к файлам, отложенным окном стабильности (метка времени).
  static const String keyRetryAt = 'retry_at';

  /// Кто именно выгружен: адрес сервера и логин. Сменились — состояние не годится.
  static const String keyAccount = 'account';

  /// Мгновенный режим включён: процесс держится сервисом, уведомление висит.
  static const String keyLive = 'live_always';

  static const String keyDeviceId = 'device_id';

  /// Корень зеркала, для которого писались строки `files`. Сменился корень (например, сервер
  /// завёл новую папку устройства) — строки описывают записи в другой папке, и держать их
  /// нельзя: сверка решила бы, что файлы уже выгружены, а новая папка осталась бы пустой.
  static const String keyMirrorRoot = 'mirror_root_id';

  static Future<MirrorStore> open({String? directory}) async {
    final path = p.join(directory ?? await getDatabasesPath(), _name);
    final db = await openDatabase(
      path,
      version: _version,
      // Своё соединение на каждый движок: в процессе живут два — приложение и фоновое задание.
      // С общим соединением закрытие базы в фоне ломало приложение («database closed»)
      singleInstance: false,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE roots(
            local_path TEXT PRIMARY KEY,
            cloud_id TEXT NOT NULL,
            cloud_path TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE dirs(
            cloud_id TEXT PRIMARY KEY,
            local_path TEXT NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX dirs_local ON dirs(local_path)');
        await db.execute('''
          CREATE TABLE files(
            path TEXT PRIMARY KEY,
            cloud_folder_id TEXT NOT NULL,
            entry_id TEXT NOT NULL,
            inode INTEGER NOT NULL DEFAULT 0,
            size INTEGER NOT NULL,
            mtime INTEGER NOT NULL,
            sha256 TEXT,
            at INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX files_entry ON files(entry_id)');
        await db.execute('CREATE INDEX files_inode ON files(inode)');
        await db.execute(
          'CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        await db.execute('''
          CREATE TABLE uploads(
            path TEXT PRIMARY KEY,
            upload_id TEXT NOT NULL,
            folder_id TEXT NOT NULL,
            size INTEGER NOT NULL,
            mtime INTEGER NOT NULL,
            sha256 TEXT NOT NULL,
            at INTEGER NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Состояние зеркала не пересобирается «на глаз»: потеря строки означает удаление
        // файла в облаке на следующем проходе. Поэтому апгрейд только добавляет таблицы.
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS uploads(
              path TEXT PRIMARY KEY,
              upload_id TEXT NOT NULL,
              folder_id TEXT NOT NULL,
              size INTEGER NOT NULL,
              mtime INTEGER NOT NULL,
              sha256 TEXT NOT NULL,
              at INTEGER NOT NULL
            )
          ''');
        }
      },
    );
    await _setBusyTimeout(db);
    return MirrorStore._(db);
  }

  Future<void> close() => _db.close();

  // ===== незавершённые выгрузки =====

  Future<UploadSessionRow?> uploadSession(String path) async {
    final rows = await _db.query(
      'uploads',
      where: 'path = ?',
      whereArgs: [path],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return UploadSessionRow(
      path: '${r['path']}',
      uploadId: '${r['upload_id']}',
      folderId: '${r['folder_id']}',
      size: (r['size'] as int?) ?? 0,
      mtime: (r['mtime'] as int?) ?? 0,
      sha256: '${r['sha256']}',
    );
  }

  Future<void> putUploadSession(UploadSessionRow row) => _db.insert('uploads', {
    'path': row.path,
    'upload_id': row.uploadId,
    'folder_id': row.folderId,
    'size': row.size,
    'mtime': row.mtime,
    'sha256': row.sha256,
    'at': DateTime.now().millisecondsSinceEpoch,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> dropUploadSession(String path) =>
      _db.delete('uploads', where: 'path = ?', whereArgs: [path]);

  // ===== корни зеркала =====

  Future<void> putRoot(
    String localPath,
    String cloudId,
    String cloudPath,
  ) async {
    await _db.insert('roots', {
      'local_path': localPath,
      'cloud_id': cloudId,
      'cloud_path': cloudPath,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await registerDir(cloudId, localPath);
  }

  Future<Map<String, MirrorRoot>> roots() async {
    final rows = await _db.query('roots');
    return {
      for (final r in rows)
        '${r['local_path']}': MirrorRoot(
          '${r['local_path']}',
          '${r['cloud_id']}',
          '${r['cloud_path']}',
        ),
    };
  }

  /// Папку сняли с выбора: пару убираем, а строки files остаются — вернуть выбор можно без
  /// повторной заливки и без удаления в облаке.
  Future<void> dropRoot(String localPath) =>
      _db.delete('roots', where: 'local_path = ?', whereArgs: [localPath]);

  // ===== папки =====

  Future<void> registerDir(String cloudId, String localPath) async {
    if (cloudId.isEmpty) return;
    await _db.insert('dirs', {
      'cloud_id': cloudId,
      'local_path': localPath,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> dirId(String localPath) async {
    final rows = await _db.query(
      'dirs',
      columns: ['cloud_id'],
      where: 'local_path = ?',
      whereArgs: [localPath],
      limit: 1,
    );
    return rows.isEmpty ? null : '${rows.first['cloud_id']}';
  }

  Future<String?> dirPath(String cloudId) async {
    final rows = await _db.query(
      'dirs',
      columns: ['local_path'],
      where: 'cloud_id = ?',
      whereArgs: [cloudId],
      limit: 1,
    );
    return rows.isEmpty ? null : '${rows.first['local_path']}';
  }

  Future<void> dropDir(String cloudId) =>
      _db.delete('dirs', where: 'cloud_id = ?', whereArgs: [cloudId]);

  /// Папку на телефоне переименовали или перенесли: путь в паре меняется, id остаётся.
  Future<void> moveDir(String cloudId, String newLocalPath) => _db.update(
    'dirs',
    {'local_path': newLocalPath},
    where: 'cloud_id = ?',
    whereArgs: [cloudId],
  );

  // ===== файлы =====

  Future<Map<String, MirrorRow>> files() async {
    final rows = await _db.query(
      'files',
      columns: [
        'path',
        'cloud_folder_id',
        'entry_id',
        'inode',
        'size',
        'mtime',
        'sha256',
      ],
    );
    return {for (final r in rows) '${r['path']}': _row(r)};
  }

  Future<MirrorRow?> fileByEntry(String entryId) async {
    final rows = await _db.query(
      'files',
      where: 'entry_id = ?',
      whereArgs: [entryId],
      limit: 1,
    );
    return rows.isEmpty ? null : _row(rows.first);
  }

  Future<int> fileCount() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS n FROM files');
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<void> putFile(MirrorRow row) => _db.insert('files', {
    'path': row.path,
    'cloud_folder_id': row.cloudFolderId,
    'entry_id': row.entryId,
    'inode': row.inode,
    'size': row.size,
    'mtime': row.mtime,
    'sha256': row.sha256,
    'at': DateTime.now().millisecondsSinceEpoch,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  /// Переименование: путь меняется, запись в облаке остаётся той же.
  Future<void> moveFile(String oldPath, MirrorRow row) =>
      _db.transaction((txn) async {
        await txn.delete('files', where: 'path = ?', whereArgs: [oldPath]);
        await txn.insert('files', {
          'path': row.path,
          'cloud_folder_id': row.cloudFolderId,
          'entry_id': row.entryId,
          'inode': row.inode,
          'size': row.size,
          'mtime': row.mtime,
          'sha256': row.sha256,
          'at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });

  Future<void> dropFile(String path) =>
      _db.delete('files', where: 'path = ?', whereArgs: [path]);

  /// Записи папки: нужны, когда папку удалили в облаке — поддерево уходит целиком.
  Future<List<MirrorRow>> filesUnder(String localPath) async {
    final prefix = localPath.endsWith('/') ? localPath : '$localPath/';
    final rows = await _db.query(
      'files',
      where: 'path LIKE ?',
      whereArgs: ['$prefix%'],
    );
    return rows.map(_row).toList();
  }

  /// Все пары «папка облака ↔ путь на телефоне»: по ним ищется хвост из опустевших папок
  /// (см. MirrorRules.emptyFolderCandidates).
  Future<Map<String, String>> allDirs() async {
    final rows = await _db.query('dirs', columns: ['cloud_id', 'local_path']);
    return {
      for (final r in rows) '${r['cloud_id']}': '${r['local_path']}',
    };
  }

  /// Папки поддерева: `cloudId` к `localPath`. Нужны при переименовании и удалении папки.
  Future<List<(String, String)>> dirsUnder(String localPath) async {
    final prefix = localPath.endsWith('/') ? localPath : '$localPath/';
    final rows = await _db.query(
      'dirs',
      columns: ['cloud_id', 'local_path'],
      where: 'local_path = ? OR local_path LIKE ?',
      whereArgs: [localPath, '$prefix%'],
    );
    return [for (final r in rows) ('${r['cloud_id']}', '${r['local_path']}')];
  }

  /// Что уже выгружено по данным зеркала: из этого считается «сколько реально в облаке».
  Future<Totals> inCloud() async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS b FROM files',
    );
    return Totals(
      (rows.first['n'] as int?) ?? 0,
      (rows.first['b'] as int?) ?? 0,
    );
  }

  /// Сколько всего нашлось в выбранных папках на последнем обходе (переживает перезапуск).
  Future<Totals> localTotals() => _totals(keyLocalFiles, keyLocalBytes);

  Future<void> setLocalTotals(int files, int bytes) async {
    await setMeta(keyLocalFiles, '$files');
    await setMeta(keyLocalBytes, '$bytes');
  }

  /// Сколько ждало выгрузки на момент последнего плана.
  Future<Totals> waitingTotals() => _totals(keyWaitFiles, keyWaitBytes);

  Future<void> setWaitingTotals(int files, int bytes) async {
    await setMeta(keyWaitFiles, '$files');
    await setMeta(keyWaitBytes, '$bytes');
  }

  Future<Totals> _totals(String filesKey, String bytesKey) async {
    final f = int.tryParse(await meta(filesKey) ?? '') ?? 0;
    final b = int.tryParse(await meta(bytesKey) ?? '') ?? 0;
    return Totals(f, b);
  }

  /// Полная очистка состояния: другой аккаунт или другой сервер. Без неё строки прошлого
  /// аккаунта делают все локальные файлы «уже выгруженными», и папка нового аккаунта
  /// остаётся пустой навсегда.
  Future<void> wipe() => _db.transaction((txn) async {
    for (final table in ['files', 'dirs', 'roots', 'uploads', 'meta']) {
      await txn.delete(table);
    }
  });

  // ===== прочее =====

  Future<String?> meta(String key) async {
    final rows = await _db.query(
      'meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : '${rows.first['value']}';
  }

  Future<void> setMeta(String key, String value) => _db.insert('meta', {
    'key': key,
    'value': value,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> clearMeta(String key) =>
      _db.delete('meta', where: 'key = ?', whereArgs: [key]);

  Future<int?> cursor() async => int.tryParse(await meta(keyCursor) ?? '');

  Future<void> setCursor(int seq) => setMeta(keyCursor, '$seq');

  MirrorRow _row(Map<String, Object?> r) => MirrorRow(
    path: '${r['path']}',
    cloudFolderId: '${r['cloud_folder_id']}',
    entryId: '${r['entry_id']}',
    inode: (r['inode'] as int?) ?? 0,
    size: (r['size'] as int?) ?? 0,
    mtime: (r['mtime'] as int?) ?? 0,
    sha256: r['sha256'] == null ? null : '${r['sha256']}',
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
