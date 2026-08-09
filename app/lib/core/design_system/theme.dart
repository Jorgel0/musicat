import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _themeModeKey = 'themeMode';
const _accentColorKey = 'accentColor';

class ThemeModeController extends Notifier<ThemeMode> {
  ThemeModeController([this._initial = ThemeMode.system]);

  final ThemeMode _initial;

  @override
  ThemeMode build() => _initial;

  Future<void> update(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_themeModeKey, mode.index);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);

class AccentColorController extends Notifier<Color> {
  AccentColorController([Color? initial])
    : _initial = initial ?? MusicatTheme.defaultSeedColor;

  final Color _initial;

  @override
  Color build() => _initial;

  Future<void> update(Color color) async {
    state = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_accentColorKey, color.toARGB32());
  }
}

final accentColorProvider = NotifierProvider<AccentColorController, Color>(
  AccentColorController.new,
);

/// Loads the persisted theme mode/accent, so bootstrap can override
/// [themeModeProvider]/[accentColorProvider] with the saved values before
/// the first frame instead of always starting from the defaults.
Future<({ThemeMode themeMode, Color accentColor})>
loadThemePreferences() async {
  final prefs = await SharedPreferences.getInstance();
  final themeModeIndex = prefs.getInt(_themeModeKey);
  final accentValue = prefs.getInt(_accentColorKey);
  return (
    themeMode: themeModeIndex == null
        ? ThemeMode.system
        : ThemeMode.values[themeModeIndex],
    accentColor: accentValue == null
        ? MusicatTheme.defaultSeedColor
        : Color(accentValue),
  );
}

abstract final class MusicatTheme {
  static const defaultSeedColor = Color(0xFF6750A4);

  /// A handful of Material-friendly seed colors to choose from in Settings.
  static const accentOptions = [
    defaultSeedColor,
    Color(0xFF006A6A),
    Color(0xFF8B4E1F),
    Color(0xFF9C4146),
    Color(0xFF3D5B9C),
    Color(0xFF3C6E38),
  ];

  static ThemeData light(Color seedColor) => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: seedColor),
  );

  static ThemeData dark(Color seedColor) => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
    ),
  );
}
