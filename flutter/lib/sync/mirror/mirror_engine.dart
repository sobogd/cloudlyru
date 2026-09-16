import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../data/mirror_store.dart';
import '../data/selection_rules.dart';
import '../data/sync_links.dart';
import '../device/hasher.dart';
import '../device/media_rules.dart';
import '../device/native_fs.dart';
import '../net/sync_api.dart';
import '../queue/uploader.dart';
import 'failure_streak.dart';
import 'mirror_folders.dart';
import 'mirror_models.dart';
import 'mirror_pull.dart';
import 'mirror_rules.dart';
import 'mirror_scanner.dart';
import 'mirror_status.dart';

/// Итог прохода: что удалось, что нет и почему.
///
/// Заполняет движок по ходу прохода, отсюда же берётся текст для интерфейса ([text]) и для
/// базы (`MirrorStore.keyReport`). Создаётся движком на каждый проход и возвращается
/// вызывающему — и при отказе тоже: ошибка приходит в [error], а не исключением.
class MirrorReport {
  /// Сколько файлов выгружено в облако (переименования считаются отдельно, в [renamed])
  /// и сколько скачано из облака на телефон.
  int uploaded = 0;
  int downloaded = 0;

  /// Сколько файлов переименовано в облаке вслед за телефоном.
  int renamed = 0;

  /// Сколько записей облака убрано в корзину: файлов, которых на телефоне больше нет.
  int deletedInCloud = 0;

  /// Пустые папки, убранные в облаке после переименований и удалений на телефоне.
  int removedFolders = 0;

  /// Файлы, удалённые на телефоне вслед за облаком (правка, которая не уехала, при этом
  /// сохраняется копией — в [conflicts]).
  int deletedOnPhone = 0;

  /// Разрешения конфликтов: столько файлов сохранено копиями с пометкой с той или другой
  /// стороны.
  int conflicts = 0;

  /// Сколько операций не вышло. Считаются по одной, поэтому проход продолжается.
  int failed = 0;

  /// Первые имена того, что не вышло («файл.pdf: нет доступа»). Счётчика «ошибок: N» для
  /// разбора мало: по нему нельзя понять, какие файлы не доехали.
  final List<String> failures = <String>[];

  /// Сколько имён попадает в отчёт: полный список на большой папке раздул бы строку итога.
  static const int maxFailures = 5;

  /// Запомнить, что именно не вышло. Хвост списка отбрасывается: в отчёте он уже не нужен,
  /// а память на проходе по сотне тысяч файлов тратить незачем.
  void noteFailure(String text) {
    if (failures.length < maxFailures) failures.add(text);
  }

  /// Сколько папок не удалось прочитать при обходе. Ненулевое значение запрещает удаления
  /// в облаке (см. [MirrorRules.deletionsAllowed]).
  int unreadable = 0;

  /// Обход упёрся в предел или был отменён и часть дерева не пройдена: удаления тоже запрещены.
  bool capped = false;

  /// Сколько удалений приостановил предохранитель и почему.
  int blockedDeletes = 0;
  String? blockedReason;

  /// Проход не доведён до конца: кончился бюджет времени, попросили остановку или оборвалась
  /// сеть. Именно по этому признаку [_finish] назначает догон.
  bool stopped = false;

  /// Ошибка, из-за которой проход закончился раньше: нет токена, нет связи, отозванный токен.
  String? error;

  /// Отказ авторизации устройства (401/403): токен отозван или истёк.
  ///
  /// Отдельный признак, а не разбор текста [error]: по нему [SyncController.mirrorPass]
  /// решает, что клиент синхронизации негоден и его надо выпустить заново.
  bool authFailed = false;

  /// Когда проход закончился: ставится в [_finish]. Ноль — проход не начинался (такой отчёт
  /// возвращается, когда работу отбил замок «проход уже идёт»): по нему видно, что догонять
  /// нечего, а не «проход шёл и упал».
  int finishedAt = 0;

  /// Итог одной строкой — то, что видит человек в настройках и в отчёте фонового задания.
  ///
  /// Печатаются только непустые счётчики: «нулей» в отчёте быть не должно. Побочных эффектов
  /// нет, но строку нельзя показывать до конца прохода — счётчики ещё растут.
  String text() {
    final out = StringBuffer('выгружено: $uploaded, скачано: $downloaded');
    if (renamed > 0) out.write(', переименовано: $renamed');
    if (deletedInCloud > 0) out.write(', удалено в облаке: $deletedInCloud');
    if (removedFolders > 0) out.write(', пустых папок убрано: $removedFolders');
    if (deletedOnPhone > 0) out.write(', удалено на телефоне: $deletedOnPhone');
    if (conflicts > 0) out.write(', конфликтов: $conflicts');
    if (failed > 0) out.write(', ошибок: $failed');
    if (unreadable > 0) out.write(', папок без доступа: $unreadable');
    if (capped) out.write(', обход неполный');
    if (failures.isNotEmpty) out.write(' (${failures.join('; ')})');
    if (blockedDeletes > 0) {
      out.write(', удаления приостановлены: $blockedDeletes');
    }
    if (stopped) out.write(', проход не закончен — продолжу в следующий раз');
    final err = error;
    if (err != null) out.write(' · $err');
    return out.toString();
  }
}

/// Двустороннее зеркало связанных папок раздела «Файлы»: содержимое телефона и папки в облаке
/// совпадает в обе стороны — как «зеркалирование» в Google Drive, но без «оптимизировать место»:
/// приложение никогда не удаляет файл на телефоне ради свободного места.
///
/// Что с чем связано, решает человек: пара «папка на устройстве ↔ папка в облаке» приходит
/// связками (см. `SyncLinks`). Движок ничего не заводит на верхнем уровне — связанная папка
/// в облаке уже существует, и содержимое папки телефона лежит прямо в ней. Ниже уровня связки
/// структура повторяется через `ensure-path`.
///
/// Порядок прохода:
///   1. корни — каждой связке ставится пара «папка телефона ↔ папка облака»;
///   2. облако → телефон: догон журнала (или полный проход, если курсора ещё нет);
///   3. телефон → облако: новые и изменившиеся файлы, переименования, удаления.
///
/// Облако идёт первым не случайно: решения по телефону принимаются по свежему состоянию
/// облака, иначе проход выгрузил бы версию, которую в облаке только что заменили.
///
/// Предохранители, без которых зеркало однажды выкосит облако:
///   • папка не читается или обход неполный — удаления в облаке не отправляются вовсе;
///   • пропало слишком много за один проход — удаления приостанавливаются до подтверждения.
/// Снятие связки удалением не считается: удаление приходит только из сравнения
/// с файловой системой, а папка без связки вообще вне области работы движка.
///
/// Проход можно прервать, и прерывание ничего не ломает: сверка идемпотентна — в базе
/// остаётся только сделанное (курсор журнала, строки выгруженного и пары папок), а остаток
/// доедет следующим проходом. Прерывают его трое:
///   • отмена снаружи ([pass.isCancelled]) — так система останавливает фоновое задание;
///   • бюджет времени ([defaultBudgetMs]) — проход заканчивает себя сам;
///   • сбой сети или отозванный токен — счётчик подряд идущих сбоев (см. [FailureStreak]).
/// В любом из этих случаев [_finish] ставит метку `retry_at`, по которой мгновенный режим
/// вернётся к работе сам (см. [MirrorRetryClock]).
///
/// Создаётся [SyncController] (один движок на приложение, живёт до выхода из аккаунта).
class MirrorEngine {
  /// Зависимости приходят готовыми: склад, связки, состояние и доступ к файлам заводит
  /// точка сборки ([SyncController]) — по одному движку на процесс.
  MirrorEngine(
    this._api,
    this._store,
    this._links, {
    MirrorStatusHolder? status,
    NativeFs? native,
  }) : _status = status ?? MirrorStatusHolder(),
       _native = native ?? NativeFs();

