// SQLite backend for Arc (sqflite).
//
// Source of truth for all user data. The schema is *sync-ready*: every
// top-level synced object (exercises, sessions) carries `owner_id`,
// `updated_at`, `deleted` (tombstone) and `dirty` (un-pushed local change)
// columns so the same tables can hold both my data (owner_id = my public id)
// and read-only mirrors of companions' data once the relay server exists.
//
// Sync granularity = the *session subtree*: a session and its entries/sets
// travel as one atomic unit, so entries/sets don't need their own version
// metadata — re-saving a session replaces its children wholesale.

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models.dart';
import '../muscle.dart';
import '../muscle_map.dart';

class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const _dbName = 'arc.db';
  static const _version = 7;

  /// Open the database. [factory] and [path] are injectable so tests can run
  /// against an in-memory sqflite_common_ffi database.
  ///
  /// [singleInstance] must be false for the background delivery isolate. sqflite
  /// keys its open databases by path across the whole process, so a worker
  /// sharing the default instance would be handed the *app's* native handle —
  /// and closing it when the pass finished would close the running app's
  /// database out from under it. Its own connection costs one file handle and
  /// removes that entirely.
  static Future<AppDatabase> open({
    DatabaseFactory? factory,
    String? path,
    bool singleInstance = true,
  }) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), _dbName);
    final database = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: _version,
        singleInstance: singleInstance,
        onConfigure: _configure,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    return AppDatabase._(database);
  }

  static Future<void> _configure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
    // Two connections now read this file — the app's and the background
    // worker's. WAL lets the worker's short reads run while the app is mid-save
    // instead of colliding, and the timeout absorbs the overlap that remains.
    // An in-memory database (tests) has no journal to switch; ignore it there.
    try {
      await db.rawQuery('PRAGMA journal_mode = WAL');
      await db.rawQuery('PRAGMA busy_timeout = 5000');
    } catch (_) {}
  }

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // v2: track whether a pending companion request is incoming (peer asked me).
    if (oldVersion < 2) {
      await db.execute(
          'ALTER TABLE companions ADD COLUMN incoming INTEGER NOT NULL DEFAULT 0');
    }
    // v3: local-only key/value settings (theme choice, …).
    if (oldVersion < 3) {
      await db.execute(_settingsTable);
    }
    // v4: drop-set tiers hanging off a set. Existing sets simply have none.
    if (oldVersion < 4) {
      await db.execute(_dropsTable);
      await db.execute(_dropsIndex);
    }
    // v5: a user-given name for a workout. Nullable — existing sessions keep
    // only the derived `title`, which is still what shows when nothing is set.
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE sessions ADD COLUMN name TEXT');
    }
    // v6: per-muscle-group exercise taxonomy. `muscle_group` stays, still
    // holding the coarse Push/Pull/Legs/Core region — that's what keeps a
    // companion on an older build able to read our exercises.
    if (oldVersion < 6) {
      await db.execute('ALTER TABLE exercises ADD COLUMN muscle TEXT');
      await db.execute(
          "ALTER TABLE exercises ADD COLUMN secondary TEXT NOT NULL DEFAULT ''");
      await db.execute('ALTER TABLE exercises '
          'ADD COLUMN muscle_confirmed INTEGER NOT NULL DEFAULT 0');
      await _backfillMuscles(db);
    }
    // v7: companion moments — the outbox that gets mine to the relay and the
    // ledger that stops theirs from being announced twice. An upgraded install
    // starts with both empty and its event cursor at 0; the age guard in
    // `CompanionAlerts` is what keeps that from replaying a week of history as
    // notifications on first run.
    if (oldVersion < 7) {
      await db.execute(_eventOutboxTable);
      await db.execute(_eventSeenTable);
      await db.execute('ALTER TABLE sync_state ADD COLUMN event_cursor TEXT');
    }
  }

  /// Reads every exercise's name through the dictionary and writes the muscle
  /// group it implies. A name the dictionary doesn't know falls back to the
  /// default group for its old region and is left `muscle_confirmed = 0`, which
  /// is what the Exercises screen's review card counts.
  static Future<void> _backfillMuscles(DatabaseExecutor db) async {
    final rows = await db.query('exercises',
        columns: ['id', 'name', 'muscle_group']);
    final batch = db.batch();
    for (final r in rows) {
      final guess = MuscleMap.resolve(
        (r['name'] as String?) ?? '',
        region: r['muscle_group'] as String?,
      );
      batch.update(
        'exercises',
        {
          'muscle': guess.primary.id,
          'secondary': Muscle.encodeList(guess.secondary),
          'muscle_confirmed': guess.confident ? 1 : 0,
          // Re-derive the region so it agrees with the group we just chose —
          // "Close-Grip Bench" was filed under Push and is now Triceps, which
          // is still Push, but "Deadlift" under Legs is now Lower Back / Pull.
          'muscle_group': guess.primary.region,
        },
        where: 'id = ?',
        whereArgs: [r['id']],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Drop-set tiers. A child of `sets` rather than a flag on it, so a set is
  /// always exactly one row in `sets` — every "how many sets" count in the app
  /// depends on that, and a `parent_set_id` column would break them silently
  /// anywhere a query forgot the filter.
  static const _dropsTable = '''
    CREATE TABLE drops (
      id       TEXT PRIMARY KEY,
      set_id   TEXT NOT NULL REFERENCES sets(id) ON DELETE CASCADE,
      weight   REAL NOT NULL,
      reps     INTEGER NOT NULL,
      position INTEGER NOT NULL,
      owner_id TEXT NOT NULL
    )
  ''';
  static const _dropsIndex = 'CREATE INDEX idx_drops_set ON drops(set_id)';

  /// Device-local preferences. Deliberately not synced — a companion's theme
  /// is their own business.
  static const _settingsTable = '''
    CREATE TABLE settings (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''';

  /// Moments of mine that haven't reached the relay yet.
  ///
  /// A workout started in a basement gym with no signal still has to announce
  /// itself when the phone comes back up, so the event is written here first and
  /// published on the next sync. Rows carry the id the server dedupes on, so a
  /// publish that succeeded but whose response was lost costs nothing on retry.
  static const _eventOutboxTable = '''
    CREATE TABLE event_outbox (
      id         TEXT PRIMARY KEY,
      kind       TEXT NOT NULL,
      payload    TEXT NOT NULL,      -- JSON
      created_at INTEGER NOT NULL
    )
  ''';

  /// Companions' moments this device has already raised a notification for.
  ///
  /// The cursor alone is not enough: the foreground app and the background
  /// worker pull the same feed from their own isolates, and whichever loses the
  /// race would otherwise announce the same PR a second time. The ledger is the
  /// single claim on "this one has been told".
  static const _eventSeenTable = '''
    CREATE TABLE event_seen (
      id      TEXT PRIMARY KEY,
      seen_at INTEGER NOT NULL
    )
  ''';

  static Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();

    // ── My own identity (single row) ─────────────────────────────────
    batch.execute('''
      CREATE TABLE identity (
        id          INTEGER PRIMARY KEY CHECK (id = 1),
        public_id   TEXT NOT NULL,
        public_key  TEXT NOT NULL,
        display_name TEXT,
        created_at  INTEGER NOT NULL
      )
    ''');

    // ── Companions (people I've paired with via QR) ──────────────────
    batch.execute('''
      CREATE TABLE companions (
        public_id      TEXT PRIMARY KEY,
        public_key     TEXT,
        display_name   TEXT NOT NULL,
        status         TEXT NOT NULL,           -- pending | accepted | blocked
        incoming       INTEGER NOT NULL DEFAULT 0, -- 1 = peer requested me (I can accept)
        added_at       INTEGER NOT NULL,
        last_synced_at INTEGER
      )
    ''');

    // ── Exercises (top-level synced object) ──────────────────────────
    batch.execute('''
      CREATE TABLE exercises (
        id           TEXT PRIMARY KEY,
        name         TEXT NOT NULL,
        -- Coarse region, derived from `muscle`. Kept as its own column because
        -- it is what a companion on a pre-v6 build reads off the sync payload.
        muscle_group TEXT NOT NULL,             -- Push | Pull | Legs | Core
        muscle       TEXT,                      -- primary group, e.g. 'chest'
        secondary    TEXT NOT NULL DEFAULT '',  -- csv, e.g. 'triceps,shoulders'
        muscle_confirmed INTEGER NOT NULL DEFAULT 0,
        unit         TEXT NOT NULL,             -- kg | bw
        owner_id     TEXT NOT NULL,
        updated_at   INTEGER NOT NULL,
        deleted      INTEGER NOT NULL DEFAULT 0,
        dirty        INTEGER NOT NULL DEFAULT 0
      )
    ''');
    batch.execute('CREATE INDEX idx_exercises_owner ON exercises(owner_id)');

    // ── Sessions (top-level synced object; atomic sync unit) ─────────
    batch.execute('''
      CREATE TABLE sessions (
        id         TEXT PRIMARY KEY,
        date       TEXT NOT NULL,               -- ISO yyyy-MM-dd
        title      TEXT NOT NULL,               -- derived: Push Day | Leg Day | …
        name       TEXT,                        -- user-given name; null = use title
        owner_id   TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted    INTEGER NOT NULL DEFAULT 0,
        dirty      INTEGER NOT NULL DEFAULT 0
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_sessions_owner_date ON sessions(owner_id, date)');

    // ── Entries / sets (children of a session; not independently synced)
    batch.execute('''
      CREATE TABLE entries (
        id          TEXT PRIMARY KEY,
        session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        exercise_id TEXT NOT NULL,
        position    INTEGER NOT NULL,
        owner_id    TEXT NOT NULL
      )
    ''');
    batch.execute('CREATE INDEX idx_entries_session ON entries(session_id)');

    batch.execute('''
      CREATE TABLE sets (
        id        TEXT PRIMARY KEY,
        entry_id  TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
        weight    REAL NOT NULL,
        reps      INTEGER NOT NULL,
        position  INTEGER NOT NULL,
        owner_id  TEXT NOT NULL
      )
    ''');
    batch.execute('CREATE INDEX idx_sets_entry ON sets(entry_id)');

    batch.execute(_dropsTable);
    batch.execute(_dropsIndex);

    // ── Per-companion sync cursors + server config (used by the relay) ─
    batch.execute('''
      CREATE TABLE sync_state (
        scope         TEXT PRIMARY KEY,         -- 'self' or a companion public_id
        server_url    TEXT,
        cursor        TEXT,
        event_cursor  TEXT,                     -- separate seq space to `cursor`
        session_token TEXT,
        updated_at    INTEGER
      )
    ''');

    // ── Device-local settings ────────────────────────────────────────
    batch.execute(_settingsTable);

    // ── Companion moments (outbound + already-announced) ─────────────
    batch.execute(_eventOutboxTable);
    batch.execute(_eventSeenTable);

    await batch.commit(noResult: true);
  }

  /// Release the handle. Only the background isolate needs this — the app's
  /// database lives as long as the app does.
  Future<void> close() => db.close();

  // ── Settings (device-local key/value) ──────────────────────────────
  Future<String?> getSetting(String key) async {
    final rows =
        await db.query('settings', where: 'key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) async {
    await db.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ── Identity ───────────────────────────────────────────────────────
  Future<Identity?> getIdentity() async {
    final rows = await db.query('identity', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Identity(
      publicId: r['public_id'] as String,
      publicKey: r['public_key'] as String,
      displayName: r['display_name'] as String?,
      createdAt: r['created_at'] as int,
    );
  }

  Future<void> setIdentity(Identity id) async {
    await db.insert(
      'identity',
      {
        'id': 1,
        'public_id': id.publicId,
        'public_key': id.publicKey,
        'display_name': id.displayName,
        'created_at': id.createdAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> setDisplayName(String name) async {
    await db.update('identity', {'display_name': name}, where: 'id = 1');
  }

  // ── Companions ───────────────────────────────────────────────────────
  Future<List<Companion>> getCompanions() async {
    final rows = await db.query('companions', orderBy: 'added_at DESC');
    return rows.map(_companionFromRow).toList();
  }

  Future<void> upsertCompanion(Companion c) async {
    await db.insert(
      'companions',
      {
        'public_id': c.publicId,
        'public_key': c.publicKey,
        'display_name': c.displayName,
        'status': c.status.name,
        'incoming': c.incoming ? 1 : 0,
        'added_at': c.addedAt,
        'last_synced_at': c.lastSyncedAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Reconcile a companion from the server's list, preserving the locally-known
  /// public key and added_at (the server doesn't return those).
  Future<void> mergeCompanionFromServer(
      String publicId, String displayName, CompanionStatus status, bool incoming) async {
    final existing = await db.query('companions',
        where: 'public_id = ?', whereArgs: [publicId], limit: 1);
    if (existing.isEmpty) {
      await db.insert('companions', {
        'public_id': publicId,
        'public_key': null,
        'display_name': displayName.isEmpty ? 'Companion' : displayName,
        'status': status.name,
        'incoming': incoming ? 1 : 0,
        'added_at': DateTime.now().millisecondsSinceEpoch,
      });
    } else {
      await db.update(
        'companions',
        {
          'display_name':
              displayName.isEmpty ? existing.first['display_name'] : displayName,
          'status': status.name,
          'incoming': incoming ? 1 : 0,
        },
        where: 'public_id = ?',
        whereArgs: [publicId],
      );
    }
  }

  Future<void> deleteCompanion(String publicId) async {
    await db.delete('companions', where: 'public_id = ?', whereArgs: [publicId]);
  }

  Companion _companionFromRow(Map<String, Object?> r) => Companion(
        publicId: r['public_id'] as String,
        publicKey: r['public_key'] as String?,
        displayName: r['display_name'] as String,
        status: CompanionStatus.values
            .byName(r['status'] as String? ?? 'pending'),
        incoming: (r['incoming'] as int? ?? 0) == 1,
        addedAt: r['added_at'] as int,
        lastSyncedAt: r['last_synced_at'] as int?,
      );

  // ── Exercises ─────────────────────────────────────────────────────────
  Future<List<Exercise>> getExercises(String ownerId) async {
    final rows = await db.query(
      'exercises',
      where: 'owner_id = ? AND deleted = 0',
      whereArgs: [ownerId],
      orderBy: 'name COLLATE NOCASE',
    );
    return rows.map(_exerciseFromRow).toList();
  }

  Future<void> upsertExercise(Exercise ex, String ownerId,
      {bool dirty = true}) async {
    await db.insert(
      'exercises',
      {
        'id': ex.id,
        'name': ex.name,
        'muscle_group': ex.region,
        'muscle': ex.muscle.id,
        'secondary': Muscle.encodeList(ex.secondary),
        'muscle_confirmed': ex.muscleConfirmed ? 1 : 0,
        'unit': ex.unit,
        'owner_id': ownerId,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'deleted': 0,
        'dirty': dirty ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Tombstone an exercise (kept for sync; hidden from the library + records).
  Future<void> deleteExercise(String exerciseId) async {
    await db.update(
      'exercises',
      {
        'deleted': 1,
        'dirty': 1,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [exerciseId],
    );
  }

  /// A row with no `muscle` is one a companion on a pre-v6 build wrote (our own
  /// rows are all backfilled at upgrade). Read it the same way the migration
  /// does — name first, coarse region as the fallback — and mark it unconfirmed.
  Exercise _exerciseFromRow(Map<String, Object?> r) {
    final name = r['name'] as String;
    final stored = Muscle.fromId(r['muscle'] as String?);
    if (stored == null) {
      final guess =
          MuscleMap.resolve(name, region: r['muscle_group'] as String?);
      return Exercise(
        id: r['id'] as String,
        name: name,
        muscle: guess.primary,
        secondary: guess.secondary,
        unit: r['unit'] as String,
        muscleConfirmed: false,
      );
    }
    return Exercise(
      id: r['id'] as String,
      name: name,
      muscle: stored,
      secondary: Muscle.parseList(r['secondary'] as String?),
      unit: r['unit'] as String,
      muscleConfirmed: (r['muscle_confirmed'] as int? ?? 0) == 1,
    );
  }

  // ── Sessions (assembled with their entries + sets) ────────────────────
  Future<List<Session>> getSessions(String ownerId) async {
    final sessionRows = await db.query(
      'sessions',
      where: 'owner_id = ? AND deleted = 0',
      whereArgs: [ownerId],
      orderBy: 'date DESC',
    );
    if (sessionRows.isEmpty) return [];

    // Pull all entries + sets for this owner in two queries, then stitch.
    final entryRows = await db.query(
      'entries',
      where: 'owner_id = ?',
      whereArgs: [ownerId],
      orderBy: 'position ASC',
    );
    final setRows = await db.query(
      'sets',
      where: 'owner_id = ?',
      whereArgs: [ownerId],
      orderBy: 'position ASC',
    );
    final dropRows = await db.query(
      'drops',
      where: 'owner_id = ?',
      whereArgs: [ownerId],
      orderBy: 'position ASC',
    );

    final dropsBySet = <String, List<SetDrop>>{};
    for (final d in dropRows) {
      (dropsBySet[d['set_id'] as String] ??= []).add(SetDrop(
        id: d['id'] as String,
        weight: (d['weight'] as num).toDouble(),
        reps: d['reps'] as int,
      ));
    }

    final setsByEntry = <String, List<WorkoutSet>>{};
    for (final s in setRows) {
      final id = s['id'] as String;
      (setsByEntry[s['entry_id'] as String] ??= []).add(WorkoutSet(
        id: id,
        weight: (s['weight'] as num).toDouble(),
        reps: s['reps'] as int,
        drops: dropsBySet[id] ?? const [],
      ));
    }

    final entriesBySession = <String, List<Entry>>{};
    for (final e in entryRows) {
      final id = e['id'] as String;
      (entriesBySession[e['session_id'] as String] ??= []).add(Entry(
        id: id,
        exerciseId: e['exercise_id'] as String,
        sets: setsByEntry[id] ?? const [],
      ));
    }

    return sessionRows
        .map((s) => Session(
              id: s['id'] as String,
              date: s['date'] as String,
              title: s['title'] as String,
              name: normalizeSessionName(s['name'] as String?),
              entries: entriesBySession[s['id'] as String] ?? const [],
            ))
        .toList();
  }

  /// Persist a whole session subtree atomically (replacing any prior children).
  Future<void> upsertSessionTree(Session s, String ownerId,
      {bool dirty = true}) async {
    await db.transaction((txn) async {
      await txn.insert(
        'sessions',
        {
          'id': s.id,
          'date': s.date,
          'title': s.title,
          'name': s.name,
          'owner_id': ownerId,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
          'deleted': 0,
          'dirty': dirty ? 1 : 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      // Replace children wholesale (cascade clears sets under old entries).
      await txn.delete('entries', where: 'session_id = ?', whereArgs: [s.id]);
      for (var ei = 0; ei < s.entries.length; ei++) {
        final e = s.entries[ei];
        await txn.insert('entries', {
          'id': e.id,
          'session_id': s.id,
          'exercise_id': e.exerciseId,
          'position': ei,
          'owner_id': ownerId,
        });
        for (var si = 0; si < e.sets.length; si++) {
          final set = e.sets[si];
          await txn.insert('sets', {
            'id': set.id,
            'entry_id': e.id,
            'weight': set.weight,
            'reps': set.reps,
            'position': si,
            'owner_id': ownerId,
          });
          for (var di = 0; di < set.drops.length; di++) {
            final drop = set.drops[di];
            await txn.insert('drops', {
              'id': drop.id,
              'set_id': set.id,
              'weight': drop.weight,
              'reps': drop.reps,
              'position': di,
              'owner_id': ownerId,
            });
          }
        }
      }
    });
  }

  /// Tombstone a session (kept for sync; children cascade-deleted).
  Future<void> deleteSession(String sessionId) async {
    await db.transaction((txn) async {
      txn.update(
        'sessions',
        {
          'deleted': 1,
          'dirty': 1,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [sessionId],
      );
      await txn.delete('entries', where: 'session_id = ?', whereArgs: [sessionId]);
    });
  }

  Future<bool> isEmpty(String ownerId) async {
    final count = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM sessions WHERE owner_id = ?',
      [ownerId],
    ));
    return (count ?? 0) == 0;
  }

  // ── Sync: outbound (dirty rows → push) ────────────────────────────────
  Future<List<Map<String, Object?>>> getDirtyExercises(String ownerId) =>
      db.query('exercises', where: 'owner_id = ? AND dirty = 1', whereArgs: [ownerId]);

  Future<List<Map<String, Object?>>> getDirtySessions(String ownerId) =>
      db.query('sessions', where: 'owner_id = ? AND dirty = 1', whereArgs: [ownerId]);

  Future<List<Map<String, Object?>>> getEntryRows(String sessionId) => db.query(
      'entries',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'position ASC');

  Future<List<Map<String, Object?>>> getSetRows(String entryId) => db.query('sets',
      where: 'entry_id = ?', whereArgs: [entryId], orderBy: 'position ASC');

  Future<List<Map<String, Object?>>> getDropRows(String setId) => db.query('drops',
      where: 'set_id = ?', whereArgs: [setId], orderBy: 'position ASC');

  Future<void> clearDirty(String table, List<String> ids) async {
    if (ids.isEmpty) return;
    assert(table == 'sessions' || table == 'exercises');
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.rawUpdate('UPDATE $table SET dirty = 0 WHERE id IN ($placeholders)', ids);
  }

  // ── Sync: inbound (apply pulled companion changes; LWW by updated_at) ──
  Future<void> applyRemoteExercise(
    String ownerId,
    Map<String, dynamic> p, {
    required int updatedAt,
    required bool deleted,
  }) async {
    final id = p['id'] as String;
    if (await _isStale('exercises', id, updatedAt)) return;

    // `muscle` is absent from anything a pre-v6 peer sends; fall back to the
    // dictionary over the name, using their coarse `group` as the tiebreak.
    final name = (p['name'] as String?) ?? '';
    final sent = Muscle.fromId(p['muscle'] as String?);
    final MuscleGuess resolved = sent != null
        ? MuscleGuess(sent, secondary: Muscle.parseList(p['secondary'] as String?))
        : MuscleMap.resolve(name, region: p['group'] as String?);
    final muscle = resolved.primary;

    await db.insert(
      'exercises',
      {
        'id': id,
        'name': name,
        'muscle_group': muscle.region,
        'muscle': muscle.id,
        'secondary': Muscle.encodeList(resolved.secondary),
        // A companion's library isn't ours to tidy — never surface their rows
        // in our review card, whichever way we resolved the group.
        'muscle_confirmed': 1,
        'unit': p['unit'] ?? 'kg',
        'owner_id': ownerId,
        'updated_at': updatedAt,
        'deleted': deleted ? 1 : 0,
        'dirty': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> applyRemoteSession(
    String ownerId,
    Map<String, dynamic> p, {
    required int updatedAt,
    required bool deleted,
  }) async {
    final id = p['id'] as String;
    if (await _isStale('sessions', id, updatedAt)) return;
    await db.transaction((txn) async {
      await txn.insert(
        'sessions',
        {
          'id': id,
          'date': p['date'] ?? '',
          'title': p['title'] ?? '',
          // Absent on payloads from a build that predates workout names.
          'name': normalizeSessionName(p['name'] as String?),
          'owner_id': ownerId,
          'updated_at': updatedAt,
          'deleted': deleted ? 1 : 0,
          'dirty': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.delete('entries', where: 'session_id = ?', whereArgs: [id]);
      if (deleted) return;
      final entries = (p['entries'] as List?) ?? const [];
      for (var ei = 0; ei < entries.length; ei++) {
        final e = entries[ei] as Map<String, dynamic>;
        final eid = e['id'] as String;
        await txn.insert('entries', {
          'id': eid,
          'session_id': id,
          'exercise_id': e['exercise_id'],
          'position': ei,
          'owner_id': ownerId,
        });
        final sets = (e['sets'] as List?) ?? const [];
        for (var si = 0; si < sets.length; si++) {
          final s = sets[si] as Map<String, dynamic>;
          final sid = s['id'];
          await txn.insert('sets', {
            'id': sid,
            'entry_id': eid,
            'weight': (s['weight'] as num).toDouble(),
            'reps': s['reps'],
            'position': si,
            'owner_id': ownerId,
          });
          // Absent on payloads from an app version that predates drop sets;
          // those sets simply arrive as plain sets.
          final drops = (s['drops'] as List?) ?? const [];
          for (var di = 0; di < drops.length; di++) {
            final d = drops[di] as Map<String, dynamic>;
            await txn.insert('drops', {
              'id': d['id'],
              'set_id': sid,
              'weight': (d['weight'] as num).toDouble(),
              'reps': d['reps'],
              'position': di,
              'owner_id': ownerId,
            });
          }
        }
      }
    });
  }

  /// True if a stored row is at least as new as [updatedAt] (skip the apply).
  Future<bool> _isStale(String table, String id, int updatedAt) async {
    final rows = await db.query(table,
        columns: ['updated_at'], where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isNotEmpty && (rows.first['updated_at'] as int) >= updatedAt;
  }

  // ── Sync state (server url / token / cursor for the 'self' scope) ─────
  Future<SyncState> getSelfSyncState() async {
    final rows = await db
        .query('sync_state', where: 'scope = ?', whereArgs: ['self'], limit: 1);
    if (rows.isEmpty) return const SyncState();
    final r = rows.first;
    return SyncState(
      serverUrl: r['server_url'] as String?,
      token: r['session_token'] as String?,
      cursor: int.tryParse((r['cursor'] as String?) ?? '') ?? 0,
      eventCursor: int.tryParse((r['event_cursor'] as String?) ?? '') ?? 0,
    );
  }

  Future<void> _setSyncField(String column, Object? value) async {
    await db.insert('sync_state', {'scope': 'self'},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.update('sync_state',
        {column: value, 'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'scope = ?', whereArgs: ['self']);
  }

  Future<void> setServerUrl(String url) => _setSyncField('server_url', url);
  Future<void> setSyncToken(String? token) => _setSyncField('session_token', token);
  Future<void> setSyncCursor(int cursor) =>
      _setSyncField('cursor', cursor.toString());
  Future<void> setEventCursor(int cursor) =>
      _setSyncField('event_cursor', cursor.toString());

  // ── Companion moments: outbox ─────────────────────────────────────────

  /// Queue one of my moments for the next publish.
  Future<void> enqueueEvent({
    required String id,
    required String kind,
    required String payloadJson,
    required int createdAt,
  }) async {
    await db.insert(
      'event_outbox',
      {
        'id': id,
        'kind': kind,
        'payload': payloadJson,
        'created_at': createdAt,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<Map<String, Object?>>> getOutboxEvents() =>
      db.query('event_outbox', orderBy: 'created_at ASC');

  Future<void> clearOutboxEvents(List<String> ids) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.rawDelete('DELETE FROM event_outbox WHERE id IN ($placeholders)', ids);
  }

  /// Drop queued moments that have gone stale. A "started a workout" that
  /// surfaces the next morning is not late news, it is wrong news — better to
  /// say nothing than to announce a session that finished hours ago.
  Future<void> pruneOutboxEvents(int olderThanMs) async {
    await db.delete('event_outbox',
        where: 'created_at <= ?', whereArgs: [olderThanMs]);
  }

  // ── Companion moments: already-announced ledger ───────────────────────

  /// Claims [ids] as announced and returns the subset that was *not* already
  /// claimed — the ones this device still owes the user a notification for.
  ///
  /// Insert-then-report rather than check-then-insert: the foreground app and
  /// the background worker read the same feed from separate isolates, and only
  /// letting the row's primary key arbitrate keeps one moment to one alert.
  Future<Set<String>> claimUnseenEvents(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final now = DateTime.now().millisecondsSinceEpoch;
    final fresh = <String>{};
    await db.transaction((txn) async {
      for (final id in ids) {
        final n = await txn.insert(
          'event_seen',
          {'id': id, 'seen_at': now},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        // sqflite returns 0 for a row `ignore` skipped, and the new rowid
        // otherwise — so a non-zero result *is* the claim.
        if (n != 0) fresh.add(id);
      }
    });
    return fresh;
  }

  Future<void> pruneSeenEvents(int olderThanMs) async {
    await db.delete('event_seen', where: 'seen_at <= ?', whereArgs: [olderThanMs]);
  }
}

/// The 'self' row of `sync_state`: where/how this device talks to the server.
class SyncState {
  final String? serverUrl;
  final String? token;
  final int cursor;

  /// Position in the *event* feed. Its own sequence space — moments and object
  /// changes are separate streams on the relay and advance independently.
  final int eventCursor;

  const SyncState({
    this.serverUrl,
    this.token,
    this.cursor = 0,
    this.eventCursor = 0,
  });
}
