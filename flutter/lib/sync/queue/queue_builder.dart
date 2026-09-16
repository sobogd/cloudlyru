import '../data/queue_store.dart';
import '../data/selection.dart';
import '../device/device_files.dart';
import '../section.dart';
import 'queue_planner.dart';

/// Итог наполнения очереди: что нашли, что поставили и что убрали.
class QueueBuildResult {
  const QueueBuildResult({
    required this.scanned,
    required this.queued,
    required this.removed,
    required this.skipped,
    required this.capped,
    required this.unreadable,
    this.problem,
  });

  /// Сколько файлов нашёл обход (все разделы вместе).
  final int scanned;

  /// Сколько строк добавилось в очередь за этот проход.
  final int queued;

  /// Сколько строк уборка сняла: папки больше нет в выборе, файла нет на телефоне или он
  /// перестал подходить под правила отбора. Уборка идёт только по полному обходу: если он
  /// упёрся в предел [capped] или был отменён, здесь ноль — неполный обход не доказывает,
  /// что файла нет.
  final int removed;

  /// Сколько кандидатов отсеялось как уже выгруженные — плюс дубликаты внутри самого прохода.
  final int skipped;

  /// Обход упёрся в предел [DeviceFiles.hardMax]: часть дерева не просмотрена.
  final bool capped;

  /// Папок, которые не удалось прочитать. Это не «пусто»: молчаливый ноль выглядел бы
  /// как пустая папка.
  final int unreadable;

  /// Что помешало части работы: нет входа в аккаунт, нет цели для раздела.
  final String? problem;

  /// Строка для человека: её показывает раздел «Очередь» и пишет в журнал фоновый проход.
  /// Части, которых не было (убрано, папок без доступа, предел), в текст не попадают —
  /// «убрано из очереди: 0» только сбивало бы с толку.
  String text() {
    final out = StringBuffer('проверено файлов: $scanned, новых в очереди: $queued');
    if (removed > 0) out.write(', убрано из очереди: $removed');
    if (unreadable > 0) out.write(', папок без доступа: $unreadable');
    // предел обхода — не мелочь: файлы за ним в очередь не попадут вовсе, и об этом надо
    // сказать прямо, а не «обход упёрся в предел»
    if (capped) {
      out.write(', файлов больше предела обхода — часть в очередь не попала');
    }
    final p = problem;
    if (p != null) out.write(' · $p');
    return out.toString();
  }
}

/// Наполнение очереди: пройти выбранные папки разделов, сравнить с тем, что уже известно,
/// и поставить новое и изменённое в очередь.
///
/// Сам ничего не выгружает: строки только ставятся в очередь и убираются, а выгрузку начинает
/// ядро синхронизации — кнопкой на строке или автоматическим сливом ждущих.
class QueueBuilder {
  /// [_files] читает телефон, [_store] — база очереди (снимок выгруженного, постановка,
  /// уборка). Оба живут дольше одного прохода и приходят снаружи: своих соединений
  /// и своих обходов билдер не заводит.
  QueueBuilder(this._files, this._store);

  final DeviceFiles _files;
  final QueueStore _store;

