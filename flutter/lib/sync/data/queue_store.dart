import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../queue/queue_planner.dart';
import '../section.dart';

/// Состояние файла в очереди.
///
///   • `pending` — ждёт запуска (так же читается зависшая строка `running` при старте);
///   • `running` — выгружается прямо сейчас;
///   • `skipped` — содержимое уже было в облаке, байты не передавались;
///   • `done`    — выгружен, в `entry_id` лежит id записи в облаке;
///   • `failed`  — попытка не удалась: текст в `last_error`, счётчик в `attempts`.
///
/// Запуск не только ручной: строку берёт и кнопка «поторопить», и автоматический слив ждущих
/// в `SyncController` (сторож раз в минуту), поэтому `pending`/`failed` означают «ждёт», а не
/// «никто не возьмётся». Раньше слива не было, и строка ждала нажатия «play».
enum QueueState {
  pending('PENDING'),
  running('RUNNING'),
  skipped('SKIPPED'),
  done('DONE'),
  failed('FAILED');

  const QueueState(this.storageKey);

  /// Как состояние записано в базе. Значения менять нельзя: они уже лежат в строках.
  final String storageKey;

  /// Состояние по значению из базы или `null`, если значение незнакомо (строка от другой
  /// версии, мусор). Так его читают счётчики и правила: незнакомое состояние — это не
  /// «ожидает», и подставлять его вместо ожидающего нельзя (см. [byKey]).
  static QueueState? byKeyOrNull(String? key) {
    for (final s in QueueState.values) {
      if (s.storageKey == key) return s;
    }
    return null;
  }

  /// Состояние по значению из базы для показа строки. Неизвестное значение (строка от другой
  /// версии, мусор) читается как `pending`: лучше показать файл ждущим, чем молча выкинуть
  /// его из очереди. Там, где от состояния зависит решение, а не подпись в списке, нужен
  /// [byKeyOrNull]: `pending` — это ещё и «можно выгружать».
  static QueueState byKey(String? key) =>
      byKeyOrNull(key) ?? QueueState.pending;
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
    this.finishedAt,
  });

  /// `queue.id` — первичный ключ строки.
  final int id;

  /// Путь файла на телефоне. Вместе с [target] — ключ строки (уникальный индекс
  /// `queue_unique`): один и тот же файл стоит в очереди столько раз, в сколько облачных
  /// папок его надо выгрузить.
  final String path;

  /// Папка относительно родителя выбранной папки. У «Фото» пустая — медиатека ложится
  /// плоско; заполняется для строк, оставшихся от сборок, которые выгружали «Файлы»
  /// очередью (сейчас этот раздел ведёт зеркало).
  final String relDir;

  /// Имя файла: под ним запись появляется в облаке (если имя займут — под свободным).
  final String name;

  // !!! ИНВАРИАНТ: size, mtime и sha256 обязаны меняться вместе !!!
  //
  // Три поля — один слепок файла: размер, дата изменения и хэш содержимого на один и тот же
  // момент. По паре size+mtime решается, годится ли закэшированный sha256: UploadRunner
  // (см. `_shaOf`) берёт хэш из строки, только когда оба совпали с тем, что лежит на диске
  // сейчас. Если обновить только size и mtime, оставив sha256 от прошлой версии файла,
  // условие совпадёт — и в дело пойдёт хэш старого содержимого: «уже выгружено», дедуп и
  // перезапись начнут решаться по чужому файлу.
  //
  // Кто пишет слепок:
  //   • [QueueStore.enqueue] — единственное место, где размер и дата приходят с диска.
  //     Слепок строки сравнивается с диском правилом `QueuePlanner.sameSnapshot`: совпал —
  //     `sha256` и `entry_id` остаются, не совпал — обнуляются вместе с состоянием;
  //   • [QueueStore.setSha] — только хэш, и лишь для слепка, который в строке уже лежит
  //     (вызывающий снял размер и дату с того же файла);
  //   • [QueueStore.markUploaded] — слепок строки `uploaded` целиком, вместе с хэшем.

  /// Размер файла на момент постановки в очередь или выгрузки.
  final int size;

  /// Дата изменения файла (миллисекунды), снятая вместе с [size].
  final int mtime;

  /// Раздел, из которого файл попал в очередь: по нему уборка решает, трогать ли строку.
  final Section section;

  /// id облачной папки получателя: медиатека для «Фото» (файлы ложатся плоско).
  ///
  /// У строк раздела «Файлов», оставшихся от прежних сборок, здесь легаси-папка «Телефон»:
  /// раздел «Файлы» ведёт зеркало, и такие строки снимает первый же проход (см. `QueueBuilder`).
  /// Если строка всё же доедет — файл ляжет плоско в эту папку.
  final String target;

  /// Что с файлом сейчас — см. [QueueState]. Неизвестное значение из базы читается
  /// как `pending` (см. [QueueState.byKey]).
  final QueueState state;

  /// Сколько раз строку пытались выгрузить. Увеличивает вызывающий и передаёт готовое число
  /// в [QueueStore.markFailed].
  final int attempts;

  /// Посчитанный хэш содержимого: пока файл не менялся, второй раз не считаем.
  /// Валиден, только пока [size] и [mtime] совпадают с файлом на диске, — см. инвариант выше.
  final String? sha256;

  /// Текст последней ошибки (обрезан до 500 знаков) — показывается в строке очереди.
  final String? lastError;

  /// id записи в облаке: заполняется, когда строка закрылась (`done`/`skipped`).
  final String? entryId;

  /// Когда строку поставили в очередь (миллисекунды): по нему идёт порядок внутри состояния.
  final int createdAt;

  /// Когда закончилась последняя попытка (миллисекунды) или `null`, если её ещё не было.
  /// По нему вместе с [attempts] считается пауза перед следующей попыткой
  /// (см. `QueuePlanner.retryReady`): строка, которую сервер принципиально не принимает,
  /// не должна ходить в сеть каждую минуту.
  final int? finishedAt;
}

