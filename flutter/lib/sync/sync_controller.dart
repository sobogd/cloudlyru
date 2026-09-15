import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/cloudly_api.dart';
import 'background/background_schedule.dart';
import 'data/mirror_store.dart';
import 'data/queue_store.dart';
import 'data/selection.dart';
import 'data/sync_prefs.dart';
import 'device/device_files.dart';
import 'device/native_fs.dart';
import 'mirror/mirror_engine.dart';
import 'mirror/mirror_live.dart';
import 'mirror/mirror_status.dart';
import 'mirror/mirror_watcher.dart';
import 'net/device_token.dart';
import 'net/sync_api.dart';
import 'queue/queue_builder.dart';
import 'queue/queue_refresher.dart';
import 'queue/upload_runner.dart';
import 'section.dart';

/// Состояние синхронизации для интерфейса: доступ к файлам, статус зеркала, очередь.
enum SyncAccess { unknown, granted, denied }

/// Одна точка сборки всего синхронизатора: базы, выбор папок, движок зеркала, очередь,
/// мгновенный режим. Интерфейс говорит только с ней — ни баз, ни сетевого клиента он не знает.
///
/// Токен устройства берётся у сессии: корень зеркала сервер заводит именно устройству, а
/// веб-сессия его не получает вовсе (см. [ensureDeviceToken]).
class SyncController extends ChangeNotifier {
  SyncController({NativeFs? native, DeviceTokenStore? tokens})
    : native = native ?? NativeFs(),
      _tokens = tokens ?? DeviceTokenStore() {
    _watcher = MirrorWatcher(this.native);
    _status = MirrorStatusHolder();
    _status.stream.listen((s) {
      mirrorStatus = s;
      notifyListeners();
    });
  }

  final NativeFs native;
  final DeviceTokenStore _tokens;

  late final MirrorWatcher _watcher;
  late final MirrorStatusHolder _status;

  SharedPreferences? _prefs;
  SyncPrefs? syncPrefs;
  Selection? selection;
  QueueStore? queueStore;
  MirrorStore? mirrorStore;
  SyncApi? _api;

  /// Сессия и логин, которыми выпускается токен устройства: нужны, чтобы повторить попытку
  /// после отказа, не дожидаясь перезапуска приложения.
  CloudlyApi? _sessionApi;
  String _login = '';
  MirrorEngine? engine;
  MirrorLive? live;
  UploadRunner? uploads;

  /// Состояние зеркала: одно на всё приложение, чтобы раздел «Файлы» и настройки не показывали
  /// разное.
  MirrorStatus mirrorStatus = const MirrorStatus();

  SyncAccess access = SyncAccess.unknown;

  /// Что делает синхронизатор прямо сейчас: «обновляю очередь», «выгружаю файл».
  String? activity;

  /// Сколько строк ждёт выгрузки: по этому числу живёт кнопка на вкладке «Очередь».
  int waiting = 0;

  /// Последний итог наполнения очереди.
  String? queueNote;

  /// Устройство: так называется корень зеркала в облаке.
  String deviceLabel = 'Android';

  /// Индекс вкладки синхронизации, к которой надо перейти (например, из раздела «Файлы»).
  int? requestedTab;

  bool _started = false;
  int _sessionEpoch = 0;

  /// Экран приложения на переднем плане: от этого зависит частота опроса журнала.
  bool foreground = true;

  bool get ready => _prefs != null;

  /// Нужно ли просить доступ ко всем файлам: без него не видно ни дерева, ни содержимого.
  bool get needsAccess => access == SyncAccess.denied;

  /// Корень зеркала этого устройства в облаке. По нему «Файлы» помечают папку, которая
  /// синхронизируется: имя у неё ничем не отличается от обычной, а перепутать её с обычной
  /// папкой — значит удалить или переименовать корень, на который смотрит зеркало.
  String get mirrorRootId => syncPrefs?.mirrorFolderId ?? '';

