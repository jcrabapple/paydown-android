import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the user's light/dark/system choice and notifies listeners.
/// Lives above both MaterialApps (login gate and shell) so the theme
/// applies everywhere.
class ThemeModeController extends ChangeNotifier {
  ThemeModeController([SharedPreferences? prefs]) : _prefs = prefs;

  static const _kKey = 'theme_mode';

  final SharedPreferences? _prefs;
  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  /// Reads the persisted choice. Without prefs (first frame before the
  /// async load lands) the controller stays on system.
  Future<void> load() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _mode = switch (prefs.getString(_kKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    notifyListeners();
  }

  Future<void> set(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setString(_kKey, switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }
}

final ThemeData kPaydownTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F6B4F)),
  useMaterial3: true,
);

final ThemeData kPaydownDarkTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFF0F6B4F),
    brightness: Brightness.dark,
  ),
  useMaterial3: true,
);