  /// Клиент синхронизации берётся функцией, а не значением: токен устройства выпускается
  /// после создания движка и может быть перевыпущен, а движок при этом остаётся тем же.
  final SyncApi Function() _api;
  final MirrorStore _store;

  /// Связки человека: что с чем синхронизировать. Читаются на каждом проходе — связки могли
  /// изменить, пока проход шёл (тогда это учтёт следующий).
  final SyncLinks _links;
  final MirrorStatusHolder _status;
  final NativeFs _native;

  /// Проход ограничен по времени: фоновая работа под присмотром системы, а не вечная.
  ///
  /// Восемь минут при фоновом задании, которое берёт семь (см. `backgroundPassBudgetMs`):
  /// остаток доезжает следующим проходом, а не обрывается системой на середине.
  static const int defaultBudgetMs = 8 * 60 * 1000;

  /// Через сколько вернуться к работе, если проход не влез в бюджет: вернуться надо скоро —
  /// работа просто не успела, а не сломалась.
  static const int retryAfterBudgetMs = 30000;

  /// Через сколько вернуться после сбоя сети или отозванного токена. Заметно дольше, чем после
  /// бюджета: иначе проход запускался бы каждые полминуты и снова упирался бы в те же таймауты,
  /// сжигая батарею.
  static const int retryAfterErrorMs = 5 * 60 * 1000;

  /// Один проход за раз. Проход запускают трое: опрос журнала (мгновенный режим), событие
  /// файловой системы и периодическое задание системы. Без замка они наложились бы друг на
  /// друга и стали бы спорить за одни и те же строки состояния.
  ///
  /// Замок внутрипроцессный и намеренно такой: это поле объекта, а не файл или запись в базе,
  /// поэтому он разводит только вызовы одного и того же движка. Фоновое задание живёт в своём
  /// изоляте со своим движком, и его от прохода приложения отделяет не замок, а проверки
  /// в фоновом проходе (задание снимается, если приложение на экране). Строки базы два
  /// процесса могут писать одновременно — от «database is locked» спасает `busy_timeout`.
  bool _busy = false;

  /// Значение метки подтверждения массового удаления, прочитанное в начале прохода.
  ///
  /// Флаг в базе один на оба движка (приложение и фоновое задание), и раньше любой закончившийся
  /// проход снимал его без разбора — вместе с чужим подтверждением, из-за чего задуманные
  /// человеком удаления не выполнялись. Здесь запоминается именно то значение, которое проход
  /// увидел: снимается только оно и только тем проходом, который может его израсходовать.
  /// Полностью задачу решает атомарный compare-and-swap в `MirrorStore` — это в чужих файлах.
  String? _confirmToken;

  /// Голова журнала изменений: нужна мгновенному режиму, чтобы понять, есть ли что догонять.
  ///
  /// К базе и диску не обращается: это один запрос к серверу. Ошибка уходит исключением
  /// вызывающему — тик мгновенного режима считает её сбоем связи.
  Future<int> syncHead() => _api().syncHead();

  /// @param budgetMs сколько можно работать за один проход. Фоновая работа ограничена системой,
  ///        а выгрузка гигабайтов идёт часами: остаток доедет следующим проходом.
  ///
  /// @param onProgress текст о ходе работы для интерфейса или лога; @param isCancelled — опрос
  ///        остановки.
  /// @return отчёт о проходе; ошибки приходят в нём, а не исключением.
  ///
  /// Побочные эффекты: сеть, файловая система телефона, запись в базу зеркала (строки
  /// выгруженного и папок, курсор журнала, метки повтора и подтверждения) и состояние
  /// в [_status]. Второй вызов во время идущего прохода работу не запускает — возвращает отчёт
  /// с ошибкой «проход уже идёт»; флаг снимается в `finally`, поэтому упавший проход
  /// не блокирует следующие.
  Future<MirrorReport> pass({
    void Function(String)? onProgress,
    bool Function()? isCancelled,
    int budgetMs = defaultBudgetMs,
  }) async {
    final progress = onProgress ?? (String _) {};
    final cancelled = isCancelled ?? () => false;
    if (_busy) return MirrorReport()..error = 'проход уже идёт';
    _busy = true;
    try {
      return await _passLocked(progress, cancelled, budgetMs);
    } catch (e) {
      // Тело прохода бросило исключение (ошибка базы, падение плагина, база закрыта выходом
      // из аккаунта) — наружу отдаём отчёт, а не исключение: вызывающие ждут отчёт.
      // Дальше `finally` вернёт фазу в idle: без этого интерфейс навсегда остался бы
      // на «выгружаю…», автодогон не запускался бы, а залипание пережило бы выход из аккаунта
      return _finishQuietly(MirrorReport()..error = 'проход прерван: $e');
    } finally {
      _busy = false;
      _confirmToken = null;
      _statusIdle();
    }
  }

  /// Привести состояние к idle, даже если проход упал на середине или база уже закрыта.
  ///
  /// [MirrorPhase.idle] — единственный признак того, что прохода нет: по нему интерфейс
  /// показывает «ждёт», а [SyncController.checkAndResume] решает, запускать ли новый проход.
  void _statusIdle() {
    if (_status.current.phase == MirrorPhase.idle) return;
    _status.update(
      (s) => s.copyWith(
        phase: MirrorPhase.idle,
        clearCurrentName: true,
        currentSent: 0,
        currentTotal: 0,
      ),
    );
  }

  /// [_finish], но не падающий: в конце прохода база может быть уже закрыта (выход
  /// из аккаунта), и тогда исходная ошибка важнее, чем невозможность записать отчёт.
  Future<MirrorReport> _finishQuietly(MirrorReport report) async {
    try {
      return await _finish(report);
    } catch (e) {
      debugPrint('cloudly-sync: отчёт о проходе не записан: $e');
      return report;
    }
  }

