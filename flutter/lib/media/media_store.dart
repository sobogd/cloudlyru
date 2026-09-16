import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../api/models.dart';

/// Локальный список ленты «Медиа»: база `cloudly-media.db`, одна таблица и мета.
///
/// ## Зачем своя база
///
/// Лента читается страницами `/media/range` (по 1000 кадров). При прокрутке это десятки
/// запросов, а при каждом открытии раздела — заново: сервер считает `count`, разбивку по
/// месяцам и отдаёт кадры, хотя состав медиатеки между открытиями почти не меняется. Список
/// на устройстве убирает эти запросы из пути открытия экрана: он читается локально (окно из
/// базы — единицы миллисекунд), а с сервером сверяется журналом изменений (см. `MediaFeedSync`).
///
/// Отдельная база, а не таблицы зеркала: у ленты свой курсор журнала и своя жизнь — её можно
/// стереть и залить заново, не задев состояние синхронизации файлов (и наоборот).
///
/// ## `media_items` — кадры ленты
///
///   • ключ: `entry_id` (id записи в дереве облака);
///   • `sort_key` — время съёмки в миллисекундах UTC, `-1` — «без даты». Целое, а не строка:
///     сортировка по нему совпадает с серверной (`capturedAt DESC NULLS LAST` — отрицательный
///     ключ уводит кадры без даты в конец), а месяцы считаются модификатором SQLite
///     `unixepoch` без разбора ISO, который к тому же понимают не все версии SQLite на Android.
///     Отдельная колонка вместо `captured_at_ms IS NULL` в сортировке нужна из-за плана
///     запроса: выражение в `ORDER BY` не даёт использовать индекс, и SQLite читал всю таблицу
///     с временной сортировкой на каждое окно ленты (проверено `EXPLAIN QUERY PLAN`:
///     `SCAN media_items` + `USE TEMP B-TREE FOR ORDER BY` против `SCAN ... USING INDEX media_order`);
///   • `preview_state` — «есть ли у кадра превью на сервере» (`done`/`none`/`impossible`),
///     обновляется опросом `/media/status`; по нему плитка решает, показывать картинку или иконку;
///   • `size_bytes` — размер содержимого (показывается в деталях кадра).
///
/// Папка кадра здесь не хранится намеренно: `/media/range` её не отдаёт, а перенос кадра (или
/// папки целиком) меняет состав ленты так, что надёжнее собрать её заново — этим и занимается
/// полный проход по журналу (см. `MediaFeedSync.syncChanges`).
///
/// ## `media_meta` — состояние синхронизации
///
///   • курсор журнала (`changes_cursor`) и время последней полной синхронизации; числа хранятся
///     текстом, разбор неудачного значения даёт 0, а не ошибку (как в состоянии зеркала).
class MediaFeedStore {
  MediaFeedStore._(this._db);

  final Database _db;

  /// Имя файла базы в папке баз приложения.
  static const String _name = 'cloudly-media.db';

  /// Версия схемы: 1 — `captured_at_ms` с NULL у кадров без даты, 2 — `sort_key` с -1.
  /// Поднимая версию, добавляй ветку в `onUpgrade`, которая только создаёт или добавляет:
  /// удалять данные здесь нельзя — иначе после обновления приложения список пришлось бы
  /// заливать заново (а он нужен офлайн).
  static const int _version = 2;

  /// Курсор журнала изменений: с какого `seq` продолжать догон. Отдельный от курсора зеркала —
  /// сервер курсоров не помнит, каждый потребитель ведёт свой.
  static const String keyCursor = 'changes_cursor';

  /// Когда список последний раз собирался целиком (ISO-8601 UTC).
  static const String keyFullSyncAt = 'full_sync_at';

