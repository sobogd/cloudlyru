import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth/login_screen.dart';
import 'providers.dart';
import 'shell/shell.dart';
import 'sync/sync_controller.dart';
import 'theme.dart';

/// Корень приложения: выбор экрана по состоянию входа плюс две вещи, которые должны
/// работать на всё приложение сразу, — привязка синхронизатора и слежение за тем,
/// на экране ли приложение.
///
/// Экран выбирается по трём состояниям `AppState`: пока идёт восстановление сессии
/// (`checking`) — прогресс, пользователя нет — [LoginScreen], пользователь есть — [Shell].
/// Состояние `checking` теперь действительно видно: вход восстанавливается в фоне, уже
/// после первого кадра (см. `main`).
///
/// Почему оба «фоновых» дела живут именно здесь: этот виджет строится первым после `runApp`
/// и живёт до конца работы приложения, то есть он единственная точка, где синхронизатор
/// получает и готовый вход, и события жизненного цикла. Вынеси это в разделы — и синхронизация
/// зависела бы от того, открыт ли конкретный экран.
///
/// Экран подменяется через `home`, а не навигатором: при выходе из аккаунта весь стек разделов
/// пропадает вместе с оболочкой, и вернуться стрелкой «назад» в чужой аккаунт нельзя. Новые
/// экраны стоит добавлять внутри разделов, а не сюда — у `home` нет ни имени маршрута, ни
/// выхода наружу.
class CloudlyApp extends ConsumerStatefulWidget {
  const CloudlyApp({super.key});

  @override
  ConsumerState<CloudlyApp> createState() => _CloudlyAppState();
}

/// Состояние корня: подписка на события жизненного цикла и одноразовая привязка
/// синхронизатора. Всё остальное — в провайдерах, чтобы корень не превращался во второй
/// «AppState».
class _CloudlyAppState extends ConsumerState<CloudlyApp> {
  AppLifecycleListener? _lifecycle;

  /// Подписывается на переходы приложения между передним планом и фоном и подключает
  /// синхронизатор к состоянию.
  ///
  /// `SyncController` читается здесь, а не в `build`: привязка запускает целую подсистему
  /// (базы, токен устройства, наблюдение за папками), а побочных эффектов в сборке виджета
  /// быть не должно — раньше первый `build` делал это, и каждое уведомление синхронизатора
  /// перестраивало корень приложения.
  ///
  /// Подписка одна на всё приложение: от неё зависят и частота фонового опроса журнала,
  /// и повторная проверка доступа к файлам (см. [_setForeground]).
  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () => _setForeground(true),
      // onInactive — это ещё не фон: системный диалог (выбор файла, шторка, экран выдачи
      // доступа) переводит приложение в «неактивно», но оно остаётся на экране, и мгновенный
      // режим синхронизации не должен из-за этого падать до фоновой частоты опроса
      onPause: () => _setForeground(false),
      onHide: () => _setForeground(false),
    );
    ref.read(appStateProvider).attachSync(ref.read(syncControllerProvider));
  }

  /// Снимает подписку на события жизненного цикла. Обязательно: без этого слушатель переживёт
  /// виджет и продолжит дёргать уже уничтоженный синхронизатор.
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
  /// Проверяем всегда, когда доступ не подтверждён (`granted`), а не только при `denied`:
  /// если старт синхронизации упал раньше проверки доступа, состояние остаётся `unknown`,
  /// и по одному лишь `denied` перепроверка не сработала бы никогда.
  ///
  /// `unawaited` здесь намеренно: проверка доступа асинхронная, а событие жизненного цикла
  /// ждать её не должен.
  void _setForeground(bool value) {
    final sync = ref.read(syncControllerProvider);
    sync.foreground = value;
    if (value && sync.access != SyncAccess.granted) unawaited(sync.recheckAccess());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appStateProvider);
    final Widget home;
    if (state.checking) {
      // видно на каждом запуске: пока идёт восстановление сессии (запрос /auth/me в фоне),
      // мы ещё не знаем, показывать экран входа или оболочку
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
