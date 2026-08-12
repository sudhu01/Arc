import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/db/app_database.dart';
import '../data/notify/arc_notifier.dart';
import 'timer_alarm.dart';
import 'timer_notification.dart';
import 'timer_overlay.dart';
import 'timer_settings.dart';
import 'timer_sound.dart';

/// What the rest timer is doing.
enum TimerPhase {
  /// Nothing running. The bar is not on screen.
  idle,

  /// Counting down toward [TimerController.endsAt].
  running,

  /// Held, with [TimerController.remaining] frozen.
  paused,

  /// Ran out. The alarm has fired and is waiting to be acknowledged, either by
  /// a tap or by the next set.
  finished,
}

/// The rest timer.
///
/// One instrument, three renditions: the bar inside Arc, the countdown in the
/// shade, and the bubble over other apps. All three read this object, so they
/// can never disagree about what time it is.
///
/// The state is a **deadline**, never a remaining count. A stored countdown
/// would be a lie the moment the process stopped ticking it — and this process
/// stops ticking every time the phone is pocketed. Everything the user sees is
/// derived from `endsAt` and the wall clock, which is why minimising, locking
/// the screen, Doze and being killed outright all come back correct with no
/// special handling for any of them.
class TimerController extends ChangeNotifier with WidgetsBindingObserver {
  TimerController(this._db, {TimerNotifier? notifier, TimerAlarm? alarm})
      : _notifier = notifier ?? TimerNotifier(),
        _alarm = alarm ?? TimerAlarm();

  final AppDatabase _db;
  final TimerNotifier _notifier;
  final TimerAlarm _alarm;

  /// Fine enough that the seconds never look stuck, coarse enough to be
  /// invisible on a battery. Only ever alive while something is counting.
  static const _tick = Duration(milliseconds: 200);

  /// How long a finished rest keeps saying so before clearing itself. Matches
  /// the alarm notification's own timeout, so the bar and the shade stop
  /// talking about the same rest at the same moment.
  static const _finishedLinger = Duration(seconds: 45);

  TimerSettings _settings = const TimerSettings();
  TimerPhase _phase = TimerPhase.idle;
  int? _endsAt;
  Duration _pausedLeft = Duration.zero;
  int _finishedAt = 0;
  Timer? _ticker;
  bool _foreground = true;

  /// Whether the OS will currently land the background alarm on the second.
  /// Read back by the settings screen rather than assumed.
  bool _exactAlarms = true;

  /// Whether Android will show anything Arc posts.
  ///
  /// The alarm for a rest that ends with Arc off screen *is* a notification —
  /// so with this false the rest simply ends in silence, while the in-app alarm
  /// keeps working perfectly and hides the fault. Read back rather than
  /// assumed, and said out loud on the settings screen.
  bool _notifications = true;

  TimerSettings get settings => _settings;
  TimerPhase get phase => _phase;
  bool get isIdle => _phase == TimerPhase.idle;
  bool get isRunning => _phase == TimerPhase.running;
  bool get isPaused => _phase == TimerPhase.paused;
  bool get isFinished => _phase == TimerPhase.finished;

  /// Whether there is anything to show. Drives the bar's presence.
  bool get isActive => _phase != TimerPhase.idle;

  bool get exactAlarms => _exactAlarms;

  /// Whether the background alarm can be heard at all. See [_notifications].
  bool get notificationsAllowed => _notifications;

  /// Epoch milliseconds the current run ends at, or null when nothing runs.
  int? get endsAt => _endsAt;

  /// Time left, floored at zero. The single value every rendition reads.
  Duration get remaining {
    switch (_phase) {
      case TimerPhase.running:
        final ms = (_endsAt ?? 0) - _now;
        return Duration(milliseconds: ms < 0 ? 0 : ms);
      case TimerPhase.paused:
        return _pausedLeft;
      case TimerPhase.finished:
        return Duration.zero;
      case TimerPhase.idle:
        return _settings.duration;
    }
  }

  /// How much of the rest is gone, 0 to 1. What the draining rail reads.
  double get progress {
    final total = _settings.duration.inMilliseconds;
    if (total <= 0) return 0;
    if (_phase == TimerPhase.finished) return 1;
    if (_phase == TimerPhase.idle) return 0;
    final gone = 1 - remaining.inMilliseconds / total;
    return gone.clamp(0.0, 1.0);
  }

