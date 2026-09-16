import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../api/cloudly_api.dart';
import '../../../api/models.dart';
import '../../../sync/net/sync_api.dart';
import 'gallery_store.dart';

/// Ход наполнения локального индекса галереи — для полосы прогрева в шапке раздела.
class GallerySyncProgress {
  /// Сколько кадров уже прочитано с сервера (не записано: часть могла совпасть).
  final int scanned;

  /// Сколько кадров в медиатеке, по данным `/media/months`.
  final int total;

  /// Проход продолжается прямо сейчас.
  final bool running;

  const GallerySyncProgress({required this.scanned, required this.total, required this.running});

  /// Доля прочитанного от 0 до 1; при неизвестном общем числе — 0.
  double get fraction => total > 0 ? (scanned / total).clamp(0.0, 1.0) : 0.0;
}

/// Синхронизация локального индекса галереи с сервером.
///
/// Три операции, по возрастанию цены:
///
///  * **верхняя страница** ([_refreshHead]) — один запрос `/media/feed` без курсора. Догоняет
///    свежие загрузки и обновляет состояние превью у самых новых кадров. Этого достаточно,
///    чтобы галерея совпадала с облаком по верхушке — а верхушку и видно при открытии раздела;
///  * **догон журнала** ([_applyChanges]) — читает `/sync/changes` от своего курсора и применяет
///    правки точечно: удаления снимаются сразу, изменившиеся кадры забираются одним запросом
///    ленты (`?ids=`). Журнал не несёт ни времени съёмки, ни состояния превью, поэтому
///    прежний список после каждой правки ходил за деталями кадра отдельным запросом, а кадр
///    без даты до конца прохода висел в хвосте;
///  * **наполнение индекса** ([_fillBackbone]) — читает ленту страницами до конца. Нужно один
///    раз (первый запуск, смена аккаунта) и после сброса журнала; проход продолжается между
///    открытиями раздела с того места, где остановился, поэтому галерея работает сразу,
///    а годы съёмки достраиваются фоном.
///
/// Чего здесь нет намеренно: сверки числа кадров на сервере с числом локальных строк. Прежний
/// список собирался заново при любом расхождении, а расхождение есть всегда — поэтому каждое
/// открытие раздела стоило десятков запросов. Состав ленты догоняется точечно, а не
/// перечитыванием целиком.
class GallerySync {
  GallerySync({
    required this.store,
    required this.apiOf,
    this.changesApiOf,
  });

  /// Локальный индекс галереи.
  final GalleryStore store;

  /// Клиент веб-сессии: им читаются лента, месяцы и детали кадра.
  final CloudlyApi Function() apiOf;

  /// Клиент синхронизации (device-токен) — только для журнала изменений. Без него журнала
  /// нет: свежие загрузки всё равно догоняет верхняя страница.
  final SyncApi? Function()? changesApiOf;

  /// Прогресс наполнения индекса; `null` — проход не идёт.
  final ValueNotifier<GallerySyncProgress?> progress = ValueNotifier(null);

  /// Сколько кадров просим одной страницей наполнения: серверный потолок `/media/feed`
  /// (`MEDIA_FEED_MAX = 1000`, src/media-feed/media-feed.service.ts).
  static const int _page = 1000;

  /// Сколько кадров берём верхней страницей: этого хватает, чтобы закрыть несколько экранов
  /// сетки, куда человек попадёт первым делом, и обновить состояние их превью.
  static const int _headPage = 300;

  /// Сколько страниц наполнения читаем за один заход.
  ///
  /// Сотня страниц — сто тысяч кадров: столько библиотека не наберёт, поэтому проход
  /// заканчивается за один заход, а не тянется открытиями по тридцать страниц (индикатор
  /// наполнения при этом выглядел вечной загрузкой). Галерея в это время уже работает:
  /// окно читается из индекса, а проход идёт фоном.
  static const int _pagesPerRun = 100;

  /// Сколько событий журнала берём за одну страницу: серверный потолок `/sync/changes`
  /// (`MAX_CHANGES = 500`, src/sync/sync.service.ts).
  static const int _changePage = 500;

  /// Сколько id можно спросить у ленты за раз: серверный потолок `?ids=`
  /// (`MEDIA_FEED_IDS_MAX = 500`).
  static const int _idsMax = 500;

  /// Не чаще раза в 15 секунд: раздел открывают и закрывают часто, а список за это время не
  /// меняется. Полное наполнение индекса под это правило не попадает — оно продолжается всегда,
  /// пока не закончится.
  static const Duration _guard = Duration(seconds: 15);

  /// Потолок страниц журнала за один догон: массовая операция даёт десятки тысяч событий,
  /// и без потолка догон превратился бы в бесконечный цикл.
  static const int _maxChangePages = 600;

  /// Проход уже идёт: параллельный запуск только дублировал бы запросы.
  bool _busy = false;

