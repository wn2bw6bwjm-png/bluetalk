import 'dart:convert';
import 'dart:math' as math;

enum ThemeModeSetting { system, light, dark, amoled, custom }

/// Colours are ARGB ints (0xAARRGGBB), kept Flutter-independent so the
/// settings can be stored, validated and unit-tested in pure Dart.
class ThemeColors {
  const ThemeColors({
    required this.primary,
    required this.onPrimary,
    required this.background,
    required this.surface,
    required this.onSurface,
    required this.accent,
  });

  final int primary;
  final int onPrimary;
  final int background;
  final int surface;
  final int onSurface;
  final int accent;

  ThemeColors copyWith({
    int? primary,
    int? onPrimary,
    int? background,
    int? surface,
    int? onSurface,
    int? accent,
  }) =>
      ThemeColors(
        primary: primary ?? this.primary,
        onPrimary: onPrimary ?? this.onPrimary,
        background: background ?? this.background,
        surface: surface ?? this.surface,
        onSurface: onSurface ?? this.onSurface,
        accent: accent ?? this.accent,
      );

  /// True for dark palettes (background luminance below 0.5).
  bool get isDark => luminance(background) < 0.5;

  Map<String, Object?> toJson() => {
        'primary': primary,
        'onPrimary': onPrimary,
        'background': background,
        'surface': surface,
        'onSurface': onSurface,
        'accent': accent,
      };

