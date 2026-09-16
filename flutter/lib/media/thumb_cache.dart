import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../api/cloudly_api.dart';
import 'thumb_store.dart';

/// Состояние очереди загрузки миниатюр — для панели прогрева и отчёта.
///
/// Значения — за время жизни объекта (сессию приложения): счётчики не сбрасываются при
/// открытии экрана, иначе прогресс «прыгал» бы при каждом заходе в настройки.
class ThumbQueueStats {
  /// Сколько миниатюр ждёт загрузки (включая фоновые, поставленные прогревом).
  final int queued;

  /// Сколько качается прямо сейчас (не больше [ThumbCache.concurrency]).
  final int running;

  /// Сколько записано с диска за сессию.
  final int done;

  /// Сколько не удалось скачать (сеть, ошибка сервера). Такие кадры остаются заглушкой
  /// и повторяются при следующем показе плитки.
  final int failed;

  /// Сколько раз сервер ответил 404: превью для файла нет (ещё не собрано, собрать нельзя).
  /// Такие кадры больше не спрашиваются до перезапуска приложения.
  final int missing;

  const ThumbQueueStats({
    required this.queued,
    required this.running,
    required this.done,
    required this.failed,
    required this.missing,
  });

  /// Ничего не происходит — стартовое состояние.
  static const ThumbQueueStats idle =
      ThumbQueueStats(queued: 0, running: 0, done: 0, failed: 0, missing: 0);

  /// Работа идёт: в очереди что-то есть или что-то качается.
  bool get busy => queued > 0 || running > 0;
}

/// Ход прогрева всей библиотеки (кнопка «Скачать все миниатюры»).
class ThumbWarmProgress {
  /// Сколько кадров ленты уже просмотрено (не скачано: часть могла быть на диске).
  final int scanned;

  /// Сколько кадров в ленте всего, по данным сервера.
  final int total;

  /// Прогрев продолжается прямо сейчас.
  final bool running;

  const ThumbWarmProgress({required this.scanned, required this.total, required this.running});

  /// Доля просмотренного от 0 до 1; при неизвестном общем числе — 0.
  double get fraction => total > 0 ? (scanned / total).clamp(0.0, 1.0) : 0.0;
}

/// Очередь загрузки миниатюр и прогрев библиотеки.
///
/// Зачем своя очередь, а не `CachedNetworkImage` у каждой плитки: миниатюры копятся в данных
/// приложения (см. [ThumbStore]), а не в кэш-каталоге, поэтому загрузку ведёт приложение.
/// Плюс одна очередь даёт то, чего не даёт загрузка «виджет за виджетом»: ограничение
/// параллелизма (сервер и канал не выдерживают сотни одновременных запросов), приоритет
/// видимого окна над фоновым прогревом и общий прогресс.
///
/// Дедупликация: один sha256 — одна загрузка. Две плитки с одинаковым содержимым (файл лежит
/// в двух папках) ждут один и тот же [Future], а не качают одно и то же дважды.
class ThumbCache {
  ThumbCache({
    required this.store,
    required this.apiOf,
    this.concurrency = 6,
  });

  /// Хранилище готовых миниатюр.
  final ThumbStore store;

  /// Текущий клиент API. Функцией, а не объектом: адрес сервера и сессия меняются в рантайме
  /// (вход, выход, смена сервера), а очередь при этом пересоздавать незачем.
  final CloudlyApi Function() apiOf;

  /// Сколько загрузок идёт одновременно.
  ///
  /// Шесть, а не четыре: миниатюра весит ~2 КБ, поэтому её время определяет не канал, а
  /// задержка круга (замер по логам сервера: при четырёх загрузках выходило ~1000 кадров в
  /// минуту, то есть упор был в параллелизм). Шесть при наблюдаемых ~130 мс на запрос дают
  /// около 2700 запросов в минуту — почти вдвое быстрее и всё ещё под серверным потолком
  /// (`/previews` — 3000 запросов в минуту на адрес, src/media/media.controller.ts). Выше
  /// поднимать нельзя: упрёмся в 429, и повторы съедят выигрыш.
  final int concurrency;

  /// Состояние очереди для интерфейса.
  final ValueNotifier<ThumbQueueStats> queue = ValueNotifier(ThumbQueueStats.idle);