  /// The last ten seconds, where the count earns the accent. Arc marks the
  /// moment the rest is nearly over; it does not celebrate the countdown.
  bool get isFinalStretch =>
      _phase == TimerPhase.running && remaining.inSeconds < 10;

  // ── lifecycle ─────────────────────────────────────────────────────

  /// Restores settings and any rest still in flight. Call before `runApp`, so
  /// the first frame already shows the right number instead of appearing a
  /// beat later with a bar that was there all along.
  Future<void> load() async {
    _settings = await TimerSettings.load(_db);

    // A stored sound that no longer exists — app data partially cleared, or a
    // restore that skipped the file — would otherwise leave the alarm silently
    // falling back forever with the settings screen still naming the file.
    if (_settings.usesCustomSound &&
        !await TimerSound.exists(_settings.soundPath)) {
      _settings = _settings.copyWith(clearSound: true);
      await _settings.save(_db);
    }

    await _rehydrate();
    WidgetsBinding.instance.addObserver(this);
    _bubble = TimerOverlay.actions.listen(_onBubbleAction);
    unawaited(_syncChannels());
    unawaited(_refreshExactAlarms());
    unawaited(_refreshNotifications());
  }

  /// A button tapped on the floating bubble.
  ///
  /// The bubble redraws itself the instant it is tapped, so it is never waiting
  /// on this; what arrives here is the app catching up. If Arc's process was
  /// gone when the tap happened, nothing arrives at all and [_reconcile]
  /// settles it at the next resume instead.
  void _onBubbleAction(dynamic event) {
    switch (event) {
      case 'pause':
        unawaited(pause());
      case 'resume':
        unawaited(resume());
      case 'reset':
        unawaited(reset());
      case 'open':
        openRequests.value = openRequests.value + 1;
    }
  }

  /// Bumped when something outside the widget tree asks for the timer screen —
  /// a tap on the bubble, or on the countdown in the shade. The shell watches
  /// it and opens the route; the controller has no navigator of its own.
  final ValueNotifier<int> openRequests = ValueNotifier(0);

  StreamSubscription<dynamic>? _bubble;

