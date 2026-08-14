import 'dart:async';

import 'package:flutter/foundation.dart';

import 'arc_data.dart';
import 'companion_data.dart';
import 'db/app_database.dart';
import 'identity/identity_service.dart';
import 'identity/pairing.dart';
import 'models.dart';
import 'muscle.dart';
import 'notify/arc_notifier.dart';
import 'notify/companion_alerts.dart';
import 'notify/companion_event.dart';
import 'sync/sync_api.dart' show SyncApi, SyncException;
import 'sync/sync_service.dart';

/// A transient toast request (saved workout / new PR / removed).
class ArcToast {
  final String msg;
  final String icon; // 'check' | 'medal' | 'trash'
  final int seq;
  const ArcToast(this.msg, this.icon, this.seq);
}

/// Mutable counterpart of [SetDrop] while editing in the log sheet.
class DraftDrop {
  double weight;
  int reps;
  final String id;
  DraftDrop({required this.weight, required this.reps, required this.id});
}

/// Draft set used while editing in the log sheet.
class DraftSet {
  double weight;
  int reps;
  final String id;

  /// Drop tiers hanging off this set. Grown and pruned in place by the log
  /// sheet, so it's a mutable list rather than a replaced one.
  final List<DraftDrop> drops;

  DraftSet({
    required this.weight,
    required this.reps,
    required this.id,
    List<DraftDrop>? drops,
  }) : drops = drops ?? [];
}

class DraftEntry {
  final String id;
  final String exerciseId;
  final List<DraftSet> sets;
  DraftEntry({required this.id, required this.exerciseId, required this.sets});
}

/// Central app state. Backed by SQLite ([AppDatabase]) as the source of truth,
/// with an in-memory cache of *my* data (owner_id == my public id) so the UI
/// stays synchronous. Every mutation writes through to the DB and marks rows
/// dirty for the future sync server.
class ArcStore extends ChangeNotifier {
  ArcStore({
    required AppDatabase db,
    required IdentityService identity,
    required SyncService sync,
    ArcNotifier? notifier,
  })  : _db = db,
        _identity = identity,
        _sync = sync,
        _notifier = notifier;

  final AppDatabase _db;
  final IdentityService _identity;
  final SyncService _sync;

  /// Presents companion moments in the OS shade. Null in tests and on any
  /// platform without notifications — every call site below tolerates that, so
  /// the feature degrades to "the events still publish" rather than throwing.
  final ArcNotifier? _notifier;

  /// Settings key holding the date this device last told companions a workout
  /// had begun. One announcement per day: the beacon fires when the sheet goes
  /// from empty to holding a lift, and re-opening it to add a fifth exercise is
  /// not a second workout.
  static const _kBeaconDateKey = 'companion_beacon_date';

  late List<Exercise> _exercises;
  late List<Session> _sessions;
  Map<String, ExerciseRecord> _records = {};
  late WorkoutStats _stats;
  List<Companion> _companions = [];

  // ── Sync status (for the companion sheet) ───────────────────────────
  bool _syncing = false;
  bool _restoring = false;
  int? _lastSyncedAt;
  String? _syncError;
  String? _serverUrl;

  bool get syncing => _syncing;
  bool get restoring => _restoring;
  int? get lastSyncedAt => _lastSyncedAt;
  String? get syncError => _syncError;
  String get serverUrl => _serverUrl ?? kDefaultArcServerUrl;

  // ── Existing public surface (unchanged for the screens) ─────────────
  List<Exercise> get exercises => _exercises;
  List<Session> get sessions => _sessions;
  Map<String, ExerciseRecord> get records => _records;
  WorkoutStats get stats => _stats;

  // ── Identity + companions ───────────────────────────────────────────
  Identity get identity => _identity.identity;
  IdentityService get identityService => _identity;
  List<Companion> get companions => _companions;

  /// My QR pairing payload (public ID + public key + name) as an `arc://` URI.
  String get pairingUri => PairingPayload(
        publicId: identity.publicId,
        publicKey: identity.publicKey,
        displayName: identity.displayName ?? 'Arc user',
      ).toUri();

  /// Toast channel — UI listens and shows a pill without full rebuilds.
  final ValueNotifier<ArcToast?> toast = ValueNotifier(null);
  int _toastSeq = 0;

  String get _me => identity.publicId;

