import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/cloudly_api.dart';
import 'data/mirror_store.dart';
import 'data/queue_store.dart';
import 'data/selection.dart';
import 'data/sync_links.dart';
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
///
/// Значение меняет только [SyncController.start] (и [SyncController.recheckAccess] после
/// возвращения из системных настроек): сам доступ спрашивается у [NativeFs].
enum SyncAccess { unknown, granted, denied }

/// Одна точка сборки всего синхронизатора: базы, выбор папок, движок зеркала, очередь,
/// мгновенный режим. Интерфейс говорит только с ней — ни баз, ни сетевого клиента он не знает.
///
/// Токен устройства берётся у сессии: корень зеркала сервер заводит именно устройству, а
/// веб-сессия его не получает вовсе (см. [ensureDeviceToken]).
///
/// Создаётся один раз на приложение (провайдер `syncControllerProvider`), переживает проходы
/// и смену раздела: движок и наблюдение за папками заводятся при [start] и живут до [signOut].
/// Состояние наружу отдаётся через [ChangeNotifier] — интерфейс перерисовывается и на
/// собственные поля, и на каждый шаг зеркала (поток [MirrorStatusHolder]).
class SyncController extends ChangeNotifier {
  SyncController({NativeFs? native, DeviceTokenStore? tokens})
    : native = native ?? NativeFs(),
      _tokens = tokens ?? DeviceTokenStore() {
    _watcher = MirrorWatcher(this.native);
    _status = MirrorStatusHolder();
    // состояние зеркала приходит из движка и мгновенного режима — здесь оно превращается
    // в уведомление интерфейсу: подписчик один, на всё приложение
    _statusSubscription = _status.stream.listen((s) {
      mirrorStatus = s;
      if (!_disposed) notifyListeners();
    });
  }

  /// Мост к Android: доступ ко всем файлам, события файловой системы, номера файлов.
  final NativeFs native;

  /// Хранилище device-токена: отдельно от сессии, потому что живёт дольше неё и выпускается
  /// на каждое устройство своё.
  final DeviceTokenStore _tokens;

  /// Наблюдение за выбранными папками: ускоритель прохода по событию файловой системы.
  late final MirrorWatcher _watcher;

  /// Состояние зеркала: пишут движок и мгновенный режим, читает интерфейс.
  late final MirrorStatusHolder _status;

  SharedPreferences? _prefs;
  SyncPrefs? syncPrefs;
  Selection? selection;

  /// Связки «папка на устройстве ↔ папка в облаке» раздела «Файлы»: что и куда синхронизировать.
  /// Выбор папок для «Фото» живёт отдельно ([selection]) — там зеркала нет, только заливка
  /// в медиатеку.
  SyncLinks? links;
  QueueStore? queueStore;
  MirrorStore? mirrorStore;
  SyncApi? _api;

  /// Клиент синхронизации (device-токен) для тех, кому нужен журнал изменений помимо зеркала.
  ///
  /// Лента «Медиа» ведёт по журналу свой курсор и свой список: `/sync/*` отвечает только на
  /// device-токен, а выпускает его этот контроллер — второй такой же токен заводить незачем.
  /// null означает, что токена ещё нет (или он отозван): потребитель обязан работать и без
  /// журнала, на том, что уже лежит на устройстве.
  SyncApi? get api => _api;

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

  /// Доступ ко всем файлам: [SyncAccess.unknown] — ещё не спрашивали.
  SyncAccess access = SyncAccess.unknown;

  /// Что делает синхронизатор прямо сейчас: «обновляю очередь», «выгружаю файл».
  String? activity;

  /// Сколько строк ждёт выгрузки: по этому числу живёт кнопка на вкладке «Очередь».
  int waiting = 0;

  /// Последний итог наполнения очереди.
  String? queueNote;

  /// Устройство: так называется корень зеркала в облаке.
  String deviceLabel = 'Android';

  /// Старт уже выполнен: [start] вызывается и при входе в аккаунт, и при старте приложения,
  /// а второй раз поднимать базы и наблюдение нельзя.
  bool _started = false;

  /// Старт идёт прямо сейчас: два одновременных вызова (пересборка провайдера) открыли бы
  /// две базы очереди и два движка.
  bool _starting = false;

  /// Контроллер уничтожен: писать в него и поднимать работу больше нельзя.
  bool _disposed = false;

  /// Номер попытки входа: растёт при каждом [start] и при выходе из аккаунта. По нему
  /// выпуск токена понимает, что его результат уже никому не нужен (успел выйти из аккаунта).
  int _sessionEpoch = 0;

  /// Экран приложения на переднем плане: от этого зависит частота опроса журнала.
  bool foreground = true;

  /// Настройки и выбор папок готовы: до этого интерфейсу показывать нечего.
  bool get ready => _prefs != null;

  /// Нужно ли просить доступ ко всем файлам: без него не видно ни дерева, ни содержимого.
  ///
  /// `unknown` тоже считается «нужно»: если старт упал до проверки доступа, `access` остаётся
  /// неизвестным, и при проверке «только denied» экран вечно показывал бы «нет доступа»,
  /// не предлагая его выдать.
  bool get needsAccess => access != SyncAccess.granted;

  /// Папки облака, которые сейчас связаны с телефоном. По ним «Файлы» помечают папку, которая
  /// синхронизируется: снаружи она ничем не отличается от обычной, а перепутать её с обычной —
  /// значит удалить или переименовать то, на что смотрит зеркало.
  ///
  /// Набор кэшируется: интерфейс подписан на него через `select`, а сравнивает `select` ссылки.
  /// Без кэша каждое уведомление контроллера (а их немало: ход прохода, счётчики, статус)
  /// выглядело бы для «Файлов» изменением, и список папок перерисовывался бы на каждый тик.
  Set<String> get linkedCloudIds =>
      _linkedCloudIds ??= links?.cloudIds() ?? const <String>{};
  Set<String>? _linkedCloudIds;