  /// Picks the run back up from disk.
  ///
  /// The three cases that matter: still running (resume the tick), paused
  /// (restore the frozen remainder), and ran out while Arc was dead — in which
  /// case the OS already alarmed, so this shows the finished state rather than
  /// alarming a second time at a moment that has passed.
  Future<void> _rehydrate() async {
    final endsAt = int.tryParse(await _db.getSetting(TimerSettings.keyEndsAt) ?? '');
    final pausedLeft =
        int.tryParse(await _db.getSetting(TimerSettings.keyPausedLeft) ?? '');

    if (pausedLeft != null && pausedLeft > 0) {
      _phase = TimerPhase.paused;
      _pausedLeft = Duration(milliseconds: pausedLeft);
      notifyListeners();
      return;
    }
    if (endsAt == null) return;

    final left = endsAt - _now;
    if (left > 0) {
      _phase = TimerPhase.running;
      _endsAt = endsAt;
      _startTicking();
    } else if (-left < _finishedLinger.inMilliseconds) {
      _phase = TimerPhase.finished;
      _finishedAt = endsAt;
      _startTicking();
    } else {
      await _persistRun(endsAt: null, pausedLeft: null);
    }
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      unawaited(_takeBackAlarm());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _foreground = false;
      unawaited(_handOverAlarm());
    }
  }

  /// Arc is leaving the screen: hand the alarm to Android.
  ///
  /// The in-process ticker stops here. That is not an optimisation — leaving it
  /// running is what makes a timer alarm twice, once from the OS and once from
  /// a Dart timer that happened to survive.
  Future<void> _handOverAlarm() async {
    _stopTicking();
    if (_phase == TimerPhase.running && _endsAt != null) {
      final accent = await _accent();
      await _notifier.showCountdown(
          endsAt: _endsAt!, settings: _settings, accent: accent);
      _exactAlarms = await _notifier.scheduleAlarm(
          endsAt: _endsAt!, settings: _settings, accent: accent);
      await TimerOverlay.show(
        endsAt: _endsAt!,
        total: _settings.duration,
        paused: false,
        enabled: _settings.floating,
      );
    } else if (_phase == TimerPhase.paused) {
      await _notifier.cancelAlarm();
      await _notifier.showPaused(
          left: _pausedLeft, settings: _settings, accent: await _accent());
      await TimerOverlay.show(
        endsAt: _now + _pausedLeft.inMilliseconds,
        total: _settings.duration,
        paused: true,
        enabled: _settings.floating,
      );
    } else {
      await _notifier.cancelAll();
      await TimerOverlay.hide();
    }
  }

  /// Arc is back: take the alarm off Android and put the shade entry away.
  ///
  /// Reconciles first — the deadline may have passed, or an action tapped in
  /// the shade may have moved it, both of which happened in a different
  /// isolate while this one was asleep.
  Future<void> _takeBackAlarm() async {
    await _notifier.cancelAlarm();
    await TimerOverlay.hide();
    await _reconcile();
    await _notifier.cancelCountdown();
    // Both are grants the user can change in system settings while Arc is
    // away, which is exactly where the notices on the settings screen send
    // them — so both are re-read on the way back rather than trusted.
    unawaited(_refreshExactAlarms());
    unawaited(_refreshNotifications());
  }

  /// Re-reads the run state written by the shade's buttons, then catches up on
  /// whatever elapsed while this isolate was not ticking.
  Future<void> _reconcile() async {
    final endsAt = int.tryParse(await _db.getSetting(TimerSettings.keyEndsAt) ?? '');
    final pausedLeft =
        int.tryParse(await _db.getSetting(TimerSettings.keyPausedLeft) ?? '');

    if (pausedLeft != null && pausedLeft > 0) {
      _phase = TimerPhase.paused;
      _pausedLeft = Duration(milliseconds: pausedLeft);
      _endsAt = null;
      _stopTicking();
      notifyListeners();
      return;
    }

    if (endsAt == null) {
      if (_phase != TimerPhase.finished) _setIdle();
      return;
    }

    _endsAt = endsAt;
    if (endsAt > _now) {
      _phase = TimerPhase.running;
      _startTicking();
    } else {
      // The OS alarmed for this one while Arc was away. Show that it happened;
      // do not make the noise again for a moment that has already passed.
      _phase = TimerPhase.finished;
      _finishedAt = endsAt;
      _startTicking();
    }
    notifyListeners();
  }

  // ── transport ─────────────────────────────────────────────────────

  /// Starts a rest of [over], or of the configured duration.
  Future<void> start({Duration? over, bool haptic = true}) async {
    final length = TimerSettings.clampDuration(over ?? _settings.duration);
    await _alarm.silence();
    _endsAt = _now + length.inMilliseconds;
    _pausedLeft = Duration.zero;
    _phase = TimerPhase.running;
    _startTicking();
    notifyListeners();
    if (haptic) unawaited(TimerAlarm.buzz(kStartVibration));
    // Fire and forget, like the haptic: nothing about the alarm being audible
    // later may make a rest start now wait on a system dialog.
    unawaited(_askForNotificationsOnce());
    await _persistRun(endsAt: _endsAt, pausedLeft: null);
    if (!_foreground) await _handOverAlarm();
  }

  /// The rest that starts itself when a set goes into the log.
  ///
  /// Silent about it when the user has turned auto-start off, and fire and
  /// forget by design: nothing about the timer may make logging a set wait.
  void autoStart() {
    if (!_settings.autoStart) return;
    unawaited(start(haptic: false));
  }

  Future<void> pause() async {
    if (_phase != TimerPhase.running) return;
    _pausedLeft = remaining;
    _endsAt = null;
    _phase = TimerPhase.paused;
    _stopTicking();
    notifyListeners();
    await _persistRun(endsAt: null, pausedLeft: _pausedLeft.inMilliseconds);
  }

  Future<void> resume() async {
    if (_phase != TimerPhase.paused) return;
    _endsAt = _now + _pausedLeft.inMilliseconds;
    _pausedLeft = Duration.zero;
    _phase = TimerPhase.running;
    _startTicking();
    notifyListeners();
    await _persistRun(endsAt: _endsAt, pausedLeft: null);
  }

  /// The one control the bar and the screen both put under a thumb: whatever
  /// the timer is doing, this does the opposite.
  Future<void> toggle() async {
    switch (_phase) {
      case TimerPhase.running:
        await pause();
      case TimerPhase.paused:
        await resume();
      case TimerPhase.idle:
      case TimerPhase.finished:
        await start();
    }
  }

  /// Back to nothing running. Also how a finished rest is acknowledged.
  Future<void> reset() async {
    await _alarm.silence();
    _setIdle();
    await _persistRun(endsAt: null, pausedLeft: null);
    await _notifier.cancelAll();
    await TimerOverlay.hide();
  }

  /// Moves the deadline by [by] without restarting — the ± during a running
  /// rest, for the set that turned out heavier than planned.
  Future<void> nudge(Duration by) async {
    switch (_phase) {
      case TimerPhase.running:
        final left = remaining + by;
        if (left <= Duration.zero) return reset();
        _endsAt = _now + left.inMilliseconds;
        notifyListeners();
        await _persistRun(endsAt: _endsAt, pausedLeft: null);
      case TimerPhase.paused:
        final left = _pausedLeft + by;
        if (left <= Duration.zero) return reset();
        _pausedLeft = left;
        notifyListeners();
        await _persistRun(endsAt: null, pausedLeft: left.inMilliseconds);
      case TimerPhase.idle:
      case TimerPhase.finished:
        await setDuration(_settings.duration + by);
    }
  }

  // ── settings ──────────────────────────────────────────────────────

  Future<void> setDuration(Duration d) async {
    final next = TimerSettings.clampDuration(d);
    if (next == _settings.duration) return;
    _settings = _settings.copyWith(duration: next);
    notifyListeners();
    await _settings.save(_db);
  }

  Future<void> setAutoStart(bool value) async {
    if (value == _settings.autoStart) return;
    _settings = _settings.copyWith(autoStart: value);
    notifyListeners();
    await _settings.save(_db);
  }

  /// Vibrate only. Rebuilds the alarm channel, because whether a channel makes
  /// a sound is fixed when it is created.
  Future<void> setSilent(bool value) async {
    if (value == _settings.silent) return;
    _settings = _settings.copyWith(silent: value);
    notifyListeners();
    await _settings.save(_db);
    await _syncChannels();
  }

  /// Adopts a sound the user picked. [sourcePath] is the file the picker
  /// handed over; it is copied, not referenced.
  ///
  /// Returns false when the copy failed, so the caller can say so rather than
  /// leaving a settings row naming a file that is not there.
  Future<bool> setSound(String sourcePath, String displayName) async {
    final stored = await TimerSound.store(sourcePath, displayName);
    if (stored == null) return false;
    _settings =
        _settings.copyWith(soundPath: stored, soundName: displayName);
    notifyListeners();
    await _settings.save(_db);
    await _syncChannels();
    return true;
  }

  /// Back to Arc's own tone.
  Future<void> clearSound() async {
    if (!_settings.usesCustomSound) return;
    _settings = _settings.copyWith(clearSound: true);
    notifyListeners();
    await _settings.save(_db);
    await TimerSound.discard();
    await _syncChannels();
  }

  /// Turns the floating bubble on, asking for the overlay grant the first time.
  ///
  /// Returns false when the user declined, and leaves the setting off — a
  /// switch that stays on while the thing it enables cannot run is a lie.
  Future<bool> setFloating(bool value) async {
    if (!value) {
      _settings = _settings.copyWith(floating: false);
      notifyListeners();
      await _settings.save(_db);
      await TimerOverlay.hide();
      return true;
    }
    if (!await TimerOverlay.ensurePermission()) return false;
    _settings = _settings.copyWith(floating: true);
    notifyListeners();
    await _settings.save(_db);
    return true;
  }

  /// Plays the configured alarm once, for the settings screen's preview.
  /// Through the real path, because a preview that takes a shortcut is a
  /// preview that can be wrong.
  Future<void> previewSound() => _alarm.play(_settings);

  Future<void> silence() => _alarm.silence();

  /// Whether Arc is allowed to post the countdown at all, and the ask if not.
  Future<bool> ensureNotificationPermission() async {
    if (await _notifier.notificationsEnabled) {
      await _refreshNotifications();
      return true;
    }
    final granted = await _notifier.requestPermission();
    await _refreshNotifications();
    return granted;
  }

  /// Sends the user to the system's exact-alarm screen and re-reads the answer.
  Future<bool> requestExactAlarms() async {
    await _notifier.requestExact();
    await _refreshExactAlarms();
    return _exactAlarms;
  }

  // ── internals ─────────────────────────────────────────────────────

  void _startTicking() {
    _ticker ??= Timer.periodic(_tick, (_) => _onTick());
  }

  void _stopTicking() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _onTick() {
    if (_phase == TimerPhase.running && (_endsAt ?? 0) <= _now) {
      unawaited(_finish());
      return;
    }
    if (_phase == TimerPhase.finished &&
        _now - _finishedAt > _finishedLinger.inMilliseconds) {
      unawaited(reset());
      return;
    }
    notifyListeners();
  }

  /// The rest ran out with Arc on screen, so Arc makes the noise.
  Future<void> _finish() async {
    _finishedAt = _endsAt ?? _now;
    _phase = TimerPhase.finished;
    _endsAt = null;
    notifyListeners();
    await _persistRun(endsAt: null, pausedLeft: null);
    await _notifier.cancelAll();
    await TimerOverlay.hide();
    await _alarm.ring(_settings);
  }

  void _setIdle() {
    _phase = TimerPhase.idle;
    _endsAt = null;
    _pausedLeft = Duration.zero;
    _finishedAt = 0;
    _stopTicking();
    notifyListeners();
  }

  Future<void> _persistRun({int? endsAt, int? pausedLeft}) async {
    await _db.setSetting(TimerSettings.keyEndsAt, endsAt?.toString() ?? '');
    await _db.setSetting(
        TimerSettings.keyPausedLeft, pausedLeft?.toString() ?? '');
  }

  Future<void> _syncChannels() async {
    await _notifier.sync(_settings, accent: await _accent());
  }

  Future<void> _refreshExactAlarms() async {
    if (!TimerNotifier.supported) return;
    final exact = await _notifier.canBeExact();
    if (exact == _exactAlarms) return;
    _exactAlarms = exact;
    notifyListeners();
  }

  Future<void> _refreshNotifications() async {
    if (!TimerNotifier.supported) return;
    final allowed = await _notifier.notificationsEnabled;
    if (allowed == _notifications) return;
    _notifications = allowed;
    notifyListeners();
  }

  /// Asks for the notification grant the background alarm is made of, once.
  ///
  /// Asked here, at the start of a rest, rather than at launch: this is the
  /// moment the ask explains itself, the same rule the companion alerts follow
  /// (see `ArcStore._requestAlertPermission`). Until this existed the grant was
  /// only ever requested from the pairing flow, so anyone who used the timer
  /// without a companion had every notification Arc posted dropped by Android —
  /// including the one that is the alarm.
  ///
  /// Once per session and no flag of its own: Android already stops showing the
  /// dialog after two dismissals, and remembering a reflexive tap forever would
  /// turn it into permanent, unexplained silence. The settings screen carries
  /// the way back.
  Future<void> _askForNotificationsOnce() async {
    if (_askedForNotifications || !_foreground || !TimerNotifier.supported) {
      return;
    }
    _askedForNotifications = true;
    await ensureNotificationPermission();
    await _refreshNotifications();
  }

  bool _askedForNotifications = false;

  /// The accent the user actually chose, rendered for the shade rather than for
  /// Arc — the same rule the companion alerts follow.
  Future<Color?> _accent() async {
    try {
      return await notificationAccent(_db);
    } catch (_) {
      return null;
    }
  }

  /// Applies an action tapped in the shade while Arc is alive. The background
  /// isolate handles the same ids when it is not — see `timer_background.dart`.
  void handleAction(TimerAction action) {
    switch (action) {
      case TimerAction.pause:
        unawaited(pause());
      case TimerAction.resume:
        unawaited(resume());
      case TimerAction.reset:
      case TimerAction.stop:
        unawaited(reset());
      case TimerAction.open:
        openRequests.value = openRequests.value + 1;
    }
  }

  static int get _now => DateTime.now().millisecondsSinceEpoch;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_bubble?.cancel());
    openRequests.dispose();
    _stopTicking();
    unawaited(_alarm.dispose());
    super.dispose();
  }
}