  /// Load from the database. Must run once at boot, after
  /// [IdentityService.ensure]. New accounts start empty — no seed/placeholder
  /// data; users build their own exercise library and history.
  Future<void> init() async {
    final st = await _db.getSelfSyncState();
    _serverUrl = st.serverUrl;
    await _reload();
  }

  Future<void> _reload() async {
    _exercises = await _db.getExercises(_me);
    _sessions = await _db.getSessions(_me)
      ..sort((a, b) => b.date.compareTo(a.date));
    _companions = await _db.getCompanions();
    _recompute();
    notifyListeners();
  }

  void _recompute() {
    _records = ArcData.computeRecords(_sessions, _exercises);
    _stats = ArcData.workoutStats(_sessions);
  }

  Exercise? exById(String id) {
    for (final e in _exercises) {
      if (e.id == id) return e;
    }
    return null;
  }

  Session? sessionForDate(String iso) {
    for (final s in _sessions) {
      if (s.date == iso) return s;
    }
    return null;
  }

  WorkoutSet? bestSetFor(String exId) {
    for (final s in _sessions) {
      for (final e in s.entries) {
        if (e.exerciseId == exId && e.sets.isNotEmpty) {
          return e.sets.reduce((a, b) =>
              a.weight > b.weight ? a : (a.weight < b.weight ? b : (a.reps >= b.reps ? a : b)));
        }
      }
    }
    return null;
  }

  Future<String> addExercise({
    required String name,
    required Muscle muscle,
    List<Muscle> secondary = const [],
    required String unit,
  }) async {
    final id = ArcData.uid('ex');
    final ex = Exercise(
      id: id,
      name: name,
      muscle: muscle,
      secondary: secondary,
      unit: unit,
    );
    await _db.upsertExercise(ex, _me);
    _exercises = [..._exercises, ex];
    _recompute();
    notifyListeners();
    unawaited(autoSync());
    return id;
  }

  /// Number of my exercises whose group Arc guessed rather than the user chose.
  /// Drives the review card on the Exercises screen.
  int get unconfirmedMuscleCount =>
      _exercises.where((e) => !e.muscleConfirmed).length;

  /// Reassign an exercise's muscle groups. Always marks the result confirmed —
  /// the only way here is the user picking, whether from the review sheet or
  /// from editing the exercise.
  Future<void> setExerciseMuscles(
    String exerciseId, {
    required Muscle muscle,
    List<Muscle>? secondary,
  }) async {
    final i = _exercises.indexWhere((e) => e.id == exerciseId);
    if (i < 0) return;
    final next = _exercises[i].copyWith(
      muscle: muscle,
      secondary: secondary,
      muscleConfirmed: true,
    );
    await _db.upsertExercise(next, _me);
    _exercises = [..._exercises]..[i] = next;
    _recompute();
    notifyListeners();
    unawaited(autoSync());
  }

  /// Accepts every guessed group as-is. The escape hatch on the review sheet
  /// for a library that Arc already got right.
  Future<void> confirmAllMuscles() async {
    final pending = _exercises.where((e) => !e.muscleConfirmed).toList();
    if (pending.isEmpty) return;
    final byId = {for (final e in pending) e.id: e.copyWith(muscleConfirmed: true)};
    for (final e in byId.values) {
      await _db.upsertExercise(e, _me);
    }
    _exercises = [
      for (final e in _exercises) byId[e.id] ?? e,
    ];
    _recompute();
    notifyListeners();
    unawaited(autoSync());
  }

  void _fire(String msg, String icon) {
    toast.value = ArcToast(msg, icon, ++_toastSeq);
  }

  /// Raises a toast from outside the store — the rest timer's settings, mostly,
  /// which have news of their own but no data to write. Routed through here
  /// rather than posted to [toast] directly so the sequence number stays the
  /// store's to hand out; two writers minting their own would let a stale one
  /// re-show a toast the shell had already retired.
  void announce(String msg, String icon) => _fire(msg, icon);