  /// Запуск: открыть базы, прочитать выбор папок, проверить доступ, поднять мгновенный режим.
  ///
  /// Вызывается при входе в аккаунт и при старте приложения, если сессия уже есть.
  ///
  /// @param sessionApi веб-сессия: ею выпускается токен устройства и спрашиваются системные
  ///        папки; @param login логин аккаунта — вторая половина ключа хранимого токена.
  /// Побочные эффекты: открывает базы (и закрывает их в [signOut]), читает настройки,
  /// регистрирует фоновое задание, заводит движок, наблюдение и мгновенный режим.
  /// Ошибки не выбрасываются наружу: причина уходит в [activity] и в лог, а состояние
  /// остаётся частично готовым — доступ к файлам видно и тогда, когда база не открылась.
  /// Повторный вызов, пока не было [signOut], ничего не делает.
  Future<void> start(CloudlyApi sessionApi, String login) async {
    if (_started || _starting || _disposed) return;
    _starting = true;
    // номер сессии: если пользователь успеет выйти из аккаунта, пока выпускается токен,
    // результат выпуска не будет записан (см. _bindToken)
    final epoch = ++_sessionEpoch;
    try {
      _prefs ??= await SharedPreferences.getInstance();
      syncPrefs ??= SyncPrefs(_prefs!);
      selection ??= Selection(_prefs!);
      links ??= SyncLinks(_prefs!);
      // Доступ и метка устройства — до баз: если база почему-то не откроется, человек всё равно
      // должен видеть, выдан ли доступ, а не «проверяю доступ к файлам…» навсегда
      deviceLabel = await native.deviceLabel();
      access = await native.hasAllFilesAccess()
          ? SyncAccess.granted
          : SyncAccess.denied;

      // Базы открываем по одной: поломка одной не должна отменять всё остальное. Так уже было —
      // не открылась база, и вместе с ней «не поставилось» наблюдение и «не запускалось» зеркало
      queueStore ??= await _openQueueStore();
      mirrorStore ??= await _openMirrorStore();
      // Выключателя синхронизации нет: она всегда включена — в этом её смысл. Флаг в базе
      // мог остаться от прежних сборок, поэтому снимаем его, иначе синхронизация молчала бы
      // без всякой возможности её вернуть.
      await mirrorStore?.clearMeta(MirrorStore.keyPaused);
      // Перенос прежнего выбора папок — после баз: пары «папка телефона ↔ папка облака»
      // сложились в прошлых проходах и лежат именно в базе зеркала
      await _migrateLegacySelection();

      await _bindToken(sessionApi, login, epoch);
      // Выход из аккаунта во время старта: продолжать нечего — [signOut] уже закрыл то, что
      // успело открыться, снял сторожа и наблюдение
      if (epoch != _sessionEpoch || _disposed) return;

      await _ensureEngine();
      await _ensureLive();

      // корень зеркала нужен «Файлам» сразу: без него синхронизируемая папка не отличается
      // от обычной
      final api = _api;
      if (api != null) await _rememberSystemFolders(api);
      if (epoch != _sessionEpoch || _disposed) return;
      notifyListeners();
      // Синхронизация не должна ждать, пока её попросят: проверяем себя сразу после старта и
      // дальше следим за собой сторожем
      _startWatchdog();
      unawaited(checkAndResume());
      // Флаг ставится только после успеха. Раньше он ставился первым делом, и одного
      // исключения в любом `await` (настройки, наблюдение, запуск движка) хватало, чтобы
      // синхронизация умерла до перезапуска приложения: повторный [start] выходил сразу,
      // а [ensureReady] догонял только токен
      _started = true;
    } catch (e) {
      debugPrint('cloudly-sync: старт синхронизации не удался: $e');
      activity = 'синхронизация недоступна: ${describeError(e)}';
      notifyListeners();
    } finally {
      _starting = false;
    }
  }

  /// Движок зеркала: заводится один раз за сессию, поэтому и вынесен отдельно — его догоняет
  /// не только [start], но и [ensureReady] после неудачного старта.
  ///
  /// Побочные эффекты: создание движка и чтение прошлого состояния зеркала из базы
  /// ([_restoreLastState]); повторный вызов ничего не делает.
  Future<void> _ensureEngine() async {
    final store = mirrorStore;
    final linkStore = links;
    if (store == null || linkStore == null || engine != null) return;
    // движок один на приложение: он держит замок «один проход за раз» и кэш хэшей
    // между проходами. Клиент берётся функцией — токен может быть перевыпущен
    engine = MirrorEngine(
      () => _requireApi(),
      store,
      linkStore,
      status: _status,
      native: native,
    );
    // Что было в прошлый раз: без этого после перезапуска карточка говорит «зеркало ещё
    // не запускалось», хотя проходы шли — в том числе в фоне
    await _restoreLastState(store);
  }

  /// Выгрузчик очереди и мгновенный режим.
  ///
  /// Мгновенный режим не зависит от базы очереди: её отказ не должен глушить опрос журнала,
  /// хотя и выгрузка из очереди без неё невозможна. Побочные эффекты: открытие базы очереди
  /// (если она ещё не открыта), создание выгрузчика и запуск опроса.
  Future<void> _ensureLive() async {
    final api = _api;
    if (api == null) return;
    queueStore ??= await _openQueueStore();
    final queue = queueStore;
    if (queue != null) uploads ??= UploadRunner(api, queue);
    final store = mirrorStore;
    final e = engine;
    if (store == null || e == null || live != null) return;
    final liveMode = MirrorLive(store, e, _status, _watcher, native);
    // токен и передний план спрашиваются функциями: и то и другое меняется на ходу,
    // а мгновенный режим заводится один раз
    liveMode.hasToken = () => _api != null;
    liveMode.foreground = () => foreground;
    liveMode.bindWatcher();
    liveMode.start();
    live = liveMode;
  }

