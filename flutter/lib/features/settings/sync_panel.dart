import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../sync/section.dart';
import '../../sync/sync_controller.dart';
import '../../sync/ui/folder_tree_screen.dart';
import '../../sync/ui/queue_screen.dart';
import '../../theme.dart';
import '../../util/widgets.dart';
import 'sync_links_screen.dart';

/// Группа «Синхронизация»: доступ к файлам, связки «устройство ↔ облако», папки «Фото»,
/// очередь и зеркало.
///
/// Всё, что делает синхронизатор, видно и настраивается здесь: отдельной вкладки у него нет —
/// нижняя навигация остаётся той же, что и раньше, а разделы «Файлы»/«Фото» и очередь
/// открываются строками отсюда.
class SyncPanel extends ConsumerStatefulWidget {
  const SyncPanel({super.key});

  @override
  ConsumerState<SyncPanel> createState() => _SyncPanelState();
}

/// Состояние панели синхронизации: своего поля у неё нет — всё берётся из контроллера.
class _SyncPanelState extends ConsumerState<SyncPanel> {
  SyncController get _sync => ref.read(syncControllerProvider);

  @override
  /// Сразу проверяем, не встала ли синхронизация.
  void initState() {
    super.initState();
    // Проверка «не встала ли синхронизация» и отсюда: настройки могут открыть первыми,
    // а кнопок «сверить»/«включить» больше нет — возобновить работу может только ядро
    unawaited(_sync.checkAndResume());
  }