  /// Persist a session for [date] from draft entries. Detects new PRs.
  ///
  /// [name] is what the user called this workout — blank or null clears it and
  /// hands the label back to the derived title, which is written either way.
  Future<void> saveSession(String date, List<DraftEntry> rawEntries,
      {String? name}) async {
    final before = _records;
    final others = _sessions.where((s) => s.date != date).toList();
    final existing = sessionForDate(date);

    List<Session> next;
    Session? saved;
    if (rawEntries.isEmpty) {
      next = others;
    } else {
      saved = Session(
        id: existing?.id ?? ArcData.uid('ses'),
        date: date,
        title: ArcData.inferTitle(rawEntries.map((e) => e.exerciseId), exById),
        name: normalizeSessionName(name),
        // The session is rebuilt from the draft, which knows nothing about the
        // note. Carried across by hand, or editing a workout would silently
        // delete what the user wrote about it.
        notes: existing?.notes,
        entries: rawEntries
            .map((e) => Entry(
                  id: ArcData.uid('ent'),
                  exerciseId: e.exerciseId,
                  sets: e.sets
                      .map((s) => WorkoutSet(
                            id: ArcData.uid('set'),
                            weight: s.weight,
                            reps: s.reps,
                            drops: s.drops
                                .map((d) => SetDrop(
                                    id: ArcData.uid('drp'),
                                    weight: d.weight,
                                    reps: d.reps))
                                .toList(),
                          ))
                      .toList(),
                ))
            .toList(),
      );
      next = [...others, saved]..sort((a, b) => b.date.compareTo(a.date));
    }

    final after = ArcData.computeRecords(next, _exercises);
    // Every lift that beat its own best, not just the first — the toast names
    // one, but a companion is owed a line per record. A lift with no previous
    // best is a first entry, not a broken record, and stays silent in both.
    final broken = <(Exercise, RecordPoint)>[];
    for (final ex in _exercises) {
      final b = before[ex.id]?.best;
      final a = after[ex.id]?.best;
      if (a != null && b != null && a.score > b.score) broken.add((ex, a));
    }
    final prName = broken.isEmpty ? null : broken.first.$1.name;

    // Write through to SQLite.
    if (saved != null) {
      await _db.upsertSessionTree(saved, _me);
    } else if (existing != null) {
      await _db.deleteSession(existing.id);
    }

    _sessions = next;
    _recompute();
    notifyListeners();

    if (prName != null) {
      _fire('New PR · $prName', 'medal');
    } else if (rawEntries.isEmpty) {
      _fire('Workout removed', 'trash');
    } else {
      _fire('Workout saved', 'check');
    }

    // Only records that were actually just set. Correcting a session from three
    // weeks ago can legitimately produce a new best, but announcing it as
    // "has a new PR record" would be reporting bookkeeping as news — the same
    // reason the start beacon refuses a back-dated date. Yesterday is allowed:
    // logging last night's session over breakfast is normal, and that PR is
    // real and current.
    if (_announcesRecords(date)) {
      for (final (ex, best) in broken) {
        await _enqueueEvent(CompanionEvent.mine(
          EventKind.personalRecord,
          CompanionEvent.prPayload(
            exercise: ex.name,
            weight: best.weight,
            reps: best.reps,
            unit: ex.unit,
          ),
        ));
      }
    }

    unawaited(autoSync()); // push this change to the relay in the background
  }

  /// Write the note on the workout logged for [date]. Null or blank clears it.
  ///
  /// Deliberately not routed through [saveSession]: a note cannot set a record,
  /// so there is nothing to recompute and nothing to announce, and firing
  /// "Workout saved" over a note the user is still writing would be a lie about
  /// what just happened. Silent by design — the note is already on screen.
  Future<void> setSessionNotes(String date, String? notes) async {
    final existing = sessionForDate(date);
    if (existing == null) return;
    final clean = normalizeSessionNotes(notes);
    if (clean == existing.notes) return;

    final next = existing.copyWith(notes: clean, clearNotes: clean == null);
    await _db.upsertSessionTree(next, _me);
    _sessions = [
      for (final s in _sessions) s.id == next.id ? next : s,
    ];
    notifyListeners();
    unawaited(autoSync());
  }

  // ── Companion moments ───────────────────────────────────────────────

  /// Whether a record set on this session's [date] is still news.
  ///
  /// Also requires somebody to tell: a device with no accepted companions
  /// publishes nothing at all.
  bool _announcesRecords(String date) {
    if (!_companions.any((c) => c.status == CompanionStatus.accepted)) {
      return false;
    }
    final ago = ArcData.daysAgo(date);
    return ago >= 0 && ago <= 1;
  }