  /// Проход целиком, уже под замком: от проверки опознания аккаунта до уборки пустых папок.
  ///
  /// Здесь же — порядок фаз и всё, что нужно сделать до них: сброс состояния в интерфейсе,
  /// проверка, что состояние в базе принадлежит этому же аккаунту и устройству, постановка пар
  /// для связок (папки в облаке уже существуют — их выбрал человек).
  Future<MirrorReport> _passLocked(
    void Function(String) onProgress,
    bool Function() isCancelled,
    int budgetMs,
  ) async {
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final report = MirrorReport();
    // Кэш хэшей живёт один проход: между проходами файл мог быть подменён с сохранением
    // размера и даты, и старый хэш уехал бы на сервер как объявленный (см. _hashCache)
    _hashCache.clear();
    // Метка подтверждения массового удаления читается один раз, в начале: снять её мог
    // и чужой проход, а решение «удалять ли» принимается по тому, что было в начале
    _confirmToken = await _store.meta(MirrorStore.keyConfirmed);
    // итоги прошлого раза нужны с самого начала: интерфейс показывает их, пока проход идёт
    final inCloud = await _store.inCloud();
    final local = await _store.localTotals();
    // состояние сбрасывается сразу, а не по ходу: иначе на экране остались бы цифры прошлого
    // прохода и «выгружаю» от файла, который давно уехал
    _status.update(
      (s) => s.copyWith(
        phase: MirrorPhase.scan,
        currentName: null,
        clearCurrentName: true,
        currentSent: 0,
        currentTotal: 0,
        passUploadedFiles: 0,
        passUploadedBytes: 0,
        passDownloaded: 0,
        passFailed: 0,
        blocked: 0,
        clearError: true,
        startedAt: startedAt,
        inCloudFiles: inCloud.files,
        inCloudBytes: inCloud.bytes,
        localFiles: local.files,
        localBytes: local.bytes,
      ),
    );

    final SyncApi api;
    try {
      api = _api();
    } catch (e) {
      return _finish(report..error = 'нет доступа к синхронизации: $e');
    }

    MeInfo me;
    try {
      me = await api.meInfo();
    } catch (e) {
      return _finish(report..error = 'нет связи с сервером: $e');
    }
    // Связки: что с чем синхронизировать. Движок ничего не выбирает сам и ни одной папки
    // в облаке на верхнем уровне не заводит — папку облака выбирает человек
    final links = _links.all();
    final roots = SelectionRules.scanRoots({for (final l in links) l.localPath});
    final cloudByRoot = {
      for (final l in links) l.localPath: l.cloudId,
    };
    // Связку перенаправили на другую папку облака: строки `files` описывают записи в прежней
    // папке, и сверка сочла бы файлы уже выгруженными — новая папка осталась бы пустой.
    // Прежнее состояние берём из meta; строки там нет (база от сборки, где корень зеркала
    // заводил сервер) — тогда прежнее соответствие лежит в парах `roots`, и повторной
    // выгрузки из-за обновления приложения не будет
    final previous = await _previousLinks();
    // Связка появилась или сменила папку: в выбранной папке облака может уже что-то лежать,
    // и это надо забрать на телефон — человек связывает папки, чтобы они объединились.
    // Журнал про прошлое содержимое не рассказывает (он про изменения с курсора), поэтому
    // курсор снимаем: догон облака пойдёт полным проходом по папкам связок — тем же путём,
    // что при первом запуске (см. `MirrorPull.catchUp`), — и только потом догонит журнал
    var linksChanged = false;
    for (final link in links) {
      final was = previous[link.localPath];
      // Связка новая (в прежнем состоянии её нет) или ведёт в другую папку: пары прежней
      // цели снимаем, чтобы `dirId` не путал папки. Что выгружать в новую папку, решит
      // сверка по папкам облака (см. `_cloudIdsOfLinks`), а строки выгруженного остаются:
      // вернут связку к прежней папке — они снова на месте, и заливать заново не придётся
      if (was == link.cloudId) continue;
      linksChanged = true;
      await _store.dropDirMapping(link.localPath);
      if (was != null) {
        onProgress(
          'связка «${p.basename(link.localPath)}» ведёт в другую папку: собираю заново',
        );
      }
    }
    if (linksChanged) await _store.clearMeta(MirrorStore.keyCursor);
    await _store.setMeta(MirrorStore.keyLinks, _linksState(links, previous));

    // Состояние зеркала принадлежит аккаунту И устройству: строки `files` описывают записи
    // в конкретной папке облака. Сменили сервер или логин — строки прошлого аккаунта сделали бы
    // все локальные файлы «уже выгруженными».
    //
    // Проверка по устройству закрывает и случай базы от старого нативного клиента: у неё есть
    // device_id прежнего токена, и он не совпадёт с нынешним.
    final identity = '${api.serverUrl}|${me.login}';
    final wasAccount = await _store.meta(MirrorStore.keyAccount);
    final wasDevice = await _store.meta(MirrorStore.keyDeviceId);
    final otherAccount = wasAccount != null && wasAccount != identity;
    final otherDevice =
        wasDevice != null &&
        wasDevice.isNotEmpty &&
        me.deviceId != null &&
        wasDevice != me.deviceId;
    if (otherAccount || otherDevice) {
      // чужое состояние выкидываем целиком: держать его — значит считать чужие записи своими,
      // а свои файлы — уже выгруженными. Всё содержимое уедет заново, в папки связок
      await _store.wipe();
      _status.update(
        (s) => s.copyWith(
          inCloudFiles: 0,
          inCloudBytes: 0,
          waitingFiles: 0,
          waitingBytes: 0,
        ),
      );
    }
    await _store.setMeta(MirrorStore.keyAccount, identity);
    await _store.setMeta(MirrorStore.keyDeviceId, me.deviceId ?? '');

    final folders = MirrorFolders(api, _store);
    // Папок вне связок зеркало не касается вовсе: снятую связку убираем из пар, а строки
    // выгруженного остаются — вернуть связку можно без повторной заливки и без удаления
    // в облаке, и уборка пустых папок в чужое дерево тоже не полезет (`roots` — её область)
    for (final gone in (await _store.roots()).keys.where(
      (r) => !roots.contains(r),
    )) {
      await _store.dropRoot(gone);
    }
    // фаза корней: связка становится парой «папка телефона ↔ папка облака». Сети здесь нет
    // вовсе — папка в облаке уже существует, её выбрал человек
    for (final link in links) {
      if (isCancelled()) return _finish(report..stopped = true);
      await _store.putRoot(link.localPath, link.cloudId, link.cloudPath);
    }

    // 1) облако → телефон
    final pull = MirrorPull(
      api,
      _store,
      me.deviceId,
      onProgress,
      native: _native,
    );
    if (roots.isNotEmpty) {
      _status.update((s) => s.copyWith(phase: MirrorPhase.cloud));
      onProgress('догоняю облако…');
      // Облачная часть идёт до диска и сети так же долго, как выгрузка, поэтому подчиняется
      // тому же бюджету прохода и той же отмене: без них система обрывала бы фон, а проход
      // не знал бы, что остаток надо догнать
      await pull.catchUp(
        isCancelled: isCancelled,
        deadlineMs: startedAt + budgetMs,
      );
    }
    _fill(report, pull);
    final fatal = pull.fatal;
    // связь или токен сломались — выгружать в такие ворота нельзя: всё равно не уедет,
    // а строки состояния разъедутся с облаком
    if (fatal != null) return _finish(report..error = fatal);
    // облачная часть не докончена (отмена или кончился бюджет) — к обходу диска не переходим:
    // иначе проход вышел бы за отведённое время ещё сильнее, а [_finish] назначит догон
    if (pull.stopped) return _finish(report);

    // 2) телефон → облако
    if (roots.isNotEmpty) {
      await _pushLocal(
        roots: roots,
        folders: folders,
        cloudByRoot: cloudByRoot,
        api: api,
        pull: pull,
        report: report,
        onProgress: onProgress,
        isCancelled: isCancelled,
        startedAt: startedAt,
        budgetMs: budgetMs,
      );
    }

    return _finish(report);
  }

  /// Папки облака, которые сейчас принадлежат связкам: папка связки и всё, что заведено
  /// под ней.
  ///
  /// Источник — пары «папка облака ↔ путь на телефоне» из базы: их ставит фаза корней (сама
  /// связка) и заведение подпапок обхода (`ensure-path`). Поэтому к моменту сверки набор
  /// описывает ровно текущее дерево связок, а папки прежней цели в него не попадают —
  /// строки зеркала, которые на них смотрят, из плана выгрузки исключаются.
  ///
  /// @param roots пути на телефоне из связок. @return id папок облака в области связок;
  ///         только чтение базы, побочных эффектов нет.
  Future<Set<String>> _cloudIdsOfLinks(List<String> roots) async {
    final dirs = await _store.allDirs();
    return {
      for (final entry in dirs.entries)
        if (MirrorRules.underRoots(entry.value, roots)) entry.key,
    };
  }

  /// Прежнее состояние связок: путь на телефоне → id папки облака.
  ///
  /// Читается из `meta` ([MirrorStore.keyLinks]). Строки там нет у базы, которую завела сборка
  /// с корнем зеркала устройства: тогда прежнее соответствие — это пары `roots`, и берём их,
  /// иначе обновление приложения выглядело бы как «цель связки сменилась» и залило бы всё заново.
  /// Испорченное значение даёт пустую карту: это «не знаем прежнего», а не ошибка прохода.
  Future<Map<String, String>> _previousLinks() async {
    final raw = await _store.meta(MirrorStore.keyLinks);
    if (raw == null) {
      final pairs = await _store.roots();
      return {
        for (final entry in pairs.entries) entry.key: entry.value.cloudId,
      };
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } catch (_) {
      return const {};
    }
  }

