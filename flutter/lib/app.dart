import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth/login_screen.dart';
import 'providers.dart';
import 'shell/shell.dart';
import 'theme.dart';

class CloudlyApp extends ConsumerWidget {
  const CloudlyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appStateProvider);
    final Widget home;
    if (state.checking) {
      home = const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
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
