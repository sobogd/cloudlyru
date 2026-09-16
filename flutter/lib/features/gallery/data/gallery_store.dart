import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../../api/models.dart';

/// Локальный индекс галереи: кадры ленты и разбивка по месяцам.
///
/// ## Зачем своя база
///
/// Галерея — это окно в десятки тысяч кадров, и ходить за каждым его сдвигом в сеть значит
/// ждать сеть на каждом движении пальца. Поэтому кадры лежат на устройстве (база
/// `cloudly-gallery.db`): окно читается отсюда за единицы миллисекунд и работает без сети,
/// а с сервером список сверяется журналом изменений (см. `GallerySync`).
///
/// ## Чем это не прежний локальный список
///
/// Прежний адресовался номером кадра (`range(offset)`) и потому требовал полного прохода,
/// чтобы заметить, что состав медиатеки изменился: номер сдвигается от каждой загрузки.
/// Здесь адрес — сам кадр, пара `(sort_key, entry_id)` (см. [MediaCursor]), и выборки идут
/// по ней ровно так же, как на сервере. Номера кадров не хранятся нигде.
///
/// ## `items` — кадры
///
///   • `entry_id` — ключ: id записи в дереве облака (не хэш);
///   • `sort_key` — время съёмки в миллисекундах UTC, `-1` у кадров без даты. Они идут
///     последними, как `ORDER BY capturedAt DESC NULLS LAST` на сервере. Целое, а не строка:
///     по нему идёт индекс, и разбора ISO в запросе нет;
///   • `preview_state` — состояние превью (`done`/`none`/`impossible`): по нему плитка решает,
///     показывать картинку или иконку;
///   • `size_bytes` — размер содержимого (виден в просмотрщике).
///
/// ## `months` — разбивка по месяцам
///
/// Отдельная таблица, а не запрос с `GROUP BY`: по ней строится шкала таймлайна при каждом
/// открытии раздела, и агрегат по десяткам тысяч строк на каждом открытии — лишняя работа.
/// Пересобирается из `items` после записи в список ([rebuildMonths]).
class GalleryStore {
  GalleryStore._(this._db);

  final Database _db;

  /// Имя файла базы в папке баз приложения.
  static const String _name = 'cloudly-gallery.db';

  /// Версия схемы. Поднимая её, добавляй ветку в `onUpgrade`, которая только создаёт или
  /// добавляет колонки: удалять данные здесь нельзя — иначе после обновления приложения
  /// список пришлось бы заливать заново, а он же и есть офлайн-галерея.
  static const int _version = 1;

  /// База прежнего локального списка: он адресовался номерами кадров и больше не нужен.
  /// Удаляется при первом открытии новой — содержимое всё равно приезжает с сервера.
  static const String _legacyName = 'cloudly-media.db';

  /// Ключ меты: индекс наполнен целиком (первый проход дошёл до конца ленты).
  static const String keyBackboneDone = 'backbone_done';

  /// Ключ меты: курсор, на котором остановилось наполнение индекса (см. [MediaCursor.encode]).
  static const String keyBackboneCursor = 'backbone_cursor';

  /// Ключ меты: курсор журнала изменений, уже применённый к списку.
  static const String keyChangesCursor = 'changes_cursor';

  /// Ключ меты: когда список последний раз сверялся с сервером (ISO-8601 UTC).
  static const String keySyncAt = 'sync_at';

  /// Ключ меты: поколение строк (см. [beginGeneration]).
  static const String keyGen = 'data_gen';

  /// Поколение, которым помечаются записываемые строки. Читается при открытии базы.
  int _gen = 0;

  /// Поколение текущего набора строк — нужно тому, кто запускает пересборку списка.
  int get generation => _gen;

