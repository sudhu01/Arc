import 'dart:convert';

import 'package:arc/data/companion_data.dart';
import 'package:arc/data/db/app_database.dart';
import 'package:arc/data/identity/identity_service.dart';
import 'package:arc/data/models.dart';
import 'package:arc/data/store.dart';
import 'package:arc/data/sync/sync_api.dart';
import 'package:arc/data/sync/sync_service.dart';
import 'package:arc/main.dart';
import 'package:arc/sheets/companion_progress_sheet.dart';
import 'package:arc/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// In-memory [SecretStore] for tests (no platform Keystore available).
class FakeSecretStore implements SecretStore {
  final _map = <String, String>{};
  @override
  Future<String?> read(String key) async => _map[key];
  @override
  Future<void> write(String key, String value) async => _map[key] = value;
}

SyncService _noopSync(AppDatabase db, IdentityService identity) =>
    SyncService(db: db, identity: identity);

Future<ArcStore> _bootStore() async {
  final db = await AppDatabase.open(
    factory: databaseFactoryFfi,
    path: inMemoryDatabasePath,
  );
  final identity = IdentityService(secrets: FakeSecretStore());
  await identity.ensure(db);
  final store = ArcStore(db: db, identity: identity, sync: _noopSync(db, identity));
  await store.init();
  return store;
}

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('Arc app boots to the dashboard', (tester) async {
    // Boot the SQLite/identity backend in the real async zone — the ffi
    // database runs in a background isolate that testWidgets' fake clock
    // would otherwise never pump.
    final store = await tester.runAsync(_bootStore);
    await tester.pumpWidget(ArcAppRoot(store: store!));
    await tester.pump();

    // A brand-new account is empty: date header + the get-started empty state.
    expect(find.text('Fri, May 29'), findsOneWidget);
    expect(find.text('No workouts yet'), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('identity: stable public id + sign/verify round-trip', () async {
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    final secrets = FakeSecretStore();
    final svc = IdentityService(secrets: secrets);
    final id = await svc.ensure(db);

    expect(id.publicId, isNotEmpty);
    final again = await IdentityService(secrets: secrets).ensure(db);
    expect(again.publicId, id.publicId);

    final msg = [1, 2, 3, 4, 5];
    final sig = await svc.sign(msg);
    expect(
      await svc.verify(msg, signature: sig, publicKeyB64u: id.publicKey),
      isTrue,
    );
    expect(
      await svc.verify([9, 9, 9], signature: sig, publicKeyB64u: id.publicKey),
      isFalse,
    );
  });

  test('identity: recovery phrase restores the same identity', () async {
    final db1 = await AppDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final svc = IdentityService(secrets: FakeSecretStore());
    final original = await svc.ensure(db1);
    final phrase = await svc.recoveryPhrase();

    final db2 = await AppDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final restored = await IdentityService(secrets: FakeSecretStore())
        .restoreFromPhrase(phrase, db2);
    expect(restored.publicId, original.publicId);
    expect(restored.publicKey, original.publicKey);
  });

  test('store: new account is empty and writes persist across reloads', () async {
    final db = await AppDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final secrets = FakeSecretStore();
    final identity = IdentityService(secrets: secrets);
    await identity.ensure(db);

    final store = ArcStore(db: db, identity: identity, sync: _noopSync(db, identity));
    await store.init();
    expect(store.sessions, isEmpty);
    expect(store.exercises, isEmpty);

    final exId =
        await store.addExercise(name: 'Bench Press', group: 'Push', unit: 'kg');
    await store.saveSession('2026-05-29', [
      DraftEntry(
        id: 'e1',
        exerciseId: exId,
        sets: [DraftSet(weight: 100, reps: 5, id: 's1')],
      ),
    ]);
    expect(store.sessions.length, 1);

    final identity2 = IdentityService(secrets: secrets);
    await identity2.ensure(db);
    final store2 =
        ArcStore(db: db, identity: identity2, sync: _noopSync(db, identity2));
    await store2.init();
    expect(store2.sessions.length, 1);
    expect(store2.exercises.length, 1);
  });

  test('sync: pushes dirty rows, applies companion changes, merges graph',
      () async {
    final db = await AppDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final identity = IdentityService(secrets: FakeSecretStore());
    await identity.ensure(db);
    final me = identity.identity.publicId;

    // A stateful mock standing in for the Go relay.
    final pushedObjectIds = <String>[];
    var pullCalls = 0;
    http.Response jsonResp(Object o) => http.Response(jsonEncode(o), 200,
        headers: {'content-type': 'application/json'});

    final mock = MockClient((req) async {
      final body = req.body.isNotEmpty
          ? jsonDecode(req.body) as Map<String, dynamic>
          : <String, dynamic>{};
      switch (req.url.path) {
        case '/v1/register':
          return jsonResp({'public_id': me});
        case '/v1/auth/challenge':
          return jsonResp({'nonce': 'n1', 'expires_at': 0});
        case '/v1/auth/verify':
          return jsonResp({'token': 'tok', 'expires_at': 0, 'public_id': me});
        case '/v1/sync/push':
          for (final c in (body['changes'] as List)) {
            pushedObjectIds.add((c as Map)['object_id'] as String);
          }
          return jsonResp({
            'results': [
              for (final c in (body['changes'] as List))
                {'object_id': (c as Map)['object_id'], 'server_seq': 1}
            ],
            'cursor': 1,
          });
        case '/v1/sync/pull':
          pullCalls++;
          if (pullCalls == 1) {
            return jsonResp({
              'changes': [
                {
                  'owner_id': 'peerX',
                  'object_type': 'session',
                  'object_id': 'rs1',
                  'server_seq': 7,
                  'payload': {
                    'id': 'rs1',
                    'date': '2026-05-20',
                    'title': 'Pat Leg Day',
                    'entries': [
                      {
                        'id': 're1',
                        'exercise_id': 'rex1',
                        'sets': [
                          {'id': 'rss1', 'weight': 150.0, 'reps': 5}
                        ],
                      }
                    ],
                  },
                  'deleted': false,
                  'updated_at': 2000,
                }
              ],
              'cursor': 7,
            });
          }
          return jsonResp({'changes': [], 'cursor': 7});
        case '/v1/companions':
          return jsonResp({
            'companions': [
              {
                'peer_id': 'peerX',
                'display_name': 'Pat',
                'status': 'accepted',
                'incoming': false,
              }
            ]
          });
        default:
          return http.Response('{}', 404);
      }
    });

    final sync = SyncService(
      db: db,
      identity: identity,
      apiFactory: (url) => SyncApi(baseUrl: url, client: mock),
    );
    final store = ArcStore(db: db, identity: identity, sync: sync);
    await store.init();

    // Local dirty data to push.
    final exId =
        await store.addExercise(name: 'Squat', group: 'Legs', unit: 'kg');
    await store.saveSession('2026-05-29', [
      DraftEntry(
          id: 'e1',
          exerciseId: exId,
          sets: [DraftSet(weight: 100, reps: 5, id: 's1')]),
    ]);

    await store.syncNow();

    // No error; dirty rows were pushed and cleared.
    expect(store.syncError, isNull);
    expect(pushedObjectIds, contains(exId));
    expect(await db.getDirtyExercises(me), isEmpty);
    expect(await db.getDirtySessions(me), isEmpty);

    // The pulled companion session was applied under its owner, cursor saved.
    final peerSessions = await db.getSessions('peerX');
    expect(peerSessions.length, 1);
    expect(peerSessions.first.title, 'Pat Leg Day');
    expect((await db.getSelfSyncState()).cursor, 7);

    // The companion graph was merged (accepted).
    final pat = store.companions.where((c) => c.publicId == 'peerX').first;
    expect(pat.status.name, 'accepted');
    expect(pat.displayName, 'Pat');
  });

  testWidgets('companion progress sheet renders a companion\'s data',
      (tester) async {
    final companion = const Companion(
      publicId: 'peerX',
      displayName: 'Pat',
      status: CompanionStatus.accepted,
      addedAt: 0,
    );
    final data = CompanionData.from(
      companion,
      const [Exercise(id: 'e1', name: 'Bench Press', group: 'Push', unit: 'kg')],
      const [
        Session(id: 's1', date: '2026-05-27', title: 'Push Day', entries: [
          Entry(id: 'en1', exerciseId: 'e1', sets: [
            WorkoutSet(id: 'st1', weight: 100, reps: 5),
          ]),
        ]),
      ],
    );

    await tester.pumpWidget(MaterialApp(
      theme: buildArcTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: CompanionProgressSheet(data: data),
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('Strength progress'), findsOneWidget);
    expect(find.text('Personal records'), findsOneWidget);
    expect(find.text('Recent workouts'), findsOneWidget);
    expect(find.text('Bench Press'), findsWidgets); // PR card + recent names
    expect(find.text('Push Day'), findsOneWidget);
  });
}
