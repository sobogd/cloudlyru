import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../util/widgets.dart';
import 'agent_controller.dart';
import 'agent_new_session.dart';
import 'agent_thread_screen.dart';
import 'agent_types.dart';

AgentSession? findReviewSession(WidgetRef ref, String key) {
  final sessions = ref.read(agentSessionsProvider).sessions;
  final saved = ref.read(settingsProvider).ui.reviewSession(key);
  if (saved != null) {
    for (final session in sessions) {
      if (session.id == saved) return session;
    }
  }
  for (final session in sessions) {
    if (session.name == key) return session;
  }
  return null;
}

Future<void> rememberReviewSession(WidgetRef ref, String key, String sessionId) =>
    ref.read(settingsProvider).ui.setReviewSession(key, sessionId);

Future<String?> applySessionName(WidgetRef ref, String sessionId, String name) async {
  if (name.isEmpty) return null;
  final saved = await ref.read(agentSessionsProvider.notifier).rename(sessionId, name);
  return saved == null ? name : null;
}

Future<void> startAgentSession(
  BuildContext context,
  WidgetRef ref, {
  String? prompt,
  String? sessionName,
}) async {
  final sessions = ref.read(agentSessionsProvider.notifier);
  if (sessionName != null && sessionName.isNotEmpty) {
    if (ref.read(agentSessionsProvider).sessions.isEmpty) await sessions.load();
    final existing = findReviewSession(ref, sessionName);
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
    effort: choice.harness == 'claude'
        ? ref.read(settingsProvider).ui.agentEffort('claude')
        : null,
  );
  if (!context.mounted) return;
  if (session == null) {
    snack(context, ref.read(agentSessionsProvider).error ?? 'Мост не поднял сессию');
    return;
  }
  final name = choice.name.isNotEmpty ? choice.name : (sessionName ?? '');
  final pending = await applySessionName(ref, session.id, name);
  if (sessionName != null && sessionName.isNotEmpty) {
    await rememberReviewSession(ref, sessionName, session.id);
  }
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
