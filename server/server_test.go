package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
)

// testClient simulates an Arc device: holds an Ed25519 keypair and drives the
// real HTTP API exactly as the Flutter client will.
type testClient struct {
	t     *testing.T
	base  string
	pub   ed25519.PublicKey
	priv  ed25519.PrivateKey
	id    string
	token string
}

func newTestBase(t *testing.T) string {
	t.Helper()
	store, err := OpenStore(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	ts := httptest.NewServer((&Server{store: store}).routes())
	t.Cleanup(ts.Close)
	return ts.URL
}

func newClient(t *testing.T, base, name string) *testClient {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	c := &testClient{t: t, base: base, pub: pub, priv: priv, id: derivePublicID(pub)}
	c.register(name)
	c.authenticate()
	return c
}

func (c *testClient) do(method, path string, body any) (int, map[string]any) {
	c.t.Helper()
	var buf bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&buf).Encode(body)
	}
	req, _ := http.NewRequest(method, c.base+path, &buf)
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func (c *testClient) register(name string) {
	sig := ed25519.Sign(c.priv, []byte(c.id))
	code, _ := c.do("POST", "/v1/register", map[string]any{
		"public_id":    c.id,
		"public_key":   b64uEncode(c.pub),
		"display_name": name,
		"sig":          b64uEncode(sig),
	})
	if code != http.StatusOK {
		c.t.Fatalf("register: got %d", code)
	}
}

func (c *testClient) authenticate() {
	code, ch := c.do("POST", "/v1/auth/challenge", map[string]any{"public_id": c.id})
	if code != http.StatusOK {
		c.t.Fatalf("challenge: got %d", code)
	}
	nonce, _ := ch["nonce"].(string)
	sig := ed25519.Sign(c.priv, []byte(nonce))
	code, out := c.do("POST", "/v1/auth/verify", map[string]any{
		"public_id": c.id, "nonce": nonce, "signature": b64uEncode(sig),
	})
	if code != http.StatusOK {
		c.t.Fatalf("verify: got %d", code)
	}
	c.token, _ = out["token"].(string)
	if c.token == "" {
		c.t.Fatal("verify: empty token")
	}
}

func TestAuthRejectsBadSignature(t *testing.T) {
	base := newTestBase(t)
	c := newClient(t, base, "Alice")

	_, ch := c.do("POST", "/v1/auth/challenge", map[string]any{"public_id": c.id})
	nonce, _ := ch["nonce"].(string)
	// Sign the WRONG message.
	badSig := ed25519.Sign(c.priv, []byte("not-the-nonce"))
	code, _ := c.do("POST", "/v1/auth/verify", map[string]any{
		"public_id": c.id, "nonce": nonce, "signature": b64uEncode(badSig),
	})
	if code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for bad signature, got %d", code)
	}
}

func TestSyncRequiresAuth(t *testing.T) {
	base := newTestBase(t)
	c := newClient(t, base, "Alice")
	c.token = "" // drop credentials
	code, _ := c.do("GET", "/v1/sync/pull?cursor=0", nil)
	if code != http.StatusUnauthorized {
		t.Fatalf("expected 401 without token, got %d", code)
	}
}