  /// Запуск: открыть базы, прочитать выбор папок, проверить доступ, поднять мгновенный режим.
  ///
  /// Вызывается при входе в аккаунт и при старте приложения, если сессия уже есть.
  Future<void> start(CloudlyApi sessionApi, String login) async {
    if (_started) return;
    _started = true;
    final epoch = ++_sessionEpoch;
    try {
      _prefs = await SharedPreferences.getInstance();
      syncPrefs = SyncPrefs(_prefs!);
      selection = Selection(_prefs!);
      // Доступ и метка устройства — до баз: если база почему-то не откроется, человек всё равно
      // должен видеть, выдан ли доступ, а не «проверяю доступ к файлам…» навсегда
      deviceLabel = await native.deviceLabel();
      access = await native.hasAllFilesAccess()
          ? SyncAccess.granted
          : SyncAccess.denied;

      // Базы открываем по одной: поломка одной не должна отменять всё остальное. Так уже было —
      // не открылась база, и вместе с ней «не поставилось» наблюдение и «не запускалось» зеркало
      queueStore = await _openQueueStore();
      mirrorStore = await _openMirrorStore();
      // Выключателя синхронизации нет: она всегда включена — в этом её смысл. Флаг в базе
      // мог остаться от прежних сборок, поэтому снимаем его, иначе синхронизация молчала бы
      // без всякой возможности её вернуть.
      await mirrorStore?.clearMeta(MirrorStore.keyPaused);

      await _bindToken(sessionApi, login, epoch);
      // Проход зеркала, когда приложения нет на экране: задание живёт в системе, а не в этом
      // процессе (см. lib/sync/background/)
      await BackgroundSync.register(
        serverUrl: sessionApi.serverUrl,
        login: login,
      );

      final store = mirrorStore;
      final sel = selection;
      if (store != null && sel != null) {
        engine = MirrorEngine(
          () => _requireApi(),
          store,
          sel,
          status: _status,
          native: native,
        );
        // Что было в прошлый раз: без этого после перезапуска карточка говорит «зеркало ещё
        // не запускалось», хотя проходы шли — в том числе в фоне
        await _restoreLastState(store);
      }
      final queue = queueStore;
      if (_api != null && queue != null && engine != null) {
        uploads = UploadRunner(_api!, queue);
        final liveMode = MirrorLive(store!, engine!, _status, _watcher, native);
        liveMode.hasToken = () => _api != null;
        liveMode.foreground = () => foreground;
        liveMode.bindWatcher();
        liveMode.start();
        live = liveMode;
      }

      if (_api != null) await _rememberSystemFolders(_api!);
      notifyListeners();
      // Синхронизация не должна ждать, пока её попросят: проверяем себя сразу после старта
      unawaited(checkAndResume());
    } catch (e) {
      debugPrint('cloudly-sync: старт синхронизации не удался: $e');
      activity = 'синхронизация недоступна: $e';
      notifyListeners();
    }
  }

  /// База очереди: своя попытка и свой отчёт об ошибке — из-за неё одной синхронизация
  /// не должна пропадать целиком.
  Future<QueueStore?> _openQueueStore() async {
    try {
      final store = await QueueStore.open();
      // после перезапуска ничего не может быть «в работе»: строки, застрявшие в RUNNING,
      // возвращаем в ожидание, иначе кнопка «play» на них не появится уже никогда
      await store.resetRunning();
      return store;
    } catch (e) {
      debugPrint('cloudly-sync: база очереди не открылась: $e');
      queueNote = 'база очереди не открылась: $e';
      return null;
    }
  }

  Future<MirrorStore?> _openMirrorStore() async {
    try {
      return await MirrorStore.open();
    } catch (e) {
      debugPrint('cloudly-sync: база зеркала не открылась: $e');
      activity = 'база зеркала не открылась: $e';
      return null;
    }
  }

  /// Состояние зеркала из базы: итоги обхода, что уже в облаке, последний отчёт и
  /// приостановленные удаления. Иначе после перезапуска приложение выглядит так, будто
  /// синхронизация никогда не работала.
  Future<void> _restoreLastState(MirrorStore store) async {
    try {
      final inCloud = await store.inCloud();
      final local = await store.localTotals();
      final waiting = await store.waitingTotals();
      final report = await store.meta(MirrorStore.keyReport) ?? '';
      final blockedRaw = await store.meta(MirrorStore.keyBlocked);
      var blocked = 0;
      String? blockedReason;
      if (blockedRaw != null && blockedRaw.isNotEmpty) {
        final parts = blockedRaw.split('|');
        blocked = int.tryParse(parts.first) ?? 0;
        if (parts.length > 1) blockedReason = parts.sublist(1).join('|');
      }
      _status.update(
        (s) => s.copyWith(
          inCloudFiles: inCloud.files,
          inCloudBytes: inCloud.bytes,
          localFiles: local.files,
          localBytes: local.bytes,
          waitingFiles: waiting.files,
          waitingBytes: waiting.bytes,
          lastText: report,
          blocked: blocked,
          blockedReason: blockedReason,
        ),
      );
    } catch (e) {
      debugPrint('cloudly-sync: состояние зеркала не прочитано: $e');
    }
  }

