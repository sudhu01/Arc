// The rest timer where Arc cannot reach it.
//
// Two notifications, doing two different jobs:
//
//   the countdown  an ongoing, silent entry whose number Android renders and
//                  decrements itself. Arc posts it once and never wakes to
//                  update it — a per-second update loop is what makes other
//                  timer apps eat a battery.
//   the alarm      an exact alarm scheduled at the deadline. It fires from the
//                  OS, which means it still fires after Android has killed
//                  Arc's process to reclaim memory — the case a purely
//                  in-process timer silently loses.
//
// Only one of these and the in-process alarm is ever armed; TimerController
// swaps between them on lifecycle, so a rest ends with one sound, not two.

import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'timer_alarm.dart';
import 'timer_settings.dart';
import 'timer_sound.dart';

/// What a tap on the countdown's buttons asks for.
enum TimerAction { pause, resume, reset, stop, open }

/// Payload prefix that tells Arc's single notification-response handler that a
/// response belongs to the timer rather than to a companion alert.
const String _payloadTag = 'arc.timer';

String timerPayload(TimerAction action) =>
    jsonEncode({'k': _payloadTag, 'a': action.name});

/// Decodes a notification response into a timer action, or null when the
/// response was about something else.
TimerAction? decodeTimerAction(NotificationResponse response) {
  final raw = response.payload;
  if (raw == null || !raw.contains(_payloadTag)) return null;
  final id = response.actionId;
  if (id != null && id.isNotEmpty) {
    for (final a in TimerAction.values) {
      if (a.name == id) return a;
    }
  }
  try {
    final map = jsonDecode(raw);
    if (map is! Map || map['k'] != _payloadTag) return null;
    for (final a in TimerAction.values) {
      if (a.name == map['a']) return a;
    }
  } catch (_) {
    return null;
  }
  return null;
}

/// Posts and schedules the timer's two notifications.
///
/// Holds no timer state of its own — every method takes what it needs — so the
/// background isolate that handles a notification action can build one and use
/// it without any of the app's object graph existing.
class TimerNotifier {
  TimerNotifier({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  static const _groupId = 'arc.timer';
  static const _groupName = 'Rest timer';

  static const _countdownChannelId = 'arc.timer.countdown';
  static const _alarmChannelPrefix = 'arc.timer.alarm';
  static const _silentChannelId = '$_alarmChannelPrefix.silent';

  /// Ids Arc owns. Deliberately far from the companion alerts' hashed ids,
  /// which are derived from event ids and land anywhere in the 31-bit range.
  static const countdownId = 424001;
  static const alarmId = 424002;

  /// The same status-bar mark every Arc notification carries.
  static const _smallIcon = 'ic_stat_arc';

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  AndroidFlutterLocalNotificationsPlugin? get _android => supported
      ? _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      : null;

  /// Creates the channel group and the countdown channel, and rebuilds the
  /// alarm channel to match [settings].
  ///
  /// Idempotent, and called again on every sound or silent-mode change,
  /// because an Android channel's sound and vibration are fixed the moment it
  /// is created. Changing them means a new channel id — which is why the alarm
  /// channel's id carries a fingerprint of the sound it was built for.
  Future<void> sync(TimerSettings settings, {Color? accent}) async {
    final android = _android;
    if (android == null) return;
    try {
      await android.createNotificationChannelGroup(
        const AndroidNotificationChannelGroup(_groupId, _groupName,
            description: 'The countdown between your sets, and the alarm '
                'when it runs out.'),
      );

      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          _countdownChannelId,
          'Running timer',
          description: 'The live countdown while a rest is running.',
          groupId: _groupId,
          // Low, and silent: this entry is a readout, not an interruption. It
          // makes noise exactly once, when the rest is over, and that is a
          // different channel.
          importance: Importance.low,
          playSound: false,
          enableVibration: false,
        ),
      );

      await android.createNotificationChannel(_alarmChannel(settings));
      await _pruneStaleAlarmChannels(android, keep: _alarmChannelId(settings));
      // The grant a content:// sound depends on does not survive a reboot.
      await TimerSound.refreshGrant(settings.soundPath);
    } catch (e) {
      debugPrint('Arc timer: channel sync failed ($e)');
    }
  }