  /// Tell companions a workout has just begun.
  ///
  /// Called the moment the log sheet goes from empty to holding its first lift,
  /// which is the only moment at which "Today is Push Day" is a statement of
  /// fact rather than a forecast — [name] is what the workout is called *now*,
  /// the user's own if they typed one and the inferred title otherwise.
  ///
  /// Silent for a back-dated entry (filling in Tuesday on Thursday is not
  /// starting a workout) and for a device with nobody to tell.
  Future<void> announceWorkoutStart({
    required String date,
    required String name,
  }) async {
    if (date != ArcData.iso(ArcData.today)) return;
    if (!_companions.any((c) => c.status == CompanionStatus.accepted)) return;
    if (await _db.getSetting(_kBeaconDateKey) == date) return;
    await _db.setSetting(_kBeaconDateKey, date);
    await _enqueueEvent(CompanionEvent.mine(
      EventKind.workoutStarted,
      CompanionEvent.workoutStartedPayload(name: name, date: date),
    ));
    unawaited(autoSync()); // get it out now; it is only news for a few hours
  }

  /// Queue a moment for the relay. Writing to disk before the network is what
  /// makes a beacon fired on a basement gym's dead signal still arrive.
  Future<void> _enqueueEvent(CompanionEvent e) => _db.enqueueEvent(
        id: e.id,
        kind: e.kind.wire,
        payloadJson: e.payloadJson,
        createdAt: e.createdAt,
      );

  /// Pull companions' moments and raise any that are new. Cheap and safe to
  /// call often — it never throws, and posts nothing without an unseen event.
  Future<int> deliverCompanionAlerts() async {
    final notifier = _notifier;
    if (notifier == null) return 0;
    return CompanionAlerts(db: _db, sync: _sync, notifier: notifier)
        .deliverPending();
  }

  /// Ask for notification permission at the one moment it explains itself:
  /// just after pairing, when the user has a companion to hear about. A cold
  /// prompt on first launch is the one people deny permanently.
  Future<void> _requestAlertPermission() async {
    final notifier = _notifier;
    if (notifier == null) return;
    try {
      if (await notifier.enabled) return;
      await notifier.requestPermission();
    } catch (e) {
      debugPrint('Arc notify: permission request failed: $e');
    }
  }

  /// The same ask, for everyone who was already paired before this build
  /// existed — made when they open the Companions sheet.
  ///
  /// Pairing is the natural prompt, but an upgrading install passed through
  /// that moment months ago, so without this the feature would ship
  /// permanently silent to exactly the users who have companions to hear
  /// about. Opening Companions is the next-best moment: they are looking at
  /// the people the alerts are about, which is the context a bare system
  /// dialog cannot supply for itself.
  ///
  /// Deliberately *not* asked from `main()`. A prompt at cold launch is the one
  /// people dismiss reflexively, and it would arrive before there is anything
  /// on screen to explain it.
  ///
  /// No ask-once flag: Android already stops showing the dialog after two
  /// dismissals, and a flag of our own would turn one reflexive tap into a
  /// permanent, unexplained silence. Re-opening Companions is therefore the way
  /// back for anyone who dismissed it once.
  Future<void> ensureAlertPermission() async {
    if (_notifier == null) return;
    if (!_companions.any((c) => c.status == CompanionStatus.accepted)) return;
    await _requestAlertPermission();
  }

  /// Hand the relay an address to nudge, if this build has a push transport.
  /// Best-effort — polling delivers everything regardless.
  Future<void> registerPushToken(String deviceToken) async {
    try {
      await _sync.registerPushToken(deviceToken);
    } catch (e) {
      debugPrint('Arc push: token registration failed: $e');
    }
  }

  /// Delete the workout logged on [date] (tombstoned for sync).
  Future<void> deleteSession(String date) async {
    final ses = sessionForDate(date);
    if (ses == null) return;
    await _db.deleteSession(ses.id);
    _sessions = _sessions.where((s) => s.id != ses.id).toList();
    _recompute();
    notifyListeners();
    _fire('Workout removed', 'trash');
    unawaited(autoSync());
  }

  /// Delete an exercise from the library (tombstoned for sync). Past workouts
  /// keep their logged sets, but the exercise no longer appears in the library
  /// or its personal records.
  Future<void> deleteExercise(String id) async {
    final ex = exById(id);
    if (ex == null) return;
    await _db.deleteExercise(id);
    _exercises = _exercises.where((e) => e.id != id).toList();
    _recompute();
    notifyListeners();
    _fire('Exercise deleted', 'trash');
    unawaited(autoSync());
  }

