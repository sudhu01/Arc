# Companion notifications

Arc tells you when someone you train with starts a workout or breaks a record.

> **Alice has started a workout!**
> Today is Push Day

> **Alice has a new PR record**
> 100 kg × 5 for Bench Press

Both arrive as Android notifications, whether or not Arc is open.

---

## How a moment travels

The relay already fans out *state* — sessions and exercises, re-read forever on
every pull. Notifications need something different: *moments*, told once, and
only while they are still true. So they ride a second feed with its own table,
its own cursor and its own retention.

```
 actor's phone                     relay                    companion's phone
 ─────────────                     ─────                    ─────────────────
 first lift added
   → event_outbox  ──publish──▶  events  ──┬── GET /v1/events ──▶ fresh?
   (survives                     (7-day    │                        ↓
    no signal)                    sweep)   │                    claim unseen
                                           │                        ↓
 PR detected on save                       └── FCM wake ─────▶  ArcNotifier
   → event_outbox  ──publish──▶            (optional)          (Android shade)
```

The wire is deliberately thin: the relay never carries a title or a body. It
carries `{kind, payload, created_at}` and, optionally, a content-free "there is
something new" nudge. **Every sentence is written on the receiving device**, in
`AlertCopy`, so a moment that arrived by push and one that arrived by poll are
identical on screen and the copy lives in exactly one place.

### The two moments

| kind | fired when | payload | still worth telling for |
|---|---|---|---|
| `workout_started` | the log sheet goes from empty to holding its first lift | `{name, date}` | 4 hours |
| `pr` | a save produces a score above that lift's previous best | `{exercise, weight, reps, unit}` | 24 hours |

`workout_started` is perishable — past its window it is not late news, it is
false — which is also what stops a freshly paired device from replaying a week
of a companion's history into the shade on its first sync.

`name` is resolved at the moment the beacon fires: what the user typed, or the
title Arc infers from the lift they just picked. That is the only moment at
which *"Today is Push Day"* is a statement rather than a forecast.

A PR quotes `100 kg × 5`, Arc's notation everywhere else, rather than the weight
alone. Records break on estimated 1RM, so the same load for more reps is a
genuine PR — and quoting only the kilos would announce a number the companion
already saw last week and call it new.

### Guards

| risk | what stops it |
|---|---|
| the same moment announced twice | `event_seen` — a row, claimed before rendering, so the app isolate and the background worker cannot both win |
| a retried publish becoming two alerts | the relay dedupes on the client-generated event id |
| a stale beacon surfacing next morning | `kOutboxTtl` (6 h) on send, `eventFreshness` on receive, and `timeoutAfter` so the shade entry expires with its own window |
| back-filling Tuesday on Thursday announcing a workout | the beacon only fires for today's date |
| editing a three-week-old session broadcasting "a new PR record" | `_announcesRecords` — the session's date must be today or yesterday |
| announcing to nobody | no accepted companions, no publish |
| a week of history on first pair | `eventFreshness` |
| a retention sweep restarting `server_seq` and stranding every cursor above it | the sequence is a counter in `meta`, not `MAX(server_seq)` |
| one account releasing another's push address | `DELETE /v1/devices/{token}` is scoped to the caller |
| the background isolate closing the app's database | the worker opens with `singleInstance: false`; the file is WAL |

---

## Delivery

**While Arc is open** — a pass runs on launch, on resume, after every sync, and
on a four-minute timer.

**While Arc is closed** — Android WorkManager wakes a headless isolate every
fifteen minutes (its floor; Doze may stretch it). The isolate opens its own
database, pulls the event feed, and posts. It shares nothing with the app.

**Optionally, instantly** — with FCM configured, publishing an event nudges every
registered companion device, which runs the same pass immediately. See below.

Fifteen minutes is the honest cost of a relay with no push credentials. It is a
complete delivery path, not a degraded one — just coarser about *when*.

---

## Permission

Android 13+ requires `POST_NOTIFICATIONS` at runtime. Arc asks **just after
pairing** — the one moment where the prompt answers its own question, because
the user has just added someone whose workouts they want to hear about. It is
never asked at cold launch on a device with no companions, which is the ask
people deny permanently.

Anyone who paired *before* this feature existed never passes through that
moment, so `ArcStore.ensureAlertPermission` makes the same ask when they open
the **Companions sheet** — they are looking at the people the alerts are about,
which is the context a bare system dialog cannot supply for itself. Without it
the feature would ship permanently silent to exactly the users it was built for.

Never from `main()`. A prompt at cold launch arrives before there is anything on
screen to explain it, and there is no ask-once flag of Arc's own: Android
already stops showing the dialog after two dismissals, and a flag would turn one
reflexive tap into permanent, unexplained silence. Re-opening Companions is
therefore the way back for anyone who dismissed it.

