import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../features/agent/projects_screen.dart';
import '../features/mac/mac_screen.dart';
import '../features/files/files_screen.dart';
import '../features/mail/mail_screen.dart';
import '../features/map/map_screen.dart';
import '../features/notes/notes_screen.dart';
import '../features/gallery/gallery_screen.dart';
import '../features/settings/settings_screen.dart';
import '../factura/invoices_screen.dart';
import '../features/trash/trash_screen.dart';
import '../providers.dart';
import '../theme.dart';

/// Разделы приложения — ровно те, что стоят в левом баре, в том же порядке.
///
/// Имя значения (`name`) — это ключ, под которым выбранный раздел лежит в настройках
/// (`settings.ui`, поле `tab`), поэтому переименование значений сломало бы восстановление
/// последнего раздела: [_ShellState.initState] ищет сохранённое имя по `name` и при промахе
/// молча остаётся на «Файлах». Список открытый: новый раздел — новое значение здесь и строка
/// в [_tabLook], больше менять нечего. Порядок значений = порядок разделов в баре, поэтому
/// новый раздел вставляется в нужное место, а не в конец списка: «Заметки» стоят после «Карты».
enum AppTab { files, mail, media, map, notes, invoices, projects, mac, trash, settings }

/// Название раздела для человека и его иконка.
///
/// Подписи здесь именно человеческие: «Медиа», а не `media`, и «Инвойсы», а не `invoices`.
/// Ключом для настроек остаётся `AppTab.name` (см. комментарий к нему), поэтому менять эти
/// подписи можно свободно — сохранённый раздел от них не зависит.
///
/// Подписи в баре нигде не рисуются: бар везде — одни иконки. Подпись остаётся подсказкой
/// при наведении и одновременно именем для экранного диктора, поэтому без неё иконку
/// пришлось бы угадывать.
typedef _TabLook = ({String label, IconData icon, IconData activeIcon});

const Map<AppTab, _TabLook> _tabLook = {
  AppTab.files: (label: 'Файлы', icon: Icons.folder_outlined, activeIcon: Icons.folder),
  AppTab.mail: (label: 'Почта', icon: Icons.mail_outline, activeIcon: Icons.mail),
  AppTab.media: (
    label: 'Медиа',
    icon: Icons.photo_library_outlined,
    activeIcon: Icons.photo_library,
  ),
  AppTab.map: (label: 'Карта', icon: Icons.map_outlined, activeIcon: Icons.map),
  AppTab.notes: (
    label: 'Заметки',
    icon: Icons.sticky_note_2_outlined,
    activeIcon: Icons.sticky_note_2,
  ),
  AppTab.invoices: (
    label: 'Инвойсы',
    icon: Icons.receipt_long_outlined,
    activeIcon: Icons.receipt_long,
  ),
  AppTab.projects: (label: 'Проекты', icon: Icons.terminal_outlined, activeIcon: Icons.terminal),
  AppTab.mac: (label: 'MacBook', icon: Icons.laptop_mac_outlined, activeIcon: Icons.laptop_mac),
  AppTab.trash: (label: 'Корзина', icon: Icons.delete_outline, activeIcon: Icons.delete),
  AppTab.settings: (
    label: 'Настройки',
    icon: Icons.settings_outlined,
    activeIcon: Icons.settings,
  ),
};

/// Ширина окна, начиная с которой иконки левого бара показываются крупнее.
///
/// Порог по ширине окна, а не раздела: бар стоит вне раздела и о его раскладке не знает.
/// Значение близко к порогу двухпанельного вида (`util/master_detail.dart`), чтобы бар
/// увеличивался тогда же, когда раздел переходит на карточки.
const double _wideMin = 760;

