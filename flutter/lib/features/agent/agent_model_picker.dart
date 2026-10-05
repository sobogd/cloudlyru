import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme.dart';
import 'agent_controller.dart';
import 'agent_providers_screen.dart';
import 'agent_types.dart';

Future<AgentModel?> showModelPicker(
  BuildContext context,
  WidgetRef ref, {
  String harness = 'pi',
  String? current,
}) async {
  final controller = ref.read(agentModelsProvider.notifier);
  unawaited(controller.load(harness: harness));
  return showDialog<AgentModel>(
    context: context,
    builder: (_) => _ModelPickerDialog(harness: harness, current: current),
  );
}

class _ModelPickerDialog extends ConsumerWidget {
  final String harness;

  final String? current;

  const _ModelPickerDialog({required this.harness, this.current});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(agentModelsProvider);

    return AlertDialog(
      backgroundColor: C.surface,
      title: Text(
        'Модель · ${ref.watch(agentHarnessesProvider).nameOf(harness)}',
        style: const TextStyle(color: C.fg, fontSize: 16),
      ),
      content: SizedBox(
        width: 420,
        child: state.loading && state.models.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (state.error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          state.error!,
                          style: const TextStyle(
                            color: C.danger,
                            fontSize: 12.5,
                            height: 1.3,
                          ),
                        ),
                      ),
                    if (state.models.isEmpty && state.error == null)
                      const Text(
                        'Моделей не видно. Проверьте на маке, что pi настроен: pi --list-models.',
                        style: TextStyle(
                          color: C.fg3,
                          fontSize: 12.5,
                          height: 1.3,
                        ),
                      ),
                    if (state.local.isNotEmpty) ...[
                      _groupTitle(
                        harness == 'claude'
                            ? 'Модели Claude Code'
                            : 'На этом маке',
                      ),
                      for (final model in state.local)
                        _row(context, ref, model),
                    ],
                    if (state.remote.isNotEmpty) ...[
                      _groupTitle(
                        harness == 'claude'
                            ? 'Остальные'
                            : 'По API (удалённые)',
                      ),
                      for (final model in state.remote)
                        _row(context, ref, model),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      harness == 'claude'
                          ? 'Список — из каталога установленного Claude Code: псевдонимы семейств'
                                ' и конкретные версии. Доступ у него свой — подписка или ключ на'
                                ' маке, и приложение в него не вмешивается.'
                          : 'Удалённую модель добавляют кнопкой «Добавить провайдера»: адрес и '
                                'ключ уедут на мак и останутся там — в приложении ключей нет.',
                      style: const TextStyle(
                        color: C.fg3,
                        fontSize: 11.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
      ),
      actions: [
        if (harness == 'pi')
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AgentProvidersScreen(),
                ),
              );
            },
            child: const Text('Добавить провайдера'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }

  Widget _groupTitle(String text) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 2),
    child: Text(text, style: const TextStyle(color: C.fg3, fontSize: 12)),
  );

  Widget _row(BuildContext context, WidgetRef ref, AgentModel model) {
    final isCurrent =
        current != null && (current == model.key || current == model.id);
    final enabled = model.hasKey;
    return InkWell(
      onTap: enabled ? () => Navigator.of(context).pop(model) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isCurrent
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: isCurrent ? C.accent : C.fg3,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.label,
                    style: TextStyle(
                      color: enabled ? C.fg : C.fg3,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      model.key,
                      if (model.contextWindow != null)
                        'окно ${_tokens(model.contextWindow!)}',
                      if (model.thinking) 'размышления',
                      if (!model.hasKey) 'нужен ключ на маке',
                    ].join(' · '),
                    style: TextStyle(
                      color: model.hasKey ? C.fg3 : C.warn,
                      fontSize: 11.5,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _tokens(int value) {
    final text = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      if (i > 0 && (text.length - i) % 3 == 0) buffer.write(' ');
      buffer.write(text[i]);
    }
    return buffer.toString();
  }
}

Future<String?> showEffortPicker(
  BuildContext context,
  WidgetRef ref, {
  required String current,
  String harness = 'claude',
}) async {
  unawaited(ref.read(agentModelsProvider.notifier).load(harness: harness));
  return showDialog<String>(
    context: context,
    builder: (_) => _EffortPickerDialog(current: current, harness: harness),
  );
}

class _EffortPickerDialog extends ConsumerWidget {
  final String current;

  final String harness;

  const _EffortPickerDialog({required this.current, this.harness = 'claude'});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(agentModelsProvider);
    final efforts = state.harness == harness
        ? state.efforts
        : const <AgentEffort>[];
    final title = harness == 'harness' ? 'Усилие · LLM-агент' : 'Усилие · Claude Code';

    return AlertDialog(
      backgroundColor: C.surface,
      title: Text(title, style: const TextStyle(color: C.fg, fontSize: 16)),
      content: SizedBox(
        width: 420,
        child: state.loading && efforts.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (state.error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          state.error!,
                          style: const TextStyle(
                            color: C.danger,
                            fontSize: 12.5,
                            height: 1.3,
                          ),
                        ),
                      ),
                    if (harness != 'harness')
                      _row(
                        context,
                        id: '',
                        label: 'Как решает Claude Code',
                        note: 'умолчание модели',
                      ),
                    for (final effort in efforts)
                      _row(context, id: effort.id, label: effort.label),
                    if (!state.loading && efforts.isEmpty && state.error == null)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'Уровни усилия мост не вернул. Проверьте на маке, что Claude Code '
                          'отвечает: claude --effort high -p "привет".',
                          style: TextStyle(
                            color: C.fg3,
                            fontSize: 12.5,
                            height: 1.3,
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    const Text(
                      'Усилие — сколько модель думает над ответом: ниже быстрее и дешевле, выше '
                          'умнее. Смена уровня перезапускает процесс агента и продолжает тот '
                          'же разговор.',
                      style: TextStyle(
                        color: C.fg3,
                        fontSize: 11.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }

  Widget _row(
    BuildContext context, {
    required String id,
    required String label,
    String? note,
  }) {
    final selected = current.trim() == id;
    return InkWell(
      onTap: () => Navigator.of(context).pop(id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? C.accent : C.fg3,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: C.fg, fontSize: 14),
              ),
            ),
            if (note != null)
              Text(
                note,
                style: const TextStyle(color: C.fg3, fontSize: 11.5),
              ),
          ],
        ),
      ),
    );
  }
}