  /// Прогресс прогрева библиотеки; `null` — прогрев не запускался в этой сессии.
  final ValueNotifier<ThumbWarmProgress?> warm = ValueNotifier(null);

  /// Приоритетная очередь: то, что человек видит сейчас.
  final List<String> _high = [];

  /// Фоновая очередь: прогрев библиотеки.
  final List<String> _low = [];

  /// Кто ждёт миниатюру: sha256 → ожидающий. Значение — и «в очереди», и «качается».
  final Map<String, Completer<void>> _waiting = {};

  /// Для чего сервер ответил 404: превью нет (не собрано, собрать нельзя, файл чужой).
  final Set<String> _missing = {};

  int _running = 0;
  int _done = 0;
  int _failed = 0;
  bool _warming = false;
  bool _stopped = false;

  /// Сколько страниц ленты просматривает прогрев за раз: серверный потолок одного
  /// `/media/range` (`MEDIA_RANGE_MAX = 1000`, src/media-feed/media-feed.service.ts).
  static const int _warmPage = 1000;

  /// Сколько загрузок прогрев держит в очереди. Больше — и десятки тысяч строк висят
  /// в памяти ради работы, которая всё равно идёт по нескольку загрузок за раз.
  static const int _warmBacklog = 400;

  /// Потолок фоновой очереди. Фоновые задачи ставит и прогрев библиотеки, и подгрузка окна
  /// ленты; при быстрой прокрутке очередь росла бы до десятков тысяч записей — это и память,
  /// и задержка для того кадра, который человек видит сейчас (фон обгонял бы его в очереди).
  /// Упершись в потолок, новые фоновые задачи не берём: нужный кадр попросит сам видимый
  /// ряд, а остальные подхватит следующий вызов.
  static const int _lowLimit = 300;

  /// Сколько раз пробовать одну миниатюру, прежде чем признать неудачу.
  static const int _attempts = 3;

  /// Готовая миниатюра на диске или `null`. Синхронный: вызывается из `build` плитки.
  File? file(String sha) => store.find(sha);

  /// Сервер ответил 404 — превью для этого файла нет. Плитка показывает заглушку и больше
  /// не спрашивает: 404 означает «не собрано» либо «собрать нельзя», и оба состояния
  /// меняются на сервере не от повторного запроса, а от работы очереди конвертации.
  bool isMissing(String sha) => _missing.contains(sha);

  /// Попросить миниатюру: вернётся, когда файл появится на диске (или станет ясно, что его
  /// не будет). Повторные вызовы для того же sha256 получают тот же [Future].
  ///
  /// [background] — фоновая загрузка (прогрев): она уступает место всему, что показывает
  /// человек, и не мешает кадру отрисоваться быстрее.
  Future<void> request(String sha, {bool background = false}) {
    if (sha.length < 2) return Future.value();
    if (file(sha) != null || _missing.contains(sha)) return Future.value();
    final existing = _waiting[sha];
    if (existing != null) return existing.future;
    // Фоновая задача сверх потолка не ставится: видимый кадр всё равно попросит себя сам,
    // а раздутая очередь фона только отодвигала бы его.
    if (background && _low.length >= _lowLimit) return Future.value();
    final completer = Completer<void>();
    _waiting[sha] = completer;
    (background ? _low : _high).add(sha);
    _publish();
    _pump();
    return completer.future;
  }

  /// Сколько миниатюр лежит на диске и сколько они занимают.
  Future<ThumbStats> stats() => store.stats();

  /// Стереть все миниатюры вместе с памятью о «превью нет»: после очистки кадры можно
  /// спрашивать заново — к этому моменту на сервере превью могло уже собраться.
  Future<void> clear() async {
    await store.clear();
    _missing.clear();
    _done = 0;
    _failed = 0;
    _publish();
  }

