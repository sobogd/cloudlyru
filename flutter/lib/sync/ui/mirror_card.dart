import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import '../mirror/mirror_status.dart';

/// Прогресс зеркала: сколько реально лежит в облаке, сколько ждёт и что происходит сейчас.
///
/// Цифры берутся из общей области состояния, а не из базы в момент открытия экрана: проход
/// движется по ходу дела, и «снимок на момент открытия» отставал бы от реальности и выглядел
/// как зависший интерфейс.
///
/// Карточка одна на приложение: в разделе «Файлы» она только показывает, в настройках —
/// ещё и управляет ([onPass], [onTogglePause], [onConfirmDeletes]).
class MirrorCard extends StatelessWidget {
  const MirrorCard({
    super.key,
    required this.status,
    this.onPass,
    this.onTogglePause,
    this.onConfirmDeletes,
    this.busy = false,
    this.blocked,
    this.activity,
  });

  final MirrorStatus status;
  final VoidCallback? onPass;
  final VoidCallback? onTogglePause;
  final VoidCallback? onConfirmDeletes;

  /// Идёт ручная сверка: кнопки не должны её дублировать.
  final bool busy;

  /// Сколько удалений приостановлено и почему — показываем предупреждением с подтверждением.
  final (int, String)? blocked;

  /// Что синхронизатор делает прямо сейчас — вместо фазы, когда она «ждёт».
  final String? activity;

  @override
  Widget build(BuildContext context) {
    final phase = status.busy && activity != null && activity!.isNotEmpty
        ? activity!
        : phaseTitle(status);
    final blockedNow = blocked;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Зеркало',
                  style: TextStyle(
                    color: C.fg,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    phase,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: C.fg3, fontSize: 11),
                  ),
                ),
              ],
            ),
            if (status.localBytes > 0) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: status.percent / 100,
                  minHeight: 5,
                  backgroundColor: C.surface3,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              (StringBuffer()
                    ..write(
                      'в облаке: ${status.inCloudFiles} файлов · ${fmt(status.inCloudBytes)}',
                    )
                    ..write(
                      status.localBytes > 0
                          ? ' из ${status.localFiles} · ${fmt(status.localBytes)}'
                          : '',
                    ))
                  .toString(),
              style: const TextStyle(color: C.fg, fontSize: 12),
            ),
            if (status.currentName != null)
              Text(
                'сейчас: ${status.currentName} — ${status.currentPercent}% '
                '(${fmt(status.currentSent)} из ${fmt(status.currentTotal)})',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: C.fg, fontSize: 12),
              ),
            if (status.waitingFiles > 0 && status.currentName == null)
              Text(
                'ждёт выгрузки: ${status.waitingFiles} файлов · ${fmt(status.waitingBytes)}',
                style: const TextStyle(color: C.fg, fontSize: 12),
              ),
            if (status.passUploadedFiles > 0 ||
                status.passDownloaded > 0 ||
                status.passFailed > 0)
              Text(
                (StringBuffer()
                      ..write(
                        'за проход: выгружено ${status.passUploadedFiles}',
                      )
                      ..write(
                        status.passDownloaded > 0
                            ? ', скачано ${status.passDownloaded}'
                            : '',
                      )
                      ..write(
                        status.passFailed > 0
                            ? ', ошибок ${status.passFailed}'
                            : '',
                      ))
                    .toString(),
                style: const TextStyle(color: C.fg3, fontSize: 11),
              ),
            if (status.lastText.isNotEmpty)
              Text(
                'последний проход: ${status.lastText}',
                style: const TextStyle(color: C.fg3, fontSize: 11),
              ),
            if (status.error != null)
              Text(
                status.error!,
                style: const TextStyle(color: C.danger, fontSize: 11),
              ),
            if (blockedNow != null) ...[
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Text(
                'удаления приостановлены: пропало файлов — ${blockedNow.$1} (${blockedNow.$2})',
                style: const TextStyle(
                  color: C.warn,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Если это вы удалили их на телефоне — подтвердите, и они уйдут в корзину облака. '
                'Если нет — проверьте доступ к папке.',
                style: TextStyle(color: C.fg3, fontSize: 11),
              ),
              if (onConfirmDeletes != null) ...[
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: busy ? null : onConfirmDeletes,
                  child: Text('Удалить эти ${blockedNow.$1} в облаке'),
                ),
              ],
            ],
            if (onPass != null || onTogglePause != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  if (onPass != null)
                    OutlinedButton(
                      onPressed: busy ? null : onPass,
                      child: Text(busy ? 'сверяю…' : 'Сверить сейчас'),
                    ),
                  if (onPass != null && onTogglePause != null)
                    const SizedBox(width: 8),
                  if (onTogglePause != null)
                    OutlinedButton(
                      onPressed: busy ? null : onTogglePause,
                      child: Text(
                        status.phase == MirrorPhase.paused
                            ? 'включить'
                            : 'выключить',
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Что зеркало делает прямо сейчас — короткой строкой.
String phaseTitle(MirrorStatus status) => switch (status.phase) {
  MirrorPhase.scan => 'обхожу папки',
  MirrorPhase.cloud => 'сверяюсь с облаком',
  MirrorPhase.upload => 'выгружаю',
  MirrorPhase.delete => 'убираю удалённое',
  MirrorPhase.paused => 'выключено',
  MirrorPhase.idle =>
    status.checkedAt > 0
        ? 'проверено ${ago(status.checkedAt)}'
        : (status.lastText.isNotEmpty ? 'готово' : 'ещё не запускалось'),
};

/// «5 с назад», «3 мин назад» — понятнее, чем время последней проверки.
String ago(int at) {
  final seconds = ((DateTime.now().millisecondsSinceEpoch - at) ~/ 1000).clamp(
    0,
    1 << 30,
  );
  return switch (seconds) {
    < 10 => 'только что',
    < 60 => '$seconds с назад',
    < 3600 => '${seconds ~/ 60} мин назад',
    _ => '${seconds ~/ 3600} ч назад',
  };
}
