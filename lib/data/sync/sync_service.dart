// Orchestrates companion sync against the Arc relay server:
//   1. register + authenticate via IdentityService (challenge → sign → token)
//   2. PUSH local `dirty` rows (sessions as subtrees, exercises), clear dirty
//   3. PULL accepted companions' changes, apply with owner_id = companion,
//      persist the cursor in sync_state
//   4. refresh the companion graph (statuses + incoming requests)
//
// The device SQLite stays the source of truth; the server is a dumb relay.

import '../db/app_database.dart';
import '../identity/identity_service.dart';
import '../models.dart';
import 'sync_api.dart';

/// Dev default. Override with `--dart-define=ARC_SERVER_URL=https://…`.
/// Set to the host PC's LAN IP so physical devices can reach the relay
/// (`10.0.2.2` only works from the Android emulator, where it aliases the
/// host's loopback).
const String kDefaultArcServerUrl =
    String.fromEnvironment('ARC_SERVER_URL', defaultValue: 'http://192.168.88.111:8080');

typedef SyncApiFactory = SyncApi Function(String baseUrl);

class SyncResult {
  final int pushed;
  final int pulled;
  const SyncResult({required this.pushed, required this.pulled});
}

class SyncService {
  SyncService({
    required AppDatabase db,
    required IdentityService identity,
    SyncApiFactory? apiFactory,
    this.defaultBaseUrl = kDefaultArcServerUrl,
  })  : _db = db,
        _identity = identity,
        _apiFactory = apiFactory ?? ((url) => SyncApi(baseUrl: url));

  final AppDatabase _db;
  final IdentityService _identity;
  final SyncApiFactory _apiFactory;
  final String defaultBaseUrl;

  SyncApi? _api;
  String? _apiUrl;

  String get _me => _identity.identity.publicId;

  Future<SyncApi> _resolveApi() async {
    final st = await _db.getSelfSyncState();
    final url = (st.serverUrl != null && st.serverUrl!.isNotEmpty)
        ? st.serverUrl!
        : defaultBaseUrl;
    if (_api == null || _apiUrl != url) {
      _api?.close();
      _api = _apiFactory(url);
      _apiUrl = url;
    }
    return _api!;
  }

  // ── Public API ────────────────────────────────────────────────────

  /// Push local changes, pull companions', refresh the companion graph.
  Future<SyncResult> syncNow() async {
    final api = await _resolveApi();
    return _authed(api, (token) async {
      final pushed = await _push(api, token);
      final pulled = await _pull(api, token);
      await _refreshCompanions(api, token);
      return SyncResult(pushed: pushed, pulled: pulled);
    });
  }

  /// Re-download this device's *own* change feed from the relay and apply it as
  /// local data (owner = me). Used after restoring an identity from a recovery
  /// phrase on a fresh install. Returns the number of objects restored.
  ///
  /// Unlike [_pull] this walks a private cursor from 0 and never advances the
  /// companion `sync_state.cursor`, so a subsequent [syncNow] still pulls
  /// companions' history in full.
  Future<int> restoreFromServer() async {
    final api = await _resolveApi();
    return _authed(api, (token) async {
      // Bring the profile name back (the change feed carries only workouts).
      final me = await api.me(token);
      final name = (me['display_name'] as String?) ?? '';
      if (name.isNotEmpty) await _db.setDisplayName(name);

      var cursor = 0;
      var applied = 0;
      while (true) {
        final resp = await api.pullSelf(token, cursor);
        final changes = (resp['changes'] as List?) ?? const [];
        for (final raw in changes) {
          final c = (raw as Map).cast<String, dynamic>();
          final type = c['object_type'] as String;
          final payload = (c['payload'] as Map?)?.cast<String, dynamic>() ?? {};
          final updatedAt = (c['updated_at'] as num).toInt();
          final deleted = c['deleted'] == true;
          if (type == 'exercise') {
            await _db.applyRemoteExercise(_me, payload,
                updatedAt: updatedAt, deleted: deleted);
          } else if (type == 'session') {
            await _db.applyRemoteSession(_me, payload,
                updatedAt: updatedAt, deleted: deleted);
          }
          applied++;
        }
        final newCursor = (resp['cursor'] as num?)?.toInt() ?? cursor;
        if (changes.isEmpty || newCursor == cursor) break; // caught up
        cursor = newCursor;
      }
      return applied;
    });
  }

  Future<void> requestCompanion(String peerId) async {
    final api = await _resolveApi();
    await _authed(api, (t) => api.requestCompanion(t, peerId));
  }

  Future<void> acceptCompanion(String peerId) async {
    final api = await _resolveApi();
    await _authed(api, (t) => api.acceptCompanion(t, peerId));
  }

  Future<void> blockCompanion(String peerId) async {
    final api = await _resolveApi();
    await _authed(api, (t) => api.blockCompanion(t, peerId));
  }

  Future<void> deleteCompanion(String peerId) async {
    final api = await _resolveApi();
    await _authed(api, (t) => api.deleteCompanion(t, peerId));
  }

