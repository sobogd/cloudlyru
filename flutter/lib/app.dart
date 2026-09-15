import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth/login_screen.dart';
import 'providers.dart';
import 'shell/shell.dart';
import 'theme.dart';

/// Корень приложения: выбор экрана по состоянию входа плюс две вещи, которые должны
/// работать на всё приложение сразу, — привязка синхронизатора и слежение за тем,
/// на экране ли приложение.
class CloudlyApp extends ConsumerStatefulWidget {
  const CloudlyApp({super.key});

  @override
  ConsumerState<CloudlyApp> createState() => _CloudlyAppState();
}

class _CloudlyAppState extends ConsumerState<CloudlyApp> {
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () => _setForeground(true),
      onInactive: () => _setForeground(false),
      onPause: () => _setForeground(false),
      onHide: () => _setForeground(false),
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  /// Приложение на экране или в фоне: в фоне мгновенный режим опрашивает журнал реже —
  /// мгновенность там не нужна, а батарея нужна.
  ///
  /// Заодно проверяем доступ ко всем файлам: он выдаётся на системном экране, и без этой
  /// проверки экраны синхронизации продолжали бы показывать «нет доступа» уже после выдачи.
  void _setForeground(bool value) {
    final sync = ref.read(syncControllerProvider);
    sync.foreground = value;
    if (value && sync.needsAccess) unawaited(sync.recheckAccess());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appStateProvider);
    // привязка идемпотентна: синхронизация стартует один раз — при первом готовом входе,
    // и восстановленном из сессии, и только что выполненном
    state.attachSync(ref.watch(syncControllerProvider));

    final Widget home;
    if (state.checking) {
      home = const Scaffold(body: Center(child: CircularProgressIndicator()));
    } else if (state.user == null) {
      home = const LoginScreen();
    } else {
      home = const Shell();
    }
    return MaterialApp(
      title: 'Cloudly',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: home,
    );
  }
}
