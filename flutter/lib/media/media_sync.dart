import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/cloudly_api.dart';
import '../api/models.dart';
import '../sync/net/sync_api.dart';
import 'media_store.dart';

/// Ход синхронизации локальной ленты — для индикатора на экране «Медиа».
class MediaSyncProgress {
  /// Сколько кадров уже прочитано с сервера (не записано: часть могла совпасть).
  final int scanned;

  /// Сколько кадров на сервере, по данным `/media/count`.
  final int total;

  /// Проход продолжается прямо сейчас.
  final bool running;

  const MediaSyncProgress({required this.scanned, required this.total, required this.running});

  /// Доля прочитанного от 0 до 1; при неизвестном общем числе — 0.
  double get fraction => total > 0 ? (scanned / total).clamp(0.0, 1.0) : 0.0;
}

/// Синхронизация локального списка ленты с сервером.
///
/// Две операции:
///
///  * **полный проход** ([syncFull]) — читает всю медиатеку страницами `/media/range` и
///    заменяет список. Нужен на первом запуске, после сброса журнала (`resetRequired`) и когда
///    изменений накопилось больше, чем разумно догонять по одному. Стоит 60 запросов на
///    библиотеку в 60 тысяч кадров;
///  * **догон журнала** ([syncChanges]) — читает `/sync/changes` от своего курсора и применяет
///    правки точечно: новые и перемещённые кадры дозапрашиваются по id, удаления снимаются без
///    запроса. Журнал не несёт времени съёмки и пояса, поэтому кадр, добавленный точечно,
///    приходит без даты — такие кадры добираются отдельным проходом ([_refreshMissingDates]),
///    когда сервер разберёт метаданные.
///
/// Про полный проход и перемещения: раньше любое `move` в зоне «Фото» заставляло перечитывать
/// ленту целиком, а переносов в журнале бывает десятки тысяч (массовая операция) — экран при
/// каждом открытии уходил в полный проход, список на это время усекался, и лента выглядела
/// «криво». Теперь `move` проверяется точечно, как и остальные правки: кадр либо есть в зоне
/// «Фото» (тогда он обновляется), либо его там нет (тогда строка снимается).
class MediaFeedSync {
  MediaFeedSync({
    required this.store,
    required this.apiOf,
    this.changesApiOf,
  });

  /// Локальный список ленты.
  final MediaFeedStore store;

  /// Клиент веб-сессии: им читаются лента, счётчик и детали кадра.
  final CloudlyApi Function() apiOf;

  /// Клиент синхронизации (device-токен) — только для журнала изменений.
  final SyncApi? Function()? changesApiOf;

  /// Прогресс прохода для индикатора; `null` — проход не идёт.
  final ValueNotifier<MediaSyncProgress?> progress = ValueNotifier(null);

  /// Сколько кадров просим одной страницей: серверный потолок `/media/range`
  /// (`MEDIA_RANGE_MAX = 1000`, src/media-feed/media-feed.service.ts).
  static const int _page = 1000;

  /// Сколько событий журнала берём за одну страницу: серверный потолок `/sync/changes`
  /// (`MAX_CHANGES = 500`, src/sync/sync.service.ts).
  static const int _changePage = 500;

  /// Потолок страниц журнала за один догон. Массовые операции (перенос всей медиатеки) дают
  /// десятки тысяч событий, и без потолка догон превратился бы в бесконечный цикл.
  static const int _maxChangePages = 600;

  /// Сколько правок догоняем точечно. Больше — дешевле перечитать ленту целиком (60 запросов
  /// против сотен), поэтому при массовой операции сразу идёт полный проход.
  static const int _inlineLimit = 300;

  /// Проход уже идёт: повторный запуск не нужен (и не должен дублировать запросы).
  bool _busy = false;