  /// Состояние связок для следующего прохода: что связано сейчас плюс то, что было связано
  /// раньше.
  ///
  /// Прежние записи сохраняются намеренно: связку сняли и вернули с той же папкой облака —
  /// по прежней записи видно, что цель не менялась, и выгружать всё заново не нужно.
  static String _linksState(
    List<SyncLink> links,
    Map<String, String> previous,
  ) {
    final state = {...previous};
    for (final link in links) {
      state[link.localPath] = link.cloudId;
    }
    return jsonEncode(state);
  }

  /// Папка облака той связки, внутри которой лежит путь на телефоне.
  ///
  /// По ней заводится папка для подпапки (`ensure-path` ищет и создаёт по имени внутри
  /// родителя). Из двух подходящих связок берётся самая длинная: вложенные связки форма
  /// не пропускает, но выбор обязан быть определённым. `null` — путь не под связкой: обход
  /// идёт только по связкам, и такого пути в снимке быть не может.
  static String? _cloudIdFor(String path, Map<String, String> cloudByRoot) {
    String? best;
    for (final root in cloudByRoot.keys) {
      if (path != root && !path.startsWith('$root/')) continue;
      if (best == null || root.length > best.length) best = root;
    }
    return best == null ? null : cloudByRoot[best];
  }

