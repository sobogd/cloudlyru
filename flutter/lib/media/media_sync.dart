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
///  * **полный проход** ([syncFull]) — страницами `/media/range` перечитывает всю медиатеку.
///    Нужен на первом запуске, после сброса журнала (`resetRequired`), при переносах кадров и
///    папок и когда изменений слишком много для точечных дозапросов. Стоит 60 запросов на
///    библиотеку в 60 тысяч кадров;
///  * **догон журнала** ([syncChanges]) — читает `/sync/changes` от своего курсора и применяет
///    изменения: удаления снимает точечно, а для новых кадров дозапрашивает метаданные по
///    одному (журнал не несёт времени съёмки и пояса, без них кадр не встанет на своё место).
///
/// Курсор свой, отдельный от курсора зеркала: сервер курсоров не помнит, и два потребителя
/// одного журнала не мешают друг другу (см. [MediaFeedStore.keyCursor]).
///
/// Журнал доступен только по device-токену (`/sync/*` — API для клиентов синхронизации),
/// поэтому [changesApiOf] может вернуть null: без токена список живёт как есть, а при
/// следующем запуске догон повторится.
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

  /// Сколько страниц журнала разбираем за один догон: предохранитель от бесконечного цикла,
  /// если сервер будет отдавать `hasMore` без движения курсора.
  static const int _maxChangePages = 200;

  /// Предел точечных дозапросов. Больше — дешевле перечитать ленту целиком (60 запросов против
  /// сотен), поэтому при массовой заливке сразу идёт полный проход.
  static const int _inlineLimit = 200;

  /// Проход уже идёт: повторный запуск не нужен (и не должен дублировать запросы).
  bool _busy = false;

  /// Синхронизировать список: пустой собирается целиком, остальное — догоном журнала.
  Future<void> sync() async {
    if (_busy) return;
    _busy = true;
    try {
      if (await store.count() == 0) {
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

  /// Полный проход: перечитать ленту страницами и заменить список.
  ///
  /// Курсор журнала берётся **до** прохода: изменения, случившиеся во время чтения страниц,
  /// останутся в журнале после этой отметки и будут догнаны следующим [syncChanges]. Иначе
  /// кадр, залитый ровно в момент прохода, потерялся бы до следующего полного чтения.
  Future<void> syncFull() async {
    final api = apiOf();
    final head = await _head();
    final total = await api.mediaCount();
    progress.value = MediaSyncProgress(scanned: 0, total: total, running: true);
    var scanned = 0;
    var first = true;
    try {
      for (var offset = 0; offset < total; offset += _page) {
        final page = await api.mediaRange(offset, _page);
        if (page.isEmpty) break;
        // Первая страница заменяет список целиком (так уходят кадры, удалённые, пока приложение
        // было закрыто), остальные добавляются: полная замена одних только первых страниц
        // оставила бы в базе хвост прошлого прохода.
        if (first) {
          await store.replaceAll(page);
          first = false;
        } else {
          await store.upsertAll(page);
        }
        scanned += page.length;
        progress.value = MediaSyncProgress(scanned: scanned, total: total, running: true);
        if (page.length < _page) break;
      }
      // Лента пуста: список тоже должен опустеть, иначе на экране остались бы прежние кадры.
      if (first) await store.replaceAll(const []);
      if (head != null) await store.setMeta(MediaFeedStore.keyCursor, '$head');
      await store.setMeta(MediaFeedStore.keyFullSyncAt, DateTime.now().toUtc().toIso8601String());
    } finally {
      progress.value = MediaSyncProgress(scanned: scanned, total: total, running: false);
    }
  }

  /// Догнать журнал изменений от локального курсора.
  ///
  /// Что делается с каждой правкой:
  ///
  ///  * `delete` — кадр снимается из списка точечно: удаление не зависит ни от даты съёмки,
  ///    ни от зоны, поэтому полный проход тут не нужен;
  ///  * `create`/`update` в зоне «Фото» — кадр дозапрашивается по id (`/media/:entryId`);
  ///    ручка сама отвечает 404, если кадр не в зоне «Фото» или не в дереве пользователя,
  ///    поэтому «дозапрос добавил лишнее» невозможно;
  ///  * `move`/`restore` и любые правки папок — полный проход: перенос меняет состав ленты
  ///    (кадр мог войти в зону «Фото» или выйти из неё), а по журналу это не видно;
  ///  * правки в других зонах (`FILES`, `MAIL`) игнорируются: лента их не показывает, и
  ///    заливка обычного файла не должна тянуть перечитывание медиатеки.
  Future<void> syncChanges() async {
    final changes = changesApiOf?.call();
    if (changes == null) return;
    var since = int.tryParse(await store.meta(MediaFeedStore.keyCursor) ?? '') ?? 0;
    final created = <String>{};
    var needFull = false;
    for (var page = 0; page < _maxChangePages; page++) {
      final res = await changes.changes(since);
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
            needFull = true;
            break;
          case 'create':
          case 'update':
            if (c.zone == 'PHOTOS') created.add(c.targetId);
            break;
        }
      }
      since = res.nextSeq;
      await store.setMeta(MediaFeedStore.keyCursor, '$since');
      if (!res.hasMore) break;
    }
    if (needFull) {
      await syncFull();
      return;
    }
    if (created.isEmpty) return;
    if (created.length > _inlineLimit) {
      await syncFull();
      return;
    }
    final items = <MediaItem>[];
    for (final id in created) {
      try {
        final info = await apiOf().mediaInfo(id);
        items.add(MediaItem(
          entryId: info.entryId,
          name: info.name,
          capturedAt: info.capturedAt,
          mime: info.mime,
          sha256: info.sha256,
          // Состояние превью журнал не несёт: ставим «ещё нет» и даём опросу `/media/status`
          // (он идёт по неготовым кадрам) подтянуть настоящее значение.
          previewState: 'none',
          size: info.size,
          tzOffsetMin: info.tzOffsetMin,
        ));
      } catch (e) {
        // Кадр мог уже уехать из зоны «Фото» или быть удалённым — тогда его в ленте и не надо;
        // остальное исправит следующий полный проход.
        if (kDebugMode) debugPrint('media sync info $id: $e');
      }
    }
    await store.upsertAll(items);
  }

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
