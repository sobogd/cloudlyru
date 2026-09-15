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

  final int scanned;
  final int queued;
  final int removed;
  final int skipped;
  final bool capped;
  final int unreadable;

  /// Что помешало части работы: нет входа в аккаунт, нет цели для раздела.
  final String? problem;

  String text() {
    final out = StringBuffer('проверено файлов: $scanned, новых в очереди: $queued');
    if (removed > 0) out.write(', убрано из очереди: $removed');
    if (unreadable > 0) out.write(', папок без доступа: $unreadable');
    if (capped) out.write(', обход упёрся в предел');
    final p = problem;
    if (p != null) out.write(' · $p');
    return out.toString();
  }
}

/// Наполнение очереди: пройти выбранные папки разделов, сравнить с тем, что уже известно,
/// и поставить новое и изменённое в очередь.
///
/// Ничего не запускает: запуск — ручной, кнопкой на строке. Здесь только подготовка.
class QueueBuilder {
  QueueBuilder(this._files, this._store);

  final DeviceFiles _files;
  final QueueStore _store;

  /// @param photoFolderId медиатека для раздела «Фото» (туда льём плоско)
  ///
  /// Раздел «Файлы» здесь не сканируется: его ведёт зеркало. Иначе один и тот же файл уезжал
  /// бы дважды — и в «Телефон» очередью, и в корень зеркала.
  Future<QueueBuildResult> build({
    required Selection selection,
    String? photoFolderId,
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
        problems.add('«Фото»: медиатека неизвестна — войдите в аккаунт');
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

    final planned = QueuePlanner.plan(candidates, await _store.uploaded());
    final added = await _store.enqueue(planned);
    // и убираем то, чего в выбранных папках больше нет: иначе отключённая папка оставалась бы
    // в очереди навсегда. Строки «Файлов» уборка тоже снимет: этот раздел больше не сканируется
    final keep = {for (final c in candidates) UploadedKey(c.path, c.target)};
    final removed = await _store.prune(keep, scannedSections);

    return QueueBuildResult(
      scanned: scanned,
      queued: added,
      removed: removed,
      skipped: candidates.length - planned.length,
      capped: capped,
      unreadable: unreadable,
      problem: problems.isEmpty ? null : problems.join('; '),
    );
  }
}
