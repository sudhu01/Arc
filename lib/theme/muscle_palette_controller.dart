import 'dart:async';

import 'package:flutter/material.dart';

import '../data/db/app_database.dart';
import '../data/muscle.dart';
import 'muscle_palette.dart';

/// Owns the user's per-group hues and keeps [MusclePalette] in step.
///
/// Shaped after `ThemeController`, and for the same reasons: the values are read
/// off statics so a change is "repoint the holder, then rebuild the tree", and a
/// slider drag emits a new hue every frame so the disk write trails behind.
///
/// Only *overrides* are stored. A new install has no row at all and therefore
/// gets [MuscleRamp.defaultHues] with nothing to migrate; a user who has
/// recoloured two groups stores two pairs, so a later change to the shipped
/// defaults reaches every group they never touched.
class MusclePaletteController extends ChangeNotifier {
  MusclePaletteController(this._db);

  static const _key = 'muscle_hues';

  /// Same 400ms as the accent slider: one sweep costs one row update rather
  /// than three hundred.
  static const _persistDelay = Duration(milliseconds: 400);

  final AppDatabase _db;
  final _overrides = <Muscle, int>{};
  Timer? _persist;

  /// Restores the saved hues. Call before `runApp`, so the first frame is
  /// already painted in the user's colours rather than flashing the defaults.
  Future<void> load() async {
    _overrides
      ..clear()
      ..addAll(_decode(await _db.getSetting(_key)));
    _push();
  }

  int hueOf(Muscle m) => _overrides[m] ?? MuscleRamp.defaultHue(m);

  Color colorOf(Muscle m) => MuscleRamp.color(hueOf(m));

  bool isDefault(Muscle m) => hueOf(m) == MuscleRamp.defaultHue(m);

  /// Whether every group is still on the colour Arc ships. Drives whether the
  /// picker offers to reset everything.
  bool get isAllDefault => Muscle.values.every(isDefault);

  /// The group whose colour sits closest to [hue] on the circle, ignoring
  /// [except] — the group being edited, which is always zero degrees from
  /// itself. Null when there are no other groups, which cannot happen with
  /// thirteen but keeps the caller honest.
  ///
  /// This is what lets the picker answer the question the user actually walked
  /// in with: *is this one going to look like another one?*
  ({Muscle muscle, int distance})? nearest(int hue, {required Muscle except}) {
    ({Muscle muscle, int distance})? best;
    for (final m in Muscle.values) {
      if (m == except) continue;
      final d = MuscleRamp.distance(hue, hueOf(m));
      if (best == null || d < best.distance) best = (muscle: m, distance: d);
    }
    return best;
  }

  /// Repoints one group. Safe to call at frame rate.
  void setHue(Muscle m, int hue) {
    final h = hue % 360;
    if (h == hueOf(m)) return;
    if (h == MuscleRamp.defaultHue(m)) {
      _overrides.remove(m);
    } else {
      _overrides[m] = h;
    }
    _push();
    notifyListeners();
    _schedulePersist();
  }

  void reset(Muscle m) => setHue(m, MuscleRamp.defaultHue(m));

  void resetAll() {
    if (_overrides.isEmpty) return;
    _overrides.clear();
    _push();
    notifyListeners();
    _schedulePersist();
  }

  void _push() => MusclePalette.apply({
        for (final m in Muscle.values) m: hueOf(m),
      });

  void _schedulePersist() {
    _persist?.cancel();
    _persist = Timer(_persistDelay, _flush);
  }

  Future<void> _flush() async {
    _persist = null;
    await _db.setSetting(_key, _encode());
  }

  /// `chest:28,lats:255` — group ids, not indices, so reordering the enum can
  /// never silently repaint somebody's library.
  String _encode() =>
      _overrides.entries.map((e) => '${e.key.id}:${e.value}').join(',');

  static Map<Muscle, int> _decode(String? raw) {
    final out = <Muscle, int>{};
    if (raw == null || raw.isEmpty) return out;
    for (final part in raw.split(',')) {
      final i = part.indexOf(':');
      if (i <= 0) continue;
      final m = Muscle.fromId(part.substring(0, i).trim());
      final h = int.tryParse(part.substring(i + 1).trim());
      // Drop anything unrecognised or out of range rather than fail the load:
      // a row written by a future build, or one edited by hand, costs the user
      // that one group's colour and not their whole palette.
      if (m == null || h == null || h < 0 || h > 359) continue;
      out[m] = h;
    }
    return out;
  }

  @override
  void dispose() {
    // Don't drop a colour the user picked in the last 400ms.
    if (_persist != null) {
      _persist!.cancel();
      unawaited(_flush());
    }
    super.dispose();
  }
}