**Known gap.** Once Android has hard-denied, or the user switches a channel off
in system settings, nothing in Arc says so — the feature is simply quiet. Fixing
that properly wants one conditional row on the companions sheet, shown only when
`ArcNotifier.enabled` is false, deep-linking the system channel settings. It is
not built, because "OS notifications only" was an explicit product decision.

Channels are created at start-up regardless (creating a channel is not a
prompt), so the user's own Android settings are the control surface:

- **Companions › Companion workouts** — default importance. A training partner
  walking into the gym is worth a sound, not the screen.
- **Companions › Companion records** — high importance. The peak moment in the
  product; it earns the peek.

Muting either, or Arc entirely, is done where users already look for it.

---

## Look

The shade is the OS's surface, so its conventions are honoured — channels,
groups, expandable text, tap-to-open. What is Arc's is the identity:

- **`ic_stat_arc`** — a rising strength curve with the record marked at its
  head. PRODUCT principle 4, and the one shape that survives 18 dp of
  monochrome.
- **The accent** — the hue the user actually picked, rendered for the surface it
  lands on. The shade follows the *system* theme, not Arc's, so a phone in dark
  mode gets the dark palette's accent even while Arc runs light; otherwise
  Surge's deep volt would sit on near-black at a whisper of contrast.
  `accentLine` is the token already solved for exactly this.
- **The split** — title carries the claim, body carries the number, and
  expanding shows the sentence whole. A glance from across the room lands on
  *"Alice has a new PR record"*; a proper look lands on *"100 kg for Bench
  Press"*.
- **The stack** — every alert shares one group key, so several become one Arc
  entry with a summary rather than a column of near-identical lines.

Tapping opens that companion's progress sheet, including from a cold launch.

---

## Server

Three endpoints, all bearer-authenticated and gated by the same accepted-edge
rule as the change feed.

| method · path | body | notes |
|---|---|---|
| `POST /v1/events` | `{events:[{id, kind, payload, created_at}]}` | owner is always the caller; idempotent on `id` |
| `GET /v1/events?cursor=N` | – | accepted companions' moments, oldest first; each carries `owner_name` |
| `POST /v1/devices` | `{token, platform}` | claim a push address |
| `DELETE /v1/devices/{token}` | – | release one |

The janitor sweeps events past seven days.

---

## Enabling FCM

Everything on the relay is already built and tested; what is missing is the
credentials, which only you can create. Four steps.

**1 — Firebase project.** Create one, add an Android app with the applicationId
`com.arc.arc`, and download `google-services.json` into `android/app/`.

**2 — Gradle.** In `android/settings.gradle.kts`, add to the `plugins` block:

```kotlin
id("com.google.gms.google-services") version "4.4.2" apply false
```

and in `android/app/build.gradle.kts`, add to its `plugins` block:

```kotlin
id("com.google.gms.google-services")
```

**3 — Client.** Add the packages:

```bash
flutter pub add firebase_core firebase_messaging
```

and create `lib/data/notify/fcm_push_transport.dart`:

```dart
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'background_worker.dart';
import 'push_transport.dart';

/// Turns the relay's content-free nudge into a delivery pass.
///
/// It carries no copy of its own by design — see push_transport.dart.
class FcmPushTransport implements PushTransport {
  final _wakes = StreamController<void>.broadcast();
  bool _started = false;

  Future<void> _start() async {
    if (_started) return;
    _started = true;
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);
    FirebaseMessaging.onMessage.listen((_) => _wakes.add(null));
    FirebaseMessaging.instance.onTokenRefresh.listen(_wakes.addError);
  }

  @override
  Future<String?> deviceToken() async {
    try {
      await _start();
      // The relay only ever sends data messages, so this does not prompt.
      return FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('Arc push: FCM unavailable ($e) — polling still delivers');
      return null;
    }
  }

  @override
  Stream<void> get wakeSignals => _wakes.stream;

  @override
  Future<void> dispose() => _wakes.close();
}

/// Runs when a nudge lands with Arc closed. Same pass the poll runs.
@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage _) async {
  await Firebase.initializeApp();
  await runCompanionDeliveryPass();
}
```

Then in `lib/main.dart`, swap the one constructor:

```dart
unawaited(_attachPushTransport(store, FcmPushTransport()));
```

**4 — Relay.** Generate a service-account key (Project settings → Service
accounts → Generate new private key) and start the server with:

```bash
ARC_FCM_CREDENTIALS=/path/to/service-account.json go run .
```

It logs `push: FCM enabled for project <id>` on start. Without it, or with a bad
path, it logs why and falls back to polling — push is an accelerator, and a typo
in a deployment variable must never take the relay down.

Leave the background worker registered either way: it is the safety net that
catches whatever a missed push dropped.
