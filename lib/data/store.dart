import 'package:flutter/foundation.dart';

import 'arc_data.dart';
import 'companion_data.dart';
import 'db/app_database.dart';
import 'identity/identity_service.dart';
import 'identity/pairing.dart';
import 'models.dart';
import 'sync/sync_service.dart';

/// A transient toast request (saved workout / new PR / removed).
class ArcToast {
  final String msg;
  final String icon; // 'check' | 'medal' | 'trash'
  final int seq;
  const ArcToast(this.msg, this.icon, this.seq);
}

/// Draft set used while editing in the log sheet.
class DraftSet {
  double weight;
  int reps;
  final String id;
  DraftSet({required this.weight, required this.reps, required this.id});
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
  })  : _db = db,
        _identity = identity,
        _sync = sync;

  final AppDatabase _db;
  final IdentityService _identity;
  final SyncService _sync;

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

  WorkoutSet? lastSetFor(String exId) {
    for (final s in _sessions) {
      for (final e in s.entries) {
        if (e.exerciseId == exId && e.sets.isNotEmpty) {
          return e.sets.last;
        }
      }
    }
    return null;
  }

  Future<String> addExercise({
    required String name,
    required String group,
    required String unit,
  }) async {
    final id = ArcData.uid('ex');
    final ex = Exercise(id: id, name: name, group: group, unit: unit);
    await _db.upsertExercise(ex, _me);
    _exercises = [..._exercises, ex];
    _recompute();
    notifyListeners();
    return id;
  }

  void _fire(String msg, String icon) {
    toast.value = ArcToast(msg, icon, ++_toastSeq);
  }

  /// Persist a session for [date] from draft entries. Detects new PRs.
  Future<void> saveSession(String date, List<DraftEntry> rawEntries) async {
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
        title: ArcData.inferTitle(
          rawEntries
              .map((e) => Entry(id: e.id, exerciseId: e.exerciseId, sets: const []))
              .toList(),
          exById,
        ),
        entries: rawEntries
            .map((e) => Entry(
                  id: ArcData.uid('ent'),
                  exerciseId: e.exerciseId,
                  sets: e.sets
                      .map((s) => WorkoutSet(
                          id: ArcData.uid('set'), weight: s.weight, reps: s.reps))
                      .toList(),
                ))
            .toList(),
      );
      next = [...others, saved]..sort((a, b) => b.date.compareTo(a.date));
    }

    final after = ArcData.computeRecords(next, _exercises);
    String? prName;
    for (final ex in _exercises) {
      final b = before[ex.id]?.best;
      final a = after[ex.id]?.best;
      if (a != null && b != null && a.score > b.score) {
        prName = ex.name;
        break;
      }
    }

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
  }

  // ── Companions ──────────────────────────────────────────────────────

  /// Set my display name (shown to companions in my QR).
  Future<void> setDisplayName(String name) async {
    await _db.setDisplayName(name);
    await _identity.ensure(_db); // refresh cached Identity
    notifyListeners();
  }

  /// Add a companion from a scanned QR payload. Returns false if it's me or a
  /// malformed/duplicate scan (already a companion just refreshes their info).
  /// Stores the contact locally, then sends a pairing request to the server
  /// (best-effort — if offline, the next sync re-sends it).
  Future<bool> addCompanionFromScan(String raw) async {
    final payload = PairingPayload.tryParse(raw);
    if (payload == null) return false;
    if (payload.publicId == _me) {
      _fire("That's your own code", 'trash');
      return false;
    }
    final existing =
        _companions.where((c) => c.publicId == payload.publicId).firstOrNull;
    await _db.upsertCompanion(Companion(
      publicId: payload.publicId,
      publicKey: payload.publicKey,
      displayName: payload.displayName,
      // Scanning is the request; the peer must accept before data flows.
      status: existing?.status ?? CompanionStatus.pending,
      incoming: existing?.incoming ?? false,
      addedAt: existing?.addedAt ?? DateTime.now().millisecondsSinceEpoch,
      lastSyncedAt: existing?.lastSyncedAt,
    ));
    _companions = await _db.getCompanions();
    notifyListeners();
    _fire('Added ${payload.displayName}', 'check');

    try {
      await _sync.requestCompanion(payload.publicId);
    } catch (_) {
      // Offline / server down — the pending row stays; resend on next sync.
    }
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
    final trimmed = url.trim();
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

  /// Push my changes, pull companions', refresh the companion graph.
  Future<void> syncNow() async {
    if (_syncing) return;
    _syncing = true;
    _syncError = null;
    notifyListeners();
    try {
      final result = await _sync.syncNow();
      _companions = await _db.getCompanions();
      _lastSyncedAt = DateTime.now().millisecondsSinceEpoch;
      notifyListeners();
      _fire('Synced · ↑${result.pushed} ↓${result.pulled}', 'check');
    } catch (e) {
      _syncError = e.toString();
      debugPrint('Arc sync failed: $e'); // visible in `flutter run` / logcat
      _fire('Sync failed', 'trash');
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
