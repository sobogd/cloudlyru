import 'package:flutter/material.dart';

/// Панель управления WARP (Cloudflare One) в разделе «Mac».
///
/// Показывает состояние, организацию и причины блокировки; предоставляет кнопки
/// connect / disconnect / reconnect.
class MacWarpPanel extends StatelessWidget {
  const MacWarpPanel({
    super.key,
    required this.status,
    required this.onAction,
    required this.onWarp,
    required this.busy,
  });

  final Map<String, dynamic> status;
  final Future<void> Function(String action, String title) onAction;
  final Future<void> Function(String op) onWarp;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final w = _map(status['warp']);
    final state = _str(w['state']) ?? 'unknown';
    final connected = state.toLowerCase() == 'connected';

    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 110, child: Text(k, style: Theme.of(context).textTheme.bodySmall)),
              Expanded(child: Text(v)),
            ],
          ),
        );

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('WARP · Cloudflare One', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          kv('Состояние', state),
          if (_str(w['org']) != null) kv('Организация', _str(w['org'])!),
          if ((_str(w['reason']) ?? '').isNotEmpty) kv('Причина', _str(w['reason'])!),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: busy || connected ? null : () => onWarp('connect'),
                child: const Text('Connect'),
              ),
              OutlinedButton(
                onPressed: busy || !connected ? null : () => onWarp('disconnect'),
                child: const Text('Disconnect'),
              ),
              TextButton(
                onPressed: busy ? null : () => onWarp('reconnect'),
                child: const Text('Reconnect'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Map<String, dynamic> _map(dynamic v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
String? _str(dynamic v) => v is String ? v : null;
