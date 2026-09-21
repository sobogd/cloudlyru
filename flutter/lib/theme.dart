import 'package:flutter/material.dart';

/// Палитра тёмной темы приложения: цвета перенесены из веб-клиента, который жил в `web/src`
/// (в репозитории его больше нет — удалён коммитом 407a490), поэтому набор имён и их значения
/// здесь и есть источник истины: экраны берут цвета только отсюда, своих литералов не заводят.
///
/// Имена описывают роль, а не оттенок: `canvas` — фон приложения, `surface` — карточки,
/// `island` — панель разделов (тот же цвет, поэтому ссылается на `surface`, чтобы палитру
/// нельзя было развести случайно), `fg/fg2/fg3` — текст по убыванию важности.
class C {
  // Фоны и поверхности
  static const canvas = Color(0xFF0D0F14);
  static const surface = Color(0xFF161A22);
  // Панель разделов лежит на фоне приложения, а не на карточке, поэтому у неё своё имя —
  // но цвет общий с карточками: одно значение на два имени ломалось бы при смене палитры
  static const island = surface;
  static const surface2 = Color(0xFF1C212B);
  static const surface3 = Color(0xFF232936);

  // Текст: основной, второстепенный (подписи), третий — приглушённые пояснения и иконки
  static const fg = Color(0xFFE6E8EB);
  static const fg2 = Color(0xFFAAB3C0);
  static const fg3 = Color(0xFF7B8494);

  // Границы: обычная рамка карточек и более заметная — для элементов, которые надо выделить
  static const brd = Color(0xFF262B33);
  static const brd2 = Color(0xFF3A4250);

  // Акцент: кнопки и выделение, тёмный вариант для нажатого состояния, soft — подложка
  // выбранного пункта панели разделов
  static const accent = Color(0xFF2B6CFF);
  static const accentFg = Color(0xFFFFFFFF);
  static const accent2 = Color(0xFF245EE0);
  static const accentSoft = Color(0xFF1B2637);

  // Статусы: успех, предупреждение (например, мало места на диске), ошибка
  static const ok = Color(0xFF2FAE5F);
  static const warn = Color(0xFFD9A343);
  static const danger = Color(0xFFFF6B6B);
}

/// Собирает тёмную тему приложения из палитры [C].
///
/// Единственная точка настройки вида: всё, что задано здесь, дальше применяется ко всем экранам,
/// поэтому цвета и метрики не приходится повторять в виджетах. Вызывается один раз при
/// построении корня приложения.
ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: C.accent,
    onPrimary: C.accentFg,
    secondary: C.accent,
    onSecondary: C.accentFg,
    surface: C.surface,
    onSurface: C.fg,
    onSurfaceVariant: C.fg2,
    outline: C.brd,
    outlineVariant: C.brd,
    error: C.danger,
    onError: Colors.white,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: C.canvas,
    // Вид отклика на нажатие задан явно: иначе он зависел бы от платформы, а на тёмных
    // подложках платформенный всплеск заметно отличается.
    splashFactory: InkRipple.splashFactory,
    visualDensity: VisualDensity.standard,
  );

  return base.copyWith(
    // Цвета текста берём из палитры: часть стилей, унаследованных от Material, рассчитана
    // на светлую тему и без этого осталась бы тёмной — то есть невидимой на нашем фоне.
    textTheme: base.textTheme.apply(
      bodyColor: C.fg,
      displayColor: C.fg,
    ),
    // Шапка раздела — того же цвета, что фон приложения: экран выглядит цельным, а границу
    // с содержимым задают только карточки. Раньше этот цвет стоял в каждом `AppBar` по
    // экрану — теперь он один на всё приложение, и менять его нужно здесь.
    appBarTheme: AppBarTheme(
      backgroundColor: C.canvas,
      // M3 подкрашивает шапку тоном primary при прокрутке содержимого под ней; подложка
      // должна остаться ровно цвета палитры.
      surfaceTintColor: Colors.transparent,
      foregroundColor: C.fg,
      elevation: 0,
      scrolledUnderElevation: 0,
      // Иконки в AppBar — тот же цвет, что и текст.
      iconTheme: IconThemeData(color: C.fg, size: 24),
    ),
    cardTheme: CardThemeData(
      color: C.surface,
      // M3 подкрашивает поднятые поверхности тоном primary; здесь подложка должна остаться
      // ровно цвета палитры.
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: C.brd),
      ),
      // Отступ вокруг карточки задаёт вызывающий экран (обычно Panel), у самой карточки его нет.
      margin: EdgeInsets.zero,
    ),
    dialogTheme: DialogThemeData(
      // Диалог лежит поверх карточек, поэтому его подложка светлее: границей слои тут не
      // разделить, у обоих рамка одного цвета.
      backgroundColor: C.surface2,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titleTextStyle: const TextStyle(color: C.fg, fontSize: 17, fontWeight: FontWeight.w600),
      contentTextStyle: const TextStyle(color: C.fg2, fontSize: 14),
    ),
    // Поля ввода — залитые surface3 с рамкой; в фокусе рамка становится акцентной: на тёмном
    // фоне это единственный признак того, что поле активно.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.surface3,
      hintStyle: const TextStyle(color: C.fg3),
      labelStyle: const TextStyle(color: C.fg2),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: C.brd),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: C.brd),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: C.accent),
      ),
    ),
    // Настроек для `drawerTheme` и `navigationBarTheme` здесь больше нет: выезжающая панель и
    // нижняя панель разделов остались в прошлом — разделы живут в левом баре оболочки
    // (`shell/shell.dart`), и он рисуется своими виджетами, а не `Drawer` или `NavigationBar`.
    //
    // Основная кнопка — заливка акцентом, текстовая — только цветом текста: на карточках
    // вторая заливка спорила бы с подложкой и рамкой.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: C.accent,
        foregroundColor: C.accentFg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: C.accent),
    ),
    // floating — сообщение висит поверх интерфейса, а не прижимается вплотную к панели
    // разделов; surface2 отделяет его от фона экрана.
    snackBarTheme: SnackBarThemeData(
      backgroundColor: C.surface2,
      contentTextStyle: const TextStyle(color: C.fg),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      behavior: SnackBarBehavior.floating,
    ),
    // Выделение текста задано явно: по умолчанию M3 берёт цвет подсветки из `primary` с малой
    // прозрачностью, и на тёмной подложке выделенные команды и вывод почти не видно — а в
    // разделе «Проекты» именно их и выделяют, чтобы перенести в терминал.
    textSelectionTheme: TextSelectionThemeData(
      selectionColor: C.accent.withValues(alpha: 0.45),
      selectionHandleColor: C.accent,
      cursorColor: C.accent,
    ),
    dividerTheme: const DividerThemeData(color: C.brd, thickness: 1),
  );
}
