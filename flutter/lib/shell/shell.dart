import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../features/files/files_screen.dart';
import '../features/mail/mail_screen.dart';
import '../features/map/map_screen.dart';
import '../features/media/media_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/trash/trash_screen.dart';
import '../providers.dart';

enum AppTab { files, mail, media, map, trash, settings }

class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});

  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  AppTab _tab = AppTab.files;

  @override
  void initState() {
    super.initState();
    final ui = ref.read(appStateProvider).settings.ui;
    final saved = ui.read()['tab'] as String?;
    final i = AppTab.values.indexWhere((t) => t.name == saved);
    if (i >= 0) _tab = AppTab.values[i];
    _checkUpdate();
  }

  /// Проверка обновления при старте (как в нативном клиенте): если на сервере
  /// сборка новее — показываем подсказку, само обновление в «Настройках».
  Future<void> _checkUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final current = int.tryParse(info.buildNumber) ?? 0;
      final latest = await ref.read(appStateProvider).api.latestApp();
      debugPrint('shell update check: current=$current latest=${latest.versionCode}');
      if (!mounted || latest.versionCode <= current) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Доступно обновление ${latest.versionName} — Настройки → Обновление'),
        ));
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: switch (_tab) {
        AppTab.files => const FilesScreen(),
        AppTab.mail => const MailScreen(),
        AppTab.media => const MediaScreen(),
        AppTab.map => const MapScreen(),
        AppTab.trash => const TrashScreen(),
        AppTab.settings => const SettingsScreen(),
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab.index,
        onDestinationSelected: (i) {
          setState(() => _tab = AppTab.values[i]);
          ref.read(appStateProvider).settings.ui.patch({'tab': AppTab.values[i].name});
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: 'Файлы'),
          NavigationDestination(icon: Icon(Icons.mail_outline), selectedIcon: Icon(Icons.mail), label: 'Почта'),
          NavigationDestination(icon: Icon(Icons.photo_library_outlined), selectedIcon: Icon(Icons.photo_library), label: 'Медиа'),
          NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Карта'),
          NavigationDestination(icon: Icon(Icons.delete_outline), selectedIcon: Icon(Icons.delete), label: 'Корзина'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Настройки'),
        ],
      ),
    );
  }
}