  /// Синхронизировать список: пустой собирается целиком, остальное — догоном журнала.
  Future<void> sync() async {
    if (_busy) return;
    _busy = true;
    try {
      final local = await store.count();
      if (local == 0) {
        await syncFull();
        return;
      }
      // Сверка числа кадров (один дешёвый запрос): если локально их меньше или больше, чем на
      // сервере, список собираем заново. Это страховка от оборванного прохода (в базе остаётся
      // часть строк) и от строк, переживших переезд кадров из медиатеки, — при расхождении
      // лента показывала бы внизу пустые клетки, а ползунок упирался бы раньше конца.
      if (await apiOf().mediaCount() != local) {
        await syncFull();
        return;
      }
      await syncChanges();
    } catch (e) {
      // Сбой синхронизации не должен ронять экран: локальный список уже есть, а догон
      // повторится при следующем открытии раздела.
      if (kDebugMode) debugPrint('media sync error: $e');
    } finally {
      _busy = false;
    }
  }

  /// Полный проход: перечитать ленту и заменить список.
  ///
  /// Все страницы собираются в память и записываются ОДНОЙ транзакцией. Раньше первая страница
  /// заменяла список, а остальные дописывались: оборванный проход (свернули приложение, сеть
  /// отвалилась) оставлял в базе усечённый список — лента выглядела короче, чем на сервере,
  /// а внизу показывала пустоту.
  ///
  /// Курсор журнала берётся **до** прохода: изменения, случившиеся во время чтения, останутся
  /// в журнале после этой отметки и будут догнаны следующим [syncChanges].
  Future<void> syncFull() async {
    final api = apiOf();
    final head = await _head();
    final total = await api.mediaCount();
    progress.value = MediaSyncProgress(scanned: 0, total: total, running: true);
    final all = <MediaItem>[];
    try {
      for (var offset = 0; offset < total; offset += _page) {
        final page = await api.mediaRange(offset, _page);
        if (page.isEmpty) break;
        all.addAll(page);
        progress.value = MediaSyncProgress(scanned: all.length, total: total, running: true);
        if (page.length < _page) break;
      }
      await store.replaceAll(all);
      if (head != null) await store.setMeta(MediaFeedStore.keyCursor, '$head');
      await store.setMeta(MediaFeedStore.keyFullSyncAt, DateTime.now().toUtc().toIso8601String());
    } finally {
      progress.value = MediaSyncProgress(scanned: all.length, total: total, running: false);
    }
  }

  /// Догнать журнал изменений от локального курсора.
  ///
  /// Что делается с каждой правкой:
  ///
  ///  * `delete` — строка снимается сразу: удаление не зависит ни от даты съёмки, ни от зоны;
  ///  * `create`, `update`, `move`, `restore` в зоне «Фото» — кадр дозапрашивается по id
  ///    (`/media/:entryId`). Эта ручка отвечает 404, если кадр не в зоне «Фото» или не в дереве
  ///    пользователя: значит он уехал из медиатеки — строка снимается. Так перенос обрабатывается
  ///    без перечитывания всей ленты;
  ///  * правки в других зонах (`FILES`, `MAIL`) игнорируются: лента их не показывает, и заливка
  ///    обычного файла не должна тянуть перечитывание медиатеки;
  ///  * правки папок и `resetRequired` — полный проход: перенос папки меняет состав ленты
  ///    целыми поддеревьями, а сброшенный курсор означает, что часть изменений уже не восстановить.
  Future<void> syncChanges() async {
    final changes = changesApiOf?.call();
    if (changes == null) {
      // Журнала нет (device-токен не выпущен или отозван): дельты взять неоткуда, но список
      // не должен замирать. Сверяемся по счётчику — он дешёвый, а расхождение означает, что
      // состав медиатеки изменился, и тогда список собирается заново.
      final onServer = await apiOf().mediaCount();
      if (onServer != await store.count()) await syncFull();
      return;
    }
    var since = int.tryParse(await store.meta(MediaFeedStore.keyCursor) ?? '') ?? 0;
    final touched = <String>{};
    var needFull = false;
    for (var page = 0; page < _maxChangePages; page++) {
      final res = await changes.changes(since, limit: _changePage);
      if (res.resetRequired) {
        // Журнал подрезан или курсор впереди него: часть правок восстановить нельзя,
        // поэтому список собирается заново — так советует и контракт ручки.
        await syncFull();
        return;
      }
      for (final c in res.changes) {
        if (c.target == 'folder') {
          needFull = true;
          continue;
        }
        switch (c.op) {
          case 'delete':
            await store.removeEntries([c.targetId]);
            break;
          case 'move':
          case 'restore':
          case 'create':
          case 'update':
            if (c.zone == 'PHOTOS') touched.add(c.targetId);
            break;
        }
      }
      since = res.nextSeq;
      await store.setMeta(MediaFeedStore.keyCursor, '$since');
      // Правок набралось больше, чем разумно догонять по одной: перечитать ленту дешевле, чем
      // сделать сотни точечных запросов. Полный проход заодно сдвинет курсор на голову журнала.
      if (touched.length > _inlineLimit) {
        await syncFull();
        return;
      }
      if (!res.hasMore) break;
    }
    // Журнал не догнан за отведённые страницы (так бывает после массовой операции, если её
    // события ещё не разобраны): список собираем целиком, иначе он останется неполным.
    if (needFull) {
      await syncFull();
      return;
    }
    if (touched.isNotEmpty) await _applyTouched(touched);
    await _refreshMissingDates();
  }