/// Локальное состояние очереди: база `cloudly-queue.db`, три таблицы.
///
/// ## `uploaded` — что уже выгружено
///
///   • назначение: помнить, какие файлы телефона уже лежат в облаке и каким именно слепком
///     содержимого они туда уехали. Отдельная строка на каждую облачную папку: один и тот же
///     файл может уехать и в «Файлы», и в «Фото», и «уже выгружено» в одной папке ничего
///     не говорит про другую;
///   • ключ: `PRIMARY KEY(path, target)` — путь файла на телефоне и id облачной папки
///     получателя. Индексов, кроме первичного ключа, нет;
///   • колонки: `entry_id` — id записи в облаке (по нему ищут пару при правках из веба),
///     `size`/`mtime`/`sha256` — слепок содержимого, `at` — когда строку записали;
///   • `sha256` допускает NULL: у строк от версий до 3.0 хэша нет, и это означает «кэша нет»,
///     а не «содержимое неизвестно» (размер и дата есть всегда);
///   • главный инвариант: строка описывает один конкретный слепок файла, поэтому `size`,
///     `mtime` и `sha256` пишутся вместе — см. предупреждение у [QueueItem.size].
///
/// ## `queue` — сама очередь
///
///   • назначение: что выгрузить, куда, что с этим уже произошло. Файл + цель, состояние,
///     попытки, текст последней ошибки и кэш посчитанного хэша;
///   • ключ: `id INTEGER PRIMARY KEY AUTOINCREMENT`;
///   • `UNIQUE INDEX queue_unique(path, target)` — одна строка на пару «файл + цель»:
///     повторная постановка обновляет строку, а не заводит вторую;
///   • `INDEX queue_state(state, id)` — по нему идут выборки списка и счётчиков;
///   • главные инварианты: пара (path, target) уникальна; `state` — одно из [QueueState];
///     `sha256` валиден, только пока `size` и `mtime` совпадают с файлом на диске.
///     База нигде не удаляется целиком: строки очереди живут до уборки ([prune]) или
///     «очистить выполненные» ([clearFinished]), а `uploaded` — до следующей выгрузки
///     того же файла.
///
/// ## `queue_uploads` — незавершённые выгрузки
///
///   • назначение: продолжить с принятой части, а не лить файл заново: очередь ручная,
///     и обрыв связи на гигабайтном видео иначе откатывал бы прогресс к нулю;
///   • ключ: `PRIMARY KEY(path, target)` — у пары «файл + цель» одна активная сессия;
///   • колонки: `upload_id` — сессия на сервере, `cloud_name` — имя, под которым начата
///     выгрузка, `replace`/`expected_sha256` — предусловие, с которым её начали,
///     `size`/`mtime`/`sha256` — слепок файла на момент начала, `at` — когда записали;
///   • инвариант: строка живёт, только пока жива сессия на сервере. Продолжать можно, когда
///     совпало всё: слепок файла, имя и предусловие попытки (см. [uploadSession] и
///     `UploadRunner._send`); после успешной выгрузки или смены содержимого строку снимают
///     ([dropUploadSession]).
///
/// Родословная схемы: 1 — базовые таблицы `uploaded` и `queue`, 2 — колонка `queue.sha256`,
/// 3 — колонка `uploaded.sha256`, 4 — таблица `queue_uploads`. Файл и нумерация общие
/// с прежним нативным синхронизатором (`data/QueueStore.kt` в удалённом `android/`, см.
/// FLUTTER.md, «Синхронизация телефона»): APK встал поверх него с тем же `applicationId`,
/// поэтому на устройстве, обновившемся с Kotlin-сборки, база могла остаться версии 1 или 2.
/// Ветви `onUpgrade` только создают и добавляют, поэтому такая база доводится до текущей
/// схемы без потерь, а старые сборки просто не знают про новые колонки и таблицы.
///
/// Миграции — в `onUpgrade`: до версии 2 добавлена колонка `queue.sha256`, до версии 3 —
/// `uploaded.sha256`, до версии 4 — таблица `queue_uploads`. Каждая ветка идемпотентна
/// (колонка добавляется только если её ещё нет), поэтому порядок ветвей не важен и повторный
/// проход по ним ничего не ломает.
///
/// Очередь переживает перезапуск и обновление приложения: выгрузка ручная, и терять
/// подготовленную работу при каждом запуске нельзя.
class QueueStore {
  QueueStore._(this._db);

