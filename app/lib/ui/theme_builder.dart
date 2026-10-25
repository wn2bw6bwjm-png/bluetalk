import 'package:flutter/material.dart';
import 'package:mesh_core/mesh_core.dart';

/// Maps the persisted, Flutter-independent [AppThemeSettings] to a
/// [ThemeData]. Applied immediately when settings change (the MaterialApp
/// watches the settings), and saved locally by the controller.
ThemeData buildTheme(AppThemeSettings s, Brightness platformBrightness) {
  final c = s.resolveColors();
  if (c == null) {
    return ThemeData(
      colorSchemeSeed: Colors.teal,
      brightness: platformBrightness,
      useMaterial3: true,
    );
  }
  final dark = c.isDark;
  Color on(int argb) =>
      luminance(argb) > 0.4 ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
  final scheme = ColorScheme(
    brightness: dark ? Brightness.dark : Brightness.light,
    primary: Color(c.primary),
    onPrimary: Color(c.onPrimary),
    secondary: Color(c.accent),
    onSecondary: on(c.accent),
    error: const Color(0xFFCF6679),
    onError: const Color(0xFF000000),
    surface: Color(c.surface),
    onSurface: Color(c.onSurface),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Color(c.background),
    appBarTheme: AppBarTheme(
      backgroundColor: Color(c.background),
      foregroundColor: Color(c.onSurface),
      elevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Color(c.surface),
      indicatorColor: Color(c.primary).withValues(alpha: 0.25),
    ),
  );
}

/// Accent for a room: the user's per-room override, else the colour the room
/// itself carries, else the theme primary.
Color roomColor(
  BuildContext context,
  AppThemeSettings theme,
  String roomIdHex,
  int? roomOwnColor,
) {
  final override = theme.colorForRoom(roomIdHex);
  if (override != null) return Color(override);
  if (roomOwnColor != null) return Color(roomOwnColor);
  return Theme.of(context).colorScheme.primary;
}
