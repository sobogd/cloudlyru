import 'dart:async';

/// Что зеркало делает прямо сейчас и сколько уже лежит в облаке.
///
/// Живёт в области приложения: пишут сюда движок (каждый шаг прохода), мгновенный режим
/// (когда он проверял журнал) и настройки (когда пользователь включил или выключил зеркало).
/// Читает интерфейс — и раздел «Файлы», и настройки, — поэтому состояние одно на всё приложение,
/// а не по копии на каждый экран: иначе две копии показывали бы разное.
class MirrorStatus {
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
    this.startedAt = 0,
    this.finishedAt = 0,
    this.checkedAt = 0,
    this.lastText = '',
    this.error,
    this.blocked = 0,
    this.blockedReason,
  });

  final MirrorPhase phase;

  /// Имя файла, который выгружается прямо сейчас.
  final String? currentName;
  final int currentSent;
  final int currentTotal;

  /// Сколько сделано за текущий проход.
  final int passUploadedFiles;
  final int passUploadedBytes;
  final int passDownloaded;
  final int passFailed;

  /// Что уже лежит в облаке по данным зеркала.
  final int inCloudFiles;
  final int inCloudBytes;

  /// Сколько всего нашлось в выбранных папках на последнем обходе.
  final int localFiles;
  final int localBytes;

  /// Сколько ждало выгрузки на момент последнего плана.
  final int waitingFiles;
  final int waitingBytes;

  final int startedAt;
  final int finishedAt;

  /// Когда в последний раз спрашивали облако (мгновенный режим).
  final int checkedAt;
  final String lastText;
  final String? error;
  final int blocked;

  /// Почему удаления приостановлены: «пропало слишком много» или «папка не читается».
  final String? blockedReason;

  bool get busy => phase != MirrorPhase.idle;

  /// Доля выгруженного: от того, что лежит в выбранных папках.
  int get percent {
    if (localBytes <= 0) return inCloudFiles > 0 ? 100 : 0;
    final done = inCloudBytes > localBytes ? localBytes : inCloudBytes;
    return (done * 100) ~/ localBytes;
  }

  /// Сколько процентов уходит у текущего файла.
  int get currentPercent => currentTotal <= 0 ? 0 : (currentSent * 100) ~/ currentTotal;

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
    int? startedAt,
    int? finishedAt,
    int? checkedAt,
    String? lastText,
    String? error,
    bool clearError = false,
    int? blocked,
    String? blockedReason,
    bool clearBlockedReason = false,
  }) =>
      MirrorStatus(
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
        startedAt: startedAt ?? this.startedAt,
        finishedAt: finishedAt ?? this.finishedAt,
        checkedAt: checkedAt ?? this.checkedAt,
        lastText: lastText ?? this.lastText,
        error: clearError ? null : (error ?? this.error),
        blocked: blocked ?? this.blocked,
        blockedReason: clearBlockedReason ? null : (blockedReason ?? this.blockedReason),
      );
}

enum MirrorPhase {
  idle('ждёт'),
  scan('обхожу папки'),
  cloud('облако'),
  upload('выгружаю'),
  delete('убираю в облаке');

  const MirrorPhase(this.label);

  final String label;
}

/// Одна точка, куда все пишут состояние зеркала. Поток, а не просто поле: интерфейсу нужно
/// обновляться по ходу выгрузки, а не по таймеру — иначе цифры «отстают» и выглядят глюком.
class MirrorStatusHolder {
  final StreamController<MirrorStatus> _controller =
      StreamController<MirrorStatus>.broadcast();

  MirrorStatus _current = const MirrorStatus();

  Stream<MirrorStatus> get stream => _controller.stream;

  MirrorStatus get current => _current;

  void update(MirrorStatus Function(MirrorStatus) block) {
    _current = block(_current);
    if (!_controller.isClosed) _controller.add(_current);
  }

  Future<void> dispose() => _controller.close();
}