  /// Догнать то, что не получилось при старте.
  ///
  /// Токен устройства выпускается один раз, и отказ бывает временным: сеть, разблокировка
  /// хранилища, лимит живых токенов на сервере. Без повторной попытки приложение оставалось бы
  /// мёртвым до перезапуска, а человек видел бы только «нет токена» без причины.
  Future<bool> ensureReady() async {
    if (_api != null) return true;
    final sessionApi = _sessionApi;
    if (sessionApi == null) return false;
    await _bindToken(sessionApi, _login, _sessionEpoch);
    final api = _api;
    if (api == null) {
      notifyListeners();
      return false;
    }
    await _rememberSystemFolders(api);
    final queue = queueStore;
    if (queue != null) uploads ??= UploadRunner(api, queue);
    if (engine != null && live == null) {
      final liveMode = MirrorLive(
        mirrorStore!,
        engine!,
        _status,
        _watcher,
        native,
      );
      liveMode.hasToken = () => _api != null;
      liveMode.foreground = () => foreground;
      liveMode.bindWatcher();
      liveMode.start();
      live = liveMode;
    }
    notifyListeners();
    return true;
  }

  /// Запомнить системные папки сервера — прежде всего корень зеркала. Спрашиваем один раз
  /// при запуске: без него «Файлы» не отличат синхронизируемую папку от обычной.
  Future<void> _rememberSystemFolders(SyncApi api) async {
    final prefs = syncPrefs;
    if (prefs == null) return;
    try {
      final me = await api.systemFolders();
      final mirror = me.mirrorFolderId;
      if (mirror != null && mirror.isNotEmpty) {
        await prefs.setMirrorFolderId(mirror);
      }
      final photo = me.photoFolderId;
      if (photo != null && photo.isNotEmpty) {
        await prefs.setPhotoFolderId(photo);
      }
      final phone = me.phoneFolderId;
      if (phone != null && phone.isNotEmpty) {
        await prefs.setPhoneFolderId(phone);
      }
      notifyListeners();
    } catch (e) {
      // папки придут и позже — например, при наполнении очереди; ронять из-за них старт незачем
      debugPrint('cloudly-sync: системные папки не спрошены: $e');
    }
  }

  /// Токен устройства: свой у каждого устройства, поэтому корень зеркала в облаке не делится
  /// между телефонами.
  Future<void> _bindToken(
    CloudlyApi sessionApi,
    String login,
    int epoch,
  ) async {
    _sessionApi = sessionApi;
    _login = login;
    try {
      final token = await ensureDeviceToken(
        session: sessionApi,
        store: _tokens,
        serverUrl: sessionApi.serverUrl,
        login: login,
        label: deviceLabel,
      );
      if (epoch != _sessionEpoch) return;
      _api = SyncApi(serverUrl: sessionApi.serverUrl, token: token.token);
      tokenError = null;
    } catch (e) {
      _api = null;
      tokenError = _tokenProblem(e);
      // Без строки в логе причину отказа на телефоне искать негде: в интерфейсе видно только
      // «нет токена», а подробность сервера приходит именно здесь
      debugPrint('cloudly-sync: $tokenError');
    }
  }

  /// Отказ выпуска токена словами. Сервер отвечает понятным текстом (в том числе про лимит
  /// живых токенов), поэтому его сообщение и показываем — но с подсказкой, что с этим делать.
  String _tokenProblem(Object e) {
    final text = 'токен устройства не выпущен: $e';
    if (e is ApiException &&
        (e.status == 400 || e.status == 401 || e.status == 403)) {
      return '$text · проверьте «Токены приложений»: ненужные лучше отозвать';
    }
    return text;
  }

