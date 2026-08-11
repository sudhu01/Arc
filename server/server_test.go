package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"
	"time"
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

// recordingPusher stands in for FCM: it captures who would have been woken so a
// test can assert fan-out without a Firebase project.
type recordingPusher struct {
	mu    sync.Mutex
	woken [][]string
}

func (p *recordingPusher) Wake(users []string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.woken = append(p.woken, append([]string(nil), users...))
}

func (p *recordingPusher) calls() [][]string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([][]string(nil), p.woken...)
}

func newTestBase(t *testing.T) string {
	t.Helper()
	base, _ := newTestBaseWithPusher(t)
	return base
}

func newTestBaseWithPusher(t *testing.T) (string, *recordingPusher) {
	t.Helper()
	store, err := OpenStore(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	push := &recordingPusher{}
	ts := httptest.NewServer((&Server{store: store, push: push}).routes())
	t.Cleanup(ts.Close)
	return ts.URL, push
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

// ── Adding a companion by link ────────────────────────────────────────
//
// The paste-a-link flow sends strict=true and expects to be told exactly why an
// add failed. The background reconciler re-sends every outstanding request on
// every sync and needs the same endpoint to stay silently idempotent, so each
// rejection below is paired with a check that the non-strict call still passes.

// request is a strict (user-initiated) companion add.
func (c *testClient) request(peerID string, extra map[string]any) (int, map[string]any) {
	body := map[string]any{"peer_id": peerID, "strict": true}
	for k, v := range extra {
		body[k] = v
	}
	return c.do("POST", "/v1/companions/request", body)
}

// unregisteredID returns a well-formed public_id with no account behind it.
func unregisteredID(t *testing.T) string {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	return derivePublicID(pub)
}

func TestCompanionRequestRejectsSelf(t *testing.T) {
	base := newTestBase(t)
	alice := newClient(t, base, "Alice")

	code, body := alice.request(alice.id, nil)
	if code != http.StatusBadRequest {
		t.Fatalf("expected 400 adding yourself, got %d %v", code, body)
	}
	// Non-strict too: a self-edge is never legitimate.
	if code, _ := alice.do("POST", "/v1/companions/request", map[string]any{"peer_id": alice.id}); code != http.StatusBadRequest {
		t.Fatalf("expected 400 for non-strict self-add, got %d", code)
	}
}

func TestCompanionRequestRejectsMalformedID(t *testing.T) {
	base := newTestBase(t)
	alice := newClient(t, base, "Alice")

	for _, id := range []string{"", "not-base64url!!", "c2hvcnQ"} { // empty, undecodable, wrong length
		if code, body := alice.request(id, nil); code != http.StatusBadRequest {
			t.Fatalf("expected 400 for peer_id %q, got %d %v", id, code, body)
		}
	}
}

func TestCompanionRequestRejectsKeyIDMismatch(t *testing.T) {
	base := newTestBase(t)
	alice := newClient(t, base, "Alice")
	bob := newClient(t, base, "Bob")
	mallory := newClient(t, base, "Mallory")

	// Bob's id carried alongside Mallory's key — a tampered link.
	code, body := alice.request(bob.id, map[string]any{"peer_key": b64uEncode(mallory.pub)})
	if code != http.StatusBadRequest {
		t.Fatalf("expected 400 for key/id mismatch, got %d %v", code, body)
	}
	// The matching key is accepted.
	if code, _ := alice.request(bob.id, map[string]any{"peer_key": b64uEncode(bob.pub)}); code != http.StatusOK {
		t.Fatalf("expected 200 for a well-formed link, got %d", code)
	}
}

func TestCompanionRequestUnknownPeer(t *testing.T) {
	base := newTestBase(t)
	alice := newClient(t, base, "Alice")
	ghost := unregisteredID(t)

	if code, body := alice.request(ghost, nil); code != http.StatusNotFound {
		t.Fatalf("expected 404 for an unregistered link, got %d %v", code, body)
	}
	// The reconciler's non-strict re-send must still be a quiet success — a peer
	// who hasn't registered yet is exactly the case it exists to heal.
	if code, _ := alice.do("POST", "/v1/companions/request", map[string]any{"peer_id": ghost}); code != http.StatusOK {
		t.Fatalf("expected 200 for non-strict unknown peer, got %d", code)
	}
}

func TestCompanionRequestRejectsDuplicates(t *testing.T) {
	base := newTestBase(t)
	alice := newClient(t, base, "Alice")
	bob := newClient(t, base, "Bob")

	code, body := alice.request(bob.id, nil)
	if code != http.StatusOK || body["result"] != "pending" {
		t.Fatalf("first request: got %d %v", code, body)
	}
	if code, body := alice.request(bob.id, nil); code != http.StatusConflict {
		t.Fatalf("expected 409 re-adding a pending peer, got %d %v", code, body)
	}
	if code, _ := alice.do("POST", "/v1/companions/request", map[string]any{"peer_id": bob.id}); code != http.StatusOK {
		t.Fatalf("non-strict re-send of a pending request must stay 200, got %d", code)
	}

	// Once accepted, a strict re-add is still a conflict; non-strict is not.
	if code, _ := bob.do("POST", "/v1/companions/accept", map[string]any{"peer_id": alice.id}); code != http.StatusOK {
		t.Fatalf("accept: got %d", code)
	}
	if code, body := alice.request(bob.id, nil); code != http.StatusConflict {
		t.Fatalf("expected 409 re-adding an accepted companion, got %d %v", code, body)
	}
	if code, body := alice.do("POST", "/v1/companions/request", map[string]any{"peer_id": bob.id}); code != http.StatusOK || body["result"] != "accepted" {
		t.Fatalf("non-strict re-send after accept: got %d %v", code, body)
	}
}

func TestCompanionRequestReciprocates(t *testing.T) {
	base := newTestBase(t)
	alice := newClient(t, base, "Alice")
	bob := newClient(t, base, "Bob")

	// Bob pastes Alice's link first; Alice pasting his back completes the pair
	// without either of them touching the accept button.
	if code, _ := bob.request(alice.id, nil); code != http.StatusOK {
		t.Fatalf("bob request: got %d", code)
	}
	code, body := alice.request(bob.id, nil)
	if code != http.StatusOK || body["result"] != "accepted" {
		t.Fatalf("expected 200 result=accepted, got %d %v", code, body)
	}
	_, list := alice.do("GET", "/v1/companions", nil)
	edges := list["companions"].([]any)
	if len(edges) != 1 || edges[0].(map[string]any)["status"] != "accepted" {
		t.Fatalf("expected one accepted edge, got %v", edges)
	}
}

func TestCompanionRequestRejectsBlocked(t *testing.T) {
	base := newTestBase(t)
	alice := newClient(t, base, "Alice")
	bob := newClient(t, base, "Bob")

	if code, _ := alice.do("POST", "/v1/companions/block", map[string]any{"peer_id": bob.id}); code != http.StatusOK {
		t.Fatalf("block: got %d", code)
	}
	if code, body := alice.request(bob.id, nil); code != http.StatusConflict {
		t.Fatalf("expected 409 adding a blocked peer, got %d %v", code, body)
	}
	// A block is never silently overridden, strict or not.
	if code, _ := alice.do("POST", "/v1/companions/request", map[string]any{"peer_id": bob.id}); code != http.StatusOK {
		t.Fatalf("non-strict request on a blocked edge should no-op with 200, got %d", code)
	}
	_, list := alice.do("GET", "/v1/companions", nil)
	edges := list["companions"].([]any)
	if len(edges) != 1 || edges[0].(map[string]any)["status"] != "blocked" {
		t.Fatalf("edge should still be blocked, got %v", edges)
	}
}

// ── Event feed ────────────────────────────────────────────────────────

// pair walks the mutual-accept handshake so an event test can start from a
// working companionship in one line.
func pair(t *testing.T, a, b *testClient) {
	t.Helper()
	if code, _ := a.do("POST", "/v1/companions/request", map[string]any{"peer_id": b.id}); code != http.StatusOK {
		t.Fatalf("request: got %d", code)
	}
	if code, _ := b.do("POST", "/v1/companions/accept", map[string]any{"peer_id": a.id}); code != http.StatusOK {
		t.Fatalf("accept: got %d", code)
	}
}

func (c *testClient) publish(events ...map[string]any) (int, map[string]any) {
	c.t.Helper()
	return c.do("POST", "/v1/events", map[string]any{"events": events})
}

func TestEventFeedIsGatedByCompanionship(t *testing.T) {
	base := newTestBase(t)
	alice := newClient(t, base, "Alice")
	bob := newClient(t, base, "Bob")

	if code, _ := alice.publish(map[string]any{
		"id":         "ev-1",
		"kind":       "workout_started",
		"payload":    map[string]any{"name": "Push Day", "date": "2026-08-11"},
		"created_at": 1000,
	}); code != http.StatusOK {
		t.Fatalf("publish: got %d", code)
	}

	// A stranger sees nothing, however recent the moment.
	_, pull := bob.do("GET", "/v1/events?cursor=0", nil)
	if n := len(pull["events"].([]any)); n != 0 {
		t.Fatalf("expected 0 events before pairing, got %d", n)
	}

	pair(t, alice, bob)

	_, pull = bob.do("GET", "/v1/events?cursor=0", nil)
	events := pull["events"].([]any)
	if len(events) != 1 {
		t.Fatalf("expected 1 event after pairing, got %d", len(events))
	}
	ev := events[0].(map[string]any)
	if ev["owner_id"] != alice.id || ev["kind"] != "workout_started" {
		t.Fatalf("unexpected event: %v", ev)
	}
	// The actor's name rides along, so a device that hasn't synced its
	// companion list yet can still write "Alice has started a workout!".
	if ev["owner_name"] != "Alice" {
		t.Fatalf("expected owner_name Alice, got %v", ev["owner_name"])
	}
	if payload := ev["payload"].(map[string]any); payload["name"] != "Push Day" {
		t.Fatalf("payload not relayed verbatim: %v", payload)
	}

	// The cursor advances and the same moment is never handed out twice.
	cursor := pull["cursor"].(float64)
	_, pull2 := bob.do("GET", "/v1/events?cursor="+itoa(int64(cursor)), nil)
	if n := len(pull2["events"].([]any)); n != 0 {
		t.Fatalf("expected 0 new events at latest cursor, got %d", n)
	}
}

func TestEventPublishIsIdempotent(t *testing.T) {
	base := newTestBase(t)
	alice := newClient(t, base, "Alice")
	bob := newClient(t, base, "Bob")
	pair(t, alice, bob)

	ev := map[string]any{
		"id":         "ev-pr-1",
		"kind":       "pr",
		"payload":    map[string]any{"exercise": "Bench Press", "weight": 100, "reps": 5, "unit": "kg"},
		"created_at": 2000,
	}
	// The outbox retries an unconfirmed publish; two attempts must still be one
	// notification on Bob's phone.
	if code, _ := alice.publish(ev); code != http.StatusOK {
		t.Fatalf("first publish: got %d", code)
	}
	if code, _ := alice.publish(ev); code != http.StatusOK {
		t.Fatalf("retried publish: got %d", code)
	}

	_, pull := bob.do("GET", "/v1/events?cursor=0", nil)
	if n := len(pull["events"].([]any)); n != 1 {
		t.Fatalf("expected 1 event after a retried publish, got %d", n)
	}
}

func TestEventPublishRejectsUnknownKind(t *testing.T) {
	base := newTestBase(t)
	alice := newClient(t, base, "Alice")

	code, _ := alice.publish(map[string]any{
		"id": "ev-x", "kind": "nudge", "payload": map[string]any{}, "created_at": 1,
	})
	if code != http.StatusBadRequest {
		t.Fatalf("expected 400 for an unknown kind, got %d", code)
	}
}

func TestEventsRequireAuth(t *testing.T) {
	base := newTestBase(t)
	c := newClient(t, base, "Alice")
	c.token = ""
	if code, _ := c.do("GET", "/v1/events?cursor=0", nil); code != http.StatusUnauthorized {
		t.Fatalf("expected 401 without token, got %d", code)
	}
	if code, _ := c.do("POST", "/v1/devices", map[string]any{
		"token": "tok", "platform": "android",
	}); code != http.StatusUnauthorized {
		t.Fatalf("expected 401 without token, got %d", code)
	}
}

func TestPublishWakesAcceptedCompanionsOnly(t *testing.T) {
	base, push := newTestBaseWithPusher(t)
	alice := newClient(t, base, "Alice")
	bob := newClient(t, base, "Bob")
	carol := newClient(t, base, "Carol")
	pair(t, alice, bob) // Carol stays a stranger

	if code, _ := alice.publish(map[string]any{
		"id": "ev-1", "kind": "workout_started",
		"payload": map[string]any{"name": "Leg Day"}, "created_at": 1000,
	}); code != http.StatusOK {
		t.Fatalf("publish: got %d", code)
	}

	calls := push.calls()
	if len(calls) != 1 {
		t.Fatalf("expected exactly one wake, got %d", len(calls))
	}
	if len(calls[0]) != 1 || calls[0][0] != bob.id {
		t.Fatalf("expected to wake only Bob, got %v", calls[0])
	}
	for _, id := range calls[0] {
		if id == carol.id {
			t.Fatal("woke a stranger")
		}
	}

	// A duplicate publish assigns no new seq, so nobody's phone lights up twice.
	if code, _ := alice.publish(map[string]any{
		"id": "ev-1", "kind": "workout_started",
		"payload": map[string]any{"name": "Leg Day"}, "created_at": 1000,
	}); code != http.StatusOK {
		t.Fatalf("republish: got %d", code)
	}
	if calls := push.calls(); len(calls) != 1 {
		t.Fatalf("a duplicate publish should wake nobody, got %d wakes", len(calls))
	}
}

func TestDeviceRegistryRoundTrip(t *testing.T) {
	base := newTestBase(t)
	alice := newClient(t, base, "Alice")

	if code, _ := alice.do("POST", "/v1/devices", map[string]any{
		"token": "fcm-token-1", "platform": "android",
	}); code != http.StatusOK {
		t.Fatalf("register device: got %d", code)
	}
	if code, _ := alice.do("POST", "/v1/devices", map[string]any{
		"token": "fcm-token-1", "platform": "web",
	}); code != http.StatusOK {
		t.Fatalf("re-register device: got %d", code)
	}
	if code, _ := alice.do("POST", "/v1/devices", map[string]any{
		"token": "fcm-token-1", "platform": "palm",
	}); code != http.StatusBadRequest {
		t.Fatalf("expected 400 for an unknown platform, got %d", code)
	}
	if code, _ := alice.do("DELETE", "/v1/devices/fcm-token-1", nil); code != http.StatusOK {
		t.Fatalf("delete device: got %d", code)
	}
}

// The sequence must never go backwards. It is derived from a counter rather
// than from MAX(server_seq) precisely because the janitor deletes rows: a quiet
// week that emptied the feed would otherwise restart at 1, and every companion
// whose cursor sat above that would stop receiving events forever, silently.
func TestEventSeqSurvivesRetentionSweep(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	ctx := context.Background()

	old := time.Now().Add(-30 * 24 * time.Hour).UnixMilli()
	first, err := store.PublishEvents(ctx, "alice", []EventIn{
		{ID: "ev-1", Kind: "pr", Payload: "{}", CreatedAt: old},
	})
	if err != nil {
		t.Fatalf("publish: %v", err)
	}

	// The janitor comes through and the table is empty again.
	store.PurgeOldEvents(ctx)
	var n int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM events`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("expected the sweep to empty the feed, %d rows left", n)
	}

	next, err := store.PublishEvents(ctx, "alice", []EventIn{
		{ID: "ev-2", Kind: "pr", Payload: "{}", CreatedAt: time.Now().UnixMilli()},
	})
	if err != nil {
		t.Fatalf("publish after sweep: %v", err)
	}
	if next <= first {
		t.Fatalf("sequence went backwards after a sweep: %d then %d", first, next)
	}

	// And a companion sitting at the pre-sweep cursor still sees what follows.
	events, _, err := store.PullEvents(ctx, []string{"alice"}, first, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].ID != "ev-2" {
		t.Fatalf("expected ev-2 past cursor %d, got %v", first, events)
	}
}

// A relay upgrading from a build that derived the sequence from MAX(server_seq)
// must adopt where that feed already got to, not hand out ids it has used.
func TestEventSeqAdoptsAnExistingFeed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	ctx := context.Background()
	// Stand in for the old scheme: rows at a high seq, and no counter.
	if _, err := store.db.ExecContext(ctx, `
		INSERT INTO events (id, owner_id, kind, payload, server_seq, created_at)
		VALUES ('legacy', 'alice', 'pr', '{}', 500, ?)`, time.Now().UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `DELETE FROM meta WHERE key = 'events_seq'`); err != nil {
		t.Fatal(err)
	}
	_ = store.Close()

	reopened, err := OpenStore(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	t.Cleanup(func() { _ = reopened.Close() })

	seq, err := reopened.PublishEvents(ctx, "alice", []EventIn{
		{ID: "ev-new", Kind: "pr", Payload: "{}", CreatedAt: time.Now().UnixMilli()},
	})
	if err != nil {
		t.Fatalf("publish: %v", err)
	}
	if seq <= 500 {
		t.Fatalf("expected a seq above the existing feed's 500, got %d", seq)
	}
}

func TestDeviceDeleteIsScopedToItsOwner(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	ctx := context.Background()

	if err := store.RegisterDevice(ctx, "alice", "alice-token", "android"); err != nil {
		t.Fatal(err)
	}

	// Naming someone else's token must not silence their phone.
	if err := store.DeleteDevice(ctx, "mallory", "alice-token"); err != nil {
		t.Fatal(err)
	}
	tokens, err := store.DeviceTokens(ctx, []string{"alice"})
	if err != nil {
		t.Fatal(err)
	}
	if len(tokens) != 1 {
		t.Fatalf("a stranger deleted Alice's push address: %v", tokens)
	}

	// Alice can still release her own.
	if err := store.DeleteDevice(ctx, "alice", "alice-token"); err != nil {
		t.Fatal(err)
	}
	tokens, _ = store.DeviceTokens(ctx, []string{"alice"})
	if len(tokens) != 0 {
		t.Fatalf("expected the owner's delete to land, got %v", tokens)
	}
}

// A relay with no FCM credentials must serve every endpoint normally — polling
// is the supported default, not a degraded mode.
func TestUnconfiguredPusherIsHarmless(t *testing.T) {
	t.Setenv("ARC_FCM_CREDENTIALS", "")
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", "")
	store, err := OpenStore(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	ts := httptest.NewServer((&Server{store: store, push: NewPusher(store)}).routes())
	t.Cleanup(ts.Close)

	alice := newClient(t, ts.URL, "Alice")
	bob := newClient(t, ts.URL, "Bob")
	pair(t, alice, bob)
	if code, _ := alice.publish(map[string]any{
		"id": "ev-1", "kind": "pr",
		"payload":    map[string]any{"exercise": "Squat", "weight": 140, "reps": 3, "unit": "kg"},
		"created_at": 1000,
	}); code != http.StatusOK {
		t.Fatalf("publish: got %d", code)
	}
	_, pull := bob.do("GET", "/v1/events?cursor=0", nil)
	if n := len(pull["events"].([]any)); n != 1 {
		t.Fatalf("expected the event to be deliverable by polling, got %d", n)
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