/// Оболочка после входа: держит выбранный раздел и левый бар с разделами.
///
/// Бар стоит слева во всю высоту экрана и виден только на основных страницах разделов. Это
/// выходит само собой, без слежения за навигацией: вложенные экраны (письмо, разговор с
/// агентом, настройки синхронизации) уходят в корневой навигатор приложения (`MaterialApp`), а он лежит
/// выше оболочки — то есть перекрывает её целиком, вместе с баром. Поэтому у вложенного экрана
/// есть своя шапка с кнопкой «назад» во всю ширину, а бар в этот момент не виден.
///
/// Своей шапки у оболочки нет намеренно: раздел видно и так — по подсветке в баре, а нижняя
/// шапка отнимала бы высоту у списков ради названия, которое уже написано в баре.
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
        AppTab.media => const GalleryScreen(),
        AppTab.map => const MapScreen(),
        AppTab.notes => const NotesScreen(),
        AppTab.invoices => const InvoicesScreen(),
        AppTab.projects => const ProjectsScreen(),
        AppTab.mac => const MacScreen(),
        AppTab.trash => const TrashScreen(),
        AppTab.settings => const SettingsScreen(),
      });

  @override
  Widget build(BuildContext context) {
    // Иконки бара крупнее на широком экране: на мониторе и планшете мелкие значки теряются,
    // а палец и курсор там точнее, чем на телефоне.
    final wide = MediaQuery.sizeOf(context).width >= _wideMin;
    return Scaffold(
      // Бар — слева и во всю высоту, рядом с ним — раздел. `SafeArea` у каждого свой: иначе
      // отступ под «вырезом» камеры (в альбомной ориентации) достался бы обоим и лёг бы в
      // середину раскладки, а не по краям экрана.
      body: SafeArea(
        left: true,
        right: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _NavBar(current: _tab, onSelect: _selectTab, wide: wide),
            // Разделителя между баром и разделом больше нет: оба лежат на одном чёрном фоне,
            // а границу задаёт только отступ от иконок до карточек раздела.
            // Разделы не пересоздаются: `IndexedStack` держит построенные экраны в дереве,
            // поэтому возврат на раздел не повторяет его загрузку и не сбрасывает прокрутку.
            // Ещё не открытые разделы остаются пустыми заглушками — их экраны создаются при
            // первом показе.
            Expanded(
              child: IndexedStack(
                index: _tab.index,
                children: [
                  for (final tab in AppTab.values)
                    (tab == _tab || _screens.containsKey(tab))
                        ? _screenFor(tab)
                        : const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Открывает раздел и запоминает выбор.
  ///
  /// Запись не ждём: раздел — мелочь, ради которой нельзя задерживать перерисовку.
  /// Повторное нажатие на открытый раздел ничего не делает: сбрасывать его состояние (открытую
  /// папку, прокрутку) было бы неожиданно — это не «обновить», а «сбросить».
  void _selectTab(AppTab tab) {
    if (_tab == tab) return;
    setState(() => _tab = tab);
    unawaited(ref.read(appStateProvider).settings.ui.patch({'tab': tab.name}));
  }
}

/// Левый бар с разделами: узкая полоса во всю высоту экрана с одними иконками.
///
/// Подписей на экране нет ни на телефоне, ни на маке — так бар занимает минимум ширины и
/// выглядит одинаково на всех платформах. Название раздела показывает `Tooltip` при наведении
/// (на маке — курсором), он же служит именем для экранного диктора.
///
/// Ни фона, ни рамки у бара нет: иконки лежат прямо на чёрном фоне приложения, а выбранный
/// раздел отличается от остальных только цветом и залитой иконкой. На широком экране значки
/// крупнее (см. [_iconSize]).
///
/// Содержимое бара прокручивается, чтобы новые разделы не упирались в нижний край, когда их
/// станет больше, чем помещается на экран.
class _NavBar extends StatelessWidget {
  const _NavBar({
    required this.current,
    required this.onSelect,
    required this.wide,
  });

  /// Открытый сейчас раздел — его иконка акцентная и залитая.
  final AppTab current;

  /// Что делать при выборе раздела.
  final ValueChanged<AppTab> onSelect;

  /// Широкий экран: иконки раздела крупнее (считает `Shell.build`).
  final bool wide;

  /// Размер иконки: на широком экране чуть больше. На мониторе и планшете мелкие значки
  /// теряются, а палец и курсор там точнее, чем на телефоне.
  double get _iconSize => wide ? 26 : 22;

  /// Поле вокруг иконки — тот же отступ сетки, что и вокруг карточек раздела ([kPaneGutter]):
  /// бар, карточки и край экрана стоят на одной вертикали, а отступ от иконок до первой
  /// карточки получается равным промежутку между карточками.
  static const _pad = kPaneGutter;

  /// Ширина полосы: иконка и поле вокруг кнопки.
  double get _width => _iconSize + 2 * _pad;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _width,
      // `Material` — не для красоты: без него `InkWell` в строках не рисует отклик на нажатие.
      // Фон прозрачный: бар читается одними иконками на общем фоне приложения.
      child: Material(
        color: Colors.transparent,
        child: ListView(
          // прокрутка содержимого бара: разделов со временем станет больше, чем помещается по
          // высоте, и последние обязаны остаться доступными
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            for (final tab in AppTab.values) _item(tab),
          ],
        ),
      ),
    );
  }

  /// Кнопка раздела: одна иконка.
  ///
  /// Не `ListTile`: тот держит минимум 56 px и собственные боковые поля, из-за которых кнопка
  /// вышла бы шире, чем полоса. Здесь размер кнопки задают только [_iconSize] и [_pad].
  Widget _item(AppTab tab) {
    final look = _tabLook[tab]!;
    final selected = tab == current;
    return Tooltip(
      // подпись раздела — единственное место, где он назван словами: видна при наведении
      // (на маке — курсором) и читается экранным диктором
      message: look.label,
      child: InkWell(
        onTap: () => onSelect(tab),
        child: Padding(
          padding: const EdgeInsets.all(_pad),
          child: Icon(
            selected ? look.activeIcon : look.icon,
            size: _iconSize,
            // выбранного раздела видно только по акценту и залитой иконке: подложки у строки
            // нет, иначе на чёрном фоне она читалась бы ещё одной плашкой
            color: selected ? C.accent : C.fg3,
          ),
        ),
      ),
    );
  }
}
