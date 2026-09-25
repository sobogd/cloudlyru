import 'package:flutter/material.dart';

/// Панель управления LLM-моделями (oMLX) на MacBook.
///
/// Показывает текущую модель и кнопки переключения на доступные.
class MacModelPanel extends StatelessWidget {
  const MacModelPanel({
    super.key,
    required this.models,
    required this.onSwitch,
    required this.busy,
  });

  final Map<String, dynamic>? models;
  final Future<void> Function(String modelId, String modelName) onSwitch;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (models == null) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('Модели не загружены'),
      );
    }

    final current = _str(models!['current']);
    final modelList = (models!['models'] as Map<String, dynamic>? ?? {});

    /// Кнопка переключения на одну модель.
    Widget modelSwitchTile(String id, Map<String, dynamic> info, String? current) {
      final isActive = id == current;
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${info['name'] ?? id} (${info['quantization'] ?? ''})',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isActive ? null : Colors.grey,
                  fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
                ),
              ),
            ),
            FilledButton.tonal(
              onPressed: busy || isActive ? null : () => onSwitch(id, '${info['name'] ?? id}'),
              child: Text(isActive ? 'Active' : 'Switch'),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('LLM · oMLX', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Текущая: ${current ?? 'не загружена'}', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          for (final entry in modelList.entries) modelSwitchTile(entry.key, entry.value, current),
        ],
      ),
    );
  }
}

String? _str(dynamic v) => v is String ? v : null;
