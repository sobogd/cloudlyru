import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../theme.dart';
import '../../util/widgets.dart';
import 'mail_accounts_panel.dart';
import 'queue_errors_screen.dart';
import 'queue_panel.dart';
import 'sync_panel.dart';
import 'tokens_panel.dart';
import 'updater.dart';

/// Экран «Настройки»: пользователь и сервер, синхронизация телефона, обновление приложения,
/// очередь превью, почтовые аккаунты и приложения с доступом по токену.
///
/// Сам экран ничего не показывает и не держит: он собирает независимые панели, и каждая
/// сама ходит на сервер и сама себя перерисовывает по таймеру или по действию человека.
/// Общего состояния у экрана нет, поэтому он без состояния — виджет без `State` честнее
/// показывал бы это и раньше, когда единственным полем была строка `_view`.
///
/// Панели лежат отдельными файлами там же, в `features/settings/`: вместе они занимали больше
/// семисот строк, и найти в них нужную было нельзя.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  /// Открывает список ошибок очереди отдельным маршрутом.
  ///
  /// Раньше это была вторая страница внутри того же виджета (`_view = 'queue-errors'`) со
  /// своей копией `Scaffold`: какая страница показана, решала строка, видимая только этому
  /// файлу. Маршрут делает то же самое средствами навигации, и кнопка «назад» появляется сама.
  void _openQueueErrors(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const QueueErrorsScreen()),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appStateProvider);
    return Scaffold(
      // Шапку красит `appBarTheme` из `theme.dart`: своего цвета у неё тут нет.
      appBar: AppBar(
        title: const Text('Настройки', style: TextStyle(color: C.fg, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.person_outline, color: C.fg3),
                    const SizedBox(width: 8),
                    Text(state.user?.login ?? '',
                        style: const TextStyle(
                            color: C.fg, fontSize: 15, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: C.danger),
                      // Выход из аккаунта: `AppState` сам гасит синхронизацию и чистит сессию,
                      // ждать тут нечего — ни подсказки, ни перехода экран не делает.
                      onPressed: () => ref.read(appStateProvider).logout(),
                      child: const Text('Выйти'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Адрес сервера — только для чтения: в приложении он не меняется, поле ввода
                // живёт на экране входа (см. `features/auth/login_screen.dart`).
                Text(state.settings.serverUrl,
                    style: const TextStyle(color: C.fg3, fontSize: 12)),
              ],
            ),
          ),
          const TokensPanel(),
          const SyncPanel(),
          const UpdaterPanel(),
          QueuePanel(onErrors: () => _openQueueErrors(context)),
          const MailAccountsPanel(),
        ],
      ),
    );
  }
}
