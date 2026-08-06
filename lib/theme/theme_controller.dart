import 'dart:async';

import 'package:flutter/material.dart';

import '../data/db/app_database.dart';
import 'accent.dart';
import 'app_theme.dart';

/// Owns the light/dark choice and the per-theme accent hue, and keeps
/// [ArcTheme] in step with both.
///
/// Arc's design tokens are read through statics (`AppColors.ink`, …) rather
/// than off a `BuildContext`, so a theme change is two steps: point [ArcTheme]
/// at the new palette, then rebuild the widget tree. `ArcAppRoot` listens here
/// and does the second half.
class ThemeController extends ChangeNotifier {
  ThemeController(this._db);

  static const _keyMode = 'theme_mode';
  static const _keyLightHue = 'accent_hue_light';
  static const _keyDarkHue = 'accent_hue_dark';

  /// A drag emits a new hue every frame. The palette and the UI follow
  /// immediately; the disk write trails behind so a single slider sweep costs
  /// one row update instead of three hundred.
  static const _persistDelay = Duration(milliseconds: 400);

  final AppDatabase _db;
  bool _dark = false;
  int _lightHue = AccentRamp.defaultLightHue;
  int _darkHue = AccentRamp.defaultDarkHue;
  Timer? _persist;

  bool get isDark => _dark;

  /// The accent hue of the *active* theme.
  int get accentHue => _dark ? _darkHue : _lightHue;

  /// Whether the active theme still uses the accent Arc ships with. Drives
  /// whether the sheet offers a reset.
  bool get isAccentDefault => accentHue == AccentRamp.defaultHue(dark: _dark);

  /// Restores the persisted choices. Call before `runApp` so the first frame is
  /// already correct — no light-mode flash on a dark install, and no flash of
  /// volt green on an install that picked something else.
  Future<void> load() async {
    _dark = await _db.getSetting(_keyMode) == 'dark';
    _lightHue = await _readHue(_keyLightHue, AccentRamp.defaultLightHue);
    _darkHue = await _readHue(_keyDarkHue, AccentRamp.defaultDarkHue);
    ArcTheme.apply(dark: _dark, lightHue: _lightHue, darkHue: _darkHue);
  }

  Future<int> _readHue(String key, int fallback) async {
    final raw = await _db.getSetting(key);
    final parsed = raw == null ? null : int.tryParse(raw);
    // Guard the range: a corrupt or hand-edited row shouldn't be able to push
    // the app into an underived palette.
    if (parsed == null || parsed < 0 || parsed > 359) return fallback;
    return parsed;
  }

  Future<void> setDark(bool dark) async {
    if (dark == _dark) return;
    _dark = dark;
    ArcTheme.apply(dark: dark);
    notifyListeners();
    await _db.setSetting(_keyMode, dark ? 'dark' : 'light');
  }

  Future<void> toggle() => setDark(!_dark);

  /// Repoints the active theme's accent. Safe to call at frame rate.
  void setAccentHue(int hue) {
    final h = hue % 360;
    if (h == accentHue) return;
    if (_dark) {
      _darkHue = h;
    } else {
      _lightHue = h;
    }
    ArcTheme.apply(dark: _dark, lightHue: _lightHue, darkHue: _darkHue);
    notifyListeners();
    _schedulePersist();
  }

  /// Returns the active theme to Arc's shipped accent.
  void resetAccent() => setAccentHue(AccentRamp.defaultHue(dark: _dark));

  void _schedulePersist() {
    _persist?.cancel();
    _persist = Timer(_persistDelay, _flush);
  }

  Future<void> _flush() async {
    _persist = null;
    await _db.setSetting(_keyLightHue, '$_lightHue');
    await _db.setSetting(_keyDarkHue, '$_darkHue');
  }

  @override
  void dispose() {
    // Don't drop a hue the user picked in the last 400ms.
    if (_persist != null) {
      _persist!.cancel();
      unawaited(_flush());
    }
    super.dispose();
  }
}
