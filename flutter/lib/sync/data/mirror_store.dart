import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../mirror/mirror_models.dart';

/// Локальное состояние зеркала: база `cloudly-mirror.db`, версия 2, пять таблиц.
///
/// ## `roots` — пары «папка телефона ↔ папка в облаке»
///
///   • назначение: пара заводится один раз, иначе при пропаже папки сверка не знает, куда
///     возвращать содержимое;
///   • ключ: `local_path` (путь выбранной папки на телефоне); `cloud_id` — id папки в облаке,
///     `cloud_path` — её путь (показывается человеку как есть);
///   • инвариант: одна строка на выбранную папку. Пару снимают вместе со снятием выбора
///     ([dropRoot]), а строки `files` при этом остаются — вернуть выбор можно без повторной
///     заливки и без удаления в облаке.
///
/// ## `dirs` — соответствие облачных папок и путей на телефоне
///
///   • назначение: по нему правка из журнала (там известен только folderId) находится
///     в файловой системе;
///   • ключ: `cloud_id`; `INDEX dirs_local(local_path)` — обратный поиск: папка на телефоне →
///     её id в облаке (см. [dirId]);
///   • инвариант: одна строка на облачную папку (это держит первичный ключ), и один путь
///     на телефоне соответствует одной папке облака — на это опирается [dirId], хотя индекс
///     `dirs_local` обратного и не запрещает. Переименование на телефоне меняет путь, а не id
///     (см. [moveDir]); повторная регистрация пары перезаписывает строку, терять здесь нечего.
///
/// ## `files` — что уже выгружено
///
///   • назначение: запись в облаке, номер файла на телефоне, слепок содержимого;
///   • ключ: `path` (путь файла на телефоне);
///   • `INDEX files_entry(entry_id)` — найти строку по записи облака (правки из веба);
///     `INDEX files_inode(inode)` — найти файл по номеру в файловой системе (переименование);
///   • колонки: `cloud_folder_id` — папка облака, `entry_id` — запись, `inode` — номер файла
///     (`0` значит «номер неизвестен»: у части томов его нет), `size`/`mtime`/`sha256` —
///     слепок выгруженного содержимого, `sha256` может быть NULL, `at` — когда записали;
///   • главный инвариант строки: **строка = «этот файл лежит в облаке»**, и сверка читает её
///     буквально: по строкам, чьи файлы пропали с телефона, облачная копия уходит в корзину,
///     а файл без строки выгружается заново. Поэтому миграции ничего не удаляют, база чистится
///     только через [wipe] (смена аккаунта, корня или устройства), а `size`/`mtime`/`sha256`
///     обновляются вместе — это один слепок файла (см. [MirrorRow]).
///
/// ## `uploads` — незавершённые выгрузки
///
///   • назначение: продолжить с принятой части, а не лить файл заново;
///   • ключ: `path` — у файла не может быть двух активных сессий;
///   • колонки: `upload_id` — сессия на сервере, `folder_id` — куда льём, `sha256 NOT NULL` —
///     без хэша нельзя проверить, что файл не изменился, а значит и продолжать нельзя,
///     `size`/`mtime` — слепок файла на момент начала сессии, `at` — когда записали;
///   • инвариант: строка живёт только пока сессия на сервере жива; после успешной выгрузки
///     её снимают ([dropUploadSession]), при несовпадении слепка — тоже.
///
/// ## `meta` — прочее состояние
///
///   • назначение: курсор журнала, итоги обходов и итог последнего прохода (ключи — константы
///     `key*` ниже);
///   • ключ: `key`, значение — `value TEXT NOT NULL`;
///   • инвариант: числа хранятся текстом, и разбор неудачного значения даёт 0, а не ошибку
///     (см. [_totals], [cursor]).
///
/// Отдельная база, а не таблицы очереди: очередь руками собирают и чистят, а состояние зеркала
/// терять нельзя — без него удаление не отличить от «ещё не видели» и облако поедет вразнос.
class MirrorStore {
  MirrorStore._(this._db);

  final Database _db;

  /// Имя файла базы в папке баз приложения. Отдельный файл от очереди: у зеркала своя
  /// жизнь, и его строки не должны зависеть от того, что человек сделал с очередью.
  static const String _name = 'cloudly-mirror.db';

