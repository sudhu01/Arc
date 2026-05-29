import 'package:flutter/foundation.dart';

import 'arc_data.dart';
import 'db/app_database.dart';
import 'identity/identity_service.dart';
import 'identity/pairing.dart';
import 'models.dart';

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
  ArcStore({required AppDatabase db, required IdentityService identity})
      : _db = db,
        _identity = identity;

  final AppDatabase _db;
  final IdentityService _identity;

  late List<Exercise> _exercises;
  late List<Session> _sessions;
  Map<String, ExerciseRecord> _records = {};
  late WorkoutStats _stats;
  List<Companion> _companions = [];

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

  // ── Companions ──────────────────────────────────────────────────────

  /// Set my display name (shown to companions in my QR).
  Future<void> setDisplayName(String name) async {
    await _db.setDisplayName(name);
    await _identity.ensure(_db); // refresh cached Identity
    notifyListeners();
  }

  /// Add a companion from a scanned QR payload. Returns false if it's me or a
  /// malformed/duplicate scan (already a companion just refreshes their info).
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
      // Scanning is consent to follow them; acceptance/sync happens server-side.
      status: existing?.status ?? CompanionStatus.pending,
      addedAt: existing?.addedAt ?? DateTime.now().millisecondsSinceEpoch,
      lastSyncedAt: existing?.lastSyncedAt,
    ));
    _companions = await _db.getCompanions();
    notifyListeners();
    _fire('Added ${payload.displayName}', 'check');
    return true;
  }

  Future<void> removeCompanion(String publicId) async {
    await _db.deleteCompanion(publicId);
    _companions = await _db.getCompanions();
    notifyListeners();
  }
}

extension<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
