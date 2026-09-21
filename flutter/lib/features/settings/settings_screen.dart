import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme.dart';
import 'agent_panel.dart';
import 'account_panel.dart';
import 'mail_accounts_panel.dart';
import 'queue_errors_screen.dart';
import 'queue_panel.dart';
import 'sync_panel.dart';
import 'thumbs_panel.dart';
import 'tokens_panel.dart';
import 'updater.dart';

/// Экран «Настройки»: аккаунт, агент (модели и ключи), синхронизация телефона, обновление
/// приложения, очередь превью, почтовые аккаунты и приложения с доступом по токену.
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
    return Scaffold(
      // Шапку красит `appBarTheme` из `theme.dart`: своего цвета у неё тут нет.
      appBar: AppBar(
        title: const Text('Настройки', style: TextStyle(color: C.fg, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          // Аккаунт — первым: он про вход целиком (логин, пароль, сеансы), а дальше идут панели
          // про само устройство и разделы приложения.
          const AccountPanel(),
          const AgentPanel(),
          const TokensPanel(),
          const SyncPanel(),
          const ThumbsPanel(),
          const UpdaterPanel(),
          QueuePanel(onErrors: () => _openQueueErrors(context)),
          const MailAccountsPanel(),
        ],
      ),
    );
  }
}