  /// Версия схемы: 1 — без `uploads`, 2 — с ней. Поднимая версию, добавь ветку в `onUpgrade`,
  /// которая только создаёт или добавляет: удалять данные здесь нельзя ни при каких условиях.
  /// Ветки там идемпотентны (`CREATE TABLE IF NOT EXISTS`), поэтому повторный проход по ним
  /// после отката версии ничего не ломает. Родословная: 1 — `roots`, `dirs`, `files`, `meta`,
  /// 2 — `uploads`; состояние строк при апгрейде не переписывается ни разу.
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
  /// Числа лежат одной строкой «файлов|байт»: пара пишется и читается целиком, поэтому
  /// интерфейс не может показать число файлов из одного прохода, а байты из другого
  /// (второе соединение — фоновое задание — пишет те же ключи).
  static const String keyLocalTotals = 'local_totals';

  /// Сколько ждало выгрузки на момент последнего плана зеркала, тоже парой.
  static const String keyWaitTotals = 'wait_totals';

  /// Прежние ключи итогов — по числу на ключ. Остались только для чтения: числа, записанные
  /// сборками до версии с парным ключом, не должны обнулиться после обновления (и до первого
  /// следующего прохода показывать «ничего не обходили»). Пишутся всегда парные ключи.
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

  /// id устройства в облаке: по нему сервер отличает проходы одного телефона от другого.
  static const String keyDeviceId = 'device_id';

  /// Корень зеркала, для которого писались строки `files`. Сменился корень (например, сервер
  /// завёл новую папку устройства) — строки описывают записи в другой папке, и держать их
  /// нельзя: сверка решила бы, что файлы уже выгружены, а новая папка осталась бы пустой.
  static const String keyMirrorRoot = 'mirror_root_id';

