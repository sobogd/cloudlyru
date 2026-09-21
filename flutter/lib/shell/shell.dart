import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../features/chat/chat_screen.dart';
import '../features/files/files_screen.dart';
import '../features/mail/mail_screen.dart';
import '../features/map/map_screen.dart';
import '../features/gallery/gallery_screen.dart';
import '../features/settings/settings_screen.dart';
import '../factura/invoices_screen.dart';
import '../features/trash/trash_screen.dart';
import '../providers.dart';
import '../theme.dart';

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
enum AppTab { files, mail, media, map, invoices, chat, trash, settings }

/// Иконки для каждого раздела. Имена соответствуют `AppTab.name`, чтобы можно было
/// восстанавливать последнюю вкладку из настроек, даже если иконка изменится.
final Map<AppTab, IconData> _tabIcons = {
  AppTab.files: Icons.folder_outlined,
  AppTab.mail: Icons.mail_outline,
  AppTab.media: Icons.photo_library_outlined,
  AppTab.map: Icons.map_outlined,
  AppTab.invoices: Icons.receipt_long_outlined,
  AppTab.chat: Icons.chat_bubble_outline,
  AppTab.trash: Icons.delete_outline,
  AppTab.settings: Icons.settings_outlined,
};

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
  bool _drawerOpen = false;

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
        AppTab.media => const GalleryScreen(),
        AppTab.map => const MapScreen(),
        AppTab.invoices => const InvoicesScreen(),
        AppTab.chat => const ChatScreen(),
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
      // Боковая панель вместо нижней: открывается по кнопке в AppBar.
      // На мобильном — только по кнопке, на десктопе — можно оставить открытым или тоже по кнопке.
      drawer: _buildDrawer(),
      // Кнопка меню в AppBar для открытия/закрытия Drawer.
      appBar: AppBar(
        title: Text(_tab.name),
        // Кнопка гамбургер: иконка меняется в зависимости от состояния Drawer.
        actions: [
          IconButton(
            icon: Icon(_drawerOpen ? Icons.close : Icons.menu),
            onPressed: () => setState(() => _drawerOpen = !_drawerOpen),
          ),
        ],
      ),
    );
  }

  /// Строит боковую панель навигации.
  Widget _buildDrawer() {
    return Drawer(
      child: ListView(
        // Отступ сверху, чтобы не наезжать на AppBar.
        padding: const EdgeInsets.only(top: 16, left: 8, right: 8, bottom: 8),
        children: [
          // Заголовок Drawer — просто название приложения или логотип.
          Container(
            height: 120,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [C.accent, C.accent2],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Center(
              child: Text(
                'Cloudly',
                style: TextStyle(
                  color: C.accentFg,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          // Список разделов навигации.
          ...AppTab.values.map((tab) {
            final selectedIcon = _tabIcons[tab];
            final icon = tab == _tab ? Icon(selectedIcon) : Icon(selectedIcon);
            return ListTile(
              leading: icon,
              title: Text(tab.name),
              onTap: () {
                setState(() {
                  _tab = tab;
                  _drawerOpen = false; // Закрыть Drawer после выбора.
                });
                // Запись в настройки — не ждём, вкладка — мелочь.
                unawaited(ref.read(appStateProvider).settings.ui.patch({'tab': tab.name}));
              },
            );
          }),
        ],
      ),
    );
  }
}