  // ── Auth ─────────────────────────────────────────────────────────

  /// Run [op] with a valid token; on 401, re-authenticate once and retry.
  Future<T> _authed<T>(SyncApi api, Future<T> Function(String token) op) async {
    var token = await _ensureToken(api);
    try {
      return await op(token);
    } on SyncException catch (e) {
      if (!e.isUnauthorized) rethrow;
      token = await _authenticate(api);
      return await op(token);
    }
  }

  Future<String> _ensureToken(SyncApi api) async {
    final st = await _db.getSelfSyncState();
    if (st.token != null && st.token!.isNotEmpty) return st.token!;
    return _authenticate(api);
  }

  Future<String> _authenticate(SyncApi api) async {
    final id = _identity.identity;
    // Register is idempotent; the self-signature proves key ownership.
    await api.register(
      publicId: id.publicId,
      publicKey: id.publicKey,
      displayName: id.displayName ?? '',
      sig: await _identity.signB64u(id.publicId),
    );
    final nonce = await api.challenge(id.publicId);
    final signature = await _identity.signB64u(nonce);
    final token =
        await api.verify(publicId: id.publicId, nonce: nonce, signature: signature);
    await _db.setSyncToken(token);
    return token;
  }

  // ── Push ─────────────────────────────────────────────────────────

  Future<int> _push(SyncApi api, String token) async {
    final changes = <Map<String, dynamic>>[];
    final exIds = <String>[];
    final sesIds = <String>[];

    for (final ex in await _db.getDirtyExercises(_me)) {
      exIds.add(ex['id'] as String);
      changes.add({
        'object_type': 'exercise',
        'object_id': ex['id'],
        'payload': {
          'id': ex['id'],
          'name': ex['name'],
          'group': ex['muscle_group'],
          'unit': ex['unit'],
        },
        'deleted': (ex['deleted'] as int) == 1,
        'updated_at': ex['updated_at'],
      });
    }

    for (final s in await _db.getDirtySessions(_me)) {
      final sid = s['id'] as String;
      sesIds.add(sid);
      final deleted = (s['deleted'] as int) == 1;
      final payload = <String, dynamic>{
        'id': sid,
        'date': s['date'],
        'title': s['title'],
      };
      if (!deleted) {
        final entries = <Map<String, dynamic>>[];
        for (final e in await _db.getEntryRows(sid)) {
          final eid = e['id'] as String;
          final sets = [
            for (final set in await _db.getSetRows(eid))
              {'id': set['id'], 'weight': set['weight'], 'reps': set['reps']}
          ];
          entries.add({'id': eid, 'exercise_id': e['exercise_id'], 'sets': sets});
        }
        payload['entries'] = entries;
      }
      changes.add({
        'object_type': 'session',
        'object_id': sid,
        'payload': payload,
        'deleted': deleted,
        'updated_at': s['updated_at'],
      });
    }

    if (changes.isEmpty) return 0;
    await api.push(token, changes);
    await _db.clearDirty('exercises', exIds);
    await _db.clearDirty('sessions', sesIds);
    return changes.length;
  }

  // ── Pull ─────────────────────────────────────────────────────────

  Future<int> _pull(SyncApi api, String token) async {
    var cursor = (await _db.getSelfSyncState()).cursor;
    var applied = 0;
    while (true) {
      final resp = await api.pull(token, cursor);
      final changes = (resp['changes'] as List?) ?? const [];
      for (final raw in changes) {
        final c = (raw as Map).cast<String, dynamic>();
        final owner = c['owner_id'] as String;
        final type = c['object_type'] as String;
        final payload = (c['payload'] as Map?)?.cast<String, dynamic>() ?? {};
        final updatedAt = (c['updated_at'] as num).toInt();
        final deleted = c['deleted'] == true;
        if (type == 'exercise') {
          await _db.applyRemoteExercise(owner, payload,
              updatedAt: updatedAt, deleted: deleted);
        } else if (type == 'session') {
          await _db.applyRemoteSession(owner, payload,
              updatedAt: updatedAt, deleted: deleted);
        }
        applied++;
      }
      final newCursor = (resp['cursor'] as num?)?.toInt() ?? cursor;
      if (newCursor != cursor) {
        cursor = newCursor;
        await _db.setSyncCursor(cursor);
      }
      if (changes.isEmpty) break; // caught up
    }
    return applied;
  }

  // ── Companions ───────────────────────────────────────────────────

  Future<void> _refreshCompanions(SyncApi api, String token) async {
    final list = await api.listCompanions(token);
    for (final raw in list) {
      final c = (raw as Map).cast<String, dynamic>();
      await _db.mergeCompanionFromServer(
        c['peer_id'] as String,
        (c['display_name'] as String?) ?? '',
        _statusFrom(c['status'] as String?),
        c['incoming'] == true,
      );
    }
  }

  CompanionStatus _statusFrom(String? s) => switch (s) {
        'accepted' => CompanionStatus.accepted,
        'blocked' => CompanionStatus.blocked,
        _ => CompanionStatus.pending,
      };
}
