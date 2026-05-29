package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
)

// The wire format for all binary values (public keys, signatures, hashes,
// nonces, tokens) is base64url WITHOUT padding — identical to the Flutter
// client's `_b64u` so values round-trip unchanged between the two.

func b64uEncode(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func b64uDecode(s string) ([]byte, error) { return base64.RawURLEncoding.DecodeString(s) }

// derivePublicID mirrors the client: base64url(SHA-256(publicKeyBytes)).
func derivePublicID(pubKey []byte) string {
	sum := sha256.Sum256(pubKey)
	return b64uEncode(sum[:])
}

// verifySig checks an Ed25519 signature (base64url) over msg using a base64url
// public key. Returns false on any decode/size/verification failure.
func verifySig(pubKeyB64u, sigB64u string, msg []byte) bool {
	pub, err := b64uDecode(pubKeyB64u)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return false
	}
	sig, err := b64uDecode(sigB64u)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(pub), msg, sig)
}

// randB64u returns n cryptographically-random bytes, base64url-encoded.
func randB64u(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return b64uEncode(b), nil
}
