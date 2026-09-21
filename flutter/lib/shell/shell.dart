import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../features/agent/projects_screen.dart';
import '../features/chat/chat_screen.dart';
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
enum AppTab { files, mail, media, map, notes, invoices, chat, projects, trash, settings }

/// Название раздела для человека и его иконка.
///
/// Подписи здесь именно человеческие: «Медиа», а не `media`, и «Инвойсы», а не `invoices`.
/// Ключом для настроек остаётся `AppTab.name` (см. комментарий к нему), поэтому менять эти
/// подписи можно свободно — сохранённый раздел от них не зависит.
///
/// Подписи — и то, что видно в баре на широком экране, и подсказка при наведении, и имя для
/// экранного диктора: в узком баре (телефон) на экране их нет, и без них иконку пришлось бы
/// угадывать.
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
  AppTab.chat: (label: 'Чат', icon: Icons.chat_bubble_outline, activeIcon: Icons.chat_bubble),
  AppTab.projects: (label: 'Проекты', icon: Icons.terminal_outlined, activeIcon: Icons.terminal),
  AppTab.trash: (label: 'Корзина', icon: Icons.delete_outline, activeIcon: Icons.delete),
  AppTab.settings: (
    label: 'Настройки',
    icon: Icons.settings_outlined,
    activeIcon: Icons.settings,
  ),
};

/// Порог ширины окна, с которого левый бар показывает подписи разделов, а не одни иконки.
///
/// Считается по ширине всего окна: бар — первое, что занимает место слева, поэтому своей
/// ширины у него ещё нет. 900 выбрано вместе с порогом двухпанельного вида раздела «Проекты»
/// (720 на содержимое): 900 − 176 (бар с подписями) − 1 (рамка) ≈ 723, то есть на той же
/// ширине, где появляются подписи разделов, список разговоров и сам разговор уже помещаются
/// рядом — раскладка меняется целиком, а не в два приёма.
const double _navLabelsMin = 900.0;

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
        AppTab.chat => const ChatScreen(),
        AppTab.projects => const ProjectsScreen(),
        AppTab.trash => const TrashScreen(),
        AppTab.settings => const SettingsScreen(),
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Бар — слева и во всю высоту, рядом с ним — раздел. `SafeArea` у каждого свой: иначе
      // отступ под «вырезом» камеры (в альбомной ориентации) достался бы обоим и лёг бы в
      // середину раскладки, а не по краям экрана.
      body: SafeArea(
        left: true,
        right: false,
        child: LayoutBuilder(
          // ширина бара и содержимого считается от окна: `LayoutBuilder` здесь один на всё
          // тело, чтобы подписи в баре и двухпанельные разделы появлялись на одной ширине
          builder: (context, c) => Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _NavBar(
                current: _tab,
                onSelect: _selectTab,
                wide: c.maxWidth >= _navLabelsMin,
              ),
              // Рамка вместо тени: на тёмной теме тень между двумя поверхностями почти не
              // читается, а линия отделяет бар от содержимого в любом месте одинаково.
              const VerticalDivider(width: 1, thickness: 1, color: C.brd),
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

/// Левый бар с разделами: полоса во всю высоту экрана.
///
/// На телефоне — одни иконки: список короткий и узнаваемый, а подписи отняли бы у содержимого
/// ширину, которая нужнее спискам файлов и писем. На широком экране ([wide]) рядом с иконкой
/// идёт название раздела: там место есть, и по названию раздел видно сразу, а не только по
/// подсказке при наведении. Подсказка (`Tooltip`) остаётся в обоих случаях — она же имя для
/// экранного диктора.
///
/// Содержимое бара прокручивается, чтобы новые разделы не упирались в нижний край, когда их
/// станет больше, чем помещается на экран.
class _NavBar extends StatelessWidget {
  const _NavBar({
    required this.current,
    required this.onSelect,
    required this.wide,
  });

  /// Открытый сейчас раздел — его строка подсвечена.
  final AppTab current;

  /// Что делать при выборе раздела.
  final ValueChanged<AppTab> onSelect;

  /// Показывать ли рядом с иконкой название раздела (широкий экран).
  final bool wide;

  /// Размер иконки и отступ вокруг неё.
  ///
  /// Кнопка раздела — квадрат со стороной [_iconSize] + 2·[_tapPad], он же задаёт ширину всей
  /// полосы. Боковых полей у кнопки нет: они читались как «полоса шире, чем нужно» и отнимали
  /// ширину у списков.
  static const _iconSize = 22.0;
  static const _tapPad = 11.0;

  /// Ширина полосы в узком виде: иконка и отступы вокруг кнопки.
  static const _width = _iconSize + 2 * _tapPad;

  /// Отступ между иконкой и подписью раздела в широком виде.
  static const _labelGap = 12.0;

  /// Ширина полосы с подписями.
  ///
  /// Число, а не «по самой длинной подписи»: ширина бара менялась бы от набора разделов, и
  /// содержимое прыгало бы при добавлении нового пункта. Подписи, которым места не хватит,
  /// обрезаются — раздел при этом всё равно виден целиком в подсказке.
  static const _wideWidth = 176.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: wide ? _wideWidth : _width,
      // `Material` — не для красоты: без него `InkWell` в строках не рисует отклик на нажатие.
      // Цвет бара — `island` (тот же, что у карточек), а не фон приложения: бар отделяется от
      // содержимого цветом, и разделитель (см. `body`) тогда только подчёркивает границу.
      child: Material(
        color: C.island,
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

  /// Кнопка раздела: иконка, подпись (в широком виде) и подсветка выбранного.
  ///
  /// Вместо `ListTile` — свой ряд с равными отступами: `ListTile` держит минимум 56 px и
  /// собственные боковые поля, из-за которых кнопка вышла бы шире, чем полоса.
  Widget _item(AppTab tab) {
    final look = _tabLook[tab]!;
    final selected = tab == current;
    return Tooltip(
      // подпись раздела — в узком баре единственное место, где он назван словами: видна при
      // наведении (на маке — курсором) и читается экранным диктором
      message: look.label,
      child: InkWell(
        onTap: () => onSelect(tab),
        child: Container(
          // подсветка выбранного — мягкая заливка акцентом, как у нижней панели разделов раньше
          color: selected ? C.accentSoft : null,
          padding: const EdgeInsets.all(_tapPad),
          child: Row(
            children: [
              Icon(
                selected ? look.activeIcon : look.icon,
                size: _iconSize,
                color: selected ? C.accent : C.fg3,
              ),
              // подпись только там, где для неё есть место: в узком баре ширину строки задаёт
              // иконка, и текст влез бы поверх соседних элементов
              if (wide) ...[
                const SizedBox(width: _labelGap),
                Expanded(
                  child: Text(
                    look.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? C.accent : C.fg3,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
