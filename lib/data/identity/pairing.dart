// The QR pairing payload.
//
// Encoded as an `arc://pair?...` URI carrying everything safe to share: the
// public ID, the public key (so a scanner can verify the owner's signatures
// without a server round-trip), and a display name. All values are public —
// the QR is a *bearer of identity*, not a secret.
//
// Future hardening: add a short-lived signed `token` so a stale screenshot of
// the QR can't be used to pair after the fact (only an in-person, fresh scan).

class PairingPayload {
  final String publicId;
  final String publicKey; // base64url Ed25519 public key
  final String displayName;

  const PairingPayload({
    required this.publicId,
    required this.publicKey,
    required this.displayName,
  });

  String toUri() => Uri(
        scheme: 'arc',
        host: 'pair',
        queryParameters: {
          'id': publicId,
          'k': publicKey,
          'n': displayName,
        },
      ).toString();

  /// Parse a scanned string. Returns null if it isn't a valid Arc pair URI.
  static PairingPayload? tryParse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != 'arc' || uri.host != 'pair') return null;
    final id = uri.queryParameters['id'];
    final k = uri.queryParameters['k'];
    if (id == null || id.isEmpty || k == null || k.isEmpty) return null;
    return PairingPayload(
      publicId: id,
      publicKey: k,
      displayName: uri.queryParameters['n']?.trim().isNotEmpty == true
          ? uri.queryParameters['n']!.trim()
          : 'Companion',
    );
  }
}
