// Thin HTTP client for the Arc sync server (see /server). Each method maps to
// one endpoint; non-2xx responses become a [SyncException]. All binary values
// on the wire are base64url-without-padding to match the server.

import 'dart:convert';

import 'package:http/http.dart' as http;

class SyncException implements Exception {
  final int statusCode;
  final String message;

  /// The URL that produced it, when known. A server URL pointing at the wrong
  /// host or carrying a stray path segment surfaces as a 404, and seeing the
  /// full URL is the fastest way to recognise that.
  final String? uri;
  const SyncException(this.statusCode, this.message, {this.uri});

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() =>
      'SyncException($statusCode): $message${uri == null ? '' : ' [$uri]'}';
}

class SyncApi {
  SyncApi({required String baseUrl, http.Client? client})
      : baseUrl = normalizeBaseUrl(baseUrl),
        _client = client ?? http.Client();

  /// A hand-typed server URL is not yet a usable base: without a scheme
  /// [Uri.parse] reads the host as a path, and a trailing slash builds
  /// `https://host//v1/sync/pull`, which the relay's mux does not route. Both
  /// are normalized once here so every request can just concatenate a path.
  static String normalizeBaseUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return url;
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://').hasMatch(url)) {
      url = 'https://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

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
  /// Ask to pair with [peerId]; returns the resulting edge state, `pending` or
  /// `accepted` (the latter when they had already requested me).
  ///
  /// [peerKey] is the public key carried by the pairing link — sending it lets
  /// the server confirm the link actually belongs to that account. [strict]
  /// marks a user-initiated add, which asks the server to report duplicates,
  /// blocks and unknown accounts as errors instead of quietly succeeding; the
  /// background re-send in [SyncService] leaves it off so it stays idempotent.
  Future<String> requestCompanion(
    String token,
    String peerId, {
    String? peerKey,
    bool strict = false,
  }) async {
    final body = <String, dynamic>{'peer_id': peerId};
    if (peerKey != null) body['peer_key'] = peerKey;
    if (strict) body['strict'] = true;
    final resp =
        await _post('/v1/companions/request', body, token: token);
    return (resp['result'] as String?) ?? 'pending';
  }

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

  // ── Events ────────────────────────────────────────────────────────
  // A separate feed to `sync`, with its own sequence space. Changes relay
  // *state* and are re-read forever; events relay *moments* and are told once.

  /// Publish my moments. Idempotent on each event's `id`, so an unconfirmed
  /// publish can be retried without announcing the same workout twice.
  Future<void> publishEvents(
          String token, List<Map<String, dynamic>> events) =>
      _post('/v1/events', {'events': events}, token: token);

  /// Accepted companions' moments with `server_seq > cursor`, oldest first.
  /// Returns `{events:[…], cursor}`.
  Future<Map<String, dynamic>> pullEvents(String token, int cursor) =>
      _get('/v1/events?cursor=$cursor', token: token);

  /// Claim a push token for this account, so the relay can wake the device
  /// instead of waiting for it to poll. A no-op on a relay with no FCM
  /// credentials configured — the row is simply never read.
  Future<void> registerDevice(String token, String deviceToken,
          {String platform = 'android'}) =>
      _post('/v1/devices', {'token': deviceToken, 'platform': platform},
          token: token);

  Future<void> unregisterDevice(String token, String deviceToken) => _send(
        'DELETE',
        '/v1/devices/${Uri.encodeComponent(deviceToken)}',
        token: token,
      );

  // ── plumbing ──────────────────────────────────────────────────────
  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body,
          {String? token}) =>
      _send('POST', path, body: body, token: token);

  Future<Map<String, dynamic>> _get(String path, {String? token}) =>
      _send('GET', path, token: token);

  Future<Map<String, dynamic>> _send(String method, String path,
      {Map<String, dynamic>? body, String? token}) async {
    final url = '$baseUrl$path';
    final req = http.Request(method, Uri.parse(url));
    // Skip ngrok's free-tier HTML interstitial so it never replaces a JSON
    // response when the relay is exposed via an ngrok tunnel. Ignored by any
    // other server.
    req.headers['ngrok-skip-browser-warning'] = 'true';
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final streamed = await _client.send(req);
    final resp = await http.Response.fromStream(streamed);

    // Only Arc answers in JSON. A 404 from the Go mux ("404 page not found"),
    // an ngrok interstitial and a proxy's HTML error page all land here too, so
    // decoding is best-effort: it must never throw over the status code, which
    // is the part that says what actually went wrong.
    Map<String, dynamic> decoded = const {};
    var wasJson = resp.body.isEmpty;
    if (resp.body.isNotEmpty) {
      try {
        final v = jsonDecode(resp.body);
        wasJson = true;
        if (v is Map<String, dynamic>) decoded = v;
      } on FormatException {
        wasJson = false;
      }
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw SyncException(
        resp.statusCode,
        (decoded['error'] as String?) ??
            _snippet(resp.body) ??
            'HTTP ${resp.statusCode}',
        uri: url,
      );
    }
    if (!wasJson) {
      // A 2xx that isn't JSON is something other than the relay answering —
      // report it rather than handing callers an empty map to trip over.
      throw SyncException(
        resp.statusCode,
        'expected JSON, got ${_snippet(resp.body)}',
        uri: url,
      );
    }
    return decoded;
  }

  /// A one-line, length-capped preview of a non-JSON body, for error messages.
  static String? _snippet(String body) {
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return null;
    return flat.length <= 120 ? flat : '${flat.substring(0, 117)}…';
  }
}