  /// Открыть базу ленты, создав её при первом запуске.
  ///
  /// [directory] — папка для файла базы; по умолчанию системная папка баз приложения.
  /// Ошибку открытия не глушит: без списка лента осталась бы пустой, и это надо видеть.
  static Future<MediaFeedStore> open({String? directory}) async {
    final path = p.join(directory ?? await getDatabasesPath(), _name);
    final db = await openDatabase(
      path,
      version: _version,
      onCreate: (db, _) async {
        // Порядок выборки кадров — тот же, что на сервере (`capturedAt DESC NULLS LAST`,
        // затем id DESC): иначе лента после локальной вставки кадра «прыгала» бы относительно
        // серверного порядка, а индексы, по которым открывается просмотрщик, разъезжались.
        await db.execute('''
          CREATE TABLE media_items(
            entry_id TEXT PRIMARY KEY,
            sha256 TEXT,
            name TEXT NOT NULL,
            mime TEXT NOT NULL,
            sort_key INTEGER NOT NULL,
            tz_offset_min INTEGER,
            preview_state TEXT NOT NULL,
            size_bytes INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX media_order ON media_items(sort_key DESC, entry_id DESC)');
        // Неготовые превью ищутся точечно: их единицы процентов от библиотеки.
        await db.execute('CREATE INDEX media_preview ON media_items(preview_state)');
        // Миниатюры адресуются хэшем: по нему список отдаёт, какие кадры ещё не скачаны.
        await db.execute('CREATE INDEX media_sha ON media_items(sha256)');
        await db.execute('CREATE TABLE media_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)');
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) {
          // Прежняя колонка времени переезжает в `sort_key`: у кадров без даты было NULL,
          // теперь -1 (то же место в порядке ленты — в конце).
          await db.execute('ALTER TABLE media_items ADD COLUMN sort_key INTEGER NOT NULL DEFAULT -1');
          await db.execute('UPDATE media_items SET sort_key = COALESCE(captured_at_ms, -1)');
          await db.execute('DROP INDEX IF EXISTS media_order');
          await db.execute('CREATE INDEX IF NOT EXISTS media_order ON media_items(sort_key DESC, entry_id DESC)');
        }
      },
    );
    return MediaFeedStore._(db);
  }

  /// Сколько кадров в локальном списке.
  Future<int> count() async {
    final rows = await _db.rawQuery('SELECT count(*) AS n FROM media_items');
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Разбивка по месяцам в порядке ленты (от свежих), хвост «без даты» — последним.
  ///
  /// Считается локально тем же правилом, что на сервере: бакет месяца — это `capturedAt` плюс
  /// пояс зрителя ([tzOffsetMin]), иначе кадр, снятый вечером последнего числа, уезжает в
  /// следующий месяц. Модификатор `unixepoch` переводит миллисекунды в дату, а смещение
  /// задаётся строкой вида `+180 minutes`.
  Future<List<MediaMonthBucket>> months({int tzOffsetMin = 0}) async {
    final shift = '${tzOffsetMin >= 0 ? '+' : '-'}${tzOffsetMin.abs()} minutes';
    final rows = await _db.rawQuery('''
      SELECT CASE WHEN sort_key < 0 THEN NULL
                  ELSE strftime('%Y-%m', sort_key / 1000, 'unixepoch', ?) END AS month,
             count(*) AS c
      FROM media_items
      GROUP BY month
      ORDER BY month IS NULL, month DESC
    ''', [shift]);
    return rows
        .map((r) => MediaMonthBucket(month: r['month'] as String?, count: (r['c'] as int?) ?? 0))
        .toList();
  }

  /// Окно кадров ленты по абсолютному смещению — то же, что отдаёт `/media/range`.
  ///
  /// `OFFSET` здесь приемлем: список читается маленькими окнами (сотни строк), а индекс
  /// `media_order` позволяет SQLite идти по нему без полной сортировки. Ключевой набор
  /// (keyset) был бы быстрее на глубоких смещениях, но тогда окно нельзя запросить «с
  /// произвольного индекса», а лента адресует кадры именно индексами.
  Future<List<MediaItem>> range(int offset, int limit) async {
    final rows = await _db.rawQuery('''
      SELECT * FROM media_items
      ORDER BY sort_key DESC, entry_id DESC
      LIMIT ? OFFSET ?
    ''', [limit, offset]);
    return rows.map(_toItem).toList();
  }

  /// Полностью заменить список: старые строки уходят, приходят новые.
  ///
  /// Одной транзакцией: читатели видят либо прежний список, либо новый, но никогда — половину.
  /// Так делается первый проход и полная сверка; для одиночных правок есть [upsertAll].
  Future<void> replaceAll(List<MediaItem> items) async {
    await _db.transaction((txn) async {
      await txn.delete('media_items');
      await _insertAll(txn, items);
    });
  }

  /// Добавить или обновить перечисленные кадры (по `entry_id`).
  Future<void> upsertAll(List<MediaItem> items) async {
    if (items.isEmpty) return;
    await _db.transaction((txn) async => _insertAll(txn, items));
  }

  /// Удалить кадры из списка (файл удалён в облаке или ушёл из зоны «Фото»).
  Future<void> removeEntries(List<String> entryIds) async {
    if (entryIds.isEmpty) return;
    final batch = _db.batch();
    for (final id in entryIds) {
      batch.delete('media_items', where: 'entry_id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// Записать состояние превью для кадров, которые ещё не готовы.
  ///
  /// Опрос `/media/status` идёт по видимым плиткам, поэтому состояния обновляются пачкой:
  /// одна транзакция на пачку вместо запроса на кадр.
  Future<void> setPreviewStates(Map<String, String> states) async {
    if (states.isEmpty) return;
    await _db.transaction((txn) async {
      for (final e in states.entries) {
        await txn.update(
          'media_items',
          {'preview_state': e.value},
          where: 'entry_id = ?',
          whereArgs: [e.key],
        );
      }
    });
  }

  /// Кадры без даты съёмки.
  ///
  /// Их дата может появиться позже: сервер разбирает метаданные при сборке превью, и кадр,
  /// добавленный точечно сразу после заливки, приходит ещё без `capturedAt`. Такой кадр стоит
  /// в конце ленты (как и на сервере — `NULLS LAST`), поэтому без дозапроса он там и остаётся.
  Future<List<String>> entriesWithoutDate({int limit = 200}) async {
    final rows = await _db.query(
      'media_items',
      columns: ['entry_id'],
      where: 'sort_key < 0',
      limit: limit,
    );
    return rows.map((r) => r['entry_id'] as String).toList();
  }

  /// Сколько кадров ещё ждут собранного превью — по ним идёт опрос `/media/status`.
  Future<int> pendingPreviewCount() async {
    final rows = await _db.rawQuery(
      "SELECT count(*) AS n FROM media_items WHERE preview_state NOT IN ('done','impossible')",
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Прочитать значение из меты; `null` — ключа нет.
  Future<String?> meta(String key) async {
    final rows = await _db.query('media_meta', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  /// Записать значение в мету.
  Future<void> setMeta(String key, String value) => _db.insert(
        'media_meta',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  /// Стереть список и состояние синхронизации: следующий проход соберёт всё заново.
  Future<void> wipe() async {
    await _db.transaction((txn) async {
      await txn.delete('media_items');
      await txn.delete('media_meta');
    });
  }

  /// Вставить кадры пачками: одна вставка на сотни строк вместо запроса на каждую.
  Future<void> _insertAll(DatabaseExecutor txn, List<MediaItem> items) async {
    const chunk = 500;
    for (var i = 0; i < items.length; i += chunk) {
      final batch = txn.batch();
      for (final it in items.skip(i).take(chunk)) {
        batch.insert('media_items', _fromItem(it), conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    }
  }

  /// Строка таблицы из кадра ленты. Время съёмки — миллисекунды UTC: разбор ISO здесь один раз,
  /// а не на каждой сортировке.
  Map<String, Object?> _fromItem(MediaItem it) => {
        'entry_id': it.entryId,
        'sha256': it.sha256,
        'name': it.name,
        'mime': it.mime,
        // «Без даты» — отрицательный ключ: он меньше любой реальной даты съёмки, поэтому
        // такие кадры оказываются в конце ленты, как и на сервере (NULLS LAST).
        'sort_key': (it.capturedAt == null ? null : DateTime.tryParse(it.capturedAt!)?.millisecondsSinceEpoch) ?? -1,
        'tz_offset_min': it.tzOffsetMin,
        'preview_state': it.previewState,
        'size_bytes': it.size,
      };

  /// Кадр ленты из строки таблицы. Время собирается обратно в ISO-8601 UTC — тот же формат,
  /// что отдаёт сервер, чтобы просмотрщик и подписи не различали источник.
  MediaItem _toItem(Map<String, Object?> r) {
    final ms = r['sort_key'] as int?;
    final captured = (ms == null || ms < 0) ? null : ms;
    return MediaItem(
      entryId: r['entry_id'] as String,
      name: r['name'] as String,
      capturedAt: captured == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(captured, isUtc: true).toIso8601String(),
      mime: r['mime'] as String,
      sha256: r['sha256'] as String?,
      previewState: r['preview_state'] as String,
      jobState: null,
      size: (r['size_bytes'] as int?) ?? 0,
      tzOffsetMin: r['tz_offset_min'] as int?,
    );
  }
}
