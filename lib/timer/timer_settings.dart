import '../data/db/app_database.dart';

/// How the rest timer behaves, as the user has set it.
///
/// Read once at launch and written a field at a time as switches move. Every
/// value has a defensible default, because a corrupt or hand-edited settings
/// row must never be able to leave the timer in a state with no sound, no
/// buzz, and no duration.
class TimerSettings {
  const TimerSettings({
    this.duration = defaultDuration,
    this.autoStart = true,
    this.silent = false,
    this.soundPath,
    this.soundName,
    this.floating = false,
  });

  /// Ninety seconds is what most programs prescribe; two minutes is what people
  /// actually take between working sets, and Arc defaults to what happens.
  static const defaultDuration = Duration(minutes: 2);

  /// Under fifteen seconds the alarm lands before the phone is back in a
  /// pocket; over twenty minutes it is not rest, it is a different session.
  static const minDuration = Duration(seconds: 15);
  static const maxDuration = Duration(minutes: 20);

  /// What ± moves by, and the grid every preset and drag snaps to.
  static const step = Duration(seconds: 15);

  static const presets = <Duration>[
    Duration(seconds: 60),
    Duration(seconds: 90),
    defaultDuration,
    Duration(minutes: 3),
    Duration(minutes: 5),
  ];

  final Duration duration;

  /// Start the rest the moment a set is logged. On by default — the whole
  /// point is that the gym floor never has to ask for it.
  final bool autoStart;

  /// Buzz, don't sound. The alarm still happens; it simply stops being audible.
  final bool silent;

  /// Absolute path of the user's chosen alarm inside Arc's storage, or null for
  /// Arc's own tone. A copy, not a reference: the document the user picked can
  /// be deleted or unshared the moment the picker closes.
  final String? soundPath;

  /// What to call that file on screen. Kept beside the path because the path is
  /// a content-provider name by then and reads like nothing.
  final String? soundName;

  /// Whether the countdown should float over other apps. Off by default: it
  /// needs a permission the user grants by hand, and asking unprompted is how
  /// an app gets denied forever.
  final bool floating;

  bool get usesCustomSound => soundPath != null;

  String get soundLabel => soundName ?? 'Arc default';

  TimerSettings copyWith({
    Duration? duration,
    bool? autoStart,
    bool? silent,
    String? soundPath,
    String? soundName,
    bool? floating,
    bool clearSound = false,
  }) =>
      TimerSettings(
        duration: duration ?? this.duration,
        autoStart: autoStart ?? this.autoStart,
        silent: silent ?? this.silent,
        soundPath: clearSound ? null : (soundPath ?? this.soundPath),
        soundName: clearSound ? null : (soundName ?? this.soundName),
        floating: floating ?? this.floating,
      );

  // ── persistence ───────────────────────────────────────────────────
  // Same key-value settings table the theme and accent hue live in, so the
  // timer needs no schema of its own and no migration.

  static const keyDuration = 'timer_duration_ms';
  static const keyAutoStart = 'timer_auto_start';
  static const keySilent = 'timer_silent';
  static const keySoundPath = 'timer_sound_path';
  static const keySoundName = 'timer_sound_name';
  static const keyFloating = 'timer_float';

  /// Live run state, so a relaunch mid-rest resumes the count instead of
  /// starting a fresh one. Deadline rather than remaining: a stored countdown
  /// would be a lie the moment the process stopped ticking it.
  static const keyEndsAt = 'timer_ends_at';
  static const keyPausedLeft = 'timer_paused_left_ms';

  static Future<TimerSettings> load(AppDatabase db) async {
    Future<bool> flag(String key, bool fallback) async {
      final raw = await db.getSetting(key);
      return raw == null ? fallback : raw == '1';
    }

    final rawDuration = int.tryParse(await db.getSetting(keyDuration) ?? '');
    final path = await db.getSetting(keySoundPath);

    return TimerSettings(
      duration: rawDuration == null
          ? defaultDuration
          : clampDuration(Duration(milliseconds: rawDuration)),
      autoStart: await flag(keyAutoStart, true),
      silent: await flag(keySilent, false),
      soundPath: (path?.isEmpty ?? true) ? null : path,
      soundName: (path?.isEmpty ?? true)
          ? null
          : await db.getSetting(keySoundName) ?? 'Custom sound',
      floating: await flag(keyFloating, false),
    );
  }

  Future<void> save(AppDatabase db) async {
    await db.setSetting(keyDuration, '${duration.inMilliseconds}');
    await db.setSetting(keyAutoStart, autoStart ? '1' : '0');
    await db.setSetting(keySilent, silent ? '1' : '0');
    await db.setSetting(keySoundPath, soundPath ?? '');
    await db.setSetting(keySoundName, soundName ?? '');
    await db.setSetting(keyFloating, floating ? '1' : '0');
  }

  static Duration clampDuration(Duration d) => d < minDuration
      ? minDuration
      : d > maxDuration
          ? maxDuration
          : d;

  /// Rounds to the nearest [step], so a duration can never end up at 1:47 and
  /// leave the ± controls walking a grid that doesn't include where they are.
  static Duration snap(Duration d) {
    final steps = (d.inMilliseconds / step.inMilliseconds).round();
    return clampDuration(Duration(milliseconds: steps * step.inMilliseconds));
  }
}

/// `m:ss` — the shape a rest is read in. Never `00:01:47`: the leading zeros
/// are noise at arm's length, and the timer never runs to an hour.
String formatRest(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// The same value as a sentence, for screen readers and notification bodies —
/// "1:47" is read aloud as a date by most of them.
String spokenRest(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final m = total ~/ 60;
  final s = total % 60;
  final parts = [
    if (m > 0) '$m minute${m == 1 ? '' : 's'}',
    if (s > 0 || m == 0) '$s second${s == 1 ? '' : 's'}',
  ];
  return parts.join(' ');
}
