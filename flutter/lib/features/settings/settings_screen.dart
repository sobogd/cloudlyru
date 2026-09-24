import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../util/master_detail.dart';
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
/// Настройки разложены по раскладке «список — деталка» ([MasterDetail]): слева список
/// разделов настроек, справа — панель выбранного. На телефоне список занимает весь экран,
/// а панель открывается отдельным экраном с кнопкой «назад». Раньше все панели шли одной
/// длинной лентой, и до нужной приходилось долистывать, не зная, сколько их всего.
///
/// Сам экран ничего не показывает и не держит: он собирает независимые панели, и каждая
/// сама ходит на сервер и сама себя перерисовывает по таймеру или по действию человека.
/// Общего состояния у экрана нет, поэтому он без состояния: единственное, что он читает
/// и пишет, — ширина колонки со списком, а её хранит настройка ([ref]).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  /// Ключ, под которым в UI-настройках лежит ширина списка настроек: у каждого раздела
  /// со своей раскладкой она своя (см. `UiStateStore.splitWidth`).
  static const _widthKey = 'settings';

  /// Открывает список ошибок очереди отдельным маршрутом.
  ///
  /// Ошибок может быть сколько угодно, и в карточке им не место: маршрут даёт им свой экран,
  /// а кнопка «назад» появляется сама.
  void _openQueueErrors(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const QueueErrorsScreen()),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ширина колонки со списком живёт в UI-настройках и переживает перезапуск: раздел,
    // который открывают часто, не должен каждый раз начинаться с ширины по умолчанию
    final ui = ref.read(settingsProvider).ui;
    return MasterDetail(
      title: 'Настройки',
      initialWidth: ui.splitWidth(_widthKey),
      onWidthChanged: (w) => ui.setSplitWidth(_widthKey, w),
      // Порядок пунктов — от общего к частному: сначала вход в аккаунт, потом сам аккаунт
      // и устройство, а дальше отдельные службы приложения.
      entries: [
        MasterDetailEntry(
          id: 'account',
          title: 'Аккаунт',
          icon: Icons.person_outline,
          body: const AccountPanel(),
        ),
        MasterDetailEntry(
          id: 'agent',
          title: 'Агент',
          icon: Icons.smart_toy_outlined,
          body: const AgentPanel(),
        ),
        MasterDetailEntry(
          id: 'tokens',
          title: 'Приложения с доступом',
          icon: Icons.vpn_key_outlined,
          body: const TokensPanel(),
        ),
        MasterDetailEntry(
          id: 'sync',
          title: 'Синхронизация',
          icon: Icons.sync,
          body: const SyncPanel(),
        ),
        MasterDetailEntry(
          id: 'thumbs',
          title: 'Миниатюры галереи',
          icon: Icons.image_outlined,
          body: const ThumbsPanel(),
        ),
        MasterDetailEntry(
          id: 'updater',
          title: 'Обновление',
          icon: Icons.system_update_alt,
          body: const UpdaterPanel(),
        ),
        MasterDetailEntry(
          id: 'queue',
          title: 'Очередь превью',
          icon: Icons.hourglass_bottom,
          body: QueuePanel(onErrors: () => _openQueueErrors(context)),
        ),
        MasterDetailEntry(
          id: 'mail',
          title: 'Почта',
          icon: Icons.mail_outline,
          body: const MailAccountsPanel(),
        ),
      ],
    );
  }
}
