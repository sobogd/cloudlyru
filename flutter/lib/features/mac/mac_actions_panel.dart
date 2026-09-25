import 'package:flutter/material.dart';

/// Панель действий над MacBook в разделе настроек «Mac».
///
/// Опасные действия требуют подтверждения через диалог, который делегируется в [onAction].
class MacActionsPanel extends StatelessWidget {
  const MacActionsPanel({super.key, required this.onAction, required this.busy});

  final Future<void> Function(String action, String title) onAction;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Действия', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: busy ? null : () => onAction('restart-tunnel', 'Перезапустить туннель?'),
                child: const Text('Restart tunnel'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => onAction('firewall-on', 'Включить firewall?'),
                child: const Text('Firewall ON'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => onAction('sleep-off', 'Запретить сон MacBook?'),
                child: const Text('Sleep OFF'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => onAction('sleep', 'Усыпить MacBook?'),
                child: const Text('Sleep now'),
              ),
              FilledButton.tonal(
                onPressed: busy ? null : () => onAction('reboot', 'Перезагрузить MacBook?'),
                child: const Text('Reboot'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('Действия выполняются на MacBook и применяются сразу.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