  /// Выход из аккаунта: токен отзывается на сервере, иначе он остаётся живым до истечения срока
  /// и даёт полный доступ к облаку мимо приложения.
  Future<void> signOut() async {
    try {
      await _api?.revokeOwnToken();
    } catch (_) {}
    // Задание снимаем: без токена оно всё равно ничего не делает, но будить приложение зря
    // после выхода из аккаунта незачем
    await BackgroundSync.cancel();
    await live?.dispose();
    _api = null;
    _sessionApi = null;
    _login = '';
    tokenError = null;
    _started = false;
    _sessionEpoch++;
    await queueStore?.close();
    await mirrorStore?.close();
    queueStore = null;
    mirrorStore = null;
    _prefs = null;
    syncPrefs = null;
    selection = null;
    engine = null;
    uploads = null;
    live = null;
    mirrorStatus = const MirrorStatus();
    waiting = 0;
    notifyListeners();
  }

  /// Что не вышло с токеном устройства: показывается в настройках, пока не получится.
  String? tokenError;

  SyncApi _requireApi() {
    final api = _api;
    if (api == null) {
      final why = tokenError;
      throw StateError(
        why == null ? 'нет токена устройства' : 'нет токена устройства: $why',
      );
    }
    return api;
  }

  DeviceFiles get files => DeviceFiles(native: native);

  /// Попросить доступ ко всем файлам: открывается системный экран, разрешение выдаётся там.
  Future<void> requestAccess() async {
    await native.openAllFilesSettings();
  }

  /// Проверить доступ после возвращения из системных настроек.
  Future<void> recheckAccess() async {
    access = await native.hasAllFilesAccess()
        ? SyncAccess.granted
        : SyncAccess.denied;
    if (access == SyncAccess.granted) {
      await startWatching();
      await refreshQueue();
    }
    notifyListeners();
  }

  /// Выбор папок изменился: пересобираем наблюдение и наполняем очередь заново.
  Future<void> onSelectionChanged(Section section) async {
    await startWatching();
    await refreshQueue();
  }

  Future<void> startWatching() async {
    final store = mirrorStore;
    final sel = selection;
    if (store == null || sel == null) return;
    try {
      await _watcher.watch(sel, store);
    } catch (_) {
      // наблюдение — только ускоритель: без него остаётся периодический проход
    }
    notifyListeners();
  }

  /// Число папок, взятых под наблюдение: 0 — система не дала, работает только периодика.
  int get watchedDirs => _watcher.watchedDirs;

  /// Сколько ждём, прежде чем считать, что синхронизация встала. Проход зеркала ограничен
  /// бюджетом времени, и если он не закончился сам, его надо догнать.
  static const int _stalePassMs = 10 * 60 * 1000;

  /// Сколько файлов очереди выгружаем за одну проверку: остальное — следующим заходом.
  static const int _drainPerCheck = 20;

  bool _resuming = false;

  /// Проверить, что синхронизация идёт, и догнать её, если встала.
  ///
  /// Встать она может по-разному: кончился бюджет времени (выгрузка гигабайтов идёт часами),
  /// пропала сеть, система прибила фоновое задание, отвалилось наблюдение за папками. Кнопки
  /// «продолжить» в разделе нет намеренно, поэтому проверка делается сама — при старте
  /// приложения и при каждом открытии раздела синхронизации.
  Future<void> checkAndResume() async {
    if (_resuming) return;
    _resuming = true;
    activity = 'проверяю, не встала ли синхронизация…';
    notifyListeners();
    try {
      if (_api == null && !await ensureReady()) return;
      await refreshQueue();
      // наблюдение могло не встать при старте или отвалиться после перезагрузки системы
      await startWatching();

      final status = mirrorStatus;
      final hasFolders = (selection?.paths(Section.files).isNotEmpty ?? false);
      final finished = status.finishedAt;
      final stale =
          finished == 0 ||
          DateTime.now().millisecondsSinceEpoch - finished > _stalePassMs;
      if (hasFolders && !status.busy && (status.waitingFiles > 0 || stale)) {
        await mirrorPass();
      }
      await _drainQueue();
    } finally {
      _resuming = false;
      activity = null;
      waiting = await queueStore?.waitingCount() ?? waiting;
      notifyListeners();
    }
  }

