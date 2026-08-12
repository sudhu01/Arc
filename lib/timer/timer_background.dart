// Notification actions tapped while Arc is not on screen.
//
// A "Pause" button on the countdown that only works when the app happens to be
// running is a button that does nothing in the one situation it exists for. So
// the action is handled in a headless isolate, the same shape the companion
// poller already uses: open a private database connection, read the deadline,
// write the new one, redraw the shade, exit.
//
// The isolate shares nothing with the app — no TimerController, no provider
// tree. Both write the same settings rows, so whichever runs first is the truth
// and the other reconciles on its next read.

import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../data/db/app_database.dart';
import '../data/notify/arc_notifier.dart';
import 'timer_notification.dart';
import 'timer_settings.dart';

/// Entry point for a notification action tapped with Arc in the background.
///
/// Must stay top-level and keep the pragma, or tree-shaking drops it from the
/// release build and the shade's buttons go dead in exactly the build nobody
/// runs in a debugger.
@pragma('vm:entry-point')
void arcTimerBackgroundAction(NotificationResponse response) {
  final action = decodeTimerAction(response);
  if (action == null || action == TimerAction.open) return;
  applyTimerActionHeadless(action);
}

/// Applies [action] to the persisted timer state from an isolate that has
/// nothing else loaded. Also the body a test can call directly.
Future<void> applyTimerActionHeadless(TimerAction action) async {
  AppDatabase? db;
  try {
    // No plugin registry in a fresh isolate: sqflite, path_provider and the
    // notification plugin are all unavailable until these two run.
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    // Its own connection, never the app's — closing a shared one would take
    // the running app's database with it.
    db = await AppDatabase.open(singleInstance: false);
    final settings = await TimerSettings.load(db);
    final notifier = TimerNotifier();
    final accent = await notificationAccent(db);
    final now = DateTime.now().millisecondsSinceEpoch;

    final endsAt = int.tryParse(await db.getSetting(TimerSettings.keyEndsAt) ?? '');
    final pausedLeft =
        int.tryParse(await db.getSetting(TimerSettings.keyPausedLeft) ?? '');

    switch (action) {
      case TimerAction.pause:
        if (endsAt == null) return;
        final left = endsAt - now;
        if (left <= 0) return;
        await _write(db, endsAt: null, pausedLeft: left);
        await notifier.cancelAlarm();
        await notifier.showPaused(
          left: Duration(milliseconds: left),
          settings: settings,
          accent: accent,
        );

      case TimerAction.resume:
        if (pausedLeft == null || pausedLeft <= 0) return;
        final resumedEnd = now + pausedLeft;
        await _write(db, endsAt: resumedEnd, pausedLeft: null);
        await notifier.showCountdown(
            endsAt: resumedEnd, settings: settings, accent: accent);
        await notifier.scheduleAlarm(
            endsAt: resumedEnd, settings: settings, accent: accent);

      case TimerAction.reset:
      case TimerAction.stop:
        await _write(db, endsAt: null, pausedLeft: null);
        await notifier.cancelAll();

      case TimerAction.open:
        break;
    }
  } catch (e) {
    debugPrint('Arc timer: background action failed ($e)');
  } finally {
    // Safe because the connection above is this isolate's own.
    await db?.close();
  }
}

/// Writes the pair of run-state rows together. They are mutually exclusive —
/// a timer is running or paused, never both — so they are always set as a pair
/// rather than left to drift out of agreement.
Future<void> _write(AppDatabase db, {int? endsAt, int? pausedLeft}) async {
  await db.setSetting(TimerSettings.keyEndsAt, endsAt?.toString() ?? '');
  await db.setSetting(
      TimerSettings.keyPausedLeft, pausedLeft?.toString() ?? '');
}