  /// Открывает вложенный экран и перерисовывается по возвращении.
  ///
  /// Перерисовка нужна потому, что там меняется то, что показывает эта панель: выбор папок
  /// для разделов и очередь выгрузки. Побочно: маршрут и `setState`.
  Future<void> _open(Widget screen) async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) setState(() {});
  }

  /// Токен устройства не выпустился: пробуем ещё раз. Причина отказа часто временная —
  /// сеть, лимит живых токенов на сервере, — и без повторной попытки приложение оставалось
  /// бы мёртвым до перезапуска.
  Future<void> _retryToken() async {
    final ok = await _sync.ensureReady();
    if (!mounted) return;
    setState(() {});
    if (!ok) snack(context, _sync.tokenError ?? 'токен устройства не выпущен');
  }

  /// Просит системное разрешение «доступ ко всем файлам» и сразу перепроверяет его.
  ///
  /// Разрешение выдают в системном окне, и панель к моменту возврата может быть уже закрыта:
  /// поэтому `mounted` проверяется после каждого `await`, до обращения к контроллеру и
  /// `context`. Перепроверка нужна, чтобы подсказка «нужен доступ» исчезла без перезапуска
  /// приложения.
  Future<void> _grantAccess() async {
    await _sync.requestAccess();
    if (!mounted) return;
    await _sync.recheckAccess();
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(syncControllerProvider);
    // у «Файлов» не выбор папок, а связки: папку в облаке человек выбирает сам
    final fileLinks = sync.links?.all().length ?? 0;
    final photoFolders = sync.selection?.count(Section.photos) ?? 0;
    final granted = sync.access == SyncAccess.granted;

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Синхронизация',
            style: TextStyle(color: C.fg, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            granted
                ? 'Работает сама: файл, появившийся или изменившийся на телефоне или в облаке, '
                      'доезжает до другой стороны.'
                : 'Синхронизация не увидит телефон, пока нет доступа ко всем файлам.',
            style: const TextStyle(color: C.fg3, fontSize: 12),
          ),
          if (sync.access == SyncAccess.unknown)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'проверяю доступ к файлам…',
                style: TextStyle(color: C.fg3, fontSize: 12),
              ),
            ),
          if (sync.access == SyncAccess.denied) ...[
            const SizedBox(height: 8),
            const Text(
              'Нужен доступ ко всем файлам: без него не видно ни дерева папок, ни содержимого. '
              'Выдаётся на системном экране — приложение личное, ставится APK-ом.',
              style: TextStyle(color: C.fg, fontSize: 12),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _grantAccess,
              child: const Text('Разрешить доступ ко всем файлам'),
            ),
          ],
          // Токен устройства не выпустился: без него синхронизация мертва, и причина
          // приходит от сервера словами — её и показываем
          if (sync.tokenError != null) ...[
            const SizedBox(height: 8),
            Text(
              sync.tokenError!,
              style: const TextStyle(color: C.fg, fontSize: 12),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => unawaited(_retryToken()),
              child: const Text('Повторить'),
            ),
          ],
          const SizedBox(height: 4),
          _row(
            icon: Icons.sync_alt,
            title: 'Папки для файлов',
            subtitle: fileLinks == 0 ? 'связок нет' : 'связок: $fileLinks',
            enabled: granted,
            onTap: () => _open(const SyncLinksScreen()),
          ),
          _row(
            icon: Icons.photo_library_outlined,
            title: 'Папки для фото и видео',
            subtitle: photoFolders == 0
                ? 'не выбраны'
                : 'выбрано: $photoFolders',
            enabled: granted,
            onTap: () => _open(const FolderTreeScreen(section: Section.photos)),
          ),
          _row(
            icon: Icons.cloud_upload_outlined,
            title: 'Очередь выгрузки',
            subtitle: sync.waiting == 0
                ? 'нечего выгружать'
                : 'в очереди: ${sync.waiting} — выгружается само',
            enabled: granted,
            onTap: () => _open(const QueueScreen()),
          ),
          const SizedBox(height: 8),
          Text(
            _statusLine(sync),
            style: const TextStyle(color: C.fg3, fontSize: 12),
          ),
          const SizedBox(height: 2),
          Text(
            _watchLine(granted, fileLinks, sync.watchedDirs),
            style: const TextStyle(color: C.fg3, fontSize: 12),
          ),
          // Итог фонового прохода показываем, только когда он есть: пока приложение ни разу
          // не выгружали из памяти, строки нет — и пустая строка «фон: —» только путала бы
          if (sync.backgroundReport != null) ...[
            const SizedBox(height: 2),
            Text(
              'фон: ${sync.backgroundReport}',
              style: const TextStyle(color: C.fg3, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  /// Короткая сводка: сколько уже в облаке и сколько ждёт. Пока прохода не было, честнее
  /// сказать «ещё не сверялось», чем показать нули: нули читаются как «в облаке пусто».
  String _statusLine(SyncController sync) {
    final status = sync.mirrorStatus;
    if (status.lastText.isEmpty && status.inCloudFiles == 0) {
      return 'ещё не сверялось';
    }
    final parts = <String>['в облаке: ${status.inCloudFiles} файлов'];
    if (status.waitingFiles > 0) {
      parts.add('ждёт выгрузки: ${status.waitingFiles}');
    }
    if (sync.waiting > 0) {
      parts.add('в очереди: ${sync.waiting}');
    }
    return parts.join(' · ');
  }

  /// Наблюдение за папками — ускоритель, а не сама синхронизация: без него изменения
  /// подхватит ближайший проход. Поэтому вместо «не поставлено» говорим причину.
  String _watchLine(bool granted, int fileLinks, int watched) {
    if (!granted) {
      return 'наблюдение за папками появится после доступа к файлам';
    }
    if (fileLinks == 0) {
      return 'наблюдение за папками: ни одной связки нет';
    }
    if (watched > 0) {
      return 'наблюдение за папками: $watched';
    }
    return 'наблюдение за папками не поставилось: изменения подхватит ближайший проход';
  }

  /// Строит строку-раздел панели: иконка, название, подпись и переход.
  ///
  /// `enabled` отражает доступ к файлам: без него и дерево папок, и очередь бессмысленны,
  /// поэтому строки не просто серые, а не нажимаются вовсе — подпись в панели объясняет почему.
  Widget _row({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: enabled,
      leading: Icon(icon, color: C.fg3),
      title: Text(title, style: const TextStyle(color: C.fg, fontSize: 14)),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: C.fg3, fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right, color: C.fg3),
      onTap: enabled ? onTap : null,
    );
  }
}