  /// Открыть базу зеркала, создав её при первом запуске.
  ///
  /// [directory] — папка для файла базы; по умолчанию системная папка баз приложения.
  /// Возвращает единственное место, где состояние зеркала читается и пишется.
  ///
  /// Побочные эффекты: файл базы на диске, таблицы и индексы при создании, добавление таблицы
  /// `uploads` при апгрейде, `PRAGMA busy_timeout`. Ошибку открытия не глушит: без состояния
  /// зеркала проход делать нельзя — он принял бы всё за «ещё не видели».
  static Future<MirrorStore> open({String? directory}) async {
    final path = p.join(directory ?? await getDatabasesPath(), _name);
    final db = await openDatabase(
      path,
      version: _version,
      // Своё соединение на каждый движок: в процессе живут два — приложение и фоновое задание.
      // С общим соединением закрытие базы в фоне ломало приложение («database closed»)
      singleInstance: false,
      onCreate: (db, version) async {
        // `roots` — выбранные папки телефона и их папки в облаке. Ключ — путь на телефоне:
        // пара заводится один раз и переживает снятие выбора (снимается только строка roots)
        await db.execute('''
          CREATE TABLE roots(
            local_path TEXT PRIMARY KEY,
            cloud_id TEXT NOT NULL,
            cloud_path TEXT NOT NULL
          )
        ''');
        // `dirs` — облачная папка ↔ путь на телефоне. Ключ — cloud_id (правка из журнала
        // приходит именно с ним), а индекс по пути нужен для обратного поиска
        await db.execute('''
          CREATE TABLE dirs(
            cloud_id TEXT PRIMARY KEY,
            local_path TEXT NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX dirs_local ON dirs(local_path)');
        // `files` — «этот файл лежит в облаке». Ключ — путь на телефоне; сверка читает строку
        // буквально (пропал файл на телефоне — облачная копия уходит в корзину), поэтому
        // при миграциях эта таблица неприкосновенна
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
        // по entry_id строку находят правки из веба (переименование, перенос, удаление),
        // по inode — переименование на телефоне: тот же файл, другой путь
        await db.execute('CREATE INDEX files_entry ON files(entry_id)');
        await db.execute('CREATE INDEX files_inode ON files(inode)');
        // `meta` — всё остальное состояние зеркала: курсор журнала, итоги обходов, отчёт
        // о проходе. Строки «ключ → значение», числа хранятся текстом
        await db.execute(
          'CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        // `uploads` — незавершённые выгрузки: без них прерванный гигабайт начинался бы
        // с нуля. Ключ — путь на телефоне: двух активных сессий у файла быть не может
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
        // Состояние зеркала не пересобирается «на глаз»: строка `files` — это знание, что файл
        // уже лежит в облаке, а строка с пропавшим файлом — команда убрать облачную копию.
        // Поэтому апгрейд только добавляет таблицы: ни одной строки здесь не удаляется
        // и не переписывается.
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
      // Версия ниже нашей — старая сборка поверх новой (откат обновления). Ронять базу из-за
      // этого нельзя: строки `files` — знание, что файл уже лежит в облаке, и без них всё
      // уехало бы в облако второй раз. Схема только дополняется, лишнюю таблицу старый код
      // просто не читает, поэтому расхождение версий безопасно и открытие продолжаем.
      onDowngrade: (db, oldVersion, newVersion) async {},
    );
    await _configure(db);
    return MirrorStore._(db);
  }

  /// Закрыть соединение с базой.
  ///
  /// Соединение своё у каждого движка (`singleInstance: false`): закрытие в фоновом задании
  /// не должно ломать приложение, и наоборот.
  Future<void> close() => _db.close();

  // ===== незавершённые выгрузки =====

  /// Незавершённая выгрузка этого файла или `null`, если её нет.
  ///
  /// [path] — путь файла на телефоне (ключ таблицы `uploads`). Возвращает сессию с id
  /// на сервере и слепком файла: сверку «то же ли это содержимое» делает вызывающий
  /// (`MirrorEngine`), прежде чем продолжать через [Uploader.resume].
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

  /// Запомнить начатую выгрузку: [row] — сессия на сервере и слепок файла, по которому она
  /// начата. Пишет `at` (когда записали). Заменяет прежнюю строку того же пути: у файла
  /// одна активная сессия.
  Future<void> putUploadSession(UploadSessionRow row) => _db.insert('uploads', {
    'path': row.path,
    'upload_id': row.uploadId,
    'folder_id': row.folderId,
    'size': row.size,
    'mtime': row.mtime,
    'sha256': row.sha256,
    'at': DateTime.now().millisecondsSinceEpoch,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  /// Забыть сессию: выгрузка завершена, файл изменился или сессия на сервере истекла.
  /// Строка только про «продолжить», поэтому удаление безопасно — состояние самого файла
  /// живёт в `files`.
  Future<void> dropUploadSession(String path) =>
      _db.delete('uploads', where: 'path = ?', whereArgs: [path]);

  // ===== корни зеркала =====

  /// Завести (или обновить) пару «папка телефона ↔ папка облака».
  ///
  /// [localPath] — путь выбранной папки, [cloudId]/[cloudPath] — её папка в облаке.
  /// Побочный эффект двойной: строка в `roots` и сразу [registerDir] — иначе обратный поиск
  /// «облачная папка → путь на телефоне» не работал бы для только что выбранной папки.
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

  /// Все пары «папка телефона ↔ папка облака», ключ — путь на телефоне.
  /// По ним зеркало и приложение (`FolderTreeScreen`) понимают, что уже выбрано и куда
  /// в облаке это лежит. Ничего не пишет.
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
  /// Строка в `dirs` тоже остаётся: она про соответствие папок, а не про выбор.
  Future<void> dropRoot(String localPath) =>
      _db.delete('roots', where: 'local_path = ?', whereArgs: [localPath]);

  // ===== папки =====

  /// Запомнить соответствие «облачная папка ↔ путь на телефоне».
  ///
  /// [cloudId] — id папки в облаке, [localPath] — её путь на телефоне. Пустой [cloudId]
  /// не записывается: id ещё нет (папку не завели), и строка «пустой id → путь» не отвечала бы
  /// ни на один вопрос. Повторная регистрация перезаписывает строку.
  Future<void> registerDir(String cloudId, String localPath) async {
    if (cloudId.isEmpty) return;
    await _db.insert('dirs', {
      'cloud_id': cloudId,
      'local_path': localPath,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// id облачной папки по пути на телефоне или `null`. Идёт по индексу `dirs_local`:
  /// им проверяют, заведена ли папка в облаке, прежде чем что-то в неё класть.
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

  /// Путь на телефоне по id облачной папки или `null`. Этим путём правка из журнала
  /// (там известен только folderId) превращается в действие над файловой системой.
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

  /// Убрать соответствие: папки больше нет — её удалили в облаке или применили удаление
  /// поддерева, пришедшее из журнала. Строки `files` поддерева снимаются отдельно,
  /// их находит [filesUnder].
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

  /// Весь снимок «что выгружено»: ключ — путь файла на телефоне.
  ///
  /// По нему сверка понимает, какие файлы в облаке уже есть. Читает таблицу целиком
  /// (колонка `at` в выборку не входит — она нужна только диагностике): вызывающие берут
  /// снимок один раз на проход и дальше работают в памяти.
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

  /// Строка по записи облака: каким файлом на телефоне она представлена (или `null`).
  /// Идёт по индексу `files_entry`; этим правки из веба находят файл на телефоне.
  Future<MirrorRow?> fileByEntry(String entryId) async {
    final rows = await _db.query(
      'files',
      where: 'entry_id = ?',
      whereArgs: [entryId],
      limit: 1,
    );
    return rows.isEmpty ? null : _row(rows.first);
  }

  /// Сколько всего строк в `files`, то есть сколько файлов зеркало считает выгруженными.
  /// Счёт по базе, без вытягивания строк в память. Ничего не пишет.
  Future<int> fileCount() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS n FROM files');
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Записать, что файл выгружен: [row] — путь, папка облака, запись, номер файла и слепок
  /// содержимого. Пишет `at` (когда записали).
  ///
  /// Заменяет прежнюю строку того же пути целиком: строка описывает один слепок, а не смесь
  /// из двух выгрузок. Ошибку не глушит — без записи следующий проход зальёт файл снова.
  ///
  /// Одной транзакцией с записью снимается чужая строка с тем же `entry_id`: инвариант таблицы
  /// — запись облака принадлежит ровно одному пути. Из его нарушения и выросла критичная
  /// находка ревью: строка оставалась на прежнем пути, и проход считал облачный файл
  /// «пропавшим с телефона», удаляя только что скачанное. Дубль мог остаться и от прошлых
  /// сборок, поэтому чистим его здесь, а не только в месте, где он заводился.
  Future<void> putFile(MirrorRow row) => _db.transaction((txn) async {
    if (row.entryId.isNotEmpty) {
      await txn.delete(
        'files',
        where: 'entry_id = ? AND path <> ?',
        whereArgs: [row.entryId, row.path],
      );
    }
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

  /// Переименование: путь меняется, запись в облаке остаётся той же.
  ///
  /// [oldPath] — прежний путь (ключ), [row] — та же запись под новым путём.
  /// Удаление и вставка идут одной транзакцией: между ними строки нет, и обрыв оставил бы
  /// файл «невыгруженным» — а он в облаке есть, и повторная заливка завела бы дубль.
  /// Как и в [putFile], заодно снимаются чужие строки с той же записью облака: после переноса
  /// запись обязана принадлежать новому пути ровно один раз.
  Future<void> moveFile(String oldPath, MirrorRow row) =>
      _db.transaction((txn) async {
        await txn.delete('files', where: 'path = ?', whereArgs: [oldPath]);
        if (row.entryId.isNotEmpty) {
          await txn.delete(
            'files',
            where: 'entry_id = ? AND path <> ?',
            whereArgs: [row.entryId, row.path],
          );
        }
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

  /// Забыть строку файла: записи в облаке больше нет (её удалили в вебе или убрали в корзину
  /// мы сами) либо файл пропал с телефона. После этого сверка считает файл невыгруженным:
  /// если он ещё лежит на телефоне, следующий проход зальёт его заново.
  Future<void> dropFile(String path) =>
      _db.delete('files', where: 'path = ?', whereArgs: [path]);

  /// Записи папки: нужны, когда папку удалили в облаке — поддерево уходит целиком.
  ///
  /// [localPath] — путь папки на телефоне; возвращает строки всех файлов внутри неё.
  /// Отбор идёт `LIKE` по префиксу пути с разделителем на конце: он отсекает соседнюю папку
  /// с общим началом имени (`/s/DCIM` не захватывает `/s/DCIM2`). Сама папка в выборку
  /// не попадает — в `files` лежат только файлы.
  Future<List<MirrorRow>> filesUnder(String localPath) async {
    final prefix = localPath.endsWith('/') ? localPath : '$localPath/';
    final rows = await _db.query(
      'files',
      // Экранирование обязательно: `_` и `%` в шаблоне LIKE — метасимволы («любой один знак»
      // и «любая строка»). Без него папка `/s/my_photos` нашла бы и файлы соседней
      // `/s/myXphotos`, а вызывающие по этому списку удаляют локальные файлы и их строки
      where: "path LIKE ? ESCAPE '\\'",
      whereArgs: ['${_likePrefix(prefix)}%'],
    );
    return rows.map(_row).toList();
  }

  /// Все пары «папка облака ↔ путь на телефоне»: по ним ищется хвост из опустевших папок
  /// (см. MirrorRules.emptyFolderCandidates).
  /// Читает `dirs` целиком: пустые папки на телефоне по диску не видны, и единственный
  /// источник знания о них — эта таблица.
  Future<Map<String, String>> allDirs() async {
    final rows = await _db.query('dirs', columns: ['cloud_id', 'local_path']);
    return {
      for (final r in rows) '${r['cloud_id']}': '${r['local_path']}',
    };
  }

  /// Папки поддерева: `cloudId` к `localPath`. Нужны при переименовании и удалении папки.
  ///
  /// [localPath] — путь папки на телефоне. В выборку входит и сама папка (отдельным условием
  /// `local_path = ?`), и всё вложенное — по префиксу с разделителем на конце, чтобы соседняя
  /// папка с общим началом имени не попала.
  Future<List<(String, String)>> dirsUnder(String localPath) async {
    final prefix = localPath.endsWith('/') ? localPath : '$localPath/';
    final rows = await _db.query(
      'dirs',
      columns: ['cloud_id', 'local_path'],
      // см. filesUnder: без ESCAPE `_` и `%` в имени папки — метасимволы шаблона
      where: "local_path = ? OR local_path LIKE ? ESCAPE '\\'",
      whereArgs: [localPath, '${_likePrefix(prefix)}%'],
    );
    return [for (final r in rows) ('${r['cloud_id']}', '${r['local_path']}')];
  }

  /// Что уже выгружено по данным зеркала: из этого считается «сколько реально в облаке».
  /// Сумма и количество считаются базой; если строк нет, оба числа — нули.
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
  /// Кэш в `meta`: обход диска дорогой, а интерфейсу числа нужны сразу при открытии раздела.
  Future<Totals> localTotals() => _totals(keyLocalTotals, keyLocalFiles, keyLocalBytes);

  /// Запомнить итоги обхода диска: [files] и [bytes] пишутся одной строкой `meta` — вместе,
  /// иначе пара чисел описывала бы разные проходы.
  Future<void> setLocalTotals(int files, int bytes) =>
      setMeta(keyLocalTotals, '$files|$bytes');

  /// Сколько ждало выгрузки на момент последнего плана.
  Future<Totals> waitingTotals() =>
      _totals(keyWaitTotals, keyWaitFiles, keyWaitBytes);

  /// Запомнить, сколько ждало выгрузки: [files] и [bytes] — одной строкой `meta`, вместе.
  Future<void> setWaitingTotals(int files, int bytes) =>
      setMeta(keyWaitTotals, '$files|$bytes');

  /// Прочитать пару чисел: сначала парный ключ «файлов|байт», затем — прежние два ключа
  /// (числа от сборок до парного формата: обнулять их при обновлении незачем).
  /// Неудачный разбор (нет строки, мусор вместо числа) даёт 0: отсутствие итогов — это
  /// «ещё не считали», а не ошибка.
  Future<Totals> _totals(
    String packedKey,
    String oldFilesKey,
    String oldBytesKey,
  ) async {
    final packed = await meta(packedKey);
    if (packed != null) {
      final parts = packed.split('|');
      final bytes = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
      return Totals(int.tryParse(parts.first) ?? 0, bytes);
    }
    final f = int.tryParse(await meta(oldFilesKey) ?? '') ?? 0;
    final b = int.tryParse(await meta(oldBytesKey) ?? '') ?? 0;
    return Totals(f, b);
  }

  /// Полная очистка состояния: другой аккаунт или другой сервер. Без неё строки прошлого
  /// аккаунта делают все локальные файлы «уже выгруженными», и папка нового аккаунта
  /// остаётся пустой навсегда.
  /// Очищает всё — включая `meta` (курсор журнала) и `uploads` (сессии): после смены
  /// аккаунта продолжать старые сессии нельзя, они принадлежат чужому облаку.
  /// Одной транзакцией: наполовину очищенное состояние зеркала опаснее пустого.
  Future<void> wipe() => _db.transaction((txn) async {
    for (final table in ['files', 'dirs', 'roots', 'uploads', 'meta']) {
      await txn.delete(table);
    }
  });

  // ===== прочее =====

  /// Значение из `meta` по ключу (ключи — константы `key*` выше) или `null`, если строки нет.
  /// Отсутствие строки и пустое значение здесь различимы: первое значит «не задавали».
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

  /// Записать значение в `meta`: заменяет прежнее значение того же ключа. Пишет и курсор
  /// журнала, который двигают только после того, как строки журнала применены.
  Future<void> setMeta(String key, String value) => _db.insert('meta', {
    'key': key,
    'value': value,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  /// Убрать значение из `meta`: так снимаются флаги и отчёты, которых больше нет
  /// (например, ожидание повтора или подтверждение удаления).
  Future<void> clearMeta(String key) =>
      _db.delete('meta', where: 'key = ?', whereArgs: [key]);

  /// Израсходовать подтверждение массового удаления ровно один раз — [token] из `meta`.
  ///
  /// Заменяет пару «прочитать, потом снять»: между этими двумя запросами второе чтение успело
  /// бы увидеть ту же метку, и подтверждение сгорело бы дважды — а значение у него уникальное
  /// именно для того, чтобы каждый проход снимал своё. Здесь чтение и удаление — одна операция
  /// (`DELETE ... WHERE key = ? AND value = ?`), поэтому «своё» подтверждение расходует только
  /// тот, кто первым до него дошёл.
  ///
  /// @return `true`, если метка была нашей и её сняли; `false` — метки нет или она чужая
  ///         (её поставило другое нажатие либо другое приложение из этого же процесса).
  Future<bool> takeConfirmed(String token) async {
    final removed = await _db.delete(
      'meta',
      where: 'key = ? AND value = ?',
      whereArgs: [keyConfirmed, token],
    );
    return removed == 1;
  }

  /// Сессии незавершённых выгрузок: путь файла и идентификатор загрузки на сервере.
  ///
  /// Нужен уборке: сессия по исчезнувшему или перенесённому пути иначе остаётся в таблице
  /// навсегда, а её место занимает живой файл с тем же путём — и выгрузка продолжилась бы
  /// в чужую (уже удалённую на сервере) сессию.
  Future<List<({String path, String uploadId})>> allUploadSessions() async {
    final rows = await _db.query('uploads', columns: ['path', 'upload_id']);
    return [
      for (final r in rows)
        (path: '${r['path']}', uploadId: '${r['upload_id']}'),
    ];
  }

  /// Курсор журнала изменений: с какого `seq` продолжать догон облака.
  /// `null` означает «журнал ещё не читали»: зеркало делает полный проход по папкам, снимает
  /// голову журнала до него и записывает курсор только после удачного прохода.
  Future<int?> cursor() async => int.tryParse(await meta(keyCursor) ?? '');

  /// Сдвинуть курсор журнала: [seq] — последняя применённая строка. Вызывается только после
  /// того, как строки применены, — иначе изменения потерялись бы навсегда.
  Future<void> setCursor(int seq) => setMeta(keyCursor, '$seq');

  /// Собрать строку `files` из результата запроса.
  ///
  /// Значения читаются «мягко»: отсутствующее число — 0 (для `inode` это «номер неизвестен»),
  /// отсутствующий `sha256` — null, то есть «хэша нет». Такая строка не ломает сверку:
  /// она просто заставит посчитать хэш заново.
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

/// Экранировать префикс пути для шаблона `LIKE ... ESCAPE '\'`.
///
/// В шаблоне `LIKE` символы `_` и `%` — метасимволы («любой один знак» и «любая строка»),
/// а в путях телефона они встречаются постоянно (`/s/DCIM/Camera/IMG_2024.jpg`,
/// папка `100%backup`). Без экранирования поиск поддерева захватывает соседние папки,
/// а по его результату удаляются и переносятся локальные файлы.
String _likePrefix(String prefix) => prefix
    .replaceAll('\\', '\\\\')
    .replaceAll('%', '\\%')
    .replaceAll('_', '\\_');

/// Два соединения к одному файлу (приложение и фоновое задание) — это нормально для SQLite,
/// но короткая параллельная запись может попасть в «database is locked». Пусть лучше подождёт.
///
/// WAL — чтобы читатель (экран, фоновое задание) не ждал писателя: без него запись блокирует
/// чтение на всё время транзакции. Режим хранится в самом файле базы, поэтому ставится один раз
/// при открытии.
///
/// PRAGMA ставится запросом, а не через `onConfigure`: там sqflite выполняет её как execSQL,
/// а Android такую строку не принимает и открытие базы падает целиком. Отказ PRAGMA работу
/// не ломает, но молчать о нём нельзя: без WAL возможен «database is locked», и причину
/// искать будет негде.
Future<void> _configure(Database db) async {
  try {
    await db.rawQuery('PRAGMA busy_timeout = 5000');
  } catch (e) {
    debugPrint('cloudly-sync: busy_timeout базы зеркала не поставлен: $e');
  }
  try {
    await db.rawQuery('PRAGMA journal_mode = WAL');
  } catch (e) {
    debugPrint('cloudly-sync: WAL для базы зеркала не включился: $e');
  }
}
