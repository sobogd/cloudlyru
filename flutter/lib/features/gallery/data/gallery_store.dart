import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../../api/models.dart';

/// Локальный индекс галереи: кадры ленты и разбивка по месяцам.
///
/// ## Зачем своя база
///
/// Галерея — это десятки тысяч кадров, и ходить за каждым движением пальца в сеть значит
/// ждать сеть на каждом движении пальца. Поэтому кадры лежат на устройстве (база
/// `cloudly-gallery.db`): строки сетки читаются отсюда за единицы миллисекунд и работают без
/// сети, а с сервером список сверяется журналом изменений (см. `GallerySync`).
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
/// Отдельная таблица, а не запрос с `GROUP BY`: по ней строятся и шкала таймлайна, и геометрия
/// сетки на всю историю (`GalleryIndex`) — то есть при каждом открытии раздела, а агрегат по
/// десяткам тысяч строк на каждом открытии — лишняя работа. Пересобирается из `items` после
/// записи в список ([rebuildMonths]).
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
        // Порядок выборки — тот же, что на сервере: кадры месяца читаются окном по этому
        // порядку, и без индекса SQLite сортировал бы всю таблицу на каждую построенную строку
        // сетки (а строку за строкой она строится на каждом движении пальца).
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

  /// Кадры месяца [month] пачкой: [offset] — номер первого нужного кадра внутри месяца.
  ///
  /// Строки сетки адресуются месяцем и номером кадра в нём (см. `GalleryIndex`), поэтому
  /// выборка идёт окном ВНУТРИ месяца, а не курсором: сетке нужен именно этот кадр, а не
  /// «следующий за предыдущим». Окно отдаёт индекс `items_order` — сортировки таблицы нет.
  ///
  /// [tzOffsetMin] — пояс, в котором посчитаны ключи месяцев (тот же, что у `months` и у
  /// `rebuildMonths`): границы месяца берутся из ключа, и с другим поясом выборка ушла бы
  /// в соседний месяц на кадрах у его края.
  ///
  /// Пустая строка вместо месяца — хвост кадров без даты: они упорядочены по id записи,
  /// ровно как на сервере (`sort_key < 0` здесь, `capturedAt DESC NULLS LAST` там).
  Future<List<MediaItem>> monthItems(
    String month, {
    required int tzOffsetMin,
    required int offset,
    required int limit,
  }) async {
    final List<Map<String, Object?>> rows;
    if (month.isEmpty) {
      rows = await _db.rawQuery('''
        SELECT * FROM items
        WHERE sort_key < 0
        ORDER BY entry_id DESC
        LIMIT ? OFFSET ?
      ''', [limit, offset]);
    } else {
      rows = await _db.rawQuery('''
        SELECT * FROM items
        WHERE sort_key >= ? AND sort_key < ?
        ORDER BY sort_key DESC, entry_id DESC
        LIMIT ? OFFSET ?
      ''', [_monthStartMs(month, tzOffsetMin), _monthStartMs(_nextMonth(month), tzOffsetMin), limit, offset]);
    }
    return rows.map(_toItem).toList();
  }

  /// Все кадры индекса, разложенные по месяцам: ключ — «ГГГГ-ММ», пустая строка — кадры
  /// без даты.
  ///
  /// Читается страницами по [chunk] строк, а не одним запросом: пятьдесят шесть тысяч строк
  /// sqflite гонит через platform channel целиком, и промежуточный список карт (около килобайта
  /// на строку) дал бы десятки мегабайт мусора в тот момент, когда галерея уже держит сетку.
  /// Страницы идут по индексу `items_order` в порядке ленты, поэтому кадры и внутри месяца
  /// получаются от свежих к старым — ровно так же, как их отдаёт [monthItems].
  ///
  /// Побочно: ничего не пишет; вызывающий получает кадры (десятки мегабайт в памяти), поэтому
  /// зовётся это один раз при открытии раздела.
  Future<Map<String, List<MediaItem>>> allItemsByMonth({
    required int tzOffsetMin,
    int chunk = 2000,
  }) async {
    final out = <String, List<MediaItem>>{};
    for (var offset = 0;; offset += chunk) {
      final rows = await _db.rawQuery(
        'SELECT * FROM items ORDER BY sort_key DESC, entry_id DESC LIMIT ? OFFSET ?',
        [chunk, offset],
      );
      for (final r in rows) {
        final key = _monthKey((r['sort_key'] as int?) ?? -1, tzOffsetMin);
        (out[key] ??= <MediaItem>[]).add(_toItem(r));
      }
      if (rows.length < chunk) break;
    }
    return out;
  }

  /// Разбивка по месяцам в порядке ленты (от свежих), «без даты» — последней.
  ///
  /// Порядок строк здесь же и есть порядок блоков сетки: по нему `GalleryIndex` раскладывает
  /// строки, поэтому сортировка задана в запросе, а не повторяется вызывающим.
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

  /// Уменьшить счётчик месяца [month] на [by]: кадр удалён из индекса.
  ///
  /// Разбивка обязана следовать за кадром сразу: по ней считается геометрия сетки
  /// (`GalleryIndex`), и разошедшись, они показали бы под удалённым кадром пустую клетку
  /// до следующей синхронизации. Пустая строка — бакет кадров без даты.
  Future<void> decrementMonth(String month, {int by = 1}) async {
    await _db.rawUpdate('UPDATE months SET count = count - ? WHERE month = ?', [by, month]);
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

  /// Ряд таблицы из кадра ленты. Разбор ISO здесь один раз, а не на каждой сортировке.
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

  /// Момент начала месяца [month] в миллисекундах UTC для пояса [tzOffsetMin].
  ///
  /// Ключ месяца — «настенное» время пояса (см. [rebuildMonths]), поэтому граница это первое
  /// число месяца БЕЗ сдвига пояса минус сам сдвиг: так кадр, снятый в 00:30 первого числа
  /// по местному времени, попадает в свой месяц, а не в предыдущий.
  int _monthStartMs(String month, int tzOffsetMin) {
    final y = int.tryParse(month.substring(0, 4)) ?? 1970;
    final m = int.tryParse(month.substring(5, 7)) ?? 1;
    return DateTime.utc(y, m).millisecondsSinceEpoch - tzOffsetMin * 60 * 1000;
  }

  /// Ключ месяца, следующего за [month]: им задаётся верхняя граница выборки месяца.
  String _nextMonth(String month) {
    final y = int.tryParse(month.substring(0, 4)) ?? 1970;
    final m = int.tryParse(month.substring(5, 7)) ?? 1;
    return m == 12 ? '${y + 1}-01' : '$y-${(m + 1).toString().padLeft(2, '0')}';
  }
}