  /// Скачать миниатюры всей библиотеки.
  ///
  /// Идёт страницами `/media/range` — по тем же кадрам и в том же порядке, что и лента, —
  /// и ставит в фоновую очередь всё, у чего превью уже собрано (`previewState == 'done'`).
  /// Кадры с несобранным превью пропускаются: качать нечего, а миниатюра «на будущее» всё
  /// равно появится только после того, как сервер её соберёт.
  ///
  /// Повторный запуск после прерывания безопасен: уже скачанные кадры пропускаются по
  /// наличию файла (см. [request]), поэтому прогресс не теряется. Останавливается
  /// [stopWarm]; завершается, когда очередь опустеет.
  Future<void> warmLibrary() async {
    if (_warming) return;
    _warming = true;
    _stopped = false;
    var scanned = 0;
    var total = 0;
    try {
      final api = apiOf();
      total = await api.mediaCount();
      warm.value = ThumbWarmProgress(scanned: 0, total: total, running: true);
      for (var offset = 0; offset < total; offset += _warmPage) {
        if (_stopped) break;
        final page = await api.mediaRange(offset, _warmPage);
        if (page.isEmpty) break;
        for (final item in page) {
          final sha = item.sha256;
          if (sha == null || sha.isEmpty || item.previewState != 'done') continue;
          unawaited(request(sha, background: true));
        }
        scanned += page.length;
        warm.value = ThumbWarmProgress(scanned: scanned, total: total, running: true);
        // Придерживаем очередь: страницы идут быстрее, чем качаются миниатюры, и без этого
        // весь список оказался бы в памяти сразу.
        while (!_stopped && _waiting.length > _warmBacklog) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }
      // Дожидаемся конца очереди: иначе полоса прогресса исчезнет с ещё идущей загрузкой.
      while (!_stopped && (_running > 0 || _waiting.isNotEmpty)) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    } catch (e) {
      if (kDebugMode) debugPrint('warm thumbs error: $e');
    } finally {
      _warming = false;
      warm.value = ThumbWarmProgress(scanned: scanned, total: total, running: false);
    }
  }

  /// Выбросить фоновые задачи, которые больше не нужны.
  ///
  /// Так делает лента при смене окна: кадры, для которых стоял прогрев, уже уехали с экрана,
  /// и качать их — значит занимать канал и потоки впустую, пока видимые плитки ждут своей
  /// очереди. Начатые загрузки доигрываются (отменить запрос в середине нельзя), но новые из
  /// старого набора не берутся.
  void dropBackground() {
    if (_low.isEmpty) return;
    for (final sha in _low) {
      _waiting.remove(sha)?.complete();
    }
    _low.clear();
    _publish();
  }

  /// Остановить прогрев. Уже начатые загрузки доигрываются, очередь фоновых задач не берётся.
  void stopWarm() {
    _stopped = true;
  }

  /// Взять следующую задачу, если есть свободный слот.
  void _pump() {
    while (_running < concurrency) {
      final sha = _high.isNotEmpty
          ? _high.removeLast()
          : (_low.isNotEmpty ? _low.removeLast() : null);
      if (sha == null) break;
      _running++;
      unawaited(_download(sha));
    }
    _publish();
  }

  /// Скачать одну миниатюру с повторами.
  ///
  /// 404 не повторяется: «превью нет» — это ответ, а не сбой. Остальные ошибки (сеть,
  /// 5xx, 429) повторяются с растущей паузой: сервер мог быть занят пересборкой превью.
  Future<void> _download(String sha) async {
    var attempt = 0;
    while (true) {
      try {
        final bytes = await apiOf().previewBytes(sha);
        if (bytes.isEmpty) throw ApiException(0, 'empty_body', 'пустой ответ');
        await store.put(sha, bytes);
        _done++;
        break;
      } on ApiException catch (e) {
        if (e.status == 404) {
          _missing.add(sha);
          break;
        }
        attempt++;
        if (attempt >= _attempts || !e.retryable) {
          _failed++;
          break;
        }
        await Future.delayed(Duration(milliseconds: 400 * attempt));
      } catch (e) {
        attempt++;
        if (attempt >= _attempts) {
          _failed++;
          break;
        }
        await Future.delayed(Duration(milliseconds: 400 * attempt));
      }
    }
    _running--;
    _waiting.remove(sha)?.complete();
    _publish();
    _pump();
  }

  /// Отдать наружу текущее состояние очереди.
  void _publish() {
    queue.value = ThumbQueueStats(
      queued: _high.length + _low.length,
      running: _running,
      done: _done,
      failed: _failed,
      missing: _missing.length,
    );
  }
}
