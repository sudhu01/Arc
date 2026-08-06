// The QR pairing payload.
//
// Encoded as an `arc://pair?...` URI carrying everything safe to share: the
// public ID, the public key (so a scanner can verify the owner's signatures
// without a server round-trip), and a display name. All values are public —
// the QR is a *bearer of identity*, not a secret.
//
// The same URI is what "Copy link" puts on the clipboard, so it also arrives
// typed or pasted — possibly mangled, truncated, or wrapped in a chat message.
// [PairingPayload.parse] is the strict reader for that path: it reports *why* a
// link is unusable so the UI can say something specific.
//
// Future hardening: add a short-lived signed `token` so a stale screenshot of
// the QR can't be used to pair after the fact (only an in-person, fresh scan).

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Why a pasted/scanned string isn't a usable pairing link.
enum PairingLinkIssue {
  empty,
  notArcLink,
  missingFields,
  badKey,
  /// The id isn't the hash of the key — the link was tampered with or truncated.
  idMismatch,
}

extension PairingLinkIssueMessage on PairingLinkIssue {
  /// Toast copy for this issue.
  String get message => switch (this) {
        PairingLinkIssue.empty => 'Paste a companion link first',
        PairingLinkIssue.notArcLink =>
          "That doesn't look like an Arc companion link",
        _ => 'That link is incomplete or corrupted',
      };
}

/// Outcome of [PairingPayload.parse]: exactly one of the two is non-null.
class PairingParse {
  final PairingPayload? payload;
  final PairingLinkIssue? issue;

  const PairingParse.ok(PairingPayload this.payload) : issue = null;
  const PairingParse.bad(PairingLinkIssue this.issue) : payload = null;
}

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
  static PairingPayload? tryParse(String raw) => parse(raw).payload;

  /// Strict parse with a reason on failure.
  ///
  /// Beyond the URI shape this verifies the link is *internally consistent*:
  /// the key must be a 32-byte Ed25519 public key and the id must be its
  /// SHA-256 hash, exactly as [IdentityService] derives it. A link failing that
  /// can never pair, so it's rejected before any network call.
  static PairingParse parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const PairingParse.bad(PairingLinkIssue.empty);

    // The link may arrive inside a larger message ("add me: arc://pair?…").
    final match = RegExp(r'arc://pair\?\S+').firstMatch(text);
    if (match == null) {
      return const PairingParse.bad(PairingLinkIssue.notArcLink);
    }
    final uri = Uri.tryParse(match.group(0)!);
    if (uri == null || uri.scheme != 'arc' || uri.host != 'pair') {
      return const PairingParse.bad(PairingLinkIssue.notArcLink);
    }

    final id = uri.queryParameters['id'];
    final k = uri.queryParameters['k'];
    if (id == null || id.isEmpty || k == null || k.isEmpty) {
      return const PairingParse.bad(PairingLinkIssue.missingFields);
    }

    final List<int> keyBytes;
    try {
      keyBytes = base64Url.decode(base64.normalize(k));
    } catch (_) {
      return const PairingParse.bad(PairingLinkIssue.badKey);
    }
    if (keyBytes.length != 32) {
      return const PairingParse.bad(PairingLinkIssue.badKey);
    }
    if (id != _b64u(sha256.convert(keyBytes).bytes)) {
      return const PairingParse.bad(PairingLinkIssue.idMismatch);
    }

    return PairingParse.ok(PairingPayload(
      publicId: id,
      publicKey: k,
      displayName: uri.queryParameters['n']?.trim().isNotEmpty == true
          ? uri.queryParameters['n']!.trim()
          : 'Companion',
    ));
  }

  static String _b64u(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
