// The one pass that turns "there is something new in the feed" into
// notifications on screen.
//
// It runs from two isolates — the app's, on launch/resume/poll, and the
// background worker's, on a WorkManager wakeup or an FCM nudge — and it must
// behave identically in both, because the user has no idea which one woke up.
// Everything that could differ between them is therefore resolved from the
// database rather than from memory, and the claim on "already told" is a row,
// not a flag.

import 'package:flutter/foundation.dart';

import '../db/app_database.dart';
import '../sync/sync_service.dart';
import 'arc_notifier.dart';
import 'companion_event.dart';

/// How long a spent ledger row is kept. Comfortably past the longest freshness
/// window, so a moment can never be re-announced by an entry ageing out from
/// under it, and short enough that the table stays small forever.
const Duration _seenRetention = Duration(days: 7);

class CompanionAlerts {
  CompanionAlerts({
    required AppDatabase db,
    required SyncService sync,
    required ArcNotifier notifier,
  })  : _db = db,
        _sync = sync,
        _notifier = notifier;

  final AppDatabase _db;
  final SyncService _sync;
  final ArcNotifier _notifier;

  /// Pull the event feed and raise a notification for everything that is new,
  /// fresh, and about somebody this device still knows. Returns how many
  /// notifications were actually posted.
  ///
  /// Never throws: this runs on a background wakeup where an uncaught error is
  /// a silent crash report, and on app launch where it would take the launch
  /// with it. A failed pass simply leaves the cursor where it was.
  Future<int> deliverPending() async {
    try {
      if (!await _notifier.enabled) return 0;

      final batch = await _sync.pullEvents();
      if (batch.events.isEmpty) return 0;

      final now = DateTime.now().millisecondsSinceEpoch;
      // Order matters. Freshness is judged first so a stale moment never
      // consumes a ledger claim it doesn't need, and the claim is taken before
      // anything is shown so the other isolate can't post the same alert while
      // this one is rendering.
      final fresh = [for (final e in batch.events) if (e.isFreshAt(now)) e];
      final unclaimed = fresh.isEmpty
          ? const <String>{}
          : await _db.claimUnseenEvents([for (final e in fresh) e.id]);

      var shown = 0;
      if (unclaimed.isNotEmpty) {
        final names = await _companionNames();
        final accent = await notificationAccent(_db);
        for (final e in fresh) {
          if (!unclaimed.contains(e.id)) continue;
          // The name the user chose to see wins; the relay's copy is the
          // fallback for a companion this device has pulled an event from but
          // not yet reconciled its graph with.
          final who = names[e.ownerId] ?? _fallbackName(e);
          if (await _notifier.show(e, who, accent: accent)) shown++;
        }
      }

      // Only now: everything in this page has either been announced or
      // deliberately passed over, so it will never need to be read again. A
      // throw anywhere above leaves the cursor put and the page is re-read next
      // pass, where the ledger recognises whatever already landed.
      await _sync.commitEventCursor(batch.cursor);
      await _db.pruneSeenEvents(
          DateTime.now().subtract(_seenRetention).millisecondsSinceEpoch);
      return shown;
    } catch (e) {
      debugPrint('Arc alerts: delivery pass failed: $e');
      return 0;
    }
  }

  Future<Map<String, String>> _companionNames() async {
    final out = <String, String>{};
    for (final c in await _db.getCompanions()) {
      if (c.displayName.trim().isNotEmpty) out[c.publicId] = c.displayName.trim();
    }
    return out;
  }

  static String _fallbackName(CompanionEvent e) {
    final n = e.ownerName.trim();
    return n.isEmpty ? 'A companion' : n;
  }
}
