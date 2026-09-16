import 'dart:async';

/// Что зеркало делает прямо сейчас и сколько уже лежит в облаке.
///
/// Живёт в области приложения: пишут сюда движок (каждый шаг прохода) и мгновенный режим
/// (снятие ошибки связи после удачного опроса), читают — раздел «Файлы», очередь и настройки.
/// Состояние одно на всё приложение, а не по копии на каждый экран: иначе две копии показывали
/// бы разное.
///
/// Выключателя зеркала нет — синхронизация включена всегда, — поэтому «включено/выключено»
/// здесь не хранится: единственный признак работы — [phase], а восстанавливаемый из базы
/// остаток описывает не настройки, а последний проход ([SyncController._restoreLastState]).
class MirrorStatus {
  /// Всё, чего нет в аргументах, — пустое состояние: так выглядит приложение до первого прохода.
  const MirrorStatus({
    this.phase = MirrorPhase.idle,
    this.currentName,
    this.currentSent = 0,
    this.currentTotal = 0,
    this.passUploadedFiles = 0,
    this.passUploadedBytes = 0,
    this.passDownloaded = 0,
    this.passFailed = 0,
    this.inCloudFiles = 0,
    this.inCloudBytes = 0,
    this.localFiles = 0,
    this.localBytes = 0,
    this.waitingFiles = 0,
    this.waitingBytes = 0,
    this.unreadable = 0,
    this.capped = false,
    this.startedAt = 0,
    this.finishedAt = 0,
    this.lastText = '',
    this.error,
    this.blocked = 0,
    this.blockedReason,
  });

  final MirrorPhase phase;

  /// Имя файла, который выгружается прямо сейчас.
  final String? currentName;

  /// Сколько байт текущего файла уже ушло и сколько в нём всего: из пары считается
  /// [currentPercent]. До начала выгрузки и после прохода — нули.
  final int currentSent;
  final int currentTotal;

  /// Сколько сделано за текущий проход.
  final int passUploadedFiles;
  final int passUploadedBytes;
  final int passDownloaded;
  final int passFailed;

  /// Что уже лежит в облаке по данным зеркала.
  ///
  /// Это не запрос к серверу, а сумма строк базы: облако может отличаться, если правку
  /// сделали в вебе или на другом устройстве, а журнал ещё не догнан.
  final int inCloudFiles;
  final int inCloudBytes;

  /// Сколько всего нашлось в выбранных папках на последнем обходе.
  final int localFiles;
  final int localBytes;

  /// Сколько ждало выгрузки на момент последнего плана.
  final int waitingFiles;
  final int waitingBytes;

  /// Сколько папок не удалось прочитать на последнем обходе и был ли обход неполным
  /// (предел снимка или отмена). По этим двум признакам удаления в облаке приостановлены
  /// (см. [MirrorRules.deletionsAllowed]) — без них в интерфейсе не видно, почему файлы
  /// в корзину не убираются, хотя человек ничего не запрещал.
  final int unreadable;
  final bool capped;

  /// Начало и конец последнего прохода (метки времени). Ноль у [finishedAt] означает, что
  /// проходов ещё не было — по этому признаку сторож решает, что синхронизация не работала.
  final int startedAt;
  final int finishedAt;

  /// Итог последнего прохода словами: то же, что лежит в базе как отчёт.
  final String lastText;

  /// Почему проход не довели до конца. Живёт до следующего удачного прохода.
  final String? error;

  /// Сколько удалений приостановлено предохранителем: остаток от прошлого прохода, пока
  /// новый проход его не пересчитает.
  final int blocked;

  /// Почему удаления приостановлены: «пропало слишком много» или «папка не читается».
  final String? blockedReason;

  /// Проход идёт прямо сейчас: фаза отличается от [MirrorPhase.idle]. По этому признаку
  /// интерфейс не запускает второй проход поверх первого (см. [SyncController.checkAndResume]).
  bool get busy => phase != MirrorPhase.idle;

  /// Доля выгруженного: от того, что лежит в выбранных папках.
  ///
  /// Сравниваются байты: сколько их в облаке по строкам зеркала против найденного обходом,
  /// с потолком в размер телефона — иначе расхождение в другую сторону (файлы удалили
  /// на телефоне, а в облаке они ещё лежат) дало бы больше ста процентов. Пустые папки
  /// не считаются: если на телефоне нет ни байта, но что-то в облаке есть, показываем
  /// «всё выгружено».
  int get percent {
    if (localBytes <= 0) return inCloudFiles > 0 ? 100 : 0;
    final done = inCloudBytes > localBytes ? localBytes : inCloudBytes;
    return (done * 100) ~/ localBytes;
  }

  /// Сколько процентов уходит у текущего файла.
  ///
  /// Размер файла известен из снимка, поэтому у нулевых (и ещё не начатых) файлов — ноль,
  /// а не «сто»: делить не на что.
  int get currentPercent =>
      currentTotal <= 0 ? 0 : (currentSent * 100) ~/ currentTotal;

