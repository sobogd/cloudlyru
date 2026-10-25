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
  /// Сколько миниатюр ждёт загрузки (включая фоновые).
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

/// Очередь загрузки миниатюр для раздела «Файлы».
///
/// Зачем своя очередь, а не `CachedNetworkImage` у каждой плитки: миниатюры копятся в данных
/// приложения (см. [ThumbStore]), а не в кэш-каталоге, поэтому загрузку ведёт приложение.
/// Плюс одна очередь даёт то, чего не даёт загрузка «виджет за виджетом»: ограничение
/// параллелизма (сервер и канал не выдерживают сотни одновременных запросов) и общий
/// прогресс.
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

  /// Приоритетная очередь: то, что человек видит сейчас.
  final List<String> _high = [];

  /// Фоновая очередь: миниатюры, которые пока не в окне, но скоро будут.
  final List<String> _low = [];

  /// Кто ждёт миниатюру: sha256 → ожидающий. Значение — и «в очереди», и «качается».
  final Map<String, Completer<void>> _waiting = {};

  /// Для чего сервер ответил 404: превью нет (не собрано, собрать нельзя, файл чужой).
  final Set<String> _missing = {};

  int _running = 0;
  int _done = 0;
  int _failed = 0;

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
  /// [background] — фоновая загрузка: уступает место тому, что человек видит сейчас, и не
  /// мешает кадру отрисоваться быстрее.
  Future<void> request(String sha, {bool background = false}) {
    if (sha.length < 2) return Future.value();
    if (file(sha) != null || _missing.contains(sha)) return Future.value();
    final existing = _waiting[sha];
    if (existing != null) return existing.future;
    // Повторную просьбу не ставим дважды: ожидающий уже в очереди.
    final completer = Completer<void>();
    _waiting[sha] = completer;
    (background ? _low : _high).add(sha);
    _publish();
    _pump();
    return completer.future;
  }

  /// Сколько миниатюр лежит на диске и сколько они занимают.
  Future<ThumbStats> stats() => store.stats();

  /// Взять следующую задачу, если есть свободный слот.
  ///
  /// Сначала — видимые миниатюры (_high): они уступают место фону, пока человек на них смотрит.
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
        if (_done % 25 == 0) {
          debugPrint('cloudly-thumb: скачано $_done, в очереди ${_high.length + _low.length}, слотов занято $_running');
        }
        break;
      } on ApiException catch (e) {
        if (e.status != 404) debugPrint('cloudly-thumb: ошибка ${sha.substring(0, 8)} — ${e.status} ${e.code}');
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
