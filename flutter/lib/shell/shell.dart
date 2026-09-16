import 'dart:async';

import 'package:flutter/foundation.dart';
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

/// Разделы приложения — ровно те, что стоят в нижней панели, в том же порядке.
///
/// Имя значения (`name`) — это ключ, под которым выбранная вкладка лежит в настройках
/// (`settings.ui`, поле `tab`), поэтому переименование значений сломало бы восстановление
/// последней вкладки: [_ShellState.initState] ищет сохранённое имя по `name` и при промахе
/// молча остаётся на «Файлах».
///
/// Порядок значений тоже значим: панель работает индексами (`selectedIndex = _tab.index`,
/// а в обработчике нажатия — `AppTab.values[i]`), поэтому порядок `destinations` в
/// [_ShellState.build] обязан совпадать с порядком значений здесь, иначе подсветится и
/// откроется не тот раздел. Число `destinations` — тоже ровно по числу значений.
enum AppTab { files, mail, media, map, trash, settings }

/// Оболочка после входа: держит выбранный раздел и нижнюю панель навигации.
///
/// Разделы живут в `IndexedStack` и создаются один раз — при первом показе вкладки. Раньше
/// тело было `switch (_tab)`, то есть каждый переход создавал экран заново: раздел терял
/// открытую папку и прокрутку, а его `initState` заново шёл в сеть за списком. Общее состояние
/// (очередь загрузки, синхронизация) при этом и так вынесено в `AppState` — здесь живёт только
/// то, что относится к самому разделу.
class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});

  @override
  ConsumerState<Shell> createState() => _ShellState();
}

/// Состояние оболочки: выбранный раздел и уже построенные экраны разделов.
class _ShellState extends ConsumerState<Shell> {
  AppTab _tab = AppTab.files;

  /// Построенные экраны разделов: `IndexedStack` держит их живыми, поэтому на экран,
  /// в который человек уже заходил, он возвращается с той же открытой папкой и прокруткой.
  ///
  /// Заполняется лениво: строить все шесть разделов на старте нельзя — каждый в `initState`
  /// идёт в сеть, и приложение открывалось бы пачкой запросов к серверу.
  final Map<AppTab, Widget> _screens = {};

  /// Восстанавливает раздел, открытый в прошлый раз, и запускает проверку обновления.
  ///
  /// Раздел читается из общих UI-настроек тем же ключом `tab`, куда его пишет
  /// [_ShellState.build] при переключении. Если ключа нет или в нём записано не имя раздела
  /// (чужая сборка, ручная правка prefs), остаётся «Файлы» — вход в приложение всегда
  /// предсказуем. Тип значения проверяет хранилище (`UiStateStore.tab`), а не этот код:
  /// сырое значение из prefs нельзя кастовать — исключение здесь означало бы красный экран.
  @override
  void initState() {
    super.initState();
    final saved = ref.read(appStateProvider).settings.ui.tab;
    final i = AppTab.values.indexWhere((t) => t.name == saved);
    if (i >= 0) _tab = AppTab.values[i];
    unawaited(_checkUpdate());
  }

  /// Проверка обновления при старте: если на сервере сборка новее — показываем подсказку,
  /// само обновление в «Настройках».
  ///
  /// Сравнивает `versionCode` текущей сборки с последней опубликованной на сервере; при
  /// расхождении показывает всплывающую подсказку с путём к обновлению. Ничего не скачивает.
  ///
  /// Побочный эффект — только подсказка, и она показывается через `postFrameCallback`, потому
  /// что `initState` ещё не имеет готового `ScaffoldMessenger` над этим экраном. Сбой проверки
  /// не должен мешать работе — обновление не повод не пустить человека в приложение, — но и
  /// молчать о нём нельзя: без записи в лог причину («сервер поменял формат `/app/android`»,
  /// «`buildNumber` не число») не найти ни в интерфейсе, ни в консоли.
  Future<void> _checkUpdate() async {
    // клиент берём до первого `await`: после него экран может быть уже уничтожен (выход из
    // аккаунта), а `ref` у уничтоженного состояния использовать нельзя
    final api = ref.read(appStateProvider).api;
    try {
      final info = await PackageInfo.fromPlatform();
      final current = int.tryParse(info.buildNumber) ?? 0;
      final latest = await api.latestApp();
      if (kDebugMode) {
        debugPrint('shell update check: current=$current latest=${latest.versionCode}');
      }
      // сравнение по числу: строки «1.10» и «1.9» так не сравнить
      if (!mounted || latest.versionCode <= current) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Доступно обновление ${latest.versionName} — Настройки → Обновление'),
        ));
      });
    } catch (e) {
      // подсказки не будет, и это нормально, но причину надо видеть: сюда попадает и
      // отсутствие сети, и неразобранный ответ сервера
      debugPrint('shell update check failed: $e');
    }
  }

  /// Экран раздела: создаётся при первом показе вкладки и дальше живёт в [_screens].
  Widget _screenFor(AppTab tab) => _screens.putIfAbsent(tab, () => switch (tab) {
        AppTab.files => const FilesScreen(),
        AppTab.mail => const MailScreen(),
        AppTab.media => const MediaScreen(),
        AppTab.map => const MapScreen(),
        AppTab.trash => const TrashScreen(),
        AppTab.settings => const SettingsScreen(),
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Разделы не пересоздаются: `IndexedStack` держит построенные экраны в дереве, поэтому
      // возврат на вкладку не повторяет её загрузку и не сбрасывает прокрутку. Ещё не
      // открытые вкладки остаются пустыми заглушками — их экраны создаются при первом показе.
      body: IndexedStack(
        index: _tab.index,
        children: [
          for (final tab in AppTab.values)
            (tab == _tab || _screens.containsKey(tab)) ? _screenFor(tab) : const SizedBox.shrink(),
        ],
      ),
      // Панель разделов: только иконки, подписи скрыты (см. theme.dart, navigationBarTheme).
      // Подписи всё равно остаются в NavigationDestination — из них берутся подсказка при
      // долгом нажатии и текст для экранного диктора, поэтому удалять их нельзя.
      // Сама панель настроена в theme.dart: высота урезана с 80 до 56, подписи выключены
      // (labelBehavior: alwaysHide), иконки 24 — отсюда и «иконки без подписей» в коде.
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab.index,
        onDestinationSelected: (i) {
          // индекс приходит от панели и совпадает с порядком AppTab — по нему же берём имя
          // для настроек, чтобы после перезапуска открылась та же вкладка
          setState(() => _tab = AppTab.values[i]);
          // запись не ждём: вкладка — мелочь, ради которой нельзя задерживать перерисовку
          unawaited(ref.read(appStateProvider).settings.ui.patch({'tab': AppTab.values[i].name}));
        },
        // Подписи обязательны, хотя на экране их не видно: NavigationDestination берёт из них
        // и всплывающую подсказку при долгом нажатии, и подпись для экранного диктора.
        // Пустой label или его удаление — это не «иконки без подписей», а панель, у которой
        // навигация перестаёт объясняться словами.
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
