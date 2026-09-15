import 'package:flutter/material.dart';

/// Палитра тёмной темы приложения: цвета перенесены из веб-клиента, который жил в `web/src`
/// (в репозитории его больше нет).
class C {
  static const canvas = Color(0xFF0D0F14);
  static const island = Color(0xFF161A22);
  static const surface = Color(0xFF161A22);
  static const surface2 = Color(0xFF1C212B);
  static const surface3 = Color(0xFF232936);

  static const fg = Color(0xFFE6E8EB);
  static const fg2 = Color(0xFFAAB3C0);
  static const fg3 = Color(0xFF7B8494);

  static const brd = Color(0xFF262B33);
  static const brd2 = Color(0xFF3A4250);

  static const accent = Color(0xFF2B6CFF);
  static const accentFg = Color(0xFFFFFFFF);
  static const accent2 = Color(0xFF245EE0);
  static const accentSoft = Color(0xFF1B2637);

  static const ok = Color(0xFF2FAE5F);
  static const warn = Color(0xFFD9A343);
  static const danger = Color(0xFFFF6B6B);
}

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
    splashFactory: InkRipple.splashFactory,
    visualDensity: VisualDensity.standard,
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: C.fg,
      displayColor: C.fg,
    ),
    cardTheme: CardThemeData(
      color: C.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: C.brd),
      ),
      margin: EdgeInsets.zero,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: C.surface2,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titleTextStyle: const TextStyle(color: C.fg, fontSize: 17, fontWeight: FontWeight.w600),
      contentTextStyle: const TextStyle(color: C.fg2, fontSize: 14),
    ),
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
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: C.island,
      indicatorColor: C.accentSoft,
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStatePropertyAll(TextStyle(color: C.fg3, fontSize: 11)),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(color: selected ? C.accent : C.fg3, size: 22);
      }),
    ),
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
    snackBarTheme: SnackBarThemeData(
      backgroundColor: C.surface2,
      contentTextStyle: const TextStyle(color: C.fg),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      behavior: SnackBarBehavior.floating,
    ),
    dividerTheme: const DividerThemeData(color: C.brd, thickness: 1),
  );
}