  /// Shows the live countdown. [endsAt] is epoch milliseconds.
  ///
  /// `usesChronometer` hands the ticking to Android: the entry counts itself
  /// down from `when`, on the lock screen too, with no further calls from Arc.
  Future<void> showCountdown({
    required int endsAt,
    required TimerSettings settings,
    Color? accent,
  }) async {
    if (!supported) return;
    final left = Duration(milliseconds: endsAt - _now);
    try {
      await _plugin.show(
        id: countdownId,
        title: 'Rest',
        body: 'Ends in ${spokenRest(left)}',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _countdownChannelId,
            'Running timer',
            channelDescription: 'The live countdown while a rest is running.',
            icon: _smallIcon,
            color: accent,
            importance: Importance.low,
            priority: Priority.low,
            // Android draws the countdown from `when` when both of these are
            // set — the body above is what a screen reader and a lock screen
            // that suppresses chronometers fall back to.
            usesChronometer: true,
            chronometerCountDown: true,
            when: endsAt,
            ongoing: true,
            autoCancel: false,
            onlyAlertOnce: true,
            silent: true,
            category: AndroidNotificationCategory.stopwatch,
            visibility: NotificationVisibility.public,
            actions: const [
              AndroidNotificationAction('pause', 'Pause',
                  cancelNotification: false),
              AndroidNotificationAction('reset', 'Reset',
                  cancelNotification: false),
            ],
          ),
        ),
        payload: timerPayload(TimerAction.open),
      );
    } catch (e) {
      debugPrint('Arc timer: countdown notification failed ($e)');
    }
  }

  /// Shows the paused state, so a rest paused from the shade does not simply
  /// vanish from it.
  Future<void> showPaused({
    required Duration left,
    required TimerSettings settings,
    Color? accent,
  }) async {
    if (!supported) return;
    try {
      await _plugin.show(
        id: countdownId,
        title: 'Rest paused',
        body: '${formatRest(left)} left',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _countdownChannelId,
            'Running timer',
            channelDescription: 'The live countdown while a rest is running.',
            icon: _smallIcon,
            color: accent,
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            autoCancel: false,
            onlyAlertOnce: true,
            silent: true,
            showWhen: false,
            category: AndroidNotificationCategory.stopwatch,
            visibility: NotificationVisibility.public,
            actions: const [
              AndroidNotificationAction('resume', 'Resume',
                  cancelNotification: false),
              AndroidNotificationAction('reset', 'Reset',
                  cancelNotification: false),
            ],
          ),
        ),
        payload: timerPayload(TimerAction.open),
      );
    } catch (e) {
      debugPrint('Arc timer: paused notification failed ($e)');
    }
  }

  /// Arms the alarm to fire at [endsAt], from the OS rather than from Arc.
  ///
  /// Returns whether it will land on the second. Exact alarms are a grant the
  /// user can revoke on Android 12+, and a timer that quietly becomes
  /// approximate is worse than one that says so — the settings screen reads
  /// this back.
  Future<bool> scheduleAlarm({
    required int endsAt,
    required TimerSettings settings,
    Color? accent,
  }) async {
    if (!supported) return false;
    final exact = await canBeExact();
    try {
      final channel = _alarmChannel(settings);
      await _plugin.zonedSchedule(
        id: alarmId,
        title: 'Rest over',
        body: 'Back to it.',
        // UTC deliberately: the plugin sends the zone by name and lets Android
        // resolve it, and pinning to UTC means a rest started either side of a
        // daylight-saving change still ends exactly when it should.
        scheduledDate: tz.TZDateTime.fromMillisecondsSinceEpoch(
            tz.UTC, endsAt < _now + 500 ? _now + 500 : endsAt),
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channel.id,
            channel.name,
            channelDescription: channel.description,
            icon: _smallIcon,
            color: accent,
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.alarm,
            visibility: NotificationVisibility.public,
            playSound: channel.playSound,
            sound: channel.sound,
            enableVibration: true,
            vibrationPattern: _vibrationPattern,
            audioAttributesUsage: AudioAttributesUsage.alarm,
            ticker: 'Rest over',
            // Clears itself after a minute. A finished rest is not a message;
            // finding it in the shade an hour later would say nothing true.
            timeoutAfter: const Duration(minutes: 1).inMilliseconds,
          ),
        ),
        payload: timerPayload(TimerAction.stop),
      );
      return exact;
    } catch (e) {
      debugPrint('Arc timer: could not schedule the alarm ($e)');
      return false;
    }
  }

  /// Whether the OS will currently let Arc land an alarm on the second.
  Future<bool> canBeExact() async {
    try {
      return await _android?.canScheduleExactNotifications() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Asks for the exact-alarm grant. Sends the user to a system screen on
  /// Android 12+, so it is only ever called from a control they tapped.
  Future<bool> requestExact() async {
    try {
      return await _android?.requestExactAlarmsPermission() ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> get notificationsEnabled async =>
      await _android?.areNotificationsEnabled() ?? false;

  Future<bool> requestPermission() async =>
      await _android?.requestNotificationsPermission() ?? false;

  /// Takes down the scheduled alarm without touching the countdown — what
  /// happens every time Arc comes back to the foreground and takes the alarm
  /// back into its own hands.
  Future<void> cancelAlarm() async {
    if (!supported) return;
    try {
      await _plugin.cancel(id: alarmId);
    } catch (e) {
      debugPrint('Arc timer: could not cancel the alarm ($e)');
    }
  }

  Future<void> cancelCountdown() async {
    if (!supported) return;
    try {
      await _plugin.cancel(id: countdownId);
    } catch (e) {
      debugPrint('Arc timer: could not cancel the countdown ($e)');
    }
  }

  Future<void> cancelAll() async {
    await cancelAlarm();
    await cancelCountdown();
  }

  // ── channels ──────────────────────────────────────────────────────

  /// A stable id per sound configuration. Silent gets its own; a custom sound
  /// gets one derived from its stored path, which already carries a
  /// fingerprint of the file (see [TimerSound.store]).
  static String _alarmChannelId(TimerSettings settings) {
    if (settings.silent) return _silentChannelId;
    final path = settings.soundPath;
    if (path == null) return '$_alarmChannelPrefix.default';
    return '$_alarmChannelPrefix.${path.hashCode.toUnsigned(32).toRadixString(16)}';
  }

  static AndroidNotificationChannel _alarmChannel(TimerSettings settings) =>
      AndroidNotificationChannel(
        _alarmChannelId(settings),
        settings.silent ? 'Rest over (silent)' : 'Rest over',
        description: 'The alarm when a rest finishes.',
        groupId: _groupId,
        importance: Importance.max,
        playSound: !settings.silent,
        sound: settings.silent
            ? null
            : settings.soundPath == null
                ? const RawResourceAndroidNotificationSound(
                    kDefaultSoundResource)
                : UriAndroidNotificationSound(
                    TimerSound.uriFor(settings.soundPath!)),
        enableVibration: true,
        vibrationPattern: _vibrationPattern,
        // The alarm stream, matching what TimerAlarm plays in-process, so the
        // rest ends at the same volume whether Arc or Android made the noise.
        audioAttributesUsage: AudioAttributesUsage.alarm,
      );

  static Int64List get _vibrationPattern =>
      Int64List.fromList(kAlarmVibration);

  /// Deletes alarm channels left behind by previous sounds.
  ///
  /// Without this, every sound the user ever picked stays listed in Android's
  /// notification settings forever — a growing column of identical "Rest over"
  /// rows, only one of which does anything.
  Future<void> _pruneStaleAlarmChannels(
      AndroidFlutterLocalNotificationsPlugin android,
      {required String keep}) async {
    try {
      final channels = await android.getNotificationChannels() ?? const [];
      for (final channel in channels) {
        if (channel.id.startsWith(_alarmChannelPrefix) && channel.id != keep) {
          await android.deleteNotificationChannel(channelId: channel.id);
        }
      }
    } catch (e) {
      // Listing channels is unsupported below Android 8 and throws on some OEM
      // builds. The live channel is already correct; this is tidying.
      debugPrint('Arc timer: channel prune skipped ($e)');
    }
  }

  static int get _now => DateTime.now().millisecondsSinceEpoch;
}