  // ── Companions ──────────────────────────────────────────────────────

  /// Set my display name (shown to companions in my QR).
  Future<void> setDisplayName(String name) async {
    await _db.setDisplayName(name);
    await _identity.ensure(_db); // refresh cached Identity
    notifyListeners();
  }

  /// Add a companion from a pairing link — scanned from their QR or pasted
  /// from "Copy link". Returns false if nothing was added, always after
  /// toasting why.
  ///
  /// The link is validated locally first (shape, key length, and that the id
  /// really is the hash of the key), then against what we already know about
  /// this person, then by the server. The server call goes *before* the local
  /// write so a rejected add never leaves an orphan row behind — except when
  /// the server can't be reached or doesn't know them yet, where we keep the
  /// contact as pending and let the reconciler in [SyncService] re-send on the
  /// next sync.
  Future<bool> addCompanionFromLink(String raw) async {
    final parsed = PairingPayload.parse(raw);
    if (parsed.payload == null) {
      _fire(parsed.issue!.message, 'trash');
      return false;
    }
    final payload = parsed.payload!;
    if (payload.publicId == _me) {
      _fire("That's your own link", 'trash');
      return false;
    }

    final existing =
        _companions.where((c) => c.publicId == payload.publicId).firstOrNull;
    final who = existing?.displayName.isNotEmpty == true
        ? existing!.displayName
        : payload.displayName;
    switch (existing?.status) {
      case CompanionStatus.accepted:
        _fire("You're already companions with $who", 'trash');
        return false;
      case CompanionStatus.blocked:
        _fire('$who is blocked — remove them first', 'trash');
        return false;
      case CompanionStatus.pending when !existing!.incoming:
        _fire('Request already sent to $who', 'trash');
        return false;
      // A pending *incoming* request falls through: re-adding them is how you
      // accept it, and the server reciprocates the edge.
      default:
        break;
    }

    var result = 'pending';
    var reachedServer = true;
    try {
      result = await _sync.requestCompanion(
        payload.publicId,
        peerKey: payload.publicKey,
        strict: true,
      );
    } on SyncException catch (e) {
      // Only the server's verdicts on the link itself are fatal. A 404 (they
      // haven't set up sync yet) or any 5xx/auth hiccup keeps the contact and
      // lets the next sync re-send.
      if (e.statusCode == 400 || e.statusCode == 409) {
        _fire(e.message, 'trash');
        return false;
      }
      reachedServer = false;
    } catch (_) {
      reachedServer = false; // offline / server down
    }

    final accepted = result == 'accepted';
    await _db.upsertCompanion(Companion(
      publicId: payload.publicId,
      publicKey: payload.publicKey,
      displayName: payload.displayName,
      status: accepted ? CompanionStatus.accepted : CompanionStatus.pending,
      // If we couldn't reciprocate their incoming request (offline), keep it
      // flagged incoming so it stays acceptable from the Requests list.
      incoming: accepted ? false : (existing?.incoming ?? false),
      addedAt: existing?.addedAt ?? DateTime.now().millisecondsSinceEpoch,
      lastSyncedAt: existing?.lastSyncedAt,
    ));
    _companions = await _db.getCompanions();
    notifyListeners();

    if (!reachedServer) {
      _fire('Saved — ${payload.displayName} will get your request on next sync',
          'check');
    } else if (accepted) {
      _fire('Now companions with ${payload.displayName}', 'check');
    } else {
      _fire('Request sent to ${payload.displayName}', 'check');
    }
    // Now the prompt has an answer to "notifications about what?" — they just
    // added someone whose workouts and records they'll want to hear about.
    unawaited(_requestAlertPermission());
    return true;
  }

  /// Accept a companion's incoming pairing request.
  Future<void> acceptCompanion(String publicId) async {
    await _sync.acceptCompanion(publicId);
    final c = _companions.where((c) => c.publicId == publicId).firstOrNull;
    if (c != null) {
      await _db.upsertCompanion(
          c.copyWith(status: CompanionStatus.accepted, incoming: false));
    }
    _companions = await _db.getCompanions();
    notifyListeners();
    _fire('Companion accepted', 'check');
    unawaited(_requestAlertPermission());
  }

