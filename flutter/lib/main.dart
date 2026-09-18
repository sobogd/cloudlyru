import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'app_state.dart';
import 'providers.dart';
import 'storage/settings.dart';

/// Точка входа: единственное место, где [AppState] и [Settings] создаются вручную, до дерева
/// виджетов. Отсюда начинается вся цепочка жизненного цикла приложения.
///
/// Порядок шагов — не случайный, и именно он объясняет, почему состояние живёт вне Riverpod:
/// 1. [Settings.load] открывает SharedPreferences: адрес сервера, cookie сессии, UI-состояние.
/// 2. [AppState] создаётся вокруг готовых настроек.
/// 3. Дерево поднимается сразу, и оба объекта отдаются в `ProviderScope` как
///    **переопределения** (`overrides`) — фабрики из `providers.dart` при этом не выполняются
///    вовсе. Дерево к этому моменту ещё не знает, есть ли пользователь: `checking` у состояния
///    `true`, и корень показывает прогресс.
/// 4. Вход восстанавливается в фоне ([AppState.restore]) — внутри неё запрос `/auth/me`, и
///    ждать его до первого кадра значило бы держать нативную заставку до полутора минут при
///    «чёрной дыре» в сети (таймауты 20 с на подключение и 60 с на ответ). По завершении
///    состояние снимает `checking` и уведомляет корень — тот сам решает, показывать экран
///    входа или оболочку. Поэтому мигания экрана входа на каждом запуске не происходит:
///    он показывается только тогда, когда сессии точно нет.
///
/// Сам `SyncController` здесь не создаётся: он живёт в `syncControllerProvider`, строится
/// лениво при первом чтении провайдера и подключается к состоянию через `attachSync`
/// (см. `app.dart`, `initState` корня).
Future<void> main() async {
  // без этого плагины (SharedPreferences) нельзя трогать до runApp
  WidgetsFlutterBinding.ensureInitialized();
  // Размер кэша раскодированных картинок. По умолчанию 100 МБ, а миниатюра галереи (256 px)
  // в клетке — это ~200 КБ, то есть около пятисот штук на всю библиотеку в десятки тысяч кадров.
  // Такой кэш вытесняется на каждой прокрутке, и картинки раскодируются заново — при листании
  // это лишняя работа на каждом экране. Память здесь нативная (`ui.Image`), а не куча Dart,
  // поэтому 200 МБ для телефона с фотогалереей — разумный размен против постоянного декода.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 200 << 20;
  // Ошибки отрисовки не перехватываем, а отдаём штатному обработчику: они должны быть видны
  // в консоли и в отчётах, а не пропадать молча
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };
  // Ошибка в необработанном фьюче (например, в `unawaited(downloadAndOpen(…))`) по умолчанию
  // уходит в платформу и в логе приложения не остаётся: «ничего не произошло, файл не
  // открылся» — и никаких следов, по которым искать причину. Логируем её сами.
  // `false` — поведение по умолчанию не меняем, ошибку всё равно видит платформа.
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('CLOUDLY UNCAUGHT: $error\n$stack');
    return false;
  };
  try {
    final settings = await Settings.load();
    final state = AppState(settings);
    if (kDebugMode) {
      // 'set'/'none' вместо самой cookie: в лог не должен попадать секрет. Логин пользователя
      // здесь не пишем — он ещё не прочитан (restore идёт в фоне), да и в логе он лишний.
      debugPrint('cloudly: booted, session=${(settings.session ?? '').isEmpty ? 'none' : 'set'}');
    }
    runApp(ProviderScope(
      // Готовые объекты вместо фабрик: состояние уже собрано, провайдеры лишь раздают его
      // дереву. Синхронизатор в этот список не входит — он строится провайдером.
      overrides: [
        settingsProvider.overrideWithValue(settings),
        appStateProvider.overrideWith((ref) => state),
      ],
      child: const CloudlyApp(),
    ));
    // не ждём: пока идёт запрос, корень показывает прогресс (`checking`)
    unawaited(state.restore());
  } catch (e, st) {
    // Старт не должен падать молча: показываем ошибку, чтобы её было видно и можно было снять.
    // Ретрая здесь нет — экран живёт до перезапуска приложения, и это осознанно: сбой на старте
    // (например, недоступные SharedPreferences) сам не пройдёт, а вслепую уводить человека в
    // экран входа с пустыми настройками хуже, чем показать причину.
    // Дерево здесь минимальное и без ProviderScope: провайдеры могли не построиться, а экран
    // ошибки обязан показаться в любом случае
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
