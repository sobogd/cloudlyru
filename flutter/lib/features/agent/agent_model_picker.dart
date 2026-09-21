import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme.dart';
import 'agent_controller.dart';
import 'agent_providers_screen.dart';
import 'agent_types.dart';

/// Диалог выбора модели: локальная llama.cpp на маке или удалённый провайдер по API.
///
/// Список приходит от pi с мака, поэтому в нём ровно то, что он действительно может запустить:
/// добавить удалённую модель — значит прописать провайдера и ключ в `~/.pi/agent/models.json`
/// на маке, и после этого она появится здесь. В приложении ключей нет и не будет: оно только
/// выбирает из того, что уже настроено, и показывает признак «ключ не задан» у тех провайдеров,
/// которые без него не ответят.
///
/// Выбранная модель применяется к открытой сессии и запоминается как модель по умолчанию для
/// новых: человек, перешедший на удалённую модель, ждёт её и в следующем проекте.
Future<AgentModel?> showModelPicker(
  BuildContext context,
  WidgetRef ref, {
  String? current,
}) async {
  final controller = ref.read(agentModelsProvider.notifier);
  // список читаем здесь, а не при входе в раздел: запрос к маку нужен только тому, кто
  // действительно открывает выбор модели
  unawaited(controller.load());
  return showDialog<AgentModel>(
    context: context,
    builder: (_) => _ModelPickerDialog(current: current),
  );
}

/// Диалог выбора модели.
class _ModelPickerDialog extends ConsumerWidget {
  /// Ключ модели, которая используется сейчас (`провайдер/идентификатор`).
  final String? current;

  /// Диалог выбора модели.
  const _ModelPickerDialog({this.current});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(agentModelsProvider);

    return AlertDialog(
      backgroundColor: C.surface,
      title: const Text('Модель', style: TextStyle(color: C.fg, fontSize: 16)),
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
                          style: const TextStyle(color: C.danger, fontSize: 12.5, height: 1.3),
                        ),
                      ),
                    if (state.models.isEmpty && state.error == null)
                      const Text(
                        'Моделей не видно. Проверьте на маке, что pi настроен: pi --list-models.',
                        style: TextStyle(color: C.fg3, fontSize: 12.5, height: 1.3),
                      ),
                    if (state.local.isNotEmpty) ...[
                      _groupTitle('На этом маке'),
                      for (final model in state.local) _row(context, ref, model),
                    ],
                    if (state.remote.isNotEmpty) ...[
                      _groupTitle('По API (удалённые)'),
                      for (final model in state.remote) _row(context, ref, model),
                    ],
                    const SizedBox(height: 8),
                    const Text(
                      'Удалённую модель добавляют кнопкой «Добавить провайдера»: адрес и ключ '
                      'уедут на мак и останутся там — в приложении ключей нет.',
                      style: TextStyle(color: C.fg3, fontSize: 11.5, height: 1.35),
                    ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          // Добавить провайдера можно прямо отсюда: чаще всего выбор модели открывают именно
          // для того, чтобы понять, чего в списке не хватает
          onPressed: () {
            Navigator.of(context).pop();
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AgentProvidersScreen()),
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

  /// Заголовок группы моделей: «на маке» и «по API».
  Widget _groupTitle(String text) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Text(text, style: const TextStyle(color: C.fg3, fontSize: 12)),
      );

  /// Строка модели: название, идентификатор, окно контекста и признак «нужен ключ».
  Widget _row(BuildContext context, WidgetRef ref, AgentModel model) {
    final isCurrent = current != null && (current == model.key || current == model.id);
    final enabled = model.hasKey;
    return InkWell(
      onTap: enabled ? () => Navigator.of(context).pop(model) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isCurrent ? Icons.radio_button_checked : Icons.radio_button_unchecked,
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
                      if (model.contextWindow != null) 'окно ${_tokens(model.contextWindow!)}',
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

  /// Токены в коротком виде: «32 768» и «200 000» читаются лучше, чем «32768».
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