func TestCompanionSyncFlow(t *testing.T) {
	base := newTestBase(t)
	alice := newClient(t, base, "Alice")
	bob := newClient(t, base, "Bob")

	// Alice logs a workout (pushes a session subtree).
	code, push := alice.do("POST", "/v1/sync/push", map[string]any{
		"changes": []map[string]any{{
			"object_type": "session",
			"object_id":   "ses-1",
			"payload":     map[string]any{"id": "ses-1", "title": "Push Day"},
			"deleted":     false,
			"updated_at":  1000,
		}},
	})
	if code != http.StatusOK {
		t.Fatalf("push: got %d", code)
	}
	if push["cursor"].(float64) <= 0 {
		t.Fatalf("expected positive cursor, got %v", push["cursor"])
	}

	// Before pairing, Bob sees nothing.
	_, pull := bob.do("GET", "/v1/sync/pull?cursor=0", nil)
	if n := len(pull["changes"].([]any)); n != 0 {
		t.Fatalf("expected 0 changes before pairing, got %d", n)
	}

	// Alice scans Bob's QR → requests; Bob accepts (mutual).
	if code, _ := alice.do("POST", "/v1/companions/request", map[string]any{"peer_id": bob.id}); code != http.StatusOK {
		t.Fatalf("request: got %d", code)
	}
	if code, _ := bob.do("POST", "/v1/companions/accept", map[string]any{"peer_id": alice.id}); code != http.StatusOK {
		t.Fatalf("accept: got %d", code)
	}

	// Now Bob pulls Alice's session.
	_, pull = bob.do("GET", "/v1/sync/pull?cursor=0", nil)
	changes := pull["changes"].([]any)
	if len(changes) != 1 {
		t.Fatalf("expected 1 change after pairing, got %d", len(changes))
	}
	ch0 := changes[0].(map[string]any)
	if ch0["owner_id"] != alice.id || ch0["object_id"] != "ses-1" {
		t.Fatalf("unexpected change: %v", ch0)
	}
	payload := ch0["payload"].(map[string]any)
	if payload["title"] != "Push Day" {
		t.Fatalf("payload not relayed verbatim: %v", payload)
	}

	// Bob's cursor advances; a second pull from that cursor is empty.
	cursor := pull["cursor"].(float64)
	_, pull2 := bob.do("GET", "/v1/sync/pull?cursor="+itoa(int64(cursor)), nil)
	if n := len(pull2["changes"].([]any)); n != 0 {
		t.Fatalf("expected 0 new changes at latest cursor, got %d", n)
	}
}

func TestSelfRestoreReturnsOwnChanges(t *testing.T) {
	base := newTestBase(t)
	alice := newClient(t, base, "Alice")
	bob := newClient(t, base, "Bob")

	// Alice pushes two of her own objects.
	if code, _ := alice.do("POST", "/v1/sync/push", map[string]any{
		"changes": []map[string]any{
			{"object_type": "session", "object_id": "ses-1", "payload": map[string]any{"id": "ses-1", "title": "Push Day"}, "deleted": false, "updated_at": 1000},
			{"object_type": "exercise", "object_id": "ex-1", "payload": map[string]any{"id": "ex-1", "name": "Bench"}, "deleted": false, "updated_at": 1000},
		},
	}); code != http.StatusOK {
		t.Fatalf("push: got %d", code)
	}
	// Bob pushes his own object (must NOT leak into Alice's self-restore).
	if code, _ := bob.do("POST", "/v1/sync/push", map[string]any{
		"changes": []map[string]any{{"object_type": "session", "object_id": "ses-b", "payload": map[string]any{"id": "ses-b"}, "deleted": false, "updated_at": 1000}},
	}); code != http.StatusOK {
		t.Fatalf("bob push: got %d", code)
	}

	// A fresh device restoring Alice's identity re-downloads her own feed —
	// no companion pairing required, and only her objects come back.
	_, self := alice.do("GET", "/v1/sync/self?cursor=0", nil)
	changes := self["changes"].([]any)
	if len(changes) != 2 {
		t.Fatalf("expected 2 of Alice's own changes, got %d", len(changes))
	}
	for _, raw := range changes {
		c := raw.(map[string]any)
		if c["owner_id"] != alice.id {
			t.Fatalf("self-restore leaked another owner's change: %v", c)
		}
	}

	// Cursor advances; restoring again from it yields nothing new.
	cursor := self["cursor"].(float64)
	_, self2 := alice.do("GET", "/v1/sync/self?cursor="+itoa(int64(cursor)), nil)
	if n := len(self2["changes"].([]any)); n != 0 {
		t.Fatalf("expected 0 new changes at latest cursor, got %d", n)
	}
}

func TestRestoreKeepsDisplayName(t *testing.T) {
	base := newTestBase(t)
	alice := newClient(t, base, "Alice")

	// /v1/me returns the caller's own profile.
	code, me := alice.do("GET", "/v1/me", nil)
	if code != http.StatusOK || me["display_name"] != "Alice" {
		t.Fatalf("me: got %d %v", code, me)
	}

	// A restored device re-registers (idempotent) before its local name is
	// repopulated; sending an empty name must NOT blank the stored one.
	alice.register("")
	_, me2 := alice.do("GET", "/v1/me", nil)
	if me2["display_name"] != "Alice" {
		t.Fatalf("re-register blanked the display name: %v", me2)
	}
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