  /// Копия состояния с заменой части полей.
  ///
  /// `null` означает «оставить как было»: сбросить [currentName], [error] и [blockedReason]
  /// можно только явными `clearCurrentName`, `clearError` и `clearBlockedReason`. Так сделано
  /// потому, что имя файла и причина приходят и уходят по ходу прохода, а `null` в аргументе
  /// иначе не отличить от «не менять».
  MirrorStatus copyWith({
    MirrorPhase? phase,
    String? currentName,
    bool clearCurrentName = false,
    int? currentSent,
    int? currentTotal,
    int? passUploadedFiles,
    int? passUploadedBytes,
    int? passDownloaded,
    int? passFailed,
    int? inCloudFiles,
    int? inCloudBytes,
    int? localFiles,
    int? localBytes,
    int? waitingFiles,
    int? waitingBytes,
    int? unreadable,
    bool? capped,
    int? startedAt,
    int? finishedAt,
    String? lastText,
    String? error,
    bool clearError = false,
    int? blocked,
    String? blockedReason,
    bool clearBlockedReason = false,
  }) => MirrorStatus(
    phase: phase ?? this.phase,
    currentName: clearCurrentName ? null : (currentName ?? this.currentName),
    currentSent: currentSent ?? this.currentSent,
    currentTotal: currentTotal ?? this.currentTotal,
    passUploadedFiles: passUploadedFiles ?? this.passUploadedFiles,
    passUploadedBytes: passUploadedBytes ?? this.passUploadedBytes,
    passDownloaded: passDownloaded ?? this.passDownloaded,
    passFailed: passFailed ?? this.passFailed,
    inCloudFiles: inCloudFiles ?? this.inCloudFiles,
    inCloudBytes: inCloudBytes ?? this.inCloudBytes,
    localFiles: localFiles ?? this.localFiles,
    localBytes: localBytes ?? this.localBytes,
    waitingFiles: waitingFiles ?? this.waitingFiles,
    waitingBytes: waitingBytes ?? this.waitingBytes,
    unreadable: unreadable ?? this.unreadable,
    capped: capped ?? this.capped,
    startedAt: startedAt ?? this.startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    lastText: lastText ?? this.lastText,
    error: clearError ? null : (error ?? this.error),
    blocked: blocked ?? this.blocked,
    blockedReason: clearBlockedReason
        ? null
        : (blockedReason ?? this.blockedReason),
  );
}

/// Фаза прохода: по ней интерфейс показывает, чем зеркало занято.
///
/// Фазы идут в порядке прохода — обход, облако, выгрузка, удаления, — но не являются
/// состояниями машины: движок просто выставляет ту, в которой работает, и в конце возвращает
/// [idle]. Несколько фаз идущего прохода подряд — это один и тот же проход.
///
/// [idle] — единственная фаза, в которой прохода нет; на этом держится [MirrorStatus.busy].
enum MirrorPhase {
  /// Прохода нет: идёт ожидание следующего события или задания системы.
  idle('ждёт'),

  /// Обход выбранных папок телефона: снимок диска перед сверкой.
  scan('обхожу папки'),

  /// Догон облака: журнал изменений или полный проход по папкам.
  cloud('облако'),

  /// Телефон → облако: переименования и выгрузка новых и изменившихся файлов.
  upload('выгружаю'),

  /// Удаления в облаке (файлы, которых на телефоне больше нет) и уборка пустых папок.
  delete('убираю в облаке');

  const MirrorPhase(this.label);

  /// Подпись для интерфейса.
  final String label;
}

/// Одна точка, куда все пишут состояние зеркала. Поток, а не просто поле: интерфейсу нужно
/// обновляться по ходу выгрузки, а не по таймеру — иначе цифры «отстают» и выглядят глюком.
///
/// Создаётся один на приложение ([SyncController]) и передаётся движку и мгновенному режиму;
/// держателей в процессе может быть и два (фоновое задание заводит свой движок со своим
/// состоянием), поэтому «одно на всё приложение» относится к интерфейсу, а не к системе.
class MirrorStatusHolder {
  final StreamController<MirrorStatus> _controller =
      StreamController<MirrorStatus>.broadcast();

  MirrorStatus _current = const MirrorStatus();

  /// Поток изменений для интерфейса: подписчик получает только то, что случится после
  /// подписки, — текущее значение берут из [current].
  Stream<MirrorStatus> get stream => _controller.stream;

  MirrorStatus get current => _current;

  /// Новое состояние: [block] получает предыдущее и возвращает следующее.
  ///
  /// Синхронный: подписчики (в том числе интерфейс) видят состояние сразу, а не следующим
  /// тиком. Само состояние никуда не сохраняется — в базе лежат только его итоги, и пишет
  /// их движок. В закрытый поток писать нельзя, поэтому после [dispose] значение меняется
  /// молча, без рассылки.
  void update(MirrorStatus Function(MirrorStatus) block) {
    _current = block(_current);
    if (!_controller.isClosed) _controller.add(_current);
  }

  /// Сбросить состояние целиком: так поступают при выходе из аккаунта.
  ///
  /// Сбросить одну фазу мало: `copyWith` не умеет её очищать (все поля «null — оставить как
  /// было»), поэтому залипшая фаза «выгружаю…» переживала бы и выход из аккаунта, и вход
  /// в другой — интерфейс показывал бы чужой проход.
  void reset() {
    _current = const MirrorStatus();
    if (!_controller.isClosed) _controller.add(_current);
  }

  /// Закрыть поток: подписчики отвязываются, состояние остаётся последним.
  Future<void> dispose() => _controller.close();
}
