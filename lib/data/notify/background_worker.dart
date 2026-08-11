// Delivery while Arc is closed.
//
// Android's WorkManager wakes a headless Flutter isolate on a schedule it owns.
// The floor is fifteen minutes and the OS is free to be later than that under
// Doze, which is the honest cost of a relay with no push credentials: a
// companion's PR lands within the quarter-hour rather than the second. Adding
// an FCM transport (see `push_transport.dart`) turns this from the delivery
// mechanism into the safety net that catches whatever a missed push dropped.
//
// The isolate shares nothing with the app: no ArcStore, no theme, no provider
// tree. It opens its own database, re-derives everything it needs from disk,
// does the one job, and exits.

import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../db/app_database.dart';
import '../identity/identity_service.dart';
import '../sync/sync_service.dart';
import 'arc_notifier.dart';
import 'companion_alerts.dart';

/// Names the OS keeps between installs — changing either strands the task
/// already registered on every device that has run this build.
const String kCompanionPollTask = 'arc.companions.poll';
const String _kCompanionPollUnique = 'arc.companions.poll.periodic';

/// WorkManager's Android floor. Asking for less does not get less.
const Duration _kPollInterval = Duration(minutes: 15);

/// Entry point for the headless isolate. Must be a top-level function and must
/// keep the `vm:entry-point` pragma, or tree-shaking drops it from the release
/// build and background delivery silently stops working in exactly the build
/// nobody debugs.
@pragma('vm:entry-point')
void arcBackgroundDispatcher() {
  Workmanager().executeTask((task, _) async {
    if (task != kCompanionPollTask) return true;
    return runCompanionDeliveryPass();
  });
}

/// One complete delivery pass, from a cold isolate. Also the body an FCM
/// background handler should call, so pushed and polled wakeups do the same
/// thing by construction.
///
/// Always reports success to WorkManager. A retry would be pointless — the next
/// period is fifteen minutes away either way — and a reported failure would
/// invite exponential backoff that quietly stretches into hours.
Future<bool> runCompanionDeliveryPass() async {
  AppDatabase? db;
  try {
    // The isolate starts with no plugin registry, so sqflite, path_provider and
    // secure storage are all unavailable until these two run.
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    // Its own connection, never the app's — see AppDatabase.open.
    db = await AppDatabase.open(singleInstance: false);
    final identity = IdentityService();
    // A device that has never completed first-run has no keypair and nothing to
    // sync; `ensure` would mint one behind the user's back.
    if (!await identity.tryLoad(db)) return true;

    final sync = SyncService(db: db, identity: identity);
    final notifier = ArcNotifier();
    await notifier.init();

    final delivered = await CompanionAlerts(
      db: db,
      sync: sync,
      notifier: notifier,
    ).deliverPending();
    if (delivered > 0) {
      debugPrint('Arc background: delivered $delivered companion alert(s)');
    }
  } catch (e) {
    debugPrint('Arc background: pass failed: $e');
  } finally {
    // Safe because the connection above is this isolate's own; closing a shared
    // one would take the running app's database with it.
    await db?.close();
  }
  return true;
}

/// Registers the recurring pass. Idempotent: `ExistingPeriodicWorkPolicy.keep`
/// means an app that launches ten times a day does not reset the schedule ten
/// times and starve the task of ever actually running.
Future<void> registerCompanionPolling() async {
  if (!defaultTargetPlatform.isBackgroundCapable) return;
  try {
    await Workmanager().initialize(arcBackgroundDispatcher);
    await Workmanager().registerPeriodicTask(
      _kCompanionPollUnique,
      kCompanionPollTask,
      frequency: _kPollInterval,
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      constraints: Constraints(
        // The pass is one authenticated GET. Without this it burns a wakeup
        // failing to reach the relay every time the phone is out of signal.
        networkType: NetworkType.connected,
      ),
      backoffPolicy: BackoffPolicy.linear,
      backoffPolicyDelay: const Duration(minutes: 5),
    );
  } catch (e) {
    // A device that refuses to schedule background work still gets every alert
    // the moment Arc is opened. Nothing here is worth failing a launch over.
    debugPrint('Arc background: could not register polling: $e');
  }
}

extension on TargetPlatform {
  /// WorkManager is Android's; the other platforms this app builds for (web)
  /// have no equivalent and would throw on registration.
  bool get isBackgroundCapable => this == TargetPlatform.android;
}
