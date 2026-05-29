// Device identity + authentication for Arc.
//
// Recoverable-seed model: a 32-byte seed is generated once, stored encrypted at
// rest via flutter_secure_storage (Android Keystore-backed), and can be exported
// as a BIP39 recovery phrase so the *same identity* moves to a new device. The
// seed deterministically yields an Ed25519 keypair:
//
//   Auth secret  = the Ed25519 private key (derived from the seed; never sent)
//   Public ID    = base64url(SHA-256(public key))  — the QR-shareable handle
//
// Ownership is proven by signing a server-issued challenge (see [sign]); the
// server / a companion verifies with the public key. No device fingerprint is
// involved — the keypair *is* the identity.

import 'dart:convert';
import 'dart:math';

import 'package:bip39/bip39.dart' as bip39;
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../db/app_database.dart';
import '../models.dart';

/// Minimal key/value secret store. Lets tests inject an in-memory fake instead
/// of the platform Keystore-backed storage.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Default [SecretStore] backed by flutter_secure_storage (Android Keystore /
/// iOS Keychain encrypted at rest).
class SecureSecretStore implements SecretStore {
  SecureSecretStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

class IdentityService {
  IdentityService({SecretStore? secrets})
      : _storage = secrets ?? SecureSecretStore();

  static const _seedKey = 'arc.identity.seed.v1';

  final SecretStore _storage;
  final _algorithm = Ed25519();

  SimpleKeyPair? _keyPair;
  List<int>? _seed;
  Identity? _identity;

  Identity get identity {
    final id = _identity;
    if (id == null) {
      throw StateError('IdentityService.ensure() must run before use');
    }
    return id;
  }

  /// Load the existing identity, or mint a fresh one on first launch.
  /// Idempotent — safe to call on every boot.
  Future<Identity> ensure(AppDatabase db) async {
    var seedB64 = await _storage.read(_seedKey);
    if (seedB64 == null) {
      final seed = _randomSeed();
      seedB64 = _b64u(seed);
      await _storage.write(_seedKey, seedB64);
    }
    return _activate(_b64uDecode(seedB64), db);
  }

  /// Sign [message] with the private key (e.g. a server challenge nonce).
  Future<List<int>> sign(List<int> message) async {
    final signature =
        await _algorithm.sign(message, keyPair: _requireKeyPair());
    return signature.bytes;
  }

  /// Verify a [signature] over [message] against a base64url public key.
  /// Used to check a companion's / the server's signatures.
  Future<bool> verify(
    List<int> message, {
    required List<int> signature,
    required String publicKeyB64u,
  }) async {
    final pub = SimplePublicKey(_b64uDecode(publicKeyB64u),
        type: KeyPairType.ed25519);
    return _algorithm.verify(message,
        signature: Signature(signature, publicKey: pub));
  }

  /// The 24-word backup phrase. Show once; whoever holds it controls the
  /// identity, so treat it like a password.
  Future<String> recoveryPhrase() async {
    final seed = _seed ??= _b64uDecode((await _storage.read(_seedKey))!);
    return bip39.entropyToMnemonic(_hex(seed));
  }

  /// Restore an identity from a recovery phrase (e.g. on a new device).
  /// Overwrites the local seed — call before loading any user data.
  Future<Identity> restoreFromPhrase(String phrase, AppDatabase db) async {
    final normalized = phrase.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (!bip39.validateMnemonic(normalized)) {
      throw const FormatException('Invalid recovery phrase');
    }
    final seed = _unhex(bip39.mnemonicToEntropy(normalized));
    await _storage.write(_seedKey, _b64u(seed));
    return _activate(seed, db);
  }

  // ── internals ──────────────────────────────────────────────────────
  Future<Identity> _activate(List<int> seed, AppDatabase db) async {
    _seed = seed;
    _keyPair = await _algorithm.newKeyPairFromSeed(seed);
    final pub = await _keyPair!.extractPublicKey();
    final publicKeyB64u = _b64u(pub.bytes);
    final publicId = _b64u(crypto.sha256.convert(pub.bytes).bytes);

    final existing = await db.getIdentity();
    final identity = Identity(
      publicId: publicId,
      publicKey: publicKeyB64u,
      displayName: existing?.displayName,
      createdAt: existing?.createdAt ?? DateTime.now().millisecondsSinceEpoch,
    );
    // Persist if new, or if a restore changed the keys.
    if (existing == null || existing.publicId != publicId) {
      await db.setIdentity(identity);
    }
    _identity = identity;
    return identity;
  }

  SimpleKeyPair _requireKeyPair() {
    final kp = _keyPair;
    if (kp == null) throw StateError('Identity not initialized');
    return kp;
  }

  List<int> _randomSeed() {
    final rnd = Random.secure();
    return List<int>.generate(32, (_) => rnd.nextInt(256));
  }

  // base64url without padding — URL/QR safe.
  static String _b64u(List<int> b) => base64Url.encode(b).replaceAll('=', '');
  static List<int> _b64uDecode(String s) {
    final pad = (4 - s.length % 4) % 4;
    return base64Url.decode(s + ('=' * pad));
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  static List<int> _unhex(String h) => [
        for (var i = 0; i < h.length; i += 2)
          int.parse(h.substring(i, i + 2), radix: 16),
      ];
}