  /// Только облачная сторона: догнать журнал, не трогая диск. Так работает мгновенный режим:
  /// правка из веба приезжает за секунды, а полный обход папок ради этого не нужен — он
  /// остаётся за событиями файловой системы и периодическим проходом.
  ///
  /// В отличие от [pass] не проверяет ни аккаунт, ни корень зеркала: состояния строк здесь
  /// не переписываются, только дочитываются — за это отвечает обычный проход.
  /// Побочные эффекты: сеть, скачивание файлов, запись в базу и состояние в [status].
  /// Возвращает отчёт: ошибка связи и отозванный токен приходят в нём, а не исключением.
  Future<MirrorReport> catchUpCloud({
    void Function(String)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final progress = onProgress ?? (String _) {};
    final cancelled = isCancelled ?? () => false;
    if (_busy) return MirrorReport()..error = 'проход уже идёт';
    _busy = true;
    final report = MirrorReport();
    try {
      final SyncApi api;
      try {
        api = _api();
      } catch (e) {
        return report..error = 'нет доступа к синхронизации: $e';
      }
      MeInfo me;
      try {
        me = await api.meInfo();
      } catch (e) {
        return report..error = 'нет связи с сервером: $e';
      }
      // номер устройства пишем в базу: он нужен, чтобы отсеивать свои же правки в журнале
      await _store.setMeta(MirrorStore.keyDeviceId, me.deviceId ?? '');
      _status.update(
        (s) => s.copyWith(
          phase: MirrorPhase.cloud,
          startedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      final pull = MirrorPull(
        api,
        _store,
        me.deviceId,
        progress,
        native: _native,
      );
      await pull.catchUp(isCancelled: isCancelled);
      _fill(report, pull);
      report.error = pull.fatal;
      // отмену проверяем на выходе: проход уже сделан, но догон не докончен —
      // вызывающий по этому признаку поймёт, что остаток ждёт следующего раза
      report.stopped = report.stopped || cancelled();
      return await _finish(report);
    } catch (e) {
      // то же, что и в [pass]: наружу отчёт, а не исключение, и фаза обязана вернуться в idle
      return _finishQuietly(report..error = 'догон прерван: $e');
    } finally {
      _busy = false;
      _statusIdle();
    }
  }

  /// Итог прохода: пишем отчёт в базу и гасим состояние. Одна точка выхода — иначе при любой
  /// новой ветке «рано вернулись» в интерфейсе навсегда осталось бы «выгружаю…».
  ///
  /// Побочные эффекты: метка догона, снятие подтверждения массового удаления, отчёт в базе
  /// и обновление [_status] (фаза возвращается в [MirrorPhase.idle] — по этому признаку
  /// интерфейс считает, что проход кончился).
  Future<MirrorReport> _finish(MirrorReport report) async {
    report.finishedAt = DateTime.now().millisecondsSinceEpoch;
    // Проход не докончен (бюджет времени, остановка) или сорвался (нет связи, отозванный
    // токен): назначаем догон, иначе работа так и останется стоять до следующего события
    // файловой системы или до задания системы. Кнопки «продолжить» в приложении нет
    // намеренно — синхронизация обязана догонять себя сама, а подхватывает метку мгновенный
    // режим (см. [MirrorRetryClock]).
    if (report.stopped || report.error != null) {
      // Кончился бюджет — возвращаемся скоро, работа просто не влезла в отведённое время.
      // Отказ сети или токена — ждём дольше: иначе проход будет запускаться каждые полминуты
      // и снова упираться в те же таймауты, сжигая батарею.
      final delayMs = report.error == null
          ? retryAfterBudgetMs
          : retryAfterErrorMs;
      await _store.setMeta(
        MirrorStore.keyRetryAt,
        '${DateTime.now().millisecondsSinceEpoch + delayMs}',
      );
    }
    // Подтверждение массового удаления живёт ровно один проход: если проход до разбора удалений
    // не дошёл, флаг всё равно должен сгореть, иначе он сработает в следующем — уже на другом
    // наборе файлов. Снимается при этом только то значение, которое проход прочитал сам:
    // флаг в базе один на приложение и фоновое задание, и раньше любой закончившийся проход
    // снимал чужое подтверждение, из-за чего задуманные человеком удаления не выполнялись
    await _consumeConfirmation();
    await _store.setMeta(MirrorStore.keyReport, report.text());
    // итоги перечитываем из базы: за проход они изменились, а в отчёте их нет
    final inCloud = await _store.inCloud();
    final waiting = await _store.waitingTotals();
    _status.update(
      (s) => s.copyWith(
        phase: MirrorPhase.idle,
        clearCurrentName: true,
        currentSent: 0,
        currentTotal: 0,
        passUploadedFiles: report.uploaded,
        passDownloaded: report.downloaded,
        passFailed: report.failed,
        inCloudFiles: inCloud.files,
        inCloudBytes: inCloud.bytes,
        waitingFiles: waiting.files,
        waitingBytes: waiting.bytes,
        unreadable: report.unreadable,
        capped: report.capped,
        finishedAt: report.finishedAt,
        lastText: report.text(),
        error: report.error,
        clearError: report.error == null,
        blocked: report.blockedDeletes,
        blockedReason: report.blockedReason,
        clearBlockedReason: report.blockedReason == null,
      ),
    );
    return report;
  }

  /// Израсходовать подтверждение массового удаления — своё, а не чужое.
  ///
  /// Значение читается в начале прохода ([_confirmToken]) и снимается атомарно
  /// (`MirrorStore.takeConfirmed`): флаг в базе один на приложение и фоновое задание, а метка
  /// уникальна на каждое нажатие. Если подтверждение уже снял другой проход, расходовать
  /// нечего — и это не ошибка.
  Future<void> _consumeConfirmation() async {
    final token = _confirmToken;
    _confirmToken = null;
    if (token == null) return;
    await _store.takeConfirmed(token);
  }

  /// Перенести счётчики облачного прохода в общий итог.
  ///
  /// Складываются, а не присваиваются: [MirrorPull] заводится на каждый догон, а проход
  /// мог догонять облако дважды (журналом с `resetRequired` и полным обходом).
  void _fill(MirrorReport report, MirrorPull pull) {
    report.downloaded += pull.downloaded;
    report.deletedOnPhone += pull.deletedLocal;
    report.conflicts += pull.conflicts;
    report.renamed += pull.renamedLocal;
    report.failed += pull.failed;
    report.authFailed = report.authFailed || pull.authFailed;
    if (pull.stopped) report.stopped = true;
    // Имена того, что не доехало: счётчика «ошибок: N» для разбора мало
    for (final note in pull.problems) {
      report.noteFailure(note);
    }
  }

  /// Фаза «телефон → облако»: снимок диска, план и его выполнение.
  ///
  /// Порядок внутри фазы продуман:
  ///   1. обход диска — по нему же считаются итоги для интерфейса;
  ///   2. папки: структура в облаке должна существовать до того, как в неё полетит файл;
  ///   3. план — что выгрузить, переименовать и удалить;
  ///   4. переименования, потом выгрузка, потом удаления, потом уборка пустых папок.
  ///
  /// Переименования идут первыми, потому что выгрузка изменившегося файла должна идти уже
  /// по новому пути, а удаления — последними: они самое необратимое, и до них проход должен
  /// убедиться, что снимок полон и читаем.
  ///
  /// Прервать фазу можно в четырёх точках (отмена или бюджет), и в каждой в базу уже записано
  /// ровно сделанное: пары папок, строки выгруженного, метка догона. Незавершённая выгрузка
  /// оставляет после себя сессию в `uploads` — по ней следующий проход продолжит с принятой
  /// части, а не начнёт файл заново.
  Future<void> _pushLocal({
    required List<String> roots,
    required MirrorFolders folders,
    required Map<String, String> cloudByRoot,
    required SyncApi api,
    required MirrorPull pull,
    required MirrorReport report,
    required void Function(String) onProgress,
    required bool Function() isCancelled,
    required int startedAt,
    required int budgetMs,
  }) async {
    final snapshot = await MirrorScanner(native: _native)
        .snapshot(roots, onProgress: onProgress, isCancelled: isCancelled);
    report.unreadable = snapshot.unreadable;
    report.capped = snapshot.capped;
    // сколько всего лежит в связанных папках: от этого считается доля выгруженного
    final localBytes = snapshot.files.fold<int>(0, (sum, f) => sum + f.size);
    await _store.setLocalTotals(snapshot.files.length, localBytes);
    _status.update(
      (s) => s.copyWith(
        phase: MirrorPhase.upload,
        localFiles: snapshot.files.length,
        localBytes: localBytes,
        unreadable: snapshot.unreadable,
        capped: snapshot.capped,
      ),
    );

    // структура в облаке повторяет структуру телефона, включая пустые папки: подпапки
    // заводятся внутри папки связки (`ensure-path`), а сама папка связки уже существует.
    // Счётчик сбоев тот же по смыслу, что у выгрузки: при отвалившейся сети заведение каждой
    // папки стоило бы своего таймаута, а проход молотил бы весь бюджет впустую
    final folderStreak = FailureStreak();
    for (final dir in snapshot.dirs) {
      if (isCancelled()) {
        report.stopped = true;
        return;
      }
      // Папка связки, внутри которой лежит эта подпапка. Пусто — пути нет ни под одной связкой:
      // обход идёт только по связкам, и такого пути в снимке быть не может, но заводить папку
      // «куда-нибудь» нельзя — пропускаем
      final parentId = _cloudIdFor(dir.path, cloudByRoot);
      if (parentId == null) continue;
      try {
        await folders.ensure(dir.relDir, dir.path, parentId);
        folderStreak.success();
      } catch (e) {
        // папку заведёт следующий проход: файлы в неё всё равно не уедут, пока её нет
        report.failed += 1;
        report.noteFailure('папка ${p.basename(dir.path)}: $e');
        if (folderStreak.failure(e)) {
          report.error = folderStreak.reason;
          report.authFailed = folderStreak.authFailed;
          report.stopped = true;
          return;
        }
      }
    }

    // Подтверждение массового удаления — то, что проход прочитал в самом начале
    // (см. _confirmToken): оно кладётся кнопкой в настройках и живёт ровно один проход.
    // Здесь же оно и расходуется — снять его успеет и [_finish], если проход сюда не дошёл
    final confirmed = (_confirmToken ?? '').isNotEmpty;
    final deletionsAllowed = MirrorRules.deletionsAllowed(snapshot);
    // Папки облака, которые принадлежат связкам сейчас: папка связки и всё, что зеркало
    // завело под ней. Строка `files` действительна ровно для своей папки: если связку
    // перевели на другую папку, файлы под ней выгружаются заново — в новую папку, а прежние
    // копии в облаке остаются на месте (человек связывает папки, чтобы содержимое было и там,
    // и там). Без этой проверки сверка считала бы файл выгруженным по строке, которая
    // описывает запись в другой папке, и новая папка осталась бы пустой.
    //
    // Дубликатов при этом не будет: содержимое сервер схлопывает по sha256 (байты не
    // передаются), а совпавшие по имени и дате файлы сверка узнаёт на облачной стороне
    // и заводит строку без скачивания (см. `MirrorRules.decideRecord`).
    final cloudIds = await _cloudIdsOfLinks(roots);
    final allKnown = await _store.files();
    // строки, относящиеся к связанным сейчас папкам и к их папкам облака: копию таблицы
    // на большой библиотеке делать нельзя, а без отсечения сверка удалила бы содержимое
    // папки, связку с которой сняли
    final known = {
      for (final entry in allKnown.entries)
        if (cloudIds.contains(entry.value.cloudFolderId))
          entry.key: entry.value,
    };
    final plan = MirrorRules.plan(
      local: snapshot.files,
      known: known,
      now: DateTime.now().millisecondsSinceEpoch,
      deletionsAllowed: deletionsAllowed,
      confirmed: confirmed,
      inScope: (path) => MirrorRules.underRoots(path, roots),
      // знаменатель предохранителя — строки текущих корней, а не вся таблица: иначе
      // в выборке «одна папка» доля пропавших занижалась бы во столько раз, во сколько
      // библиотека больше выборки, и предохранитель не срабатывал бы. Считается по всем
      // строкам корней, включая те, что описывают записи в чужой папке облака: это
      // по-прежнему наши строки, и знаменатель не должен скакать от смены связки
      knownInScope: () => allKnown.values
          .where((row) => MirrorRules.underRoots(row.path, roots))
          .length,
    );

    // отложенные файлы (ещё пишутся) не забываем: к ним вернёмся через окно стабильности
    if (plan.unstable > 0) {
      await _store.setMeta(
        MirrorStore.keyRetryAt,
        '${DateTime.now().millisecondsSinceEpoch + MirrorRules.stableMs}',
      );
    } else {
      // всё устоялось — прошлая метка больше не нужна, иначе мгновенный режим ходил бы
      // на пустой проход
      await _store.clearMeta(MirrorStore.keyRetryAt);
    }
    final waitingBytes = plan.uploads.fold<int>(0, (sum, f) => sum + f.size);
    await _store.setWaitingTotals(plan.uploads.length, waitingBytes);
    _status.update(
      (s) => s.copyWith(
        waitingFiles: plan.uploads.length,
        waitingBytes: waitingBytes,
        blocked: plan.blockedCount,
        localFiles: snapshot.files.length,
        localBytes: localBytes,
      ),
    );

    // Причина приостановки уходит в базу строкой «сколько|почему»: её читают настройки,
    // чтобы объяснить человеку, чего от него ждут
    if (plan.blocked) {
      final reason = deletionsAllowed
          ? 'одним проходом пропало слишком много файлов'
          : 'часть папок не читается или обход неполный';
      await _store.setMeta(
        MirrorStore.keyBlocked,
        '${plan.blockedCount}|$reason',
      );
      report.blockedDeletes = plan.blockedCount;
      report.blockedReason = reason;
    } else {
      await _store.clearMeta(MirrorStore.keyBlocked);
    }

    // Сеть может отвалиться посреди прохода: без счётчика каждый следующий файл ждал бы
    // таймаута, а проход молотил бы весь бюджет впустую (см. FailureStreak).
    // Счётчик один на всю фазу: подряд идущими считаются переименования, выгрузки и удаления
    // вместе — сеть-то одна
    final streak = FailureStreak();

    // переименования первыми: выгрузка изменившегося файла пойдёт уже по новому пути
    for (final (row, file) in plan.renames) {
      if (_outOfTime(startedAt, budgetMs) || isCancelled()) {
        report.stopped = true;
        return;
      }
      // папка берётся из пар (её могло не быть при первом проходе), а если пары нет —
      // та, что записана в строке: запись в облаке от этого не потеряется
      final folderId = await _store.dirId(file.dir) ?? row.cloudFolderId;
      try {
        await api.moveFile(row.entryId, folderId, file.name);
        // строку переписываем на новый путь, а не заводим новую: иначе сверка сочла бы
        // файл новым, а прежнюю запись — пропавшей
        final moved = MirrorRow(
          path: file.path,
          cloudFolderId: folderId,
          entryId: row.entryId,
          inode: file.inode,
          size: file.size,
          mtime: file.mtime,
          sha256: row.sha256,
        );
        // карту known правим здесь же: ниже по ней будет считаться выгрузка, а план
        // составлялся до переименований
        known.remove(row.path);
        known[file.path] = moved;
        await _store.moveFile(row.path, moved);
        report.renamed += 1;
        streak.success();
        onProgress('переименовано: ${file.name}');
      } catch (e) {
        report.failed += 1;
        report.noteFailure('${file.name}: $e');
        // сеть легла — дальше нет смысла: остальное доедет следующим проходом
        if (streak.failure(e)) {
          report.error = streak.reason;
          report.authFailed = streak.authFailed;
          report.stopped = true;
          return;
        }
      }
    }

    for (final file in plan.uploads) {
      if (_outOfTime(startedAt, budgetMs) || isCancelled()) {
        report.stopped = true;
        return;
      }
      final folderId = await _store.dirId(file.dir);
      if (folderId == null) {
        // папки нет в парах: её не завёл завод корней и не завёл обход — выгружать некуда
        report.failed += 1;
        continue;
      }
      try {
        await _upload(
          api: api,
          file: file,
          folderId: folderId,
          known: known,
          pull: pull,
          report: report,
          onProgress: onProgress,
        );
        streak.success();
      } catch (e) {
        report.failed += 1;
        report.noteFailure('${file.name}: $e');
        onProgress('не выгрузилось ${file.name}: $e');
        if (streak.failure(e)) {
          report.error = streak.reason;
          report.authFailed = streak.authFailed;
          report.stopped = true;
          return;
        }
      }
    }

    // фаза удалений объявляется только когда удаления действительно есть: иначе в интерфейсе
    // мелькало бы «убираю в облаке» на проходе, который ничего не убирает
    if (plan.deletes.isNotEmpty) {
      _status.update(
        (s) => s.copyWith(phase: MirrorPhase.delete, clearCurrentName: true),
      );
    }
    for (final row in plan.deletes) {
      if (_outOfTime(startedAt, budgetMs) || isCancelled()) {
        report.stopped = true;
        return;
      }
      try {
        await api.deleteFile(row.entryId);
        // запись ушла в корзину — строку снимаем, иначе будем удалять её в каждом проходе
        known.remove(row.path);
        await _store.dropFile(row.path);
        report.deletedInCloud += 1;
        // счётчик «в облаке» уменьшаем на ходу: интерфейс смотрит на него во время прохода
        _status.update(
          (s) => s.copyWith(
            inCloudFiles: s.inCloudFiles > 0 ? s.inCloudFiles - 1 : 0,
            inCloudBytes: s.inCloudBytes - row.size > 0
                ? s.inCloudBytes - row.size
                : 0,
          ),
        );
        onProgress('удалено в облаке: ${p.basename(row.path)}');
      } on SyncApiException catch (e) {
        // 404 — записи в облаке уже нет: строку всё равно убираем, иначе будем пытаться
        // удалить её в каждом проходе
        if (e.status == 404) {
          known.remove(row.path);
          await _store.dropFile(row.path);
        } else {
          report.failed += 1;
          report.noteFailure('удаление ${p.basename(row.path)}: $e');
          if (streak.failure(e)) {
            report.error = streak.reason;
            report.authFailed = streak.authFailed;
            report.stopped = true;
            return;
          }
        }
      } catch (e) {
        report.failed += 1;
        report.noteFailure('удаление ${p.basename(row.path)}: $e');
        if (streak.failure(e)) {
          report.error = streak.reason;
          report.authFailed = streak.authFailed;
          report.stopped = true;
          return;
        }
      }
    }

    // Хвост после переименований и удалений: папки, которые завело зеркало и которых больше
    // нет на телефоне. Убираем только пустые и только по полному снимку — папка с содержимым
    // не тронется ни при каких условиях.
    // Бюджет здесь проверяется ещё раз: если время уже вышло, пустые папки подождёт следующий
    // проход — уборка необязательна, и метку догона ради неё не ставим (признак остановки
    // в этой ветке не выставляется)
    if (deletionsAllowed &&
        !isCancelled() &&
        !_outOfTime(startedAt, budgetMs)) {
      await _sweepEmptyFolders(
        api: api,
        roots: roots,
        snapshot: snapshot,
        report: report,
        onProgress: onProgress,
        isCancelled: isCancelled,
        startedAt: startedAt,
        budgetMs: budgetMs,
      );
    }

    // Сессии прерванных выгрузок по исчезнувшим файлам: строка `uploads` ключуется путём,
    // а путь мог пропасть вместе с файлом (его удалили, папку переименовали, карту вынули).
    // Такая сессия не «продолжение», а мусор: файла нет, и продолжить её нечем — зато место
    // в таблице она держит и на следующем проходе сверяется со свежим файлом по тому же пути.
    // Уборка необязательная: не убралось сейчас — уберётся в следующий раз.
    if (!isCancelled()) await _dropStaleSessions();
  }

  /// Убрать сессии выгрузок, у которых на телефоне больше нет файла.
  ///
  /// Снимаем только те, чей путь точно исчез: ошибку `exists` трактуем как «файл есть» —
  /// терять живую сессию из-за разового отказа файловой системы нельзя, докачка после обрыва
  /// дороже мусорной строки.
  Future<void> _dropStaleSessions() async {
    try {
      for (final s in await _store.allUploadSessions()) {
        if (await File(s.path).exists()) continue;
        await _store.dropUploadSession(s.path);
      }
    } catch (e) {
      // Уборка мусора не повод считать проход неудачным
      debugPrint('cloudly-sync: сессии выгрузок не убраны: $e');
    }
  }

  /// Сколько пустых папок убираем за один проход. Папка уходит отдельным запросом, а после
  /// переименования большого дерева кандидатов бывает сотни: остальное доедет следующим разом.
  static const int _maxFolderSweep = 200;

  /// Убрать в облаке опустевшие папки, оставшиеся от переименований и удалений на телефоне.
  ///
  /// Зеркало удаляет в облаке только файлы, поэтому папка, из которой файлы перенесли,
  /// оставалась там навсегда. Здесь она уходит — но лишь при трёх условиях сразу: её завело
  /// зеркало, на телефоне её больше нет и она внутри связанных папок. Плюс на момент удаления
  /// в ней должно быть пусто: если сверка ошиблась и содержимое осталось, папка останется тоже.
  ///
  /// Список кандидатов считает [MirrorRules.emptyFolderCandidates] — без запросов; пустоту
  /// здесь проверяет листинг облака. Побочные эффекты: удаление папок в облаке, снятие пар
  /// в базе и счётчик в отчёте. Сбой одной папки (её удалили в вебе, в неё что-то легло)
  /// проход не останавливает и в ошибки не пишется.
  ///
  /// Бюджет проверяется и внутри цикла: до [_maxFolderSweep] итераций по два запроса каждая —
  /// это минуты, а фоновая работа обязана влезать в окно задания системы. Остаток доедет
  /// следующим проходом: уборка пустых папок не срочная.
  Future<void> _sweepEmptyFolders({
    required SyncApi api,
    required List<String> roots,
    required LocalSnapshot snapshot,
    required MirrorReport report,
    required void Function(String) onProgress,
    required bool Function() isCancelled,
    required int startedAt,
    required int budgetMs,
  }) async {
    // корни связанных папок: их пары тоже лежат в dirs, но корень — это адрес, по которому
    // лежит всё содержимое, и удалять его нельзя
    final rootIds = {for (final r in (await _store.roots()).values) r.cloudId};
    final candidates = MirrorRules.emptyFolderCandidates(
      dirs: await _store.allDirs(),
      aliveLocally: {for (final d in snapshot.dirs) d.path},
      roots: roots,
      rootCloudIds: rootIds,
    );
    var removed = 0;
    for (final localPath in candidates) {
      if (removed >= _maxFolderSweep || isCancelled()) break;
      if (_outOfTime(startedAt, budgetMs)) {
        // Проход кончился по времени, а уборка не докончена: признак остановки выставляем —
        // остаток должен доехать, и [_finish] назначит догон, а не будет ждать события
        // файловой системы или задания системы
        report.stopped = true;
        onProgress('пустые папки: успел убрать $removed, остальное — в следующий раз');
        break;
      }
      final cloudId = (await _store.dirId(localPath)) ?? '';
      if (cloudId.isEmpty) continue;
      try {
        final children = await api.children(cloudId);
        // непустая папка — не наш случай: содержимое могло остаться и после переименования
        if (children.entries.isNotEmpty || children.folderIds.isNotEmpty) {
          continue;
        }
        await api.deleteFolder(cloudId);
        await _store.dropDir(cloudId);
        removed += 1;
      } catch (_) {
        // папку могли удалить в вебе или в неё что-то легло: следующий проход разберётся
      }
    }
    if (removed > 0) {
      report.removedFolders += removed;
      onProgress('убрано пустых папок: $removed');
    }
  }

  /// Выгрузка одного файла.
  ///
  /// Конфликтом считается ответ сервера про расхождение версий (`stale_version`), про занятое
  /// имя (`conflict`) и про имя, занятое записью из корзины (`in_trash`): в первых двух случаях
  /// содержимое обеих сторон сохраняется — локальная версия уезжает копией с пометкой, а по
  /// каноническому имени скачивается версия облака; в третьем живой записи с таким именем нет,
  /// поэтому копии не будет и строка просто снимается (см. [_resolveConflict]). Молча затирать
  /// нельзя ни там, ни тут.
  ///
  /// Оговорка про занятое имя: `stale_version` приходит только при `replace: true`, то есть
  /// когда запись уже наша (тогда мы и передаём `expectedSha256`), а `conflict` сервер бросает
  /// из переименования и переноса — не из загрузки. Значит на пути «заливаем новый файл,
  /// а имя в облаке занято» этой защиты может не быть вовсе: проверить на живом сервере
  /// (см. `nameConflict` в `src/files/files.service.ts`) — если так, молчаливая перезапись
  /// чужой записи возможна, и это уже серверная сторона.
  ///
  /// Побочные эффекты: чтение файла (хэш), сеть, строка в базе (`files`), сессия выгрузки
  /// в `uploads` и состояние в [status]. Ошибки сети и сервера уходят исключением наверх —
  /// их считает счётчик подряд идущих сбоев; конфликтные коды разбираются здесь и наружу
  /// не выходят.
  Future<void> _upload({
    required SyncApi api,
    required LocalFile file,
    required String folderId,
    required Map<String, MirrorRow> known,
    required MirrorPull pull,
    required MirrorReport report,
    required void Function(String) onProgress,
  }) async {
    final local = File(file.path);
    // файл мог исчезнуть между обходом и выгрузкой: это не ошибка — сверка просто ничего
    // не выгружает, а строку снимет удаление на следующем проходе
    if (!await local.exists()) return;
    final row = known[file.path];
    _status.update(
      (s) => s.copyWith(
        phase: MirrorPhase.upload,
        currentName: file.name,
        currentSent: 0,
        currentTotal: file.size,
      ),
    );
    final sha = await _hash(local);
    void progress(int sent, int total) {
      _status.update((s) => s.copyWith(currentSent: sent, currentTotal: total));
      onProgress('${file.name}: $sent из $total');
    }

    // Незавершённая выгрузка этого же содержимого — продолжаем с принятой части: заново лить
    // двухгигабайтное видео после каждой остановки нельзя, и прогресс не должен прыгать назад.
    // Хэш в слепке обязателен: если файл успели изменить, сессия не подходит.
    final session = await _store.uploadSession(file.path);
    final resumable =
        session != null &&
        session.folderId == folderId &&
        session.size == file.size &&
        session.mtime == file.mtime &&
        session.sha256 == sha;

    UploadResult result;
    try {
      if (resumable) {
        try {
          result = await Uploader(api).resume(
            uploadId: session.uploadId,
            file: local,
            sha256: sha,
            onProgress: progress,
          );
        } catch (_) {
          // сессия на сервере могла истечь — тогда только с начала
          await api.abort(session.uploadId);
          await _store.dropUploadSession(file.path);
          result = await _startUpload(
            api: api,
            file: file,
            folderId: folderId,
            local: local,
            sha: sha,
            row: row,
            progress: progress,
          );
        }
      } else {
        // сессия не подходит (другая папка, изменился файл): её надо закрыть, иначе она
        // останется висеть на сервере
        await _store.dropUploadSession(file.path);
        result = await _startUpload(
          api: api,
          file: file,
          folderId: folderId,
          local: local,
          sha: sha,
          row: row,
          progress: progress,
        );
      }
    } on SyncDirectUnavailable catch (e) {
      // Хранилище с этого телефона недоступно (сеть, VPN, блокировщик): льём через сервер.
      // Иначе файл упирался бы в мёртвый хост в каждом проходе и не уехал бы никогда.
      onProgress(
        '${file.name}: хранилище недоступно (${e.message}) — лью через сервер',
      );
      // сессия прямого пути больше не годится: её закрываем, иначе она останется висеть
      final broken = await _store.uploadSession(file.path);
      if (broken != null) {
        await api.abort(broken.uploadId);
        await _store.dropUploadSession(file.path);
      }
      result = await _startUpload(
        api: api,
        file: file,
        folderId: folderId,
        local: local,
        sha: sha,
        row: row,
        progress: progress,
        forceRelay: true,
      );
    } on SyncApiException catch (e) {
      if (e.code == 'stale_version' ||
          e.code == 'conflict' ||
          e.code == 'in_trash') {
        // разрешение конфликта делает свою выгрузку (копией) и своё скачивание,
        // поэтому счётчики ведёт оно; наверх ничего не бросаем — это не сбой
        await _resolveConflict(
          api: api,
          file: file,
          folderId: folderId,
          known: known,
          pull: pull,
          report: report,
          onProgress: onProgress,
        );
        return;
      }
      rethrow;
    }

    // размер и дата берутся из снимка, по которому считался хэш: если файл успел измениться
    // во время выгрузки, строка останется несовпадающей и следующий проход выгрузит его снова
    final fresh = MirrorRow(
      path: file.path,
      cloudFolderId: folderId,
      entryId: result.entryId,
      inode: file.inode,
      size: file.size,
      mtime: file.mtime,
      sha256: sha,
    );
    known[file.path] = fresh;
    await _store.putFile(fresh);
    // выгрузка завершена: незавершённой сессии больше нет
    await _store.dropUploadSession(file.path);
    report.uploaded += 1;
    _status.update(
      (s) => s.copyWith(
        passUploadedFiles: s.passUploadedFiles + 1,
        passUploadedBytes: s.passUploadedBytes + file.size,
        // Счётчик «в облаке» растёт только на новых записях: перезапись уже учтённой
        // (row != null) считалась бы вторым файлом, и доля выгруженного врала бы вверх,
        // упираясь в 100 раньше времени
        inCloudFiles: row == null ? s.inCloudFiles + 1 : s.inCloudFiles,
        inCloudBytes: row == null ? s.inCloudBytes + file.size : s.inCloudBytes,
      ),
    );
    onProgress('выгружено: ${file.name}');
  }

  /// Выгрузка с нуля: запоминаем сессию, чтобы после обрыва продолжить, а не начинать заново.
  ///
  /// @param row строка «что уже выгружено» по этому пути: она есть — значит перезаписываем
  ///        существующую запись и называем серверу версию, которую заменяем; @param forceRelay
  ///        гонит байты через сервер, когда хранилище с телефона недоступно.
  /// Сессию сохраняет колбэк `onSession` — движок кладёт её в базу зеркала. Ошибки (в том
  /// числе конфликтные коды) уходят исключением: их разбирает [_upload].
  Future<UploadResult> _startUpload({
    required SyncApi api,
    required LocalFile file,
    required String folderId,
    required File local,
    required String sha,
    required MirrorRow? row,
    required void Function(int, int) progress,
    bool forceRelay = false,
  }) => Uploader(api).upload(
    folderId: folderId,
    file: local,
    cloudName: file.name,
    mime: MediaRules.mimeOf(file.name),
    sha256: sha,
    // перезапись только когда запись уже наша: новый файл сервер заводит сам
    replace: row != null,
    // версия, которую клиент считает актуальной: сервер откажет, если в облаке уже другая
    expectedSha256: row?.sha256,
    onSession: (uploadId) => _store.putUploadSession(
      UploadSessionRow(
        path: file.path,
        uploadId: uploadId,
        folderId: folderId,
        size: file.size,
        mtime: file.mtime,
        sha256: sha,
      ),
    ),
    onProgress: progress,
    // Хранилище с телефона недоступно: байты идут через сервер (см. SyncDirectUnavailable)
    forceRelay: forceRelay,
    // телефон — источник истины: если файл с таким именем лежит в корзине облака, это наша
    // же удалённая версия, и место под именем надо занять, а не ждать очистки корзины
    replaceTrashed: true,
  );

  /// Конфликт версий. Локальное содержимое сохраняется копией с пометкой, а по каноническому
  /// имени скачивается версия облака — так не теряется ни одна из сторон.
  ///
  /// Если записи с таким именем в облаке нет (имя занято записью из корзины), не делаем ничего
  /// и говорим об этом: воскрешать чужую корзину самостоятельно нельзя. Строку при этом
  /// снимаем, иначе файл не уедет никогда и в каждом проходе будет одна и та же ошибка.
  ///
  /// Побочные эффекты: выгрузка копии, скачивание версии облака, снятие строки в базе
  /// и счётчики отчёта ([MirrorReport.conflicts], [MirrorReport.failed]).
  Future<void> _resolveConflict({
    required SyncApi api,
    required LocalFile file,
    required String folderId,
    required Map<String, MirrorRow> known,
    required MirrorPull pull,
    required MirrorReport report,
    required void Function(String) onProgress,
  }) async {
    final local = File(file.path);
    List<RemoteEntry>? remote;
    try {
      remote = (await api.children(folderId)).entries;
    } catch (_) {
      // без листинга не видно занятых имён: свободное имя выбрать не из чего
      remote = null;
    }
    if (remote == null) {
      report.failed += 1;
      onProgress(
        'конфликт по «${file.name}»: не удалось прочитать папку облака',
      );
      return;
    }
    RemoteEntry? cloudEntry;
    for (final entry in remote) {
      if (entry.name == file.name) {
        cloudEntry = entry;
        break;
      }
    }
    if (cloudEntry == null) {
      // записи с таким именем в облаке нет вовсе: строка устарела (её удалили в вебе или
      // с другого устройства). Снимаем её и даём следующему проходу выгрузить файл как новый —
      // иначе он не уедет никогда и в каждом проходе будет ошибка.
      known.remove(file.path);
      await _store.dropFile(file.path);
      onProgress('«${file.name}»: запись в облаке пропала — выгружу заново');
      return;
    }
    // Имя конфликтной копии ищется среди имён облака: на телефоне копии может не быть вовсе.
    // Сравнение — с учётом регистра тома, на котором лежит файл: на карте памяти «Фото.JPG»
    // и «фото.jpg» — один и тот же файл, и «свободное» имя, выбранное посимвольно, затёрло бы
    // чужую запись. Длина ограничена байтами, иначе сервер откажет по пределу имени
    final taken = remote.map((e) => e.name).toSet();
    final copyName = MirrorRules.uniqueName(
      MirrorRules.conflictName(
        file.name,
        DateTime.now().millisecondsSinceEpoch,
      ),
      taken,
      caseInsensitive: MirrorRules.caseInsensitive(file.path),
    );
    try {
      await Uploader(api).upload(
        folderId: folderId,
        file: local,
        cloudName: copyName,
        mime: MediaRules.mimeOf(file.name),
        sha256: await _hash(local),
        // копия — всегда новая запись: перезаписывать ею чужое имя нельзя
        replace: false,
        onProgress: (_, _) {},
      );
    } catch (e) {
      // копия не уехала — облачную версию поверх локальной не кладём: сначала сохранность
      report.failed += 1;
      onProgress('конфликтная копия «$copyName» не уехала: $e');
      return;
    }
    report.conflicts += 1;
    onProgress(
      'конфликт: «${file.name}» сохранён как «$copyName», по основному имени — версия облака',
    );
    // строку снимаем до скачивания: теперь на телефоне по этому пути лежит версия облака,
    // и её заведёт скачивание; копию выгрузит следующий проход как новый файл
    known.remove(file.path);
    await _store.dropFile(file.path);
    final ok = await pull.downloadInto(
      cloudEntry.id,
      folderId,
      file.path,
      cloudEntry.sha256,
      cloudEntry.size,
      cloudEntry.clientMtime,
    );
    if (ok) {
      report.downloaded += 1;
    } else {
      report.failed += 1;
    }
  }

  /// SHA-256 содержимого файла с кэшем по пути.
  ///
  /// Кэш признаётся годным, если у файла тот же размер и та же дата изменения, что при
  /// подсчёте: содержимое при этом не перечитывается, поэтому подмена файла с сохранением
  /// размера и даты из кэша не видна. Дата берётся из `stat` непосредственно перед проверкой.
  ///
  /// Побочные эффекты: чтение файла (при промахе кэша) и запись в [_hashCache]. Ошибки чтения
  /// уходят исключением — выгрузка из-за них не начинается.
  Future<String> _hash(File file) async {
    final stat = await file.stat();
    final cached = _hashCache[file.path];
    if (cached != null &&
        cached.$2 == stat.size &&
        cached.$3 == stat.modified.millisecondsSinceEpoch) {
      return cached.$1;
    }
    final sha = await Hasher.sha256(file);
    _hashCache[file.path] = (
      sha,
      stat.size,
      stat.modified.millisecondsSinceEpoch,
    );
    return sha;
  }

  /// Хэш содержимого за проход считается один раз: файл может попасть и в план выгрузки,
  /// и в разбор конфликта.
  ///
  /// Живёт ровно один проход: чистится в его начале ([_passLocked]). Между проходами кэш
  /// хранить нельзя — файл мог быть подменён с сохранением размера и даты (`cp -p`, `rsync -a`),
  /// и старый хэш уехал бы на сервер как объявленный: `complete` ответил бы
  /// `upload_hash_mismatch`, и файл не выгрузился бы до тех пор, пока связка «размер + дата»
  /// не изменится. В базу кэш не пишется. Ключ — путь файла, значение — «хэш, размер, дата»
  /// на момент подсчёта.
  final Map<String, (String, int, int)> _hashCache = {};

  /// Время прохода вышло? Проверяется перед каждой операцией выгрузки, удаления и уборки
  /// папок, но не внутри самой операции: файл, начавший уезжать, доедет или оборвётся по
  /// своей ошибке — на середине его бросать незачем.
  ///
  /// Сравнение строгое: ровно в бюджет проход продолжается. Когда время вышло, вызывающий
  /// ставит признак остановки, и [_finish] назначает догон.
  bool _outOfTime(int startedAt, int budgetMs) =>
      DateTime.now().millisecondsSinceEpoch - startedAt > budgetMs;
}