  /// Выгрузить ждущее из очереди — без кнопки. Очередь «Фото» наполняется сама, а кнопок
  /// «начать» в разделе больше нет: если файл ждёт выгрузки, он должен уехать сам.
  Future<void> _drainQueue() async {
    final store = queueStore;
    if (store == null || uploads == null) return;
    // Каждую строку в этой проверке пробуем один раз: иначе упавший файл крутился бы вечно
    final tried = <int>{};
    for (var done = 0; done < _drainPerCheck; done++) {
      QueueItem? next;
      for (final item in await store.items()) {
        if (tried.contains(item.id)) continue;
        if (item.state == QueueState.pending ||
            item.state == QueueState.failed) {
          next = item;
          break;
        }
      }
      if (next == null) return;
      tried.add(next.id);
      await uploadItem(next.id);
    }
  }

  /// Наполнить очередь: пройти выбранные папки и поставить новое. Ничего не выгружает.
  Future<QueueBuildResult?> refreshQueue() async {
    final store = queueStore;
    final sel = selection;
    final prefs = syncPrefs;
    if (store == null || sel == null || prefs == null) return null;
    // Токен мог не выпуститься при старте (сеть, лимит живых токенов): без повторной попытки
    // кнопка «Обновить» молча ничего бы не делала
    if (_api == null && !await ensureReady()) {
      queueNote = tokenError ?? 'нет токена устройства';
      notifyListeners();
      return null;
    }
    activity = 'прохожу папки…';
    notifyListeners();
    try {
      final refresher = QueueRefresher(() => _api, prefs, sel, store, files);
      final result = await refresher.refresh(
        onProgress: (m) {
          activity = m;
          notifyListeners();
        },
      );
      queueNote = result.text();
      waiting = await store.waitingCount();
      return result;
    } catch (e) {
      queueNote = 'не удалось пройти папки: $e';
      return null;
    } finally {
      activity = null;
      notifyListeners();
    }
  }

  /// Выгрузить один файл из очереди: запускается вручную, кнопкой на строке.
  Future<void> uploadItem(
    int itemId, {
    void Function(UploadProgress)? onProgress,
  }) async {
    if (_api == null && !await ensureReady()) {
      queueNote = tokenError ?? 'нет токена устройства';
      notifyListeners();
      return;
    }
    final runner = uploads;
    if (runner == null) return;
    activity = 'выгружаю…';
    notifyListeners();
    try {
      await runner.run(itemId, onProgress: onProgress);
    } catch (e) {
      queueNote = 'выгрузка не удалась: $e';
    } finally {
      activity = null;
      waiting = await queueStore!.waitingCount();
      notifyListeners();
    }
  }

  /// Ручная сверка зеркала: работает и когда автоматика выключена.
  Future<MirrorReport?> mirrorPass() async {
    final e = engine;
    if (e == null) return null;
    // Сверить сейчас имеет смысл и после отказа выпустить токен: причина часто временная,
    // и повторная попытка тут же даёт ответ — либо проход, либо внятную ошибку
    if (_api == null && !await ensureReady()) {
      return MirrorReport()..error = tokenError ?? 'нет токена устройства';
    }
    activity = 'сверяю…';
    notifyListeners();
    try {
      final report = await e.pass(
        onProgress: (m) {
          activity = m;
          notifyListeners();
        },
      );
      // Токен устройства отозвали (в вебе или на другом устройстве): пока он лежит в клиенте,
      // каждый проход будет упираться в 401. Признаём его негодным, чтобы ближайшая проверка
      // выпустила новый и синхронизация вернулась сама, без переустановки приложения.
      final error = report.error;
      if (error != null && error.contains('токен отозван')) {
        _api = null;
        tokenError = 'токен устройства отозван — нужен новый';
        debugPrint('cloudly-sync: $tokenError');
      }
      return report;
    } catch (err) {
      return MirrorReport()..error = '$err';
    } finally {
      activity = null;
      notifyListeners();
    }
  }

  /// Подтвердить удаления, приостановленные предохранителем: следующий проход выполнит их один раз.
  Future<void> confirmDeletes() async {
    final store = mirrorStore;
    if (store == null) return;
    await store.setMeta(MirrorStore.keyConfirmed, '1');
    await mirrorPass();
  }

  /// Что удаления приостановлены и почему: «пропало слишком много» или «папка не читается».
  Future<(int, String)?> blockedInfo() async {
    final raw = await mirrorStore?.meta(MirrorStore.keyBlocked);
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split('|');
    return (
      int.tryParse(parts.first) ?? 0,
      parts.length > 1 ? parts.sublist(1).join('|') : '',
    );
  }

  @override
  void dispose() {
    unawaited(live?.dispose());
    super.dispose();
  }
}
