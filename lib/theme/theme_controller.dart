import 'package:flutter/material.dart';

import '../data/db/app_database.dart';
import 'app_theme.dart';

/// Owns the light/dark choice and keeps [ArcTheme] in step with it.
///
/// Arc's design tokens are read through statics (`AppColors.ink`, …) rather
/// than off a `BuildContext`, so a theme switch is two steps: point [ArcTheme]
/// at the new palette, then rebuild the widget tree. `ArcAppRoot` listens here
/// and does the second half.
class ThemeController extends ChangeNotifier {
  ThemeController(this._db);

  static const _key = 'theme_mode';

  final AppDatabase _db;
  bool _dark = false;

  bool get isDark => _dark;

  /// Restores the persisted choice. Call before `runApp` so the first frame
  /// is already in the right theme — no light-mode flash on a dark install.
  Future<void> load() async {
    _dark = await _db.getSetting(_key) == 'dark';
    ArcTheme.apply(dark: _dark);
  }

  Future<void> setDark(bool dark) async {
    if (dark == _dark) return;
    _dark = dark;
    ArcTheme.apply(dark: dark);
    notifyListeners();
    await _db.setSetting(_key, dark ? 'dark' : 'light');
  }

  Future<void> toggle() => setDark(!_dark);
}
