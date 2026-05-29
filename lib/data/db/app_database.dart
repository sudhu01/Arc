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

class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const _dbName = 'arc.db';
  static const _version = 1;

  /// Open the database. [factory] and [path] are injectable so tests can run
  /// against an in-memory sqflite_common_ffi database.
  static Future<AppDatabase> open({DatabaseFactory? factory, String? path}) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), _dbName);
    final database = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: _version,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: _onCreate,
      ),
    );
    return AppDatabase._(database);
  }

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
        added_at       INTEGER NOT NULL,
        last_synced_at INTEGER
      )
    ''');

    // ── Exercises (top-level synced object) ──────────────────────────
    batch.execute('''
      CREATE TABLE exercises (
        id           TEXT PRIMARY KEY,
        name         TEXT NOT NULL,
        muscle_group TEXT NOT NULL,             -- Push | Pull | Legs | Core
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
        title      TEXT NOT NULL,
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

    // ── Per-companion sync cursors + server config (used by the relay) ─
    batch.execute('''
      CREATE TABLE sync_state (
        scope         TEXT PRIMARY KEY,         -- 'self' or a companion public_id
        server_url    TEXT,
        cursor        TEXT,
        session_token TEXT,
        updated_at    INTEGER
      )
    ''');

    await batch.commit(noResult: true);
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
        'added_at': c.addedAt,
        'last_synced_at': c.lastSyncedAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
        'muscle_group': ex.group,
        'unit': ex.unit,
        'owner_id': ownerId,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'deleted': 0,
        'dirty': dirty ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Exercise _exerciseFromRow(Map<String, Object?> r) => Exercise(
        id: r['id'] as String,
        name: r['name'] as String,
        group: r['muscle_group'] as String,
        unit: r['unit'] as String,
      );

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

    final setsByEntry = <String, List<WorkoutSet>>{};
    for (final s in setRows) {
      (setsByEntry[s['entry_id'] as String] ??= []).add(WorkoutSet(
        id: s['id'] as String,
        weight: (s['weight'] as num).toDouble(),
        reps: s['reps'] as int,
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
              entries: entriesBySession[s['id'] as String] ?? const [],
            ))
        .toList();
  }

  /// Persist a whole session subtree atomically (replacing any prior children).
  Future<void> upsertSessionTree(Session s, String ownerId,
      {bool dirty = true}) async {
    await db.transaction((txn) async {
      txn.insert(
        'sessions',
        {
          'id': s.id,
          'date': s.date,
          'title': s.title,
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
        txn.insert('entries', {
          'id': e.id,
          'session_id': s.id,
          'exercise_id': e.exerciseId,
          'position': ei,
          'owner_id': ownerId,
        });
        for (var si = 0; si < e.sets.length; si++) {
          final set = e.sets[si];
          txn.insert('sets', {
            'id': set.id,
            'entry_id': e.id,
            'weight': set.weight,
            'reps': set.reps,
            'position': si,
            'owner_id': ownerId,
          });
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
}
