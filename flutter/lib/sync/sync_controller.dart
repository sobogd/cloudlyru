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

  bool get paused => _paused;
  bool _paused = false;

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
      queueStore = await QueueStore.open();
      mirrorStore = await MirrorStore.open();
      deviceLabel = await native.deviceLabel();
      access = await native.hasAllFilesAccess() ? SyncAccess.granted : SyncAccess.denied;
      _paused = await mirrorStore!.meta(MirrorStore.keyPaused) == '1';
      // после перезапуска ничего не может быть «в работе»: строки, застрявшие в RUNNING,
      // возвращаем в ожидание, иначе кнопка «play» на них не появится уже никогда
      await queueStore!.resetRunning();

      await _bindToken(sessionApi, login, epoch);
      // Проход зеркала, когда приложения нет на экране: задание живёт в системе, а не в этом
      // процессе (см. lib/sync/background/)
      await BackgroundSync.register(serverUrl: sessionApi.serverUrl, login: login);

      engine = MirrorEngine(
        () => _requireApi(),
        mirrorStore!,
        selection!,
        status: _status,
        native: native,
      );
      if (_api != null) {
        uploads = UploadRunner(_api!, queueStore!);
        final liveMode = MirrorLive(mirrorStore!, engine!, _status, _watcher, native);
        liveMode.hasToken = () => _api != null;
        liveMode.paused = () => _paused;
        liveMode.foreground = () => foreground;
        liveMode.bindWatcher();
        liveMode.start();
        live = liveMode;
      }

      if (_api != null) await _rememberSystemFolders(_api!);
      _status.update((s) => s.copyWith(
            phase: _paused ? MirrorPhase.paused : s.phase,
          ));
      await startWatching();
      await refreshQueue();
      notifyListeners();
    } catch (e) {
      debugPrint('cloudly-sync: старт синхронизации не удался: $e');
      activity = 'синхронизация недоступна: $e';
      notifyListeners();
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
    uploads ??= UploadRunner(api, queueStore!);
    if (engine != null && live == null) {
      final liveMode = MirrorLive(mirrorStore!, engine!, _status, _watcher, native);
      liveMode.hasToken = () => _api != null;
      liveMode.paused = () => _paused;
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
      if (mirror != null && mirror.isNotEmpty) await prefs.setMirrorFolderId(mirror);
      final photo = me.photoFolderId;
      if (photo != null && photo.isNotEmpty) await prefs.setPhotoFolderId(photo);
      final phone = me.phoneFolderId;
      if (phone != null && phone.isNotEmpty) await prefs.setPhoneFolderId(phone);
      notifyListeners();
    } catch (e) {
      // папки придут и позже — например, при наполнении очереди; ронять из-за них старт незачем
      debugPrint('cloudly-sync: системные папки не спрошены: $e');
    }
  }

  /// Токен устройства: свой у каждого устройства, поэтому корень зеркала в облаке не делится
  /// между телефонами.
  Future<void> _bindToken(CloudlyApi sessionApi, String login, int epoch) async {
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
    if (e is ApiException && (e.status == 400 || e.status == 401 || e.status == 403)) {
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
      throw StateError(why == null ? 'нет токена устройства' : 'нет токена устройства: $why');
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
    access = await native.hasAllFilesAccess() ? SyncAccess.granted : SyncAccess.denied;
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

  /// Наполнить очередь: пройти выбранные папки и поставить новое. Ничего не выгружает.
  Future<QueueBuildResult?> refreshQueue() async {
    final store = queueStore;
    final sel = selection;
    if (store == null || sel == null) return null;
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
      final refresher = QueueRefresher(
        () => _api,
        syncPrefs!,
        sel,
        store,
        files,
      );
      final result = await refresher.refresh(onProgress: (m) {
        activity = m;
        notifyListeners();
      });
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
  Future<void> uploadItem(int itemId, {void Function(UploadProgress)? onProgress}) async {
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
  Future<MirrorReport?> mirrorPass({bool manual = true}) async {
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
      return await e.pass(manual: manual, onProgress: (m) {
        activity = m;
        notifyListeners();
      });
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

  /// Включить или выключить автоматические проходы. Ручная сверка работает всегда.
  Future<void> setPaused(bool value) async {
    final store = mirrorStore;
    if (store == null) return;
    _paused = value;
    await store.setMeta(MirrorStore.keyPaused, value ? '1' : '0');
    _status.update((s) => s.copyWith(
          phase: value ? MirrorPhase.paused : MirrorPhase.idle,
        ));
    if (!value) {
      await startWatching();
      unawaited(mirrorPass(manual: false));
    }
    notifyListeners();
  }

  /// Что удаления приостановлены и почему: «пропало слишком много» или «папка не читается».
  Future<(int, String)?> blockedInfo() async {
    final raw = await mirrorStore?.meta(MirrorStore.keyBlocked);
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split('|');
    return (int.tryParse(parts.first) ?? 0, parts.length > 1 ? parts.sublist(1).join('|') : '');
  }

  @override
  void dispose() {
    unawaited(live?.dispose());
    super.dispose();
  }
}