  /// Применить правки по перечисленным кадрам: обновить существующие, добавить новые, снять
  /// уехавшие из медиатеки.
  Future<void> _applyTouched(Set<String> ids) async {
    final items = <MediaItem>[];
    final gone = <String>[];
    for (final id in ids) {
      try {
        items.add(_fromInfo(await apiOf().mediaInfo(id)));
      } on ApiException catch (e) {
        // 404 — кадр больше не в зоне «Фото» (перенесли в «Файлы» или удалили): у себя его
        // тоже снимаем. Остальные ошибки не трогают список: следующий догон повторит.
        if (e.status == 404) gone.add(id);
      } catch (e) {
        if (kDebugMode) debugPrint('media sync info $id: $e');
      }
    }
    await store.removeEntries(gone);
    await store.upsertAll(items);
  }

  /// Дозапросить дату у кадров, которые лежат без неё.
  ///
  /// Кадр, добавленный точечно сразу после заливки, приходит без `capturedAt`: метаданные
  /// сервер разбирает при сборке превью. Такой кадр стоит в конце ленты, поэтому, когда разбор
  /// закончился, дату надо забрать — иначе он останется в «хвосте без даты» навсегда.
  ///
  /// Берём только кадры с готовым превью: у остальных метаданных ещё нет, и запрос был бы
  /// впустую. Их немного — это хвост недавних заливок, а не вся библиотека.
  Future<void> _refreshMissingDates() async {
    final ids = await store.entriesWithoutDate(limit: 200);
    if (ids.isEmpty) return;
    final fixed = <MediaItem>[];
    for (final id in ids) {
      try {
        final info = await apiOf().mediaInfo(id);
        if (info.capturedAt == null) continue;
        fixed.add(_fromInfo(info));
      } catch (e) {
        if (kDebugMode) debugPrint('media sync date $id: $e');
      }
    }
    await store.upsertAll(fixed);
  }

  /// Строка ленты из деталей кадра.
  ///
  /// Состояние превью детали не несут: для нового кадра ставим «ещё нет» — его подтянет опрос
  /// `/media/status`, который идёт по неготовым кадрам.
  MediaItem _fromInfo(MediaInfo info) => MediaItem(
        entryId: info.entryId,
        name: info.name,
        capturedAt: info.capturedAt,
        mime: info.mime,
        sha256: info.sha256,
        previewState: 'none',
        size: info.size,
        tzOffsetMin: info.tzOffsetMin,
      );

  /// Голова журнала или null, если журнала в этой сборке нет (нет device-токена).
  Future<int?> _head() async {
    final changes = changesApiOf?.call();
    if (changes == null) return null;
    try {
      return await changes.syncHead();
    } catch (e) {
      if (kDebugMode) debugPrint('media sync head: $e');
      return null;
    }
  }
}
