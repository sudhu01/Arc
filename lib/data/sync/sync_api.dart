// Thin HTTP client for the Arc sync server (see /server). Each method maps to
// one endpoint; non-2xx responses become a [SyncException]. All binary values
// on the wire are base64url-without-padding to match the server.

import 'dart:convert';

import 'package:http/http.dart' as http;

class SyncException implements Exception {
  final int statusCode;
  final String message;
  const SyncException(this.statusCode, this.message);

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => 'SyncException($statusCode): $message';
}

class SyncApi {
  SyncApi({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  void close() => _client.close();

  // ── Auth ──────────────────────────────────────────────────────────
  Future<void> register({
    required String publicId,
    required String publicKey,
    required String displayName,
    required String sig,
  }) async {
    await _post('/v1/register', {
      'public_id': publicId,
      'public_key': publicKey,
      'display_name': displayName,
      'sig': sig,
    });
  }

  /// The caller's own profile: `{public_id, display_name}`.
  Future<Map<String, dynamic>> me(String token) => _get('/v1/me', token: token);

  Future<String> challenge(String publicId) async {
    final body = await _post('/v1/auth/challenge', {'public_id': publicId});
    return body['nonce'] as String;
  }

  /// Returns a bearer token.
  Future<String> verify({
    required String publicId,
    required String nonce,
    required String signature,
  }) async {
    final body = await _post('/v1/auth/verify', {
      'public_id': publicId,
      'nonce': nonce,
      'signature': signature,
    });
    return body['token'] as String;
  }

  // ── Companions ────────────────────────────────────────────────────
  Future<void> requestCompanion(String token, String peerId) =>
      _post('/v1/companions/request', {'peer_id': peerId}, token: token);

  Future<List<dynamic>> listCompanions(String token) async {
    final body = await _get('/v1/companions', token: token);
    return (body['companions'] as List?) ?? const [];
  }

  Future<void> acceptCompanion(String token, String peerId) =>
      _post('/v1/companions/accept', {'peer_id': peerId}, token: token);

  Future<void> blockCompanion(String token, String peerId) =>
      _post('/v1/companions/block', {'peer_id': peerId}, token: token);

  Future<void> deleteCompanion(String token, String peerId) => _send(
        'DELETE',
        '/v1/companions/${Uri.encodeComponent(peerId)}',
        token: token,
      );

  // ── Sync ──────────────────────────────────────────────────────────
  /// Returns `{results:[{object_id, server_seq}], cursor}`.
  Future<Map<String, dynamic>> push(
          String token, List<Map<String, dynamic>> changes) =>
      _post('/v1/sync/push', {'changes': changes}, token: token);

  /// Returns `{changes:[…], cursor}`.
  Future<Map<String, dynamic>> pull(String token, int cursor) =>
      _get('/v1/sync/pull?cursor=$cursor', token: token);

  /// The caller's *own* change feed (for restoring a reinstalled device).
  /// Returns `{changes:[…], cursor}` with `owner_id == me`.
  Future<Map<String, dynamic>> pullSelf(String token, int cursor) =>
      _get('/v1/sync/self?cursor=$cursor', token: token);

  // ── plumbing ──────────────────────────────────────────────────────
  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body,
          {String? token}) =>
      _send('POST', path, body: body, token: token);

  Future<Map<String, dynamic>> _get(String path, {String? token}) =>
      _send('GET', path, token: token);

  Future<Map<String, dynamic>> _send(String method, String path,
      {Map<String, dynamic>? body, String? token}) async {
    final req = http.Request(method, Uri.parse('$baseUrl$path'));
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final streamed = await _client.send(req);
    final resp = await http.Response.fromStream(streamed);

    Map<String, dynamic> decoded = const {};
    if (resp.body.isNotEmpty) {
      final v = jsonDecode(resp.body);
      if (v is Map<String, dynamic>) decoded = v;
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw SyncException(
          resp.statusCode, (decoded['error'] as String?) ?? 'HTTP ${resp.statusCode}');
    }
    return decoded;
  }
}