  static ThemeColors? fromJson(Object? j) {
    if (j is! Map) return null;
    int? c(String k) {
      final v = j[k];
      return (v is int && v >= 0 && v <= 0xFFFFFFFF) ? (v | 0xFF000000) : null;
    }

    final p = c('primary'), op = c('onPrimary'), bg = c('background');
    final s = c('surface'), os = c('onSurface'), a = c('accent');
    if ([p, op, bg, s, os, a].contains(null)) return null;
    return ThemeColors(
      primary: p!,
      onPrimary: op!,
      background: bg!,
      surface: s!,
      onSurface: os!,
      accent: a!,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ThemeColors &&
      other.primary == primary &&
      other.onPrimary == onPrimary &&
      other.background == background &&
      other.surface == surface &&
      other.onSurface == onSurface &&
      other.accent == accent;

  @override
  int get hashCode =>
      Object.hash(primary, onPrimary, background, surface, onSurface, accent);
}

/// WCAG 2.x relative luminance of an ARGB colour.
double luminance(int argb) {
  double ch(int v) {
    final s = v / 255.0;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  final r = ch((argb >> 16) & 0xFF);
  final g = ch((argb >> 8) & 0xFF);
  final b = ch(argb & 0xFF);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// WCAG contrast ratio (1..21).
double contrastRatio(int a, int b) {
  final la = luminance(a), lb = luminance(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

class ThemePreset {
  const ThemePreset(this.id, this.name, this.colors);
  final String id;
  final String name;
  final ThemeColors colors;
}

const List<ThemePreset> themePresets = [
  ThemePreset(
      'midnight',
      'Midnight',
      ThemeColors(
          primary: 0xFF7C9CFF,
          onPrimary: 0xFF0B1020,
          background: 0xFF0B1020,
          surface: 0xFF141B33,
          onSurface: 0xFFE6E9F5,
          accent: 0xFFB39DFF)),
  ThemePreset(
      'ocean',
      'Ocean',
      ThemeColors(
          primary: 0xFF0277BD,
          onPrimary: 0xFFFFFFFF,
          background: 0xFFF2FAFD,
          surface: 0xFFFFFFFF,
          onSurface: 0xFF0B2A36,
          accent: 0xFF00ACC1)),
  ThemePreset(
      'forest',
      'Forest',
      ThemeColors(
          primary: 0xFF66BB6A,
          onPrimary: 0xFF0E1A13,
          background: 0xFF0E1A13,
          surface: 0xFF16281C,
          onSurface: 0xFFE4F2E7,
          accent: 0xFFA5D6A7)),
  ThemePreset(
      'purple',
      'Purple',
      ThemeColors(
          primary: 0xFFBA68C8,
          onPrimary: 0xFF140B1F,
          background: 0xFF140B1F,
          surface: 0xFF1F1330,
          onSurface: 0xFFF0E6FA,
          accent: 0xFFE1BEE7)),
  ThemePreset(
      'sunset',
      'Sunset',
      ThemeColors(
          primary: 0xFFC53A0B,
          onPrimary: 0xFFFFFFFF,
          background: 0xFFFFF4EC,
          surface: 0xFFFFFFFF,
          onSurface: 0xFF3A1D0F,
          accent: 0xFFFF8F00)),
  ThemePreset(
      'monochrome',
      'Monochrome',
      ThemeColors(
          primary: 0xFF222222,
          onPrimary: 0xFFFFFFFF,
          background: 0xFFFFFFFF,
          surface: 0xFFF2F2F2,
          onSurface: 0xFF111111,
          accent: 0xFF555555)),
  ThemePreset(
      'cyberpunk',
      'Cyberpunk',
      ThemeColors(
          primary: 0xFFFF2BD6,
          onPrimary: 0xFF0A0A12,
          background: 0xFF0A0A12,
          surface: 0xFF14142A,
          onSurface: 0xFFF5F5FF,
          accent: 0xFF00F0FF)),
];

ThemePreset? presetById(String? id) {
  for (final p in themePresets) {
    if (p.id == id) return p;
  }
  return null;
}

/// Persisted appearance. System/Light/Dark use the platform's base scheme;
/// AMOLED is Dark with a pure-black background; Custom uses [custom] (or a
/// [presetId]). [roomColors] overrides the accent of single rooms.
class AppThemeSettings {
  const AppThemeSettings({
    this.mode = ThemeModeSetting.system,
    this.presetId,
    this.custom,
    this.roomColors = const {},
  });

  final ThemeModeSetting mode;
  final String? presetId;
  final ThemeColors? custom;
  final Map<String, int> roomColors;

  static const int amoledBlack = 0xFF000000;

  /// The palette to apply, or null to use the platform default scheme.
  ThemeColors? resolveColors() {
    switch (mode) {
      case ThemeModeSetting.system:
      case ThemeModeSetting.light:
      case ThemeModeSetting.dark:
        final p = presetById(presetId);
        return p?.colors;
      case ThemeModeSetting.amoled:
        final base = presetById(presetId)?.colors;
        if (base != null && base.isDark) {
          return base.copyWith(background: amoledBlack);
        }
        return const ThemeColors(
          primary: 0xFFBB86FC,
          onPrimary: 0xFF000000,
          background: amoledBlack,
          surface: 0xFF0D0D0D,
          onSurface: 0xFFFFFFFF,
          accent: 0xFF03DAC6,
        );
      case ThemeModeSetting.custom:
        return custom ?? presetById(presetId)?.colors;
    }
  }

  int? colorForRoom(String roomIdHex) => roomColors[roomIdHex];

  AppThemeSettings copyWith({
    ThemeModeSetting? mode,
    String? presetId,
    bool clearPreset = false,
    ThemeColors? custom,
    Map<String, int>? roomColors,
  }) =>
      AppThemeSettings(
        mode: mode ?? this.mode,
        presetId: clearPreset ? null : (presetId ?? this.presetId),
        custom: custom ?? this.custom,
        roomColors: roomColors ?? this.roomColors,
      );

  AppThemeSettings withRoomColor(String roomIdHex, int? argb) {
    final m = Map<String, int>.of(roomColors);
    if (argb == null) {
      m.remove(roomIdHex);
    } else {
      m[roomIdHex] = argb | 0xFF000000;
    }
    return copyWith(roomColors: m);
  }

  String toJsonString() => jsonEncode({
        'v': 1,
        'mode': mode.name,
        if (presetId != null) 'preset': presetId,
        if (custom != null) 'custom': custom!.toJson(),
        'rooms': roomColors,
      });

  /// Tolerant parser: anything malformed falls back to defaults, never throws.
  static AppThemeSettings fromJsonString(String? s) {
    if (s == null || s.isEmpty) return const AppThemeSettings();
    try {
      final j = jsonDecode(s);
      if (j is! Map) return const AppThemeSettings();
      final mode = ThemeModeSetting.values.firstWhere(
        (m) => m.name == j['mode'],
        orElse: () => ThemeModeSetting.system,
      );
      final preset = presetById(j['preset'] as String?)?.id;
      final rooms = <String, int>{};
      final rj = j['rooms'];
      if (rj is Map) {
        for (final e in rj.entries) {
          if (e.key is String && e.value is int) {
            rooms[e.key as String] = (e.value as int) | 0xFF000000;
          }
        }
      }
      return AppThemeSettings(
        mode: mode,
        presetId: preset,
        custom: ThemeColors.fromJson(j['custom']),
        roomColors: rooms,
      );
    } catch (_) {
      return const AppThemeSettings();
    }
  }
}
