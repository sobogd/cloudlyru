import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../util/widgets.dart';
import '../agent/agent_providers_screen.dart';

/// Панель «Агент» в настройках: вход в раздел «Модели и ключи».
///
/// Раньше настройка провайдеров и ключей жила кнопкой в шапке раздела «Проекты». Это настройка
/// харнесса на маке, а не действие над разговорами: в списке она мешала и путалась с уборкой
/// сессий, поэтому её место — среди прочих настроек. Сам экран не переехал: панель только
/// открывает его маршрутом, как «Очередь превью» открывает список ошибок.
///
/// Панель без состояния: показывать нечего, кроме строки входа, а список провайдеров грузит
/// сам экран при открытии.
class AgentPanel extends StatelessWidget {
  const AgentPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Агент',
            style: TextStyle(color: C.fg, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          // Пояснение на месте: ключи хранятся только на маке, и человек должен это знать до
          // того, как начнёт их вводить
          const Text(
            'Модели и ключи, которыми считает агент на маке. Ключи уезжают на мак и остаются '
            'там — в приложении и на сервере они не хранятся.',
            style: TextStyle(color: C.fg3, fontSize: 13),
          ),
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.vpn_key_outlined, color: C.fg3),
            title: const Text(
              'Модели и ключи',
              style: TextStyle(color: C.fg, fontSize: 14),
            ),
            subtitle: const Text(
              'Провайдеры pi и ключи встроенных моделей',
              style: TextStyle(color: C.fg3, fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right, color: C.fg3),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AgentProvidersScreen(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