  /// @param photoFolderId медиатека для раздела «Фото» (туда льём плоско)
  /// @param photoProblem почему медиатека неизвестна, если она неизвестна: вызывающий знает
  ///        причину (нет токена, сервер не ответил, ещё не спрашивали), а [build] — нет,
  ///        и без этого параметра в текст попадал бы один и тот же совет «войдите в аккаунт»
  ///        даже когда вход есть, а сети нет
  ///
  /// Раздел «Файлы» здесь не сканируется: его ведёт зеркало. Иначе один и тот же файл уезжал
  /// бы дважды — и в «Телефон» очередью, и в корень зеркала.
  ///
  /// [selection] — выбранные папки (читаются по разделам), [photoFolderId] — цель раздела
  /// «Фото» (null или пустая строка — раздел в этом проходе не сканируется), [onProgress] —
  /// текст о ходе обхода (в него добавляется имя раздела), [isCancelled] — проверка отмены,
  /// её спрашивают перед каждым разделом и внутри обхода.
  ///
  /// Возвращает счётчики прохода. Побочные эффекты: только запись в SQLite — постановка
  /// новых строк и уборка лишних; диск читается, в сеть проход не ходит.
  ///
  /// Ошибки обхода и базы не глотаются — уходят вызывающему (он показывает текст в заметке
  /// раздела). Неизвестная медиатека — не ошибка: раздел «Фото» пропускается, а причина
  /// попадает в [QueueBuildResult.problem]. Отмена не исключение: возвращается частичный итог,
  /// и уборка в этом случае не делается вовсе (см. ниже).
  Future<QueueBuildResult> build({
    required Selection selection,
    String? photoFolderId,
    String? photoProblem,
    void Function(String)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final progress = onProgress ?? (String _) {};
    final cancelled = isCancelled ?? () => false;
    final problems = <String>[];
    final candidates = <Candidate>[];
    final scannedSections = <Section>{};
    var scanned = 0;
    var unreadable = 0;
    var capped = false;

    // Разделы перебираем все, даже если в разделе ничего не выбрано: пропущенный раздел
    // уборка считает непройденным и его строки не трогает — тогда снятая последняя папка
    // оставалась бы в очереди навсегда
    for (final section in Section.values) {
      if (cancelled()) break;
      // «Файлы» ведёт зеркало: в очередь они не попадают, а строки от версий до 0.7.0
      // (цель — папка «Телефон») считаются пройденными и уборка их снимает
      if (section == Section.files) {
        scannedSections.add(Section.files);
        continue;
      }
      final target = photoFolderId;
      if (target == null || target.isEmpty) {
        // Цель раздела неизвестна (не выполнен вход) — раздел не сканируем и НЕ считаем
        // пройденным: иначе уборка выкашивала бы его строки из-за одной неполадки.
        // Причину знает вызывающий (нет токена, сервер не ответил) — его текстом и объясняем
        problems.add(
          photoProblem ?? '«Фото»: медиатека неизвестна — войдите в аккаунт',
        );
        continue;
      }
      // Цель есть — раздел пройден целиком, даже если папок в нём не выбрано: тогда его строки
      // из очереди убираются. Без этого отключённая последняя папка оставалась бы навсегда.
      scannedSections.add(section);
      final paths = selection.paths(section);
      if (paths.isEmpty) continue;
      final result = await _files.scan(
        paths,
        onProgress: (message) => progress('${section.label}: $message'),
        isCancelled: cancelled,
      );
      scanned += result.total;
      unreadable += result.unreadable;
      capped = capped || result.capped;
      for (final file in result.files) {
        candidates.add(Candidate(
          path: file.path,
          // «Фото» ложится плоско: медиатека — не дерево, а лента
          relDir: '',
          name: file.name,
          size: file.size,
          mtime: file.mtime,
          section: section,
          target: target,
        ));
      }
    }

    // снимок «что уже выгружено» берём один раз на проход: на фотоальбоме это десятки тысяч
    // строк, а план считается по каждому файлу
    final planned = QueuePlanner.plan(candidates, await _store.uploaded());
    final added = await _store.enqueue(planned);
    // Уборка идёт только по полному обходу. Обход бывает заведомо неполным: предел
    // DeviceFiles.hardMax (часть дерева не просмотрена) и отмена (проход брошен на середине).
    // В обоих случаях «файла нет среди кандидатов» значит «мы его не видели», а не «его нет
    // на телефоне»: уборка сняла бы строки живых файлов вместе с их ошибками и числом попыток.
    // Папки без доступа такую уборку не отменяют: их файлы вернутся в очередь первым же
    // проходом, который их прочитает, а вот предел обхода и отмена — это «мы не дошли».
    final cancelledNow = cancelled();
    final keep = {for (final c in candidates) UploadedKey(c.path, c.target)};
    final removed = capped || cancelledNow
        ? 0
        : await _store.prune(keep, scannedSections);

    return QueueBuildResult(
      scanned: scanned,
      queued: added,
      removed: removed,
      // всё, что не попало в план: уже выгруженные и дубликаты внутри одного прохода
      skipped: candidates.length - planned.length,
      capped: capped,
      unreadable: unreadable,
      problem: problems.isEmpty ? null : problems.join('; '),
    );
  }
}
