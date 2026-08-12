// Orchestrates companion sync against the Arc relay server:
//   1. register + authenticate via IdentityService (challenge → sign → token)
//   2. PUSH local `dirty` rows (sessions as subtrees, exercises), clear dirty
//   3. PULL accepted companions' changes, apply with owner_id = companion,
//      persist the cursor in sync_state
//   4. refresh the companion graph (statuses + incoming requests)
//
// The device SQLite stays the source of truth; the server is a dumb relay.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../db/app_database.dart';
import '../identity/identity_service.dart';
import '../models.dart';
import '../notify/companion_event.dart';
import 'sync_api.dart';

/// Public default: the relay is exposed over HTTPS through an ngrok tunnel
/// (agent runs on the host, auto-starts at logon), so any device reaches it
/// with no LAN/IP/Tailscale setup. Override with
/// `--dart-define=ARC_SERVER_URL=https://…` (e.g. a LAN IP for local dev).
const String kDefaultArcServerUrl = String.fromEnvironment(
  'ARC_SERVER_URL',
  defaultValue: 'https://storeyed-paz-undeadened.ngrok-free.dev',
);

typedef SyncApiFactory = SyncApi Function(String baseUrl);

class SyncResult {
  final int pushed;
  final int pulled;
  const SyncResult({required this.pushed, required this.pulled});
}

/// Nothing older than this is worth trying to publish. A "started a workout"
/// that has sat in the outbox all night is not late, it is false — the phone
/// drops it rather than announcing a session that ended hours ago. Generous
/// enough to cover a long session in a signal-dead basement.
const Duration kOutboxTtl = Duration(hours: 6);

/// One page of companions' moments, and where the feed stood when it was read.
class EventBatch {
  final List<CompanionEvent> events;
  final int cursor;
  const EventBatch({required this.events, required this.cursor});
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

  /// Push local changes, (re)send pending pairing requests, pull companions',
  /// refresh the companion graph.
  Future<SyncResult> syncNow() async {
    final api = await _resolveApi();
    return _authed(api, (token) async {
      final pushed = await _push(api, token);
      final pulled = await _pull(api, token);
      await _publishEvents(api, token);
      await _pushPendingRequests(api, token);
      await _refreshCompanions(api, token);
      return SyncResult(pushed: pushed, pulled: pulled);
    });
  }

  /// Drain the event outbox to the relay.
  ///
  /// Deliberately isolated from the rest of [syncNow]: a workout beacon that
  /// cannot be published must never take the workout data down with it, and a
  /// failed publish leaves the rows in place for the next sync — the server
  /// dedupes on the event id, so a retry costs nothing.
  Future<void> _publishEvents(SyncApi api, String token) async {
    await _db.pruneOutboxEvents(
        DateTime.now().subtract(kOutboxTtl).millisecondsSinceEpoch);
    final rows = await _db.getOutboxEvents();
    if (rows.isEmpty) return;

    final wire = <Map<String, dynamic>>[];
    final ids = <String>[];
    for (final r in rows) {
      final id = r['id'] as String;
      ids.add(id);
      wire.add({
        'id': id,
        'kind': r['kind'],
        'payload': _decodePayload(r['payload'] as String?),
        'created_at': r['created_at'],
      });
    }
    await api.publishEvents(token, wire);
    await _db.clearOutboxEvents(ids);
  }

