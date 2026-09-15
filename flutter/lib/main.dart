import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'app_state.dart';
import 'providers.dart';
import 'storage/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };
  try {
    final settings = await Settings.load();
    final state = AppState(settings);
    await state.restore();
    debugPrint('cloudly: booted, session=${(settings.session ?? '').isEmpty ? 'none' : 'set'} user=${state.user?.login ?? 'null'}');
    runApp(ProviderScope(
      overrides: [
        settingsProvider.overrideWithValue(settings),
        appStateProvider.overrideWith((ref) => state),
      ],
      child: const CloudlyApp(),
    ));
  } catch (e, st) {
    // Старт не должен падать молча: показываем ошибку, чтобы её было видно и можно было снять.
    debugPrint('CLOUDLY STARTUP ERROR: $e\n$st');
    runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Ошибка запуска: $e', textAlign: TextAlign.center),
          ),
        ),
      ),
    ));
  }
}