  /// Block a companion (severs sync both ways).
  Future<void> blockCompanion(String publicId) async {
    await _sync.blockCompanion(publicId);
    final c = _companions.where((c) => c.publicId == publicId).firstOrNull;
    if (c != null) {
      await _db.upsertCompanion(
          c.copyWith(status: CompanionStatus.blocked, incoming: false));
    }
    _companions = await _db.getCompanions();
    notifyListeners();
  }

  Future<void> removeCompanion(String publicId) async {
    try {
      await _sync.deleteCompanion(publicId);
    } catch (_) {
      // Best-effort; remove locally regardless.
    }
    await _db.deleteCompanion(publicId);
    _companions = await _db.getCompanions();
    notifyListeners();
  }

  /// Load a read-only snapshot of a companion's synced data (owner = them),
  /// with the same derived records/stats the dashboard uses.
  Future<CompanionData?> loadCompanionData(String publicId) async {
    final companion =
        _companions.where((c) => c.publicId == publicId).firstOrNull;
    if (companion == null) return null;
    final exercises = await _db.getExercises(publicId);
    final sessions = await _db.getSessions(publicId);
    return CompanionData.from(companion, exercises, sessions);
  }

  /// Point this device at a different sync server (forces re-auth).
  Future<void> setServerUrl(String url) async {
    // Store it already normalized (scheme added, trailing slash dropped) so the
    // sheet shows the URL that will actually be called.
    final trimmed = SyncApi.normalizeBaseUrl(url);
    await _db.setServerUrl(trimmed);
    await _db.setSyncToken(null);
    _serverUrl = trimmed;
    notifyListeners();
  }

  // ── Account restore ───────────────────────────────────────────────────

  /// Restore a backed-up account from its 24-word recovery phrase: re-key this
  /// device to that identity, then re-download my own data (workouts + library)
  /// from the relay. Returns the number of objects restored.
  ///
  /// Replaces whatever identity/data is on this device, so it's intended for a
  /// fresh install. Throws [FormatException] on an invalid phrase, or a
  /// [SyncException]/network error if the server is unreachable.
  Future<int> restoreAccount(String phrase) async {
    if (_restoring) return 0;
    _restoring = true;
    notifyListeners();
    try {
      // Swap in the backed-up identity (validates the phrase first).
      await _identity.restoreFromPhrase(phrase, _db);
      // Any cached credentials/cursor belonged to the old identity.
      await _db.setSyncToken(null);
      await _db.setSyncCursor(0);
      // Pull my own change feed back down (also repopulates my display name),
      // then refresh the cached identity + UI caches.
      final restored = await _sync.restoreFromServer();
      await _identity.ensure(_db);
      await _reload();
      _fire('Account restored · $restored items', 'check');
      return restored;
    } finally {
      _restoring = false;
      notifyListeners();
    }
  }

  // ── Sync ────────────────────────────────────────────────────────────

  /// Manual sync (the "Sync now" button). Announces success and failure.
  /// Kept as the user's explicit fallback alongside the automatic syncs.
  Future<void> syncNow() => _runSync(announceSuccess: true);

  /// Background sync fired after a local change and on app open. Stays quiet on
  /// success (no toast spam) but surfaces failures loudly — and since failed
  /// pushes leave rows `dirty`, the next sync retries automatically.
  Future<void> autoSync() => _runSync(announceSuccess: false);

  Future<void> _runSync({required bool announceSuccess}) async {
    if (_syncing) return; // a sync is already in flight; let it finish
    _syncing = true;
    _syncError = null;
    notifyListeners();
    try {
      final result = await _sync.syncNow();
      _companions = await _db.getCompanions();
      _lastSyncedAt = DateTime.now().millisecondsSinceEpoch;
      notifyListeners();
      // The relay was reachable a moment ago, so this is the cheapest chance
      // all day to find out what companions have been up to.
      unawaited(deliverCompanionAlerts());
      if (announceSuccess) {
        _fire('Synced · ↑${result.pushed} ↓${result.pulled}', 'check');
      }
    } catch (e) {
      _syncError = e.toString();
      debugPrint('Arc sync failed: $e'); // visible in `flutter run` / logcat
      // Loud either way: the user must know data didn't reach the server. The
      // local copy is safe (rows stay dirty) and will retry on the next sync.
      _fire('Sync failed — saved locally, will retry', 'trash');
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }
}

extension<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
