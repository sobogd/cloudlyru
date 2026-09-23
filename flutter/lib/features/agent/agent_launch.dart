import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../util/widgets.dart';
import 'agent_controller.dart';
import 'agent_new_session.dart';
import 'agent_thread_screen.dart';

/// Поднимает новую сессию агента из любого раздела приложения.
///
/// Тот же путь, что и по кнопке «+» в «Проектах»: мастер выбора папки и модели → открытие
/// процесса на маке → экран разговора. Вынесено сюда, потому что повод начать разговор
/// появляется и вне раздела — например, из списка пул-реквестов, где уже известно, о чём
/// просить агента ([prompt]).
///
/// Текст [prompt] подставляется в поле ввода и НЕ отправляется: агент работает в реальной
/// папке на маке, и решение «поехали» остаётся за человеком — как и с голосовым вводом.
Future<void> startAgentSession(
  BuildContext context,
  WidgetRef ref, {
  String? prompt,
}) async {
  final choice = await showNewSessionWizard(context, ref);
  if (choice == null || !context.mounted) return;
  if (choice.modelKey != null) {
    await ref.read(settingsProvider).ui.setAgentModel(choice.harness, choice.modelKey!);
  }
  final sessions = ref.read(agentSessionsProvider.notifier);
  final session = await sessions.open(
    choice.project,
    harness: choice.harness,
    modelKey: choice.modelKey,
    // Усилие хранится в настройках и в файле разговора его нет: без него Claude Code взял бы
    // умолчание модели вместо выбранного уровня. У pi выбор игнорируется.
    effort: choice.harness == 'claude'
        ? ref.read(settingsProvider).ui.agentEffort('claude')
        : null,
  );
  if (!context.mounted) return;
  if (session == null) {
    snack(context, ref.read(agentSessionsProvider).error ?? 'Мост не поднял сессию');
    return;
  }
  await Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (_) => AgentThreadScreen(
        session: session,
        project: choice.project,
        initialPrompt: prompt,
      ),
    ),
  );
  await sessions.load();
}
