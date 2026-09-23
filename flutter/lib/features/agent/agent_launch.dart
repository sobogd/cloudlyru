import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../util/widgets.dart';
import 'agent_controller.dart';
import 'agent_new_session.dart';
import 'agent_thread_screen.dart';
import 'agent_types.dart';

/// Разговор с таким именем, если он уже есть на маке.
///
/// Имя — это ключ повторного захода: доска пул-реквестов зовёт разговор `repo#123`, и второе
/// нажатие робота должно вернуть в тот же разговор, а не завести рядом второй.
AgentSession? findSessionByName(WidgetRef ref, String name) {
  for (final session in ref.read(agentSessionsProvider).sessions) {
    if (session.name == name) return session;
  }
  return null;
}

/// Ставит имя только что открытому разговору; возвращает имя, которое осталось поставить.
///
/// Мост помнит имя и до появления журнала сессии, поэтому обычный ответ — `null`: имя уже
/// принято. Если мост отказал (например, его перезапустили между открытием и этим вызовом),
/// имя уезжает экрану разговора и ставится после первого сообщения.
Future<String?> applySessionName(WidgetRef ref, String sessionId, String name) async {
  if (name.isEmpty) return null;
  final saved = await ref.read(agentSessionsProvider.notifier).rename(sessionId, name);
  return saved == null ? name : null;
}

/// Поднимает новую сессию агента из любого раздела приложения.
///
/// Тот же путь, что и по кнопке «+» в «Проектах»: мастер выбора папки и модели → открытие
/// процесса на маке → экран разговора. Вынесено сюда, потому что повод начать разговор
/// появляется и вне раздела — например, из списка пул-реквестов, где уже известно, о чём
/// просить агента ([prompt]).
///
/// [sessionName] — имя разговора. Если разговор с таким именем уже есть, мастер не
/// показывается: открывается он сам, потому что продолжать ревью в одной переписке правильнее,
/// чем заводить вторую. Новый разговор получает это имя после первого сообщения — раньше
/// харнессу некуда его записать (см. [AgentThreadScreen.pendingName]).
///
/// Текст [prompt] подставляется в поле ввода и НЕ отправляется: агент работает в реальной
/// папке на маке, и решение «поехали» остаётся за человеком — как и с голосовым вводом.
Future<void> startAgentSession(
  BuildContext context,
  WidgetRef ref, {
  String? prompt,
  String? sessionName,
}) async {
  final sessions = ref.read(agentSessionsProvider.notifier);
  if (sessionName != null && sessionName.isNotEmpty) {
    // Список разговоров в этом разделе могли ещё не читать: без него «уже есть» не проверить.
    if (ref.read(agentSessionsProvider).sessions.isEmpty) await sessions.load();
    final existing = findSessionByName(ref, sessionName);
    if (existing != null) {
      if (!context.mounted) return;
      final project = AgentProject.fromPath(existing.path);
      final opened = await sessions.open(
        project,
        harness: existing.harness,
        sessionId: existing.id,
      );
      if (!context.mounted) return;
      if (opened == null) {
        snack(context, ref.read(agentSessionsProvider).error ?? 'Мост не поднял сессию');
        return;
      }
      await Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => AgentThreadScreen(session: opened, project: project),
        ),
      );
      await sessions.load();
      return;
    }
  }

  if (!context.mounted) return;
  final choice = await showNewSessionWizard(context, ref, suggestedName: sessionName ?? '');
  if (choice == null || !context.mounted) return;
  if (choice.modelKey != null) {
    await ref.read(settingsProvider).ui.setAgentModel(choice.harness, choice.modelKey!);
  }
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
  // Имя, названное человеком в мастере, важнее предложенного разделом.
  final name = choice.name.isNotEmpty ? choice.name : (sessionName ?? '');
  final pending = await applySessionName(ref, session.id, name);
  if (!context.mounted) return;
  await Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (_) => AgentThreadScreen(
        session: session,
        project: choice.project,
        initialPrompt: prompt,
        pendingName: pending,
      ),
    ),
  );
  await sessions.load();
}
