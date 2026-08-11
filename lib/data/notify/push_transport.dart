// The seam between "a moment exists on the relay" and "this device finds out
// about it now rather than at its next poll".
//
// Arc ships with polling as the delivery mechanism, because that works against
// a self-hosted relay with no accounts, no console and no keys — see
// `background_worker.dart`. A push transport only ever *accelerates* that: it
// hands the relay an address to nudge, and turns a nudge back into the same
// delivery pass polling would have run. It never carries the notification
// itself, so the copy, the channels, the icon and the accent stay in one place
// and a pushed alert is indistinguishable from a polled one.
//
// `packages/arc_fcm` implements this over Firebase Cloud Messaging; see
// `docs/push-notifications.md` for the four steps that switch it on.

import 'dart:async';

/// A way for the relay to reach this device directly.
abstract class PushTransport {
  /// The address to register with the relay, or null when this device has none
  /// (no transport configured, permission refused, no network at start-up).
  Future<String?> deviceToken();

  /// Fires whenever the relay nudges this device. Each event means "run a
  /// delivery pass now"; it carries no content of its own by design.
  Stream<void> get wakeSignals;

  Future<void> dispose();
}

/// The shipped default: no direct address, no nudges. Delivery is entirely by
/// the background poll, which is a complete implementation rather than a
/// degraded one — it is simply coarser about *when*.
class PollingOnlyTransport implements PushTransport {
  const PollingOnlyTransport();

  @override
  Future<String?> deviceToken() async => null;

  @override
  Stream<void> get wakeSignals => const Stream<void>.empty();

  @override
  Future<void> dispose() async {}
}