  /// Открыть базу индекса, создав её при первом запуске.
  ///
  /// [directory] — папка для файла базы; по умолчанию системная папка баз приложения.
  /// Ошибку открытия не глушим: без индекса галерея пуста, и это надо видеть.
  static Future<GalleryStore> open({String? directory}) async {
    final dir = directory ?? await getDatabasesPath();
    // Прежняя база удаляется целиком, вместе с журналами WAL: её схема и смысл другие, а
    // содержимое восстанавливается с сервера первым же проходом.
    for (final suffix in const ['', '-wal', '-shm']) {
      await databaseFactory.deleteDatabase(p.join(dir, '$_legacyName$suffix'));
    }
    final db = await openDatabase(
      p.join(dir, _name),
      version: _version,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE items(
            entry_id TEXT PRIMARY KEY,
            sha256 TEXT,
            name TEXT NOT NULL,
            mime TEXT NOT NULL,
            sort_key INTEGER NOT NULL,
            tz_offset_min INTEGER,
            preview_state TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            gen INTEGER NOT NULL DEFAULT 0
          )
        ''');
        // Порядок выборки — тот же, что на сервере: окно читается окрест курсора, и без
        // индекса SQLite сортировал бы всю таблицу на каждый сдвиг окна.
        await db.execute('CREATE INDEX items_order ON items(sort_key DESC, entry_id DESC)');
        // Ключ месяца; пустая строка — бакет «Без даты» (NULL в первичном ключе SQLite не хранит).
        await db.execute('CREATE TABLE months(month TEXT PRIMARY KEY, count INTEGER NOT NULL)');
        await db.execute('CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)');
      },
      onUpgrade: (db, from, to) async {
        // Пока версия одна, веток нет: первая же правка схемы обязана добавить сюда
        // `if (from < 2) { ... }`, а не пересоздавать таблицы.
      },
    );
    final store = GalleryStore._(db);
    store._gen = int.tryParse(await store.meta(keyGen) ?? '') ?? 0;
    return store;
  }

  /// Начать новое поколение строк: пересборка списка пишет свои строки в него.
  ///
  /// Строки прежних поколений снимаются [dropOtherGenerations] только после того, как проход
  /// дочитал ленту до конца. Так обрыв прохода не оставляет список усечённым (в базе лежит
  /// полный прежний набор плюс обновлённые строки) и не оставляет в нём призраков удалённого.
  Future<int> beginGeneration() async {
    _gen++;
    await setMeta(keyGen, '$_gen');
    return _gen;
  }

  /// Снять строки прежних поколений: после этого в списке ровно то, что прочитал проход.
  Future<void> dropOtherGenerations() async {
    await _db.delete('items', where: 'gen != ?', whereArgs: [_gen]);
  }

  /// Закрыть базу (выход из аккаунта, разрушение провайдера).
  Future<void> close() => _db.close();

  // ---------- чтение ленты ----------

  /// Сколько кадров в индексе (включая хвост без даты).
  Future<int> count() async {
    final rows = await _db.rawQuery('SELECT count(*) AS n FROM items');
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Начало ленты — самые свежие датированные кадры.
  ///
  /// Кадры без даты сюда не попадают: они идут после всех датированных и дочитываются
  /// страницей хвоста (`older` с курсором без даты) — так же, как на сервере.
  Future<MediaFeedPage> head(int limit) async {
    final rows = await _db.rawQuery('''
      SELECT * FROM items
      WHERE sort_key >= 0
      ORDER BY sort_key DESC, entry_id DESC
      LIMIT ?
    ''', [limit + 1]);
    return _page(rows, limit);
  }

  /// Кадры старше курсора — листание в прошлое.
  ///
  /// Курсор без даты (`at == null`) адресует хвост ленты: пустой `id` — его начало, непустой —
  /// позицию внутри хвоста. Датированный курсор хвост не захватывает, поэтому хвост дочитывают
  /// отдельной страницей.
  Future<MediaFeedPage> older(MediaCursor cursor, int limit) async {
    final List<Map<String, Object?>> rows;
    if (cursor.at == null) {
      rows = await _db.rawQuery('''
        SELECT * FROM items
        WHERE sort_key < 0 ${cursor.id.isEmpty ? '' : 'AND entry_id < ?'}
        ORDER BY entry_id DESC
        LIMIT ?
      ''', [if (cursor.id.isNotEmpty) cursor.id, limit + 1]);
    } else {
      final ms = _ms(cursor.at!);
      // Разрыв ничьих по одинаковому моменту съёмки — только когда id назван: пустой id
      // означает границу месяца (строго до момента), см. `MediaCursor`.
      rows = cursor.id.isEmpty
          ? await _db.rawQuery('''
              SELECT * FROM items
              WHERE sort_key >= 0 AND sort_key < ?
              ORDER BY sort_key DESC, entry_id DESC
              LIMIT ?
            ''', [ms, limit + 1])
          : await _db.rawQuery('''
              SELECT * FROM items
              WHERE sort_key >= 0 AND (sort_key < ? OR (sort_key = ? AND entry_id < ?))
              ORDER BY sort_key DESC, entry_id DESC
              LIMIT ?
            ''', [ms, ms, cursor.id, limit + 1]);
    }
    return _page(rows, limit);
  }

  /// Кадры новее курсора — листание к свежему.
  ///
  /// Курсор без даты означает «новее хвоста»: с непустым `id` — остаток хвоста, с пустым —
  /// самые старые датированные кадры (они и примыкают к хвосту снизу).
  ///
  /// Читаем по возрастанию и разворачиваем: нужны кадры, примыкающие к окну, а не начало ленты.
  Future<MediaFeedPage> newer(MediaCursor cursor, int limit) async {
    final List<Map<String, Object?>> rows;
    if (cursor.at == null && cursor.id.isNotEmpty) {
      rows = await _db.rawQuery('''
        SELECT * FROM items
        WHERE sort_key < 0 AND entry_id > ?
        ORDER BY entry_id ASC
        LIMIT ?
      ''', [cursor.id, limit + 1]);
    } else if (cursor.at == null) {
      rows = await _db.rawQuery('''
        SELECT * FROM items
        WHERE sort_key >= 0
        ORDER BY sort_key ASC, entry_id ASC
        LIMIT ?
      ''', [limit + 1]);
    } else {
      final ms = _ms(cursor.at!);
      rows = cursor.id.isEmpty
          ? await _db.rawQuery('''
              SELECT * FROM items
              WHERE sort_key >= 0 AND sort_key > ?
              ORDER BY sort_key ASC, entry_id ASC
              LIMIT ?
            ''', [ms, limit + 1])
          : await _db.rawQuery('''
              SELECT * FROM items
              WHERE sort_key >= 0 AND (sort_key > ? OR (sort_key = ? AND entry_id > ?))
              ORDER BY sort_key ASC, entry_id ASC
              LIMIT ?
            ''', [ms, ms, cursor.id, limit + 1]);
    }
    final page = _page(rows, limit);
    return MediaFeedPage(items: page.items.reversed.toList(), hasMore: page.hasMore);
  }

  /// Разбивка по месяцам в порядке ленты (от свежих), «без даты» — последней.
  Future<List<MediaMonthBucket>> months() async {
    // Сортировка по `month IS NULL` уводит пустой ключ («без даты») в конец — как в ленте.
    final rows = await _db.rawQuery("SELECT month, count FROM months ORDER BY month = '', month DESC");
    return rows
        .map((r) => MediaMonthBucket(
              month: (r['month'] as String?)?.isEmpty ?? true ? null : r['month'] as String,
              count: (r['count'] as int?) ?? 0,
            ))
        .toList();
  }

  // ---------- запись ----------

  /// Добавить или обновить кадры (по `entry_id`).
  ///
  /// Пачками: страница ленты — до тысячи строк, и вставка по одной была бы тысячей транзакций.
  Future<void> upsertAll(List<MediaItem> items) async {
    if (items.isEmpty) return;
    const chunk = 500;
    await _db.transaction((txn) async {
      for (var i = 0; i < items.length; i += chunk) {
        final batch = txn.batch();
        for (final it in items.skip(i).take(chunk)) {
          batch.insert('items', _fromItem(it), conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      }
    });
  }

  /// Убрать кадры из индекса (файл удалён в облаке или ушёл из зоны «Фото»).
  Future<void> removeEntries(List<String> entryIds) async {
    if (entryIds.isEmpty) return;
    final batch = _db.batch();
    for (final id in entryIds) {
      batch.delete('items', where: 'entry_id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// Обновить состояние превью у перечисленных кадров (ответ `/media/status`).
  Future<void> setPreviewStates(Map<String, String> states) async {
    if (states.isEmpty) return;
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final e in states.entries) {
        batch.update('items', {'preview_state': e.value}, where: 'entry_id = ?', whereArgs: [e.key]);
      }
      await batch.commit(noResult: true);
    });
  }

  /// Записать разбивку по месяцам, посчитанную сервером.
  ///
  /// Нужна, пока локальный индекс неполон: шкала таймлайна должна показать все годы съёмки
  /// сразу при первом открытии, а не после того, как с сервера приедет вся библиотека. После
  /// полного прохода её сменяет точная разбивка из [rebuildMonths].
  Future<void> writeMonths(List<MediaMonthBucket> months) async {
    await _db.transaction((txn) async {
      await txn.delete('months');
      final batch = txn.batch();
      for (final m in months) {
        if (m.count <= 0) continue;
        batch.insert('months', {'month': m.month ?? '', 'count': m.count});
      }
      await batch.commit(noResult: true);
    });
  }

  /// Пересобрать разбивку по месяцам из кадров.
  ///
  /// [tzOffsetMin] — сдвиг пояса зрителя в минутах на восток: бакет месяца — это
  /// `время съёмки + пояс`, ровно как на сервере (`/media/months?tz=`). Иначе кадр, снятый
  /// вечером последнего числа, попал бы в следующий месяц и шкала уехала бы от ленты.
  ///
  /// Читается один проход по индексу `items_order` (пары «ключ, id» без обращения к строкам),
  /// а группировка идёт в Dart: так «первый кадр месяца» — это просто первый встреченный,
  /// и никаких коррелированных подзапросов на каждый месяц не нужно.
  Future<void> rebuildMonths({required int tzOffsetMin}) async {
    final rows = await _db.rawQuery('SELECT entry_id, sort_key FROM items ORDER BY sort_key DESC, entry_id DESC');
    final counts = <String, int>{};
    for (final r in rows) {
      final key = _monthKey((r['sort_key'] as int?) ?? -1, tzOffsetMin);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    await _db.transaction((txn) async {
      await txn.delete('months');
      final batch = txn.batch();
      counts.forEach((month, n) => batch.insert('months', {'month': month, 'count': n}));
      await batch.commit(noResult: true);
    });
  }

  /// Стереть индекс и состояние синхронизации: следующий проход соберёт всё заново.
  Future<void> wipe() async {
    await _db.transaction((txn) async {
      await txn.delete('items');
      await txn.delete('months');
      await txn.delete('meta');
    });
  }

  // ---------- мета ----------

  /// Прочитать значение меты; `null` — ключа нет.
  Future<String?> meta(String key) async {
    final rows = await _db.query('meta', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  /// Записать значение меты.
  Future<void> setMeta(String key, String value) => _db.insert(
        'meta',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  // ---------- внутреннее ----------

  /// Страница из строк запроса: лишняя строка сверх [limit] — это признак продолжения.
  ///
  /// Сравнивать длину с `limit` нельзя: ровно полная страница не значит, что за ней что-то
  /// есть, и список показал бы «прокрутка кончилась» на живой ленте.
  MediaFeedPage _page(List<Map<String, Object?>> rows, int limit) => MediaFeedPage(
        items: rows.take(limit).map(_toItem).toList(),
        hasMore: rows.length > limit,
      );

  /// Строка таблицы из кадра ленты. Разбор ISO здесь один раз, а не на каждой сортировке.
  Map<String, Object?> _fromItem(MediaItem it) => {
        'entry_id': it.entryId,
        'sha256': it.sha256,
        'name': it.name,
        'mime': it.mime,
        // «Без даты» — отрицательный ключ: он меньше любого реального времени съёмки, поэтому
        // такие кадры оказываются в конце ленты, как и на сервере (NULLS LAST).
        'sort_key': (it.capturedAt == null ? null : DateTime.tryParse(it.capturedAt!)?.millisecondsSinceEpoch) ?? -1,
        'tz_offset_min': it.tzOffsetMin,
        'preview_state': it.previewState,
        'size_bytes': it.size,
        // Поколение ставится каждой строке: по нему полный проход в конце снимает то, чего
        // в ленте больше нет, не трогая свежие строки (см. `dropOtherGenerations`).
        'gen': _gen,
      };

  /// Кадр ленты из строки таблицы. Время собирается обратно в ISO-8601 UTC — тот же формат,
  /// что отдаёт сервер, чтобы просмотрщик и подписи не различали источник.
  MediaItem _toItem(Map<String, Object?> r) {
    final ms = (r['sort_key'] as int?) ?? -1;
    return MediaItem(
      entryId: r['entry_id'] as String,
      name: r['name'] as String,
      capturedAt: ms < 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String(),
      mime: r['mime'] as String,
      sha256: r['sha256'] as String?,
      previewState: r['preview_state'] as String,
      size: (r['size_bytes'] as int?) ?? 0,
      tzOffsetMin: r['tz_offset_min'] as int?,
    );
  }

  /// Ключ месяца «ГГГГ-ММ» для ключа сортировки; пустая строка — кадр без даты.
  String _monthKey(int sortKey, int tzOffsetMin) {
    if (sortKey < 0) return '';
    final shifted = DateTime.fromMillisecondsSinceEpoch(sortKey + tzOffsetMin * 60 * 1000, isUtc: true);
    final m = shifted.month.toString().padLeft(2, '0');
    return '${shifted.year}-$m';
  }

  /// Миллисекунды из ISO-строки курсора.
  ///
  /// Неразобранная дата — ошибка вызывающего (курсор приходит из наших же данных: кадра ленты
  /// или границы месяца), и молча подставить сюда 0 значило бы показать человеку не тот участок
  /// ленты, поэтому падаем громко.
  int _ms(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) throw ArgumentError('курсор ленты: не разобрана дата «$iso»');
    return dt.millisecondsSinceEpoch;
  }
}