  static Map<String, dynamic> _decodePayload(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final v = jsonDecode(raw);
      return v is Map<String, dynamic> ? v : const {};
    } catch (_) {
      return const {};
    }
  }

  /// Fetch companions' moments past the stored cursor.
  ///
  /// Run on its own rather than inside [syncNow] because it is the *only* thing
  /// the background worker needs: pulling a week of session subtrees to find out
  /// that someone benched 100 kg would waste a doze-window wakeup.
  ///
  /// The cursor is deliberately *not* advanced here — [commitEventCursor] is,
  /// once the caller has actually taken responsibility for the batch. Advancing
  /// on receipt would mean a crash between the pull and the notification lost
  /// those moments for good; advancing after means the worst case is re-pulling
  /// events the ledger then recognises and drops.
  Future<EventBatch> pullEvents() async {
    final api = await _resolveApi();
    return _authed(api, (token) async {
      final cursor = (await _db.getSelfSyncState()).eventCursor;
      final out = <CompanionEvent>[];
      // One page is plenty: the relay caps a response at 500 and the feed is
      // swept weekly, so a device that has been away simply resumes from the
      // newest cursor it is handed.
      final resp = await api.pullEvents(token, cursor);
      for (final raw in (resp['events'] as List?) ?? const []) {
        try {
          final e = CompanionEvent.fromWire((raw as Map).cast<String, dynamic>());
          if (e != null) out.add(e);
        } catch (err) {
          debugPrint('Arc events: skipped an event: $err');
        }
      }
      return EventBatch(
        events: out,
        cursor: (resp['cursor'] as num?)?.toInt() ?? cursor,
      );
    });
  }

  /// Mark a pulled batch as dealt with.
  Future<void> commitEventCursor(int cursor) async {
    if (cursor <= (await _db.getSelfSyncState()).eventCursor) return;
    await _db.setEventCursor(cursor);
  }

  /// Hand the relay a push token so it can wake this device rather than wait
  /// for it to poll. Best-effort: push is an accelerator, never the delivery.
  Future<void> registerPushToken(String deviceToken) async {
    final api = await _resolveApi();
    await _authed(api, (t) => api.registerDevice(t, deviceToken));
  }

  /// Re-send any still-outstanding outbound pairing requests. Scanning a QR
  /// fires the request immediately, but that lone call can fail (the peer or
  /// server briefly unreachable, or the peer not yet registered) — and nothing
  /// else would retry it, so the request would be silently lost while the
  /// scanner sees a paired contact. Reconciling here on every sync makes
  /// pairing self-healing. The server's request endpoint is idempotent
  /// (ON CONFLICT DO NOTHING; reciprocal pending auto-accepts), so re-sending
  /// an already-known or already-accepted edge is harmless.
  Future<void> _pushPendingRequests(SyncApi api, String token) async {
    for (final c in await _db.getCompanions()) {
      // My own outgoing request still awaiting the peer's acceptance.
      if (c.status == CompanionStatus.pending && !c.incoming) {
        await api.requestCompanion(token, c.publicId);
      }
    }
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
          // Isolate each change: one malformed/unapplyable object must never
          // abort the whole restore and silently drop everything after it.
          try {
            final c = (raw as Map).cast<String, dynamic>();
            final type = c['object_type'] as String;
            final payload =
                (c['payload'] as Map?)?.cast<String, dynamic>() ?? {};
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
          } catch (e) {
            debugPrint('Arc restore: skipped a change: $e');
          }
        }
        final newCursor = (resp['cursor'] as num?)?.toInt() ?? cursor;
        if (changes.isEmpty || newCursor == cursor) break; // caught up
        cursor = newCursor;
      }
      return applied;
    });
  }

  /// Send a pairing request; returns `pending` or `accepted`. See
  /// [SyncApi.requestCompanion] for what [peerKey] and [strict] buy you.
  Future<String> requestCompanion(
    String peerId, {
    String? peerKey,
    bool strict = false,
  }) async {
    final api = await _resolveApi();
    return _authed(
        api, (t) => api.requestCompanion(t, peerId, peerKey: peerKey, strict: strict));
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
          // `group` is the coarse Push/Pull/Legs/Core region and stays first-
          // class: it is the only muscle signal a peer on a pre-v6 build can
          // read, and it is derived from `muscle` so the two never disagree.
          'group': ex['muscle_group'],
          'muscle': ex['muscle'],
          if ((ex['secondary'] as String?)?.isNotEmpty ?? false)
            'secondary': ex['secondary'],
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
        // Only carried when the workout actually has one, so an unnamed
        // session's payload stays identical to what earlier versions pushed.
        if (s['name'] != null) 'name': s['name'],
        // Same rule for the note: carried only when there is one. A peer on a
        // build without notes drops the key and the workout is unaffected.
        if (s['notes'] != null) 'notes': s['notes'],
      };
      if (!deleted) {
        final entries = <Map<String, dynamic>>[];
        for (final e in await _db.getEntryRows(sid)) {
          final eid = e['id'] as String;
          final sets = <Map<String, dynamic>>[];
          for (final set in await _db.getSetRows(eid)) {
            final payloadSet = <String, dynamic>{
              'id': set['id'],
              'weight': set['weight'],
              'reps': set['reps'],
            };
            // Only carried when the set actually has drops, so a plain set's
            // payload stays byte-identical to what earlier versions pushed.
            final drops = await _db.getDropRows(set['id'] as String);
            if (drops.isNotEmpty) {
              payloadSet['drops'] = [
                for (final d in drops)
                  {'id': d['id'], 'weight': d['weight'], 'reps': d['reps']}
              ];
            }
            sets.add(payloadSet);
          }
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
        // Isolate each change so one bad companion object can't abort the pull.
        try {
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
        } catch (e) {
          debugPrint('Arc pull: skipped a change: $e');
        }
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
