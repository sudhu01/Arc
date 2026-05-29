import 'package:arc/data/db/app_database.dart';
import 'package:arc/data/identity/identity_service.dart';
import 'package:arc/data/store.dart';
import 'package:arc/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// In-memory [SecretStore] for tests (no platform Keystore available).
class FakeSecretStore implements SecretStore {
  final _map = <String, String>{};
  @override
  Future<String?> read(String key) async => _map[key];
  @override
  Future<void> write(String key, String value) async => _map[key] = value;
}

Future<ArcStore> _bootStore() async {
  final db = await AppDatabase.open(
    factory: databaseFactoryFfi,
    path: inMemoryDatabasePath,
  );
  final identity = IdentityService(secrets: FakeSecretStore());
  await identity.ensure(db);
  final store = ArcStore(db: db, identity: identity);
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

    // Public ID is derived from the key, not empty, and stable across reloads.
    expect(id.publicId, isNotEmpty);
    final again = await IdentityService(secrets: secrets).ensure(db);
    expect(again.publicId, id.publicId);

    // A signature verifies against the public key.
    final msg = [1, 2, 3, 4, 5];
    final sig = await svc.sign(msg);
    expect(
      await svc.verify(msg, signature: sig, publicKeyB64u: id.publicKey),
      isTrue,
    );
    // A tampered message does not verify.
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

    // Fresh device: restore from the phrase → same public id.
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

    final store = ArcStore(db: db, identity: identity);
    await store.init();
    // Blank slate — no placeholder data.
    expect(store.sessions, isEmpty);
    expect(store.exercises, isEmpty);

    // Adding an exercise + workout persists.
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

    // A second store over the same DB sees the persisted data.
    final identity2 = IdentityService(secrets: secrets);
    await identity2.ensure(db);
    final store2 = ArcStore(db: db, identity: identity2);
    await store2.init();
    expect(store2.sessions.length, 1);
    expect(store2.exercises.length, 1);
  });
}