  final Database _db;

  /// Имя файла базы в папке баз приложения. Отдельный файл, а не общий с зеркалом: очередь
  /// можно пересобрать и почистить, ничего не тронув в состоянии зеркала.
  static const String _name = 'cloudly-queue.db';

  /// Версия схемы: 1 — базовая, 2 — колонка `queue.sha256`, 3 — колонка `uploaded.sha256`,
  /// 4 — таблица `queue_uploads` (продолжение прерванной выгрузки).
  /// Поднимая версию, добавь ветку в `onUpgrade`: очередь пересобирается проходом, а
  /// `uploaded` (что уже выгружено) терять нельзя.
  static const int _version = 4;

  /// Сколько строк пишем одним запросом: 20 000 отдельных вставок подряд держат
  /// эксклюзивную транзакцию заметно дольше, а предел числа параметров в SQLite (999
  /// в старых сборках) не даёт делать порцию произвольно большой. 100 строк × 9 колонок = 900.
  static const int _batchRows = 100;

  /// Сколько id перечисляем в одном `DELETE ... WHERE id IN (...)`: 500 × 1 параметр.
  static const int _deleteIds = 500;

  /// Открыть базу очереди, создав её при первом запуске.
  ///
  /// [directory] — папка для файла базы; по умолчанию системная папка баз приложения
  /// (её же, но отдельным файлом, отдаёт `getDatabasesPath`).
  /// Возвращает готовое хранилище — единственное место, где очередь читается и пишется.
  ///
  /// Побочные эффекты: файл базы на диске, таблицы и индексы при создании, добавление колонок
  /// и таблицы при апгрейде, `PRAGMA busy_timeout` и `PRAGMA journal_mode`. Ошибку открытия
  /// не глушит: без базы очередь не работает, и вызывающий обязан об этом узнать (он либо
  /// покажет ошибку, либо откажется наполнять очередь).
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
        // `uploaded` — «что уже лежит в облаке». Ключ (path, target): один и тот же файл
        // может быть выгружен в две разные облачные папки. sha256 допускает NULL: у строк
        // от версий до 3.0 его просто нет
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
        // `queue` — сама очередь: файл + цель, состояние, попытки, последняя ошибка,
        // кэш хэша и метки времени. Уникальность пары держит индекс ниже
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
        // одна строка на пару «файл + цель»: повторная постановка обновляет строку,
        // а не плодит дубликаты (см. enqueue)
        await db.execute(
          'CREATE UNIQUE INDEX queue_unique ON queue(path, target)',
        );
        // список и счётчики идут по состоянию, а внутри состояния — по id: этим индексом
        // живут items() и waitingCount()
        await db.execute('CREATE INDEX queue_state ON queue(state, id)');
        await db.execute(_createUploadsTable);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Очередь пересобирается проходом, а вот uploaded (что уже выгружено) терять нельзя:
        // без строки файл считался бы невыгруженным и уехал бы в облако второй раз.
        // Ветви только добавляют колонки и таблицы, и каждая проверяет, что именно добавляет:
        // тогда она безопасна и при повторном проходе (версия могла побывать ниже — например,
        // поверх новой сборки поставили старый APK и вернулись на неё).
        if (oldVersion < 3) {
          // слепок выгруженного теперь хранит и хэш: по нему узнаётся, что содержимое
          // на телефоне и в облаке совпадает
          await _addColumn(db, 'uploaded', 'sha256', 'TEXT');
        }
        if (oldVersion < 2) {
          // кэш хэша: считать SHA-256 заново на каждую попытку большого видео — минуты работы
          await _addColumn(db, 'queue', 'sha256', 'TEXT');
        }
        if (oldVersion < 4) {
          // незавершённые выгрузки: без них обрыв на большом файле откатывал бы прогресс
          // к нулю
          await db.execute(_createUploadsTable);
        }
      },
      // Версия ниже нашей — это старая сборка поверх новой (откат обновления). Ронять базу
      // из-за этого нельзя: `uploaded` — знание о том, что уже лежит в облаке, и без него
      // всё уехало бы второй раз. Схема только дополняется, а лишние колонки и таблицы старый
      // код просто не читает, поэтому расхождение версий безопасно, и открытие продолжаем.
      onDowngrade: (db, oldVersion, newVersion) async {},
    );
    await _configure(db);
    return QueueStore._(db);
  }

  /// Закрыть соединение с базой.
  ///
  /// Нужно при выходе из аккаунта и в конце фонового прохода: соединение своё у каждого
  /// движка (`singleInstance: false`), и закрытие в фоне не должно ломать приложение.
  Future<void> close() => _db.close();

  // ===== что уже выгружено =====

  /// Весь снимок «что выгружено»: ключ — файл и облачная папка.
  ///
  /// Читает таблицу целиком (на фотоальбоме это десятки тысяч строк), поэтому вызывается
  /// один раз на проход, а не на файл: наполнение очереди ([QueueBuilder]) берёт снимок
  /// один раз и дальше работает с ним в памяти.
  ///
  /// Возвращает карту «файл + папка → слепок». Строки без `entry_id` пропускаются: без id
  /// записи в облаке слепок ничего не описывает, а `'${r['entry_id']}'` превратил бы SQL-NULL
  /// в строку «null» и такая строка ушла бы в запрос метаданных. Ничего не пишет.
  Future<Map<UploadedKey, Uploaded>> uploaded() async {
    final rows = await _db.query(
      'uploaded',
      columns: ['path', 'target', 'entry_id', 'size', 'mtime'],
    );
    final out = <UploadedKey, Uploaded>{};
    for (final r in rows) {
      final entryId = _str(r['entry_id']);
      final path = _str(r['path']);
      final target = _str(r['target']);
      if (entryId == null || path == null || target == null) continue;
      out[UploadedKey(path, target)] = Uploaded(
        entryId,
        (r['size'] as int?) ?? 0,
        (r['mtime'] as int?) ?? 0,
      );
    }
    return out;
  }

  /// Слепок одной пары «файл + папка» или `null`, если её нет.
  ///
  /// Отдельный точечный запрос для выгрузки: ей нужна ровно одна пара, а [uploaded] читает
  /// таблицу целиком — на библиотеке в десятки тысяч строк это лишняя работа на каждый файл.
  /// Идёт по первичному ключу (`sqlite_autoindex_uploaded_1`). Ничего не пишет.
  Future<Uploaded?> uploadedOne(String path, String target) async {
    final rows = await _db.query(
      'uploaded',
      columns: ['entry_id', 'size', 'mtime'],
      where: 'path = ? AND target = ?',
      whereArgs: [path, target],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    final entryId = _str(r['entry_id']);
    // строка без id записи в облаке не описывает ничего: считаем, что её нет
    if (entryId == null) return null;
    return Uploaded(
      entryId,
      (r['size'] as int?) ?? 0,
      (r['mtime'] as int?) ?? 0,
    );
  }

  /// Записать, что файл выгружен: строка в `uploaded` описывает, что именно лежит в облаке.
  ///
  /// [path]/[target] — ключ, [entryId] — id записи в облаке, [size]/[mtime] — слепок файла
  /// на момент выгрузки, [sha256] — хэш содержимого (может быть null: значит «кэша нет»).
  /// Обновляет `at`.
  ///
  /// Пишет через `INSERT OR REPLACE`: повторная запись той же пары заменяет строку целиком,
  /// поэтому слепок всегда соответствует последней выгрузке, а не смеси из двух.
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
  ///
  /// [items] — план наполнения (см. [QueuePlanner.plan]): только файлы, которых в облаке нет
  /// или которые с тех пор изменились.
  ///
  /// Возвращает число добавленных строк; существующие строки в счёт не идут.
  /// Побочный эффект — запись в SQLite одной транзакцией: либо весь план, либо ничего
  /// (обрыв на середине не оставил бы очередь наполовину обновлённой). Ошибку не глушит.
  ///
  /// Проходы не мешают друг другу: снимок «что уже стоит» читается ВНУТРИ той же транзакции,
  /// что и запись. Снаружи между снимком и вставкой успевал влезть второй проход (фоновая
  /// сторона задания и приложение делят базу), и его вставка становилась нарушением
  /// `queue_unique`, а вместе с ним терялся весь батч — включая строки, которых он не касался.
  /// Транзакция эксклюзивная, поэтому отдельного `INSERT OR IGNORE` здесь не нужно.
  Future<int> enqueue(List<Candidate> items) async {
    if (items.isEmpty) return 0;
    return _db.transaction((txn) async {
      // Какие пары «файл + цель» уже стоят в очереди: отдельный запрос на каждый файл — это
      // десятки тысяч запросов на фотоальбоме при каждом входе в раздел. Один запрос вместо
      // них, но уже под транзакцией: снаружи он бы устарел, пока идёт обновление.
      final existing =
          <String, ({int size, int mtime, String? sha256, String? entryId})>{};
      for (final r in await txn.query(
        'queue',
        columns: ['path', 'target', 'size', 'mtime', 'sha256', 'entry_id'],
      )) {
        existing['${r['path']}\u0000${r['target']}'] = (
          size: (r['size'] as int?) ?? 0,
          mtime: (r['mtime'] as int?) ?? 0,
          sha256: _str(r['sha256']),
          entryId: _str(r['entry_id']),
        );
      }
      // строки, которых в очереди ещё нет: их пишем порциями ниже
      final fresh = <Candidate>[];
      for (final item in items) {
        final key = '${item.path}\u0000${item.target}';
        final before = existing[key];
        if (before == null) {
          fresh.add(item);
          // пару помечаем занятой сразу: повтор внутри самого плана (это уже не «нет строки»,
          // а та же пара дважды) не должен дать вторую вставку — та нарушила бы queue_unique
          // и уронила бы всю порцию
          existing[key] = (
            size: item.size,
            mtime: item.mtime,
            sha256: null,
            entryId: null,
          );
          continue;
        }
        // ИНВАРИАНТ слепка: `size`, `mtime` и `sha256` строки описывают один и тот же момент
        // файла, поэтому обновлять размер и дату в одиночку нельзя. Здесь слепок с диска
        // сравнивается со слепком строки: совпал — кэш хэша и id прошлой выгрузки относятся
        // к тому же содержимому и остаются; не совпал — обнуляются, иначе в дело пошёл бы
        // хэш прежнего содержимого («уже в облаке» на изменившемся файле — и правка
        // не доехала бы никогда). Решение принимает чистое правило QueuePlanner.sameSnapshot.
        final same = QueuePlanner.sameSnapshot(
          size: before.size,
          mtime: before.mtime,
          candidate: item,
        );
        // строка уже есть: обновляем то, что изменилось, но состояние не сбрасываем —
        // иначе RUNNING-строка вернулась бы в ожидание прямо во время выгрузки
        await txn.rawUpdate(
          '''
          UPDATE queue SET rel_dir = ?, name = ?, size = ?, mtime = ?, sha256 = ?, entry_id = ?,
            state = CASE WHEN state IN ('${QueueState.done.storageKey}','${QueueState.skipped.storageKey}')
              THEN '${QueueState.pending.storageKey}' ELSE state END,
            last_error = CASE WHEN state IN ('${QueueState.done.storageKey}','${QueueState.skipped.storageKey}')
              THEN NULL ELSE last_error END
          WHERE path = ? AND target = ?
          ''',
          [
            item.relDir,
            item.name,
            item.size,
            item.mtime,
            same ? before.sha256 : null,
            same ? before.entryId : null,
            item.path,
            item.target,
          ],
        );
      }
      var added = 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (var start = 0; start < fresh.length; start += _batchRows) {
        final chunk = fresh.sublist(
          start,
          start + _batchRows > fresh.length ? fresh.length : start + _batchRows,
        );
        final values = List.filled(
          chunk.length,
          '(?,?,?,?,?,?,?,?,?)',
        ).join(',');
        final args = <Object?>[];
        for (final item in chunk) {
          args.addAll([
            item.path,
            item.relDir,
            item.name,
            item.size,
            item.mtime,
            item.section.storageKey,
            item.target,
            QueueState.pending.storageKey,
            now,
          ]);
        }
        // одной вставкой на порцию: 20 000 отдельных INSERT держали бы эксклюзивную
        // транзакцию заметно дольше, а очередь в это время недоступна экрану
        await txn.rawInsert(
          'INSERT INTO queue(path, rel_dir, name, size, mtime, section, target, state, created_at) '
          'VALUES $values',
          args,
        );
        added += chunk.length;
      }
      return added;
    });
  }

  /// Строки очереди в порядке показа: сначала то, что в работе, потом ожидающее, ошибки
  /// и только затем закрытые; внутри состояния — по id, то есть по порядку постановки.
  ///
  /// [limit] — предел выборки (по умолчанию 2000): очередь на фотоальбоме бывает огромной,
  /// а показать и слить всё равно успевают только первые. Ничего не пишет.
  ///
  /// Порядок собирается отдельными узкими запросами на состояние, а не `ORDER BY CASE`:
  /// такой `ORDER BY` не может использовать индекс `queue_state(state, id)` — SQLite
  /// просканировал бы всю таблицу и построил временное дерево сортировки на каждый вызов,
  /// а `items()` зовётся и на каждом обновлении экрана, и до двадцати раз за один слив.
  Future<List<QueueItem>> items({int limit = 2000}) async {
    final out = <QueueItem>[];
    // порядок ровно тот же, что был у ORDER BY CASE: работа, ожидание, ошибки
    for (final state in [
      QueueState.running,
      QueueState.pending,
      QueueState.failed,
    ]) {
      if (out.length >= limit) break;
      final rows = await _db.rawQuery(
        'SELECT * FROM queue WHERE state = ? ORDER BY id LIMIT ?',
        [state.storageKey, limit - out.length],
      );
      out.addAll(rows.map(_readItem));
    }
    // Закрытые и незнакомые состояния — в конце. Запрос без индекса, но выполняется только
    // когда известных состояний не хватило до предела, то есть таблица невелика.
    if (out.length < limit) {
      final rows = await _db.rawQuery(
        "SELECT * FROM queue WHERE state NOT IN (?,?,?) ORDER BY id LIMIT ?",
        [
          QueueState.running.storageKey,
          QueueState.pending.storageKey,
          QueueState.failed.storageKey,
          limit - out.length,
        ],
      );
      out.addAll(rows.map(_readItem));
    }
    return out;
  }

  /// Сколько строк в каждом состоянии: строкой итогов живёт шапка раздела «Очередь».
  /// Считает база (`GROUP BY state`), поэтому таблицу целиком в память не тянет.
  ///
  /// Незнакомое состояние в счётчик не попадает вовсе: сложить его с ожидающими значило бы
  /// показать в шапке числа, которых в очереди нет (строку с таким состоянием выгрузка
  /// не возьмёт, а [items] покажет — см. [QueueState.byKeyOrNull]).
  Future<Map<QueueState, int>> counts() async {
    final rows = await _db.rawQuery(
      'SELECT state, COUNT(*) AS n FROM queue GROUP BY state',
    );
    final out = <QueueState, int>{};
    for (final r in rows) {
      final state = QueueState.byKeyOrNull(_str(r['state']));
      if (state == null) continue;
      out[state] = (r['n'] as int?) ?? 0;
    }
    return out;
  }

  /// Ждут запуска: кнопка «play», счётчик в шапке и сторож (`SyncController`) смотрят сюда.
  /// Ошибки считаются вместе с ожидающими: строка с ошибкой тоже ждёт следующей попытки.
  Future<int> waitingCount() async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM queue '
      "WHERE state IN ('${QueueState.pending.storageKey}','${QueueState.failed.storageKey}')",
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Одна строка по ключу: её читает выгрузка перед началом работы.
  /// Возвращает `null`, если строку успели снять уборкой или «очистить выполненные» —
  /// это нормальный случай, а не ошибка.
  Future<QueueItem?> item(int id) async {
    final rows = await _db.query(
      'queue',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _readItem(rows.first);
  }

  /// Отметить строку работающей: ставится до сети, вместе с временем начала.
  /// Текст прошлой ошибки стирается — он относится к прошлой попытке.
  Future<void> markRunning(int id) => _update(id, {
    'state': QueueState.running.storageKey,
    'started_at': DateTime.now().millisecondsSinceEpoch,
    'last_error': null,
  });

  /// Отметить строку выгруженной: [entryId] — id записи в облаке, время окончания — сейчас.
  Future<void> markDone(int id, String entryId) => _update(id, {
    'state': QueueState.done.storageKey,
    'entry_id': entryId,
    'finished_at': DateTime.now().millisecondsSinceEpoch,
  });

  /// Содержимое уже было в облаке: байты не передавались, но запись там есть.
  ///
  /// Состояние отличается от `done` намеренно: по нему видно, что файл нашли в облаке,
  /// а не залили, — и «очистить выполненные» снимает обе строки одинаково.
  Future<void> markSkipped(int id, String entryId) => _update(id, {
    'state': QueueState.skipped.storageKey,
    'entry_id': entryId,
    'finished_at': DateTime.now().millisecondsSinceEpoch,
  });

  /// Отметить неудачу: [error] — текст исключения, [attempts] — уже увеличенное число
  /// попыток (считает вызывающий: он видит свежую строку).
  ///
  /// Текст обрезается до 500 знаков: в ошибку попадает и тело ответа сервера, а хранить
  /// в строке простыню незачем — её читает только человек в списке.
  Future<void> markFailed(int id, String error, int attempts) => _update(id, {
    'state': QueueState.failed.storageKey,
    'last_error': error.length > 500 ? error.substring(0, 500) : error,
    'attempts': attempts,
    'finished_at': DateTime.now().millisecondsSinceEpoch,
  });

  /// Вернуть в ожидание: кнопка повтора на строке с ошибкой.
  /// Текст ошибки стирается вместе с состоянием, а счётчик попыток остаётся: по нему видно,
  /// что попытка не первая.
  Future<void> markPending(int id) =>
      _update(id, {'state': QueueState.pending.storageKey, 'last_error': null});

  /// Запомнить посчитанный хэш: повторная попытка не должна перечитывать весь файл.
  ///
  /// Хэш относится к слепку, который лежит в строке (`size`/`mtime`): писать его без этого
  /// слепка нельзя — см. инвариант у [QueueItem.size].
  Future<void> setSha(int id, String sha256) => _update(id, {'sha256': sha256});

  /// Снять зависшие «грузится». После перезапуска приложения ничего не может быть в работе,
  /// а строка осталась бы в этом состоянии навсегда.
  ///
  /// Возвращает число снятых строк. Возвращает их в ожидание, а не в ошибку: файл просто
  /// не доехал, и вторая попытка нужна без упрёков. Вызывается один раз — когда ядро
  /// синхронизации открывает базу очереди на старте (`SyncController`).
  Future<int> resetRunning() => _db.update(
    'queue',
    {'state': QueueState.pending.storageKey, 'last_error': null},
    where: 'state = ?',
    whereArgs: [QueueState.running.storageKey],
  );

  /// Убрать из очереди то, чего больше не должно быть: папку отключили от раздела или файл
  /// с телефона исчез. Ключи, которые остались кандидатами, и незатронутые разделы
  /// остаются на месте.
  ///
  /// [keep] — пары «файл + цель» из текущего обхода, [scannedSections] — разделы, которые
  /// в этом проходе действительно прошли (включая те, где ничего не выбрано).
  ///
  /// Возвращает число удалённых строк.
  /// Побочные эффекты: чтение, решение и удаление — всё в одной транзакции, поэтому строка,
  /// ставшая `RUNNING` в этот момент, уборке не достанется (раньше отбор шёл по снимку,
  /// сделанному до транзакции, и выгрузку можно было снести вместе со строкой: `markDone`
  /// потом обновлял 0 строк, а след оставался только в `uploaded`). Вместе со строками
  /// снимаются их незавершённые сессии выгрузки. Решение принимает чистое правило
  /// [QueuePlanner.obsolete] — здесь только база. Ошибку не глушит.
  Future<int> prune(Set<UploadedKey> keep, Set<Section> scannedSections) async {
    // ни один раздел не считаем пройденным (например, не выполнен вход) — не трогаем ничего:
    // иначе одна неполадка выкосила бы всю очередь
    if (scannedSections.isEmpty) return 0;
    return _db.transaction((txn) async {
      final rows = await txn.query(
        'queue',
        columns: ['id', 'path', 'target', 'section', 'state'],
      );
      final doomed = QueuePlanner.obsolete(
        rows.map(_readRow).toList(),
        keep,
        scannedSections,
      );
      if (doomed.isEmpty) return 0;
      for (var start = 0; start < doomed.length; start += _deleteIds) {
        final chunk = doomed.sublist(
          start,
          start + _deleteIds > doomed.length
              ? doomed.length
              : start + _deleteIds,
        );
        final marks = List.filled(chunk.length, '?').join(',');
        // сессия незавершённой выгрузки уходит вместе со строкой: продолжать её будет некому
        await txn.rawDelete(
          'DELETE FROM queue_uploads WHERE EXISTS ('
          'SELECT 1 FROM queue WHERE queue.path = queue_uploads.path '
          'AND queue.target = queue_uploads.target AND queue.id IN ($marks))',
          chunk,
        );
        await txn.rawDelete('DELETE FROM queue WHERE id IN ($marks)', chunk);
      }
      return doomed.length;
    });
  }

  // ===== незавершённые выгрузки =====

  /// Незавершённая выгрузка этой пары «файл + цель» или `null`, если её нет.
  ///
  /// [path] — путь файла на телефоне, [target] — облачная папка (для очереди это и есть
  /// папка получателя). Возвращает сессию с id на сервере и слепком попытки: сверку
  /// «то же ли это содержимое и та же ли попытка» делает вызывающий
  /// (`UploadRunner._send`), прежде чем продолжать через `Uploader.resume`.
  Future<QueueUploadSession?> uploadSession(String path, String target) async {
    final rows = await _db.query(
      'queue_uploads',
      where: 'path = ? AND target = ?',
      whereArgs: [path, target],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return QueueUploadSession(
      path: _str(r['path']) ?? path,
      target: _str(r['target']) ?? target,
      uploadId: _str(r['upload_id']) ?? '',
      cloudName: _str(r['cloud_name']) ?? '',
      replace: ((r['replace_flag'] as int?) ?? 0) != 0,
      expectedSha256: _str(r['expected_sha256']),
      size: (r['size'] as int?) ?? 0,
      mtime: (r['mtime'] as int?) ?? 0,
      sha256: _str(r['sha256']) ?? '',
    );
  }

  /// Запомнить начатую выгрузку: [row] — сессия на сервере, имя и предусловие попытки,
  /// с которыми она начата, и слепок файла. Пишет `at` (когда записали). Заменяет прежнюю
  /// строку той же пары: продолжить можно только одну сессию.
  Future<void> putUploadSession(QueueUploadSession row) =>
      _db.insert('queue_uploads', {
        'path': row.path,
        'target': row.target,
        'upload_id': row.uploadId,
        'cloud_name': row.cloudName,
        'replace_flag': row.replace ? 1 : 0,
        'expected_sha256': ?row.expectedSha256,
        'size': row.size,
        'mtime': row.mtime,
        'sha256': row.sha256,
        'at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  /// Забыть сессию: выгрузка завершена, файл изменился, попытка начата иначе или сессия
  /// на сервере истекла. Строка только про «продолжить», поэтому удаление безопасно —
  /// состояние самого файла живёт в `queue`/`uploaded`.
  Future<void> dropUploadSession(String path, String target) => _db.delete(
    'queue_uploads',
    where: 'path = ? AND target = ?',
    whereArgs: [path, target],
  );

  /// Убрать выполненные строки: очередь не должна превращаться в летопись.
  /// Снимает и `done`, и `skipped` — обе строки свою работу уже сделали. Строки с ошибкой
  /// остаются: они ещё ждут следующей попытки.
  Future<int> clearFinished() => _db.delete(
    'queue',
    where:
        "state IN ('${QueueState.done.storageKey}','${QueueState.skipped.storageKey}')",
  );

  /// Общий путь для смены состояния и служебных полей строки: ключ всегда `id`.
  /// Число изменённых строк не возвращается и не проверяется: если строки уже нет (её сняла
  /// уборка или «очистить выполненные»), это не ошибка.
  Future<void> _update(int id, Map<String, Object?> values) =>
      _db.update('queue', values, where: 'id = ?', whereArgs: [id]);

  /// Собрать строку из результата запроса.
  ///
  /// Значения читаются «мягко»: отсутствующее число — 0, строка — как есть. Раздел и
  /// состояние разбираются из строк базы; неизвестные значения не роняют чтение, а дают
  /// `files` и `pending` соответственно — старая или чужая строка не должна ломать список.
  QueueItem _readItem(Map<String, Object?> r) => QueueItem(
    id: (r['id'] as int?) ?? 0,
    path: _str(r['path']) ?? '',
    relDir: _str(r['rel_dir']) ?? '',
    name: _str(r['name']) ?? '',
    size: (r['size'] as int?) ?? 0,
    mtime: (r['mtime'] as int?) ?? 0,
    section: Section.byStorageKey(_str(r['section'])) ?? Section.files,
    target: _str(r['target']) ?? '',
    state: QueueState.byKey(_str(r['state'])),
    attempts: (r['attempts'] as int?) ?? 0,
    lastError: _str(r['last_error']),
    entryId: _str(r['entry_id']),
    sha256: _str(r['sha256']),
    createdAt: (r['created_at'] as int?) ?? 0,
    finishedAt: r['finished_at'] as int?,
  );

  /// Строка очереди для правила уборки: раздел и состояние разбираются здесь, где оба
  /// перечисления под рукой, а незнакомое значение приходит в правило явным `null`.
  QueueRow _readRow(Map<String, Object?> r) => QueueRow(
    (r['id'] as int?) ?? 0,
    _str(r['path']) ?? '',
    _str(r['target']) ?? '',
    Section.byStorageKey(_str(r['section'])),
    QueueState.byKeyOrNull(_str(r['state'])),
  );
}

/// Незавершённая выгрузка очереди: сессия на сервере и то, с чем она начата.
///
/// Хранит не только id сессии, но и имя с предусловием попытки: продолжать можно, только если
/// файл не изменился И попытка начиналась так же (то же имя, то же «перезаписываем версию X»).
/// Иначе принятые сервером части относились бы к другому решению, и продолжение могло бы
/// затереть в облаке то, что предусловие как раз охраняло.
class QueueUploadSession {
  const QueueUploadSession({
    required this.path,
    required this.target,
    required this.uploadId,
    required this.cloudName,
    required this.replace,
    required this.size,
    required this.mtime,
    required this.sha256,
    this.expectedSha256,
  });

  /// Путь файла на телефоне и облачная папка получателя: они же ключ строки очереди.
  final String path;
  final String target;

  /// Сессия выгрузки на сервере: по ней её и продолжают (`Uploader.resume`).
  final String uploadId;

  /// Имя, под которым выгрузка начата (оно же уходит в облако).
  final String cloudName;

  /// Начиналась ли попытка перезаписью существующей записи.
  final bool replace;

  /// Версия в облаке, которую попытка считала актуальной (при перезаписи).
  final String? expectedSha256;

  /// Слепок файла на момент начала выгрузки: размер, дата и хэш.
  final int size;
  final int mtime;
  final String sha256;
}

/// Значение из колонки как строка или `null`, если его нет.
///
/// Нужно вместо `'${r['column']}'`: такой шаблон превращает SQL-NULL в строку «null»,
/// и она уходит дальше как настоящее значение (пустой id записи, «null» вместо имени).
String? _str(Object? value) => value == null ? null : '$value';

/// Создание таблицы незавершённых выгрузок. Нужна и при первом создании базы, и при
/// апгрейде до версии 4, поэтому лежит одной строкой: схема в двух местах разойтись не может.
const String _createUploadsTable = '''
  CREATE TABLE IF NOT EXISTS queue_uploads(
    path TEXT NOT NULL,
    target TEXT NOT NULL,
    upload_id TEXT NOT NULL,
    cloud_name TEXT NOT NULL,
    replace_flag INTEGER NOT NULL,
    expected_sha256 TEXT,
    size INTEGER NOT NULL,
    mtime INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    at INTEGER NOT NULL,
    PRIMARY KEY(path, target)
  )
''';

/// Добавить колонку, если её ещё нет.
///
/// Явная проверка нужна из-за откатов версии: после установки старой сборки поверх новой
/// sqflite опускает `user_version`, и ветка апгрейда выполнится второй раз — `ALTER TABLE
/// ADD COLUMN` без проверки упал бы с «duplicate column name» и база не открылась бы вовсе.
Future<void> _addColumn(
  Database db,
  String table,
  String column,
  String declaration,
) async {
  final columns = await db.rawQuery('PRAGMA table_info($table)');
  for (final c in columns) {
    if (c['name'] == column) return;
  }
  await db.execute('ALTER TABLE $table ADD COLUMN $column $declaration');
}

/// Два соединения к одному файлу (приложение и фоновое задание) — это нормально для SQLite,
/// но короткая параллельная запись может попасть в «database is locked». Пусть лучше подождёт.
///
/// WAL — чтобы читатель (экран очереди, фоновое задание) не ждал писателя: без него любая
/// запись блокирует чтение на всё время транзакции, а транзакции здесь бывают длинными
/// (постановка тысяч строк). Режим хранится в самом файле базы, поэтому ставится один раз
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
    debugPrint('cloudly-sync: busy_timeout не поставлен: $e');
  }
  try {
    await db.rawQuery('PRAGMA journal_mode = WAL');
  } catch (e) {
    debugPrint('cloudly-sync: WAL для базы очереди не включился: $e');
  }
}
