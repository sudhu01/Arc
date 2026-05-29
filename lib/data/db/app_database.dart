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
  static const _version = 2;

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
        onUpgrade: _onUpgrade,
      ),
    );
    return AppDatabase._(database);
  }

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // v2: track whether a pending companion request is incoming (peer asked me).
    if (oldVersion < 2) {
      await db.execute(
          'ALTER TABLE companions ADD COLUMN incoming INTEGER NOT NULL DEFAULT 0');
    }
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
    await db.insert(
      'exercises',
      {
        'id': id,
        'name': p['name'] ?? '',
        'muscle_group': p['group'] ?? '',
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
      txn.insert(
        'sessions',
        {
          'id': id,
          'date': p['date'] ?? '',
          'title': p['title'] ?? '',
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
        txn.insert('entries', {
          'id': eid,
          'session_id': id,
          'exercise_id': e['exercise_id'],
          'position': ei,
          'owner_id': ownerId,
        });
        final sets = (e['sets'] as List?) ?? const [];
        for (var si = 0; si < sets.length; si++) {
          final s = sets[si] as Map<String, dynamic>;
          txn.insert('sets', {
            'id': s['id'],
            'entry_id': eid,
            'weight': (s['weight'] as num).toDouble(),
            'reps': s['reps'],
            'position': si,
            'owner_id': ownerId,
          });
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
}

/// The 'self' row of `sync_state`: where/how this device talks to the server.
class SyncState {
  final String? serverUrl;
  final String? token;
  final int cursor;
  const SyncState({this.serverUrl, this.token, this.cursor = 0});
}