  /// База очереди: своя попытка и свой отчёт об ошибке — из-за неё одной синхронизация
  /// не должна пропадать целиком.
  ///
  /// @return открытая база или `null`, если она не открылась: причина уходит в [queueNote]
  ///         и в лог, а остальная синхронизация продолжает подниматься. Строки, застрявшие
  ///         в работе после прошлого запуска, возвращаются в ожидание.
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

  /// База зеркала: та же логика, что у очереди, — своя попытка и своя причина отказа
  /// в [activity], чтобы интерфейс объяснил, почему зеркало молчит.
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
  ///
  /// Только чтение базы и запись в [mirrorStatus]; при любой ошибке состояние остаётся
  /// пустым, а причина уходит в лог. Проход от этого не запускается.
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
        // формат записи — «сколько|почему»: причина может содержать разделитель, поэтому
        // собираем её обратно из остатка строки
        final parts = blockedRaw.split('|');
        blocked = int.tryParse(parts.first) ?? 0;
        if (parts.length > 1) blockedReason = parts.sublist(1).join('|');
      }
      _status.update(
        (s) => s.copyWith(
          // фаза ставится явно: восстанавливать состояние нужно и тогда, когда в памяти
          // осталась залипшая фаза прошлого прохода
          phase: MirrorPhase.idle,
          clearCurrentName: true,
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
  ///
  /// @return `true`, если клиент синхронизации есть (в том числе если он был и раньше).
  /// Побочные эффекты: выпуск токена (сеть, шифрованное хранилище), запрос системных папок,
  /// завод выгрузчика и мгновенного режима, уведомление интерфейса. Второй раз движок
  /// и наблюдение не заводятся — только то, чего не хватало.
  Future<bool> ensureReady() async {
    if (_disposed) return false;
    if (_api == null) {
      final sessionApi = _sessionApi;
      // сессии нет — повторить нечем: так бывает после выхода из аккаунта или если [start]
      // не дошёл до привязки токена
      if (sessionApi == null) return false;
      await _bindToken(sessionApi, _login, _sessionEpoch);
      final api = _api;
      if (api == null) {
        notifyListeners();
        return false;
      }
      await _rememberSystemFolders(api);
    }
    // Старт мог упасть на любой фазе: не открылись настройки, не открылась база зеркала,
    // не поднялся движок. Догоняем всё, чего не хватает, а не только токен — иначе
    // синхронизация оставалась бы мёртвой до перезапуска приложения, хотя все вызывающие
    // ([checkAndResume], [refreshQueue], [uploadItem], [mirrorPass]) считали бы её живой
    if (_prefs == null) {
      try {
        _prefs = await SharedPreferences.getInstance();
        syncPrefs ??= SyncPrefs(_prefs!);
        selection ??= Selection(_prefs!);
        links ??= SyncLinks(_prefs!);
      } catch (e) {
        debugPrint('cloudly-sync: настройки не открылись: $e');
      }
    }
    queueStore ??= await _openQueueStore();
    mirrorStore ??= await _openMirrorStore();
    await _migrateLegacySelection();
    await _ensureEngine();
    await _ensureLive();
    if (_disposed) return false;
    notifyListeners();
    return true;
  }

  /// Запомнить системные папки сервера: медиатеку «Фото» и легаси-«Телефон». Спрашиваем один
  /// раз при запуске — id медиатеки нужен наполнению очереди.
  ///
  /// Корень зеркала устройства здесь больше не запоминается: папки в облаке для «Файлов»
  /// выбирает человек, и сервер их не заводит (см. `SyncLinks`).
  ///
  /// Побочные эффекты: запрос к серверу и запись в настройки (кэш — истина всё равно за
  /// ответом сервера). Ошибка не пробрасывается: папки придут при следующем случае.
  Future<void> _rememberSystemFolders(SyncApi api) async {
    final prefs = syncPrefs;
    if (prefs == null) return;
    try {
      final me = await api.systemFolders();
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
  ///
  /// @param epoch номер попытки входа на момент вызова: если он разошёлся с текущим (успел
  ///        пройти [signOut] или новый [start]), выпущенный токен не записывается — иначе
  ///        вышедший из аккаунта клиент ожил бы сам.
  /// Побочные эффекты: запрос к сессии, чтение и запись шифрованного хранилища токена.
  /// Ошибка не выбрасывается: клиент обнуляется, а причина уходит в [tokenError] и в лог —
  /// без строки в логе причину отказа на телефоне искать негде.
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

  /// Ошибка словами для интерфейса: сырое исключение транспорта человеку ничего не объясняет,
  /// а один и тот же отказ в разных местах выглядел бы по-разному.
  ///
  /// Тексты сервера сохраняются (в них бывает суть: «имя занято», «нет места»), но длинные
  /// обрезаются — адрес запроса и внутренности транспорта в интерфейсе не нужны.
  static String describeError(Object e) {
    if (e is SyncApiException) {
      if (e.status == 401 || e.status == 403) {
        return 'нет доступа к синхронизации — войдите заново';
      }
      if (e.status == 429) return 'сервер просит подождать: слишком много запросов';
      if (e.status == 0) return 'нет связи с сервером';
      return _short(e.message);
    }
    if (e is ApiException) return _short(e.message);
    if (e is SocketException) return 'нет связи с сервером';
    return _short('$e');
  }

  /// Обрезать служебный хвост сообщения: в интерфейсе строка места мало, а URL и стек в ней
  /// ничего не объясняют.
  static String _short(String text) =>
      text.length <= 200 ? text : '${text.substring(0, 200)}…';

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
  /// и даёт полный доступ к облаку мимо приложения. Вместе с отзывом стирается и локальная
  /// копия токена: иначе она переживает «выход», и следующая привязка молча вернула бы прежний
  /// токен вместе с его корнем зеркала в облаке.
  ///
  /// Побочные эффекты: запрос отзыва (его неудача не мешает выходу), снятие фонового задания,
  /// остановка мгновенного режима, закрытие баз и полная очистка состояния — после вызова
  /// [start] можно звать снова. Закрытие баз закрывает и состояние зеркала в памяти: строки
  /// в базе остаются на диске и переживут следующий вход в тот же аккаунт.
  Future<void> signOut() async {
    // Сессия закрывается до всего остального: текущий проход и текущая выгрузка увидят смену
    // эпохи (см. [mirrorPass] и [uploadItem]) и остановятся сами, а не будут писать в базу,
    // которую вот-вот закроют
    _sessionEpoch++;
    try {
      await _api?.revokeOwnToken();
    } catch (_) {}
    // Ключ записи токена — «адрес сервера + логин», поэтому берём их до того, как обнулим
    // состояние: после этого восстановить пару будет нечем, и запись осталась бы навсегда
    final sessionApi = _sessionApi;
    final login = _login;
    if (sessionApi != null && login.isNotEmpty) {
      try {
        await _tokens.clear(sessionApi.serverUrl, login);
      } catch (e) {
        // Не повод не выходить из аккаунта: серверный токен уже отозван, а запись в хранилище
        // безвредна — следующая привязка проверит её живость и выпустит новый токен
        debugPrint('cloudly-sync: токен устройства не забыт: $e');
      }
    }
    _watchdog?.cancel();
    _watchdog = null;
    await live?.dispose();
    _api = null;
    _sessionApi = null;
    _login = '';
    tokenError = null;
    _started = false;
    _lastTokenRetryAt = null;
    _lastQueueRefreshAt = null;

    // Базы закрываем, только когда текущая работа закончилась: закрыть их под работающим
    // движком — значит получить исключения из закрытой базы и незавершённую сессию выгрузки.
    // Если работа идёт, закрытие откладывается до её конца, а сессия считается новой уже сейчас
    final pending = <Future<void>>[
      ?_passInFlight,
      ?_uploadInFlight,
    ];
    final queue = queueStore;
    final mirror = mirrorStore;
    queueStore = null;
    mirrorStore = null;
    _prefs = null;
    syncPrefs = null;
    selection = null;
    links = null;
    _linkedCloudIds = null;
    engine = null;
    uploads = null;
    live = null;
    _files = null;
    if (pending.isEmpty) {
      await queue?.close();
      await mirror?.close();
    } else {
      unawaited(
        Future.wait(pending).then((_) async {
          await queue?.close();
          await mirror?.close();
        }),
      );
    }

    // Состояние сбрасывается целиком: иначе после смены аккаунта экраны показывали бы значения
    // прошлого (доступ, «выгружено: …», метку устройства), а залипшая фаза зеркала пережила бы
    // выход и вход — интерфейс вечно писал бы «выгружаю…»
    _status.reset();
    mirrorStatus = const MirrorStatus();
    access = SyncAccess.unknown;
    activity = null;
    queueNote = null;
    deviceLabel = 'Android';
    waiting = 0;
    notifyListeners();
  }

  /// Что не вышло с токеном устройства: показывается в настройках, пока не получится.
  String? tokenError;

  /// Клиент синхронизации или исключение, если токена нет.
  ///
  /// Движок берёт клиент этой функцией (см. `MirrorEngine._api`): проход с мёртвым токеном
  /// должен закончиться внятной ошибкой, а не молчанием. Причина из [tokenError] попадает
  /// в текст — иначе человеку останется только «нет токена устройства».
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

  /// Чтение телефона (дерево папок, содержимое, превью).
  ///
  /// Экземпляр один на сессию: [DeviceFiles] состояния не держит, но каждый вызов создавал бы
  /// новый «читатель телефона» — на одном экране их оказывалось бы несколько, и кэши обхода
  /// не переживали бы ни одного вызова. Сбрасывается при выходе из аккаунта.
  DeviceFiles get files => _files ??= DeviceFiles(native: native);
  DeviceFiles? _files;

  /// Попросить доступ ко всем файлам: открывается системный экран, разрешение выдаётся там.
  ///
  /// Само разрешение проверяется не здесь, а в [recheckAccess] — узнать об ответе можно
  /// только вернувшись на экран приложения.
  Future<void> requestAccess() async {
    await native.openAllFilesSettings();
  }

  /// Проверить доступ после возвращения из системных настроек.
  ///
  /// Побочные эффекты: проба доступа, при выданном доступе — постановка наблюдения за папками
  /// и наполнение очереди (без доступа и то и другое бессмысленно), затем уведомление
  /// интерфейса.
  Future<void> recheckAccess() async {
    access = await native.hasAllFilesAccess()
        ? SyncAccess.granted
        : SyncAccess.denied;
    if (access == SyncAccess.granted) {
      await startWatching();
      await refreshQueue();
    } else {
      // доступ отозвали в системных настройках: наблюдать больше нечего, а обход без него
      // считает папки нечитаемыми и запрещает удаления — об этом надо сказать, а не молчать
      await _watcher.stop();
      activity = 'нет доступа ко всем файлам — синхронизация почти не работает';
    }
    notifyListeners();
  }

  /// Тихо перепроверить доступ: мог быть отозван в системных настройках при живом приложении.
  ///
  /// Без него `access` остаётся `granted`, экраны пишут «доступ есть», а обход молча
  /// деградирует до нечитаемых папок (удаления при этом запрещаются — это правильно), и
  /// причины не видно. Вызов дешёвый, поэтому делается на каждом тике сторожа.
  Future<void> _recheckAccessQuietly() async {
    final was = access;
    final now = await native.hasAllFilesAccess()
        ? SyncAccess.granted
        : SyncAccess.denied;
    if (now == was) return;
    await recheckAccess();
  }

  /// Выбор папок раздела «Фото» изменился: наполняем очередь заново.
  ///
  /// @param section раздел, в котором меняли выбор; в теле не используется — очередь
  ///        пересобирается целиком. Наблюдения за папками у «Фото» нет: там плоская заливка
  ///        в медиатеку, а не зеркало дерева (см. `QueueBuilder`).
  Future<void> onSelectionChanged(Section section) async {
    await refreshQueue();
  }

  /// Разовый перенос прежнего выбора папок в связки.
  ///
  /// Раньше «Файлы» синхронизировались по галочкам в дереве, а папку в облаке каждой галочке
  /// заводил сервер (`‹Имя устройства› - Файлы/‹имя›`). Теперь обе стороны выбирает человек,
  /// и без переноса после обновления синхронизация молча встала бы: галочки на месте, связок нет.
  ///
  /// Пары берутся из базы зеркала: там лежит соответствие, сложившееся в прошлых проходах,
  /// поэтому в облаке ничего не создаётся и не перевыгружается. Путь, которого в парах нет,
  /// пропускается — он и не синхронизировался.
  ///
  /// Побочные эффекты: запись связок в настройки и стирание прежнего ключа выбора (переносить
  /// больше нечего). Ничего не делает, если связки уже есть или прежнего выбора нет.
  Future<void> _migrateLegacySelection() async {
    final linkStore = links;
    final store = mirrorStore;
    if (linkStore == null || store == null) return;
    final legacy = selection?.paths(Section.files) ?? const <String>{};
    if (legacy.isEmpty) return;
    // Связки уже есть — человек их создал сам: прежний выбор ему больше не нужен
    if (linkStore.all().isNotEmpty) {
      await selection?.clear(Section.files);
      return;
    }
    final pairs = await store.roots();
    final migrated = <SyncLink>[];
    for (final path in legacy) {
      final pair = pairs[path];
      if (pair == null) continue;
      migrated.add(
        SyncLink(
          localPath: path,
          cloudId: pair.cloudId,
          cloudPath: pair.cloudPath,
        ),
      );
    }
    if (migrated.isEmpty) {
      // Переносить нечего, но и стирать прежний выбор нельзя: пар может не быть просто потому,
      // что база ещё не открылась или проход ни разу не доходил до этой папки
      return;
    }
    await linkStore.replaceAll(migrated);
    await selection?.clear(Section.files);
    debugPrint('cloudly-sync: прежний выбор папок перенесён в связки: ${migrated.length}');
  }

  /// Связки раздела «Файлы» изменились: переставляем наблюдение и запускаем проход.
  ///
  /// Проход запускается сразу, не дожидаясь сторожа: человек только что связал папку и ждёт,
  /// что она поедет. Ожидания в интерфейсе нет — проход идёт в фоне.
  ///
  /// Побочные эффекты: перестановка наблюдения за папками, возможно проход зеркала
  /// и уведомление интерфейса (снятая связка должна погасить метку в «Файлах» сразу,
  /// а не после перезахода).
  Future<void> onLinksChanged() async {
    // кэш папок облака снимаем до уведомления: «Файлы» должны увидеть новый набор в той же
    // перерисовке, а не на следующем событии
    _linkedCloudIds = null;
    await startWatching();
    notifyListeners();
    // Связок нет — идти некуда: проход всё равно ничего не сделает, кроме пустого снимка
    if (!(links?.all().isNotEmpty ?? false)) return;
    // Проход уже идёт, и связку, добавленную посреди него, он не увидит: ждём его конца
    // и запускаем свой. Иначе новая связка ждала бы сторожа — до десяти минут, и человек
    // решил бы, что связка не работает
    final running = _passInFlight;
    if (running != null) {
      unawaited(running.then((_) async => mirrorPass()));
      return;
    }
    unawaited(mirrorPass());
  }

  /// Переставить наблюдение за папками раздела «Файлы» по текущим связкам.
  ///
  /// Зовётся при старте, после выдачи доступа и при смене связок. Ошибка наблюдения
  /// не пробрасывается: наблюдение — только ускоритель, без него остаётся периодический
  /// проход. Фактический результат видно по [watchedDirs].
  Future<void> startWatching() async {
    final linkStore = links;
    if (linkStore == null) return;
    try {
      await _watcher.watch(linkStore.localPaths());
    } catch (_) {
      // наблюдение — только ускоритель: без него остаётся периодический проход
    }
    notifyListeners();
  }

  /// Число папок, взятых под наблюдение: 0 — система не дала, работает только периодика.
  int get watchedDirs => _watcher.watchedDirs;

  /// Сколько ждём, прежде чем считать, что синхронизация встала. Проход зеркала ограничен
  /// бюджетом времени (восемь минут — `MirrorEngine.defaultBudgetMs`), и если он не закончился
  /// сам, его надо догнать.
  static const int _stalePassMs = 10 * 60 * 1000;

  /// Сколько файлов очереди выгружаем за одну проверку: остальное — следующим заходом.
  ///
  /// Число выбрано так, чтобы одна проверка (тик сторожа — раз в минуту) не занимала канал
  /// надолго на очереди в сотни файлов: остальное подхватит следующий тик. Источник —
  /// соображение о длительности, а не замер.
  static const int _drainPerCheck = 20;

  /// Как часто сторож просыпается: раз в минуту он смотрит, есть ли что выгружать.
  static const Duration _watchdogEvery = Duration(seconds: 60);

  /// Как часто сторож пересматривает выбранные папки, когда выгружать нечего. Пять минут —
  /// компромисс между свежестью очереди и обходом диска: заход стоит `stat` по каждому файлу
  /// выбранных папок и полного чтения таблицы очереди.
  static const Duration _queueRefreshEvery = Duration(minutes: 5);

  /// Как часто сторож пробует выпустить токен заново, если клиента синхронизации нет.
  /// Реже, чем [._watchdogEvery]: выпуск токена — это запрос к серверу и запись в шифрованное
  /// хранилище, а отказ обычно держится дольше минуты.
  static const Duration _tokenRetryEvery = Duration(minutes: 5);

  /// Проверка уже идёт: два захода разом трогали бы одни и те же строки очереди.
  bool _resuming = false;

  /// Сторож: пока приложение открыто, ждущее выгружается само.
  Timer? _watchdog;
  DateTime? _lastQueueRefreshAt;
  DateTime? _lastTokenRetryAt;

  /// Идёт выгрузка файла. Очередь, сторож, «проверить» и кнопка на строке должны делить один
  /// канал: иначе сторож начинал следующий файл, пока льётся гигабайтное видео, — и канал,
  /// и батарея делились бы между N выгрузками.
  bool _uploading = false;

  /// Строки, выгружаемые прямо сейчас: повторный запуск той же строки (тап по ней в момент
  /// тика сторожа) дал бы два `initUpload` на одно имя и лишнюю конфликтную копию в облаке.
  final Set<int> _uploadingIds = <int>{};

  /// Идущий проход зеркала: по нему [signOut] понимает, что базы закрывать ещё рано.
  Future<void>? _passInFlight;

  /// Идущая выгрузка очереди — по той же причине.
  Future<void>? _uploadInFlight;

  /// Подписка на состояние зеркала: её нужно отменять вместе с контроллером.
  StreamSubscription<MirrorStatus>? _statusSubscription;

  /// Проверить, что синхронизация идёт, и догнать её, если встала.
  ///
  /// Встать она может по-разному: кончился бюджет времени (выгрузка гигабайтов идёт часами),
  /// пропала сеть, система прибила фоновое задание, отвалилось наблюдение за папками. Кнопки
  /// «продолжить» в разделе нет намеренно, поэтому проверка делается сама — при старте
  /// приложения и при каждом открытии раздела синхронизации.
  ///
  /// @param mirror запустить проход зеркала в любом случае, а не только когда он «встал».
  ///        Так зовёт кнопка «Проверить и догнать»: человек нажал её, чтобы синхронизация
  ///        прошла сейчас, — и проход обязан пройти, даже если предыдущий закончился минуту
  ///        назад и ждать нечего. Автоматическим заходам (старт, открытие раздела, сторож)
  ///        это не нужно: там проход идёт по нужде, а не по требованию.
  ///
  /// Побочные эффекты: выпуск токена, если его нет, наполнение очереди, выгрузка до
  /// [_drainPerCheck] файлов и, если зеркало не работает или давно не заканчивало проход,
  /// запуск прохода в фоне ([mirrorPass] не ожидается). Второй заход во время первого
  /// возвращается сразу. В конце — подсчёт ждущих строк и уведомление интерфейса.
  Future<void> checkAndResume({bool mirror = false}) async {
    if (_resuming) return;
    _resuming = true;
    activity = 'проверяю, не встала ли синхронизация…';
    notifyListeners();
    try {
      if (_api == null && !await ensureReady()) return;
      await refreshQueue();
      // наблюдение могло не встать при старте или отвалиться после перезагрузки системы
      await startWatching();

      // Сначала очередь: её и видно в разделе. Раньше догон стоял после прохода зеркала,
      // а проход идёт минутами — всё это время человек смотрел на «ждёт запуска» и решал,
      // что синхронизация встала.
      await _drainQueue();

      // Проход зеркала — после очереди и без ожидания: он может идти минутами, а раздел
      // не должен из-за него ничего ждать
      final status = mirrorStatus;
      // связок нет — зеркалу нечего делать: ни обходить, ни догонять
      final hasLinks = links?.all().isNotEmpty ?? false;
      final finished = status.finishedAt;
      // прохода не было вовсе (0) — тоже повод: после перезапуска состояние пустое,
      // а работа могла стоять
      final stale =
          finished == 0 ||
          DateTime.now().millisecondsSinceEpoch - finished > _stalePassMs;
      // Проход запускаем по трём поводам: есть что выгружать (waitingFiles), зеркало давно
      // не заканчивало проход (stale) или проход попросили руками ([mirror]). Порог
      // _stalePassMs (10 минут) вдвое больше бюджета самого прохода (8 минут —
      // MirrorEngine.defaultBudgetMs): проход, который идёт дольше, уже не «работает»,
      // а застрял.
      // busy — это «фаза не idle»: если проход уже идёт, второй не запускаем
      if (hasLinks && !status.busy && (mirror || status.waitingFiles > 0 || stale)) {
        unawaited(mirrorPass());
      }
    } finally {
      _resuming = false;
      activity = null;
      waiting = await queueStore?.waitingCount() ?? waiting;
      notifyListeners();
    }
  }

  /// Выгрузить ждущее из очереди — без кнопки. Очередь «Фото» наполняется сама, а кнопок
  /// «начать» в разделе больше нет: если файл ждёт выгрузки, он должен уехать сам.
  ///
  /// Побочные эффекты — выгрузка файлов в облако (см. [uploadItem]); ход работы уходит
  /// в [activity] и в очередь на экране. Исключения не пробрасываются: сбой одного файла
  /// остаётся ошибкой его строки.
  Future<void> _drainQueue() async {
    final store = queueStore;
    if (store == null || uploads == null) return;
    // Одна выгрузка за раз: если файл уже льётся (его начал сторож, «проверить» или кнопка),
    // второй не начинаем — очередь подождёт текущего
    if (_uploading) return;
    // Таблицу читаем один раз: раньше она перечитывалась на каждой итерации — до двадцати
    // полных чтений тысяч строк за одну проверку на изоляте интерфейса
    final items = await store.items();
    // Каждую строку в этой проверке пробуем один раз: иначе упавший файл крутился бы вечно
    final tried = <int>{};
    for (var done = 0; done < _drainPerCheck; done++) {
      QueueItem? next;
      for (final item in items) {
        if (tried.contains(item.id)) continue;
        // неудавшиеся пробуем наравне с ожидающими: следующий заход может пройти
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

  /// Сторож, пока приложение открыто.
  ///
  /// Проверки «при открытии раздела» мало: файл может появиться, пока раздел закрыт, а строка
  /// очереди — остаться ждать, пока человек снова туда зайдёт. Сторож каждую минуту смотрит,
  /// есть ли что выгружать (и выгружает), а раз в пять минут пересматривает выбранные папки —
  /// иначе новые файлы вообще не попадут в очередь до следующей проверки.
  ///
  /// Работает только на переднем плане: в фоне тем же занимается задание системы.
  /// Заводится один раз: повторный вызов оставляет прежний таймер.
  void _startWatchdog() {
    if (_disposed) return;
    _watchdog ??= Timer.periodic(_watchdogEvery, (_) {
      unawaited(_watchdogTick());
    });
  }

  /// Один тик сторожа: выгрузить ждущее или, если ждать нечего, пересобрать очередь.
  ///
  /// В фоне, во время другой проверки и без клиента синхронизации тик молча выходит: без
  /// токена он ничего не сделает, а очередь зависит от сервера. Ошибки не пробрасываются —
  /// сторож не должен падать из-за одного сбоя.
  Future<void> _watchdogTick() async {
    if (_disposed || !foreground || _resuming) return;
    // Токен устройства мог быть отозван в вебе или не выпуститься при старте. Сторож —
    // единственный, кто проверяет это сам, без действия человека: без повтора синхронизация
    // стояла бы до перезапуска приложения, а в интерфейсе не было бы даже причины
    if (_api == null) {
      final last = _lastTokenRetryAt;
      final now = DateTime.now();
      if (last != null && now.difference(last) < _tokenRetryEvery) return;
      _lastTokenRetryAt = now;
      await ensureReady();
      if (_api == null) return;
    }
    final store = queueStore;
    if (store == null) return;
    try {
      // доступ могли отозвать в системных настройках при живом приложении
      await _recheckAccessQuietly();
      // выгрузка уже идёт — второй файл не начинаем
      if (_uploading) return;
      if (await store.waitingCount() > 0) {
        await _drainQueue();
        return;
      }
      // ждать нечего: не чаще раза в пять минут смотрим, не появилось ли нового на телефоне
      final last = _lastQueueRefreshAt;
      final now = DateTime.now();
      if (last == null || now.difference(last) > _queueRefreshEvery) {
        // Срок отсчитываем и при неудачном заходе: иначе отказ (нет сети, нет токена) заставлял
        // бы обходить папки заново каждую минуту
        _lastQueueRefreshAt = now;
        await refreshQueue(quiet: true);
      }
    } catch (e) {
      debugPrint('cloudly-sync: сторож споткнулся: $e');
    }
  }

  /// Наполнить очередь: пройти выбранные папки и поставить новое. Ничего не выгружает.
  ///
  /// @param quiet тихий заход (сторож): не показывать ход работы в [activity].
  /// @return итог наполнения для интерфейса или `null`, если наполнить не удалось: причина
  ///         уходит в [queueNote]. Побочные эффекты: чтение диска, запросы к серверу, строки
  ///         в базе очереди, счётчик [waiting]. Ошибка не выбрасывается наружу — иначе сторож
  ///         и открытие раздела падали бы из-за одной нечитаемой папки.
  Future<QueueBuildResult?> refreshQueue({bool quiet = false}) async {
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
    // тихий заход не перебивает то, что уже показано в «синхронизация: …»
    if (!quiet) {
      activity = 'прохожу папки…';
      notifyListeners();
    }
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
      queueNote = 'не удалось пройти папки: ${describeError(e)}';
      return null;
    } finally {
      if (!quiet) {
        activity = null;
        notifyListeners();
      }
    }
  }

  /// Выгрузить один файл из очереди: кнопкой на строке — если хочется поторопить.
  ///
  /// @param itemId строка очереди; @param onProgress — счётчик байтов для строки на экране.
  /// Побочные эффекты: сеть, файл в облаке, состояние строки в базе очереди, [activity]
  /// и [waiting]. Ошибки не пробрасываются: причина уходит в [queueNote].
  Future<void> uploadItem(
    int itemId, {
    void Function(UploadProgress)? onProgress,
  }) async {
    // строка могла ждать с прошлого запуска, когда токена ещё не было
    if (_api == null && !await ensureReady()) {
      queueNote = tokenError ?? 'нет токена устройства';
      notifyListeners();
      return;
    }
    final runner = uploads;
    if (runner == null) return;
    // Одна выгрузка за раз и ни одной строки дважды: очередь, сторож, «проверить» и кнопка
    // на строке делят один канал. Без этого тап по строке в момент тика сторожа запускал бы
    // два прохода по одной строке, а сторож — второй файл поверх гигабайтного видео
    if (_uploading || !_uploadingIds.add(itemId)) return;
    _uploading = true;
    activity = 'выгружаю…';
    notifyListeners();
    try {
      final run = runner.run(itemId, onProgress: onProgress);
      _uploadInFlight = run.then<void>((_) {}, onError: (Object _) {});
      await run;
    } catch (e) {
      // Отказ авторизации (401/403) выглядит как обычная ошибка строки, но означает, что
      // токен устройства отозван или истёк. Клиент синхронизации помечаем негодным:
      // [ensureReady] при следующей проверке выпустит новый, иначе вся очередь осталась бы
      // мёртвой до перезапуска приложения, а признака в интерфейсе не было бы
      if (e is SyncApiException && (e.status == 401 || e.status == 403)) {
        _api = null;
        tokenError = 'токен устройства отозван — нужен новый';
        debugPrint('cloudly-sync: $tokenError');
      } else {
        queueNote = 'выгрузка не удалась: ${describeError(e)}';
      }
    } finally {
      _uploading = false;
      _uploadingIds.remove(itemId);
      _uploadInFlight = null;
      // счётчик обновляем в любом случае: строка могла сменить состояние даже при ошибке.
      // База берётся в переменную: [signOut] мог её обнулить прямо во время выгрузки
      final store = queueStore;
      activity = null;
      if (store != null) waiting = await store.waitingCount();
      if (!_disposed) notifyListeners();
    }
  }

  /// Ручная сверка зеркала: работает и когда автоматика выключена.
  ///
  /// Ход работы идёт в [activity]; @return отчёт о проходе или `null`, если движка нет
  /// (база зеркала не открылась). Побочные эффекты: всё, что делает проход зеркала, плюс
  /// [activity]. Исключения не пробрасываются: падение прохода возвращается отчётом с ошибкой.
  Future<MirrorReport?> mirrorPass() async {
    final e = engine;
    if (e == null || _disposed) return null;
    // Сверить сейчас имеет смысл и после отказа выпустить токен: причина часто временная,
    // и повторная попытка тут же даёт ответ — либо проход, либо внятную ошибку
    if (_api == null && !await ensureReady()) {
      return MirrorReport()..error = tokenError ?? 'нет токена устройства';
    }
    activity = 'сверяю…';
    notifyListeners();
    // Номер сессии: выход из аккаунта во время прохода должен остановить его, а не оставить
    // движок писать в закрытую базу (см. [signOut])
    final epoch = _sessionEpoch;
    try {
      final pass = e.pass(
        onProgress: (m) {
          activity = m;
          notifyListeners();
        },
        isCancelled: () => _disposed || _sessionEpoch != epoch,
      );
      _passInFlight = pass.then<void>((_) {}, onError: (Object _) {});
      final report = await pass;
      // Отказ авторизации устройства (в вебе отозвали токен или он истёк): пока он лежит
      // в клиенте, каждый проход будет упираться в 401. Признак приходит структурно
      // ([MirrorReport.authFailed]), а не разбором русского текста ошибки. Помечаем клиент
      // негодным: сохранённый токен проверяется на живость перед использованием, и ближайшая
      // проверка ([ensureReady] — её зовут сторожа, открытие раздела, наполнение очереди,
      // старт приложения) выпустит вместо него новый.
      // Связки при этом не трогаются: выгрузка пойдёт в те же папки облака, которые выбрал
      // человек, а прежние строки зеркала останутся при своих связках.
      if (report.authFailed) {
        _api = null;
        tokenError = 'токен устройства отозван — нужен новый';
        debugPrint('cloudly-sync: $tokenError');
      }
      return report;
    } catch (err) {
      return MirrorReport()..error = describeError(err);
    } finally {
      _passInFlight = null;
      activity = null;
      if (!_disposed) notifyListeners();
    }
  }

  /// Подтвердить удаления, приостановленные предохранителем: следующий проход выполнит их один раз.
  ///
  /// Побочные эффекты: метка в базе зеркала (сгорает в конце ближайшего прохода — см.
  /// `MirrorEngine._finish`) и сам проход, который здесь же и запускается. Если базы нет,
  /// ничего не происходит.
  ///
  /// Значение метки — уникальное на каждое нажатие, а не «1»: флаг в базе один на приложение
  /// и фоновое задание, и по уникальному значению проход снимает ровно то подтверждение,
  /// которое прочитал сам, а не чужое (см. `MirrorEngine._consumeConfirmation`).
  Future<void> confirmDeletes() async {
    final store = mirrorStore;
    if (store == null) return;
    await store.setMeta(
      MirrorStore.keyConfirmed,
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    await mirrorPass();
  }

  /// Что удаления приостановлены и почему: «пропало слишком много» или «папка не читается».
  ///
  /// @return пару «сколько, почему» или `null`, если приостановок нет. Только чтение базы;
  ///         строка причины собирается из остатка после разделителя, поэтому её формат
  ///         менять нельзя, не поменяв запись.
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
    // Провайдер уничтожается — работа прекращается целиком: таймер сторожа, подписка
    // на состояние, мгновенный режим и базы. Раньше здесь закрывался только мгновенный режим,
    // а сторож продолжал будить изолят интерфейса и выгружать файлы, дёргая notifyListeners
    // у уже уничтоженного [ChangeNotifier]
    _disposed = true;
    _watchdog?.cancel();
    _watchdog = null;
    unawaited(_statusSubscription?.cancel());
    _statusSubscription = null;
    unawaited(live?.dispose());
    unawaited(_status.dispose());
    final queue = queueStore;
    final mirror = mirrorStore;
    queueStore = null;
    mirrorStore = null;
    if (queue != null) unawaited(queue.close());
    if (mirror != null) unawaited(mirror.close());
    super.dispose();
  }
}