  /// Сверить индекс с сервером. Возвращает `true`, если локальный список изменился.
  ///
  /// Порядок важен: сначала верхняя страница и журнал (они дёшевы и дают актуальную верхушку),
  /// потом наполнение — оно самое долгое, и обрывать его ради двух дешёвых запросов незачем.
  /// Исключение — индекс пуст: пока он не начат, наполнение идёт первым, иначе галерея
  /// показала бы один экран новых кадров и не показала остального.
  ///
  /// Побочно: `progress`, счётчики наполнения, мета синхронизации и сам локальный список.
  Future<bool> sync() async {
    if (_busy) return false;
    _busy = true;
    try {
      return await _run();
    } finally {
      _busy = false;
    }
  }

  /// Продолжить наполнение индекса и дождаться его конца.
  ///
  /// Нужно после того, как индекс признан неполным по ходу листания: идущий проход мог уже
  /// считать его полным и сам наполнение не запустит (`sync` в этот момент только вернёт
  /// «занято»), поэтому сначала дожидаемся текущего прохода, а потом запускаем свой.
  Future<void> refill() async {
    for (var i = 0; i < 120 && _busy; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    await sync();
  }

  /// Тело прохода: то, что было в [sync] до появления [refill].
  Future<bool> _run() async {
    var changed = false;
    try {
      final last = DateTime.tryParse(await store.meta(GalleryStore.keySyncAt) ?? '');
      final now = DateTime.now().toUtc();
      final fresh = last != null && now.difference(last) < _guard;
      final complete = await store.meta(GalleryStore.keyBackboneDone) == '1';
      // Сторож не распространяется на незаконченное наполнение индекса: пока он неполон,
      // раздел умеет показать меньше, чем есть, и ждать 15 секунд ради этого незачем.
      if (fresh && complete) return false;
      await store.setMeta(GalleryStore.keySyncAt, now.toIso8601String());

      if (!complete) {
        // Индекс ещё собирается: продолжение прохода важнее всего остального — и верхнюю
        // страницу, и журнал этот же проход и читает.
        changed = await _fillBackbone() || changed;
      } else {
        changed = await _refreshHead() || changed;
        changed = await _applyChanges() || changed;
      }
      // Разбивка по месяцам пересобирается один раз за проход и только по полному индексу:
      // у неполного счётчики считались бы по части кадров, и шкала показывала бы не всю съёмку.
      final filledAll = await store.meta(GalleryStore.keyBackboneDone) == '1';
      if (filledAll && changed) {
        await store.rebuildMonths(tzOffsetMin: _tz());
      }
      return changed;
    } catch (e) {
      // Сбой синхронизации не должен ронять раздел: в индексе уже есть то, что показать,
      // а догон повторится при следующем открытии.
      if (kDebugMode) debugPrint('gallery sync error: $e');
      return changed;
    } finally {
      _busy = false;
      progress.value = null;
    }
  }

  /// Сбросить индекс и собрать его заново: журнал подрезан, курсор впереди журнала или
  /// перенесена папка целиком.
  ///
  /// Прежние строки НЕ стираются: галерея не должна пустеть, пока идёт перечитывание. Их снимет
  /// конец полного прохода ([GalleryStore.dropOtherGenerations]), а до тех пор окно показывает
  /// то, что уже было, — включая, возможно, кадр, которого в ленте больше нет.
  Future<void> _resetIndex() async {
    await store.beginGeneration();
    await store.setMeta(GalleryStore.keyBackboneCursor, '');
    await store.setMeta(GalleryStore.keyBackboneDone, '0');
  }

  /// Дочитать ленту страницами до конца — то, из чего состоит локальный индекс.
  ///
  /// Курсор прохода лежит в мете, поэтому проход продолжается с места остановки, сколько бы
  /// раз его ни прерывали. Когда датированные кадры кончаются, курсор переводится в хвост
  /// без даты (курсор без даты, см. `MediaCursor`) — иначе кадры без даты не попали бы в индекс
  /// никогда: в датированной части ленты их нет.
  ///
  /// Побочно: строки в `items`, курсор и флаг завершения в мете, `progress`.
  Future<bool> _fillBackbone() async {
    if (await store.meta(GalleryStore.keyBackboneDone) == '1') return false;
    final api = apiOf();
    final tz = _tz();
    // Разбивка по месяцам с сервера — сразу, до чтения кадров: шкала таймлайна рисуется из неё
    // и должна знать все годы съёмки с первого открытия раздела.
    var total = 0;
    try {
      final months = await api.mediaMonths(tzOffsetMin: tz);
      total = months.fold(0, (sum, m) => sum + m.count);
      await store.writeMonths(months);
    } catch (e) {
      // Месяцы не приехали — не повод не читать кадры: разбивка пересоберётся из них в конце.
      if (kDebugMode) debugPrint('gallery months error: $e');
    }

    var scanned = 0;
    var cursor = MediaCursor.decode(await store.meta(GalleryStore.keyBackboneCursor) ?? '');
    progress.value = GallerySyncProgress(scanned: 0, total: total, running: true);
    for (var page = 0; page < _pagesPerRun; page++) {
      final res = cursor == null ? await api.mediaFeed(limit: _page) : await api.mediaFeed(before: cursor, limit: _page);
      if (res.items.isEmpty) {
        // Лента кончилась (или пуста): проход дошёл до конца.
        await _finishBackbone();
        return true;
      }
      await store.upsertAll(res.items);
      scanned += res.items.length;
      cursor = MediaCursor.of(res.items.last);
      if (!res.hasMore) {
        if (cursor.at == null) {
          // Хвост без даты тоже дочитан — это и есть конец ленты.
          await _finishBackbone();
          return true;
        }
        // Датированная часть кончилась: дальше идёт хвост кадров без даты.
        cursor = const MediaCursor(at: null, id: '');
      }
      await store.setMeta(GalleryStore.keyBackboneCursor, cursor.encode());
      progress.value = GallerySyncProgress(scanned: scanned, total: total, running: true);
    }
    // Страницы за заход кончились — проход продолжится при следующем открытии раздела.
    return true;
  }

  /// Закрыть полный проход: снять призраков, отметить готовность и синхронизировать журнал.
  ///
  /// Курсор журнала берётся у его головы: всё, что случилось до этого момента, уже отражено
  /// в прочитанной ленте, и догонять эти события значило бы применять их второй раз.
  Future<void> _finishBackbone() async {
    await store.dropOtherGenerations();
    final head = await _head();
    if (head != null) await store.setMeta(GalleryStore.keyChangesCursor, '$head');
    await store.setMeta(GalleryStore.keyBackboneDone, '1');
    await store.setMeta(GalleryStore.keyBackboneCursor, '');
  }

  /// Забрать верхнюю страницу ленты: свежие загрузки и актуальные состояния превью.
  ///
  /// Страница кладётся поверх индекса по `entry_id`, поэтому повторный проход ничего не ломает
  /// и не требует ни сверки числа кадров, ни полного перечитывания.
  Future<bool> _refreshHead() async {
    final page = await apiOf().mediaFeed(limit: _headPage);
    if (page.items.isEmpty) return false;
    await store.upsertAll(page.items);
    return true;
  }

  /// Догнать журнал изменений от локального курсора.
  ///
  /// Что делается с каждой правкой:
  ///
  ///  * `delete` — строка снимается сразу: удаление не зависит ни от даты съёмки, ни от зоны;
  ///  * `create`, `update`, `move`, `restore` в зоне «Фото» — id собираются в пачку и
  ///    запрашиваются у ленты одним запросом (`?ids=`). Кто из них в ленте не нашёлся, тот из
  ///    медиатеки уехал — его строку снимаем: так перенос обрабатывается без перечитывания;
  ///  * правки в других зонах (`FILES`, `MAIL`) игнорируются: лента их не показывает, и заливка
  ///    обычного файла не должна тянуть работу по медиатеке;
  ///  * правки папок и `resetRequired` — пересборка индекса: перенос папки меняет состав ленты
  ///    целыми поддеревьями (отдельных событий по файлам журнал не даёт), а сброшенный курсор
  ///    означает, что часть изменений восстановить уже нельзя.
  Future<bool> _applyChanges() async {
    final changes = changesApiOf?.call();
    if (changes == null) return false;
    var since = int.tryParse(await store.meta(GalleryStore.keyChangesCursor) ?? '') ?? 0;
    final touched = <String>{};
    final gone = <String>{};
    for (var page = 0; page < _maxChangePages; page++) {
      final res = await changes.changes(since, limit: _changePage);
      if (res.resetRequired) {
        await _resetIndex();
        return true;
      }
      for (final c in res.changes) {
        if (c.target == 'folder') {
          await _resetIndex();
          return true;
        }
        if (c.op == 'delete') {
          gone.add(c.targetId);
        } else if (c.zone == 'PHOTOS') {
          touched.add(c.targetId);
        }
      }
      since = res.nextSeq;
      await store.setMeta(GalleryStore.keyChangesCursor, '$since');
      if (!res.hasMore) break;
    }
    await store.removeEntries(gone.toList());
    if (touched.isEmpty) return gone.isNotEmpty;
    // Спрошенное пачками: длина одной страницы ленты ограничена сервером.
    final items = <MediaItem>[];
    final ids = touched.toList();
    for (var i = 0; i < ids.length; i += _idsMax) {
      final page = await apiOf().mediaFeed(ids: ids.skip(i).take(_idsMax).toList());
      items.addAll(page.items);
    }
    final found = items.map((e) => e.entryId).toSet();
    await store.removeEntries(touched.where((id) => !found.contains(id)).toList());
    await store.upsertAll(items);
    return true;
  }

  /// Голова журнала или `null`, если журнала в этой сборке нет (нет device-токена).
  Future<int?> _head() async {
    final changes = changesApiOf?.call();
    if (changes == null) return null;
    try {
      return await changes.syncHead();
    } catch (e) {
      if (kDebugMode) debugPrint('gallery sync head: $e');
      return null;
    }
  }

  /// Сдвиг пояса устройства в минутах на восток: месяцы и границы месяцев считаются в поясе
  /// зрителя — так же, как их считает сервер (`/media/months?tz=`).
  int _tz() => DateTime.now().timeZoneOffset.inMinutes;
}
