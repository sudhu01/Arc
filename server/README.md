# Arc Sync Server

A thin **store-and-forward relay + signature verifier** for Arc companion sync.
It is **not** a database of record — each device's SQLite is the source of
truth. The server only holds a public-key registry, short-lived auth artifacts,
the companion graph, and an opaque per-user change feed that it fans out to
accepted companions.

- **Stack:** Go (stdlib `net/http`) + SQLite (`modernc.org/sqlite`, pure Go — no cgo).
- **Crypto:** Ed25519 verification via the standard library.
- **Auth:** challenge–response → opaque bearer tokens.
- **Privacy (v1):** TLS in transit + at-rest encryption is a deployment concern
  (run behind a TLS proxy or set `ARC_TLS_*`; encrypt the DB file / disk).
  Payloads are stored as plaintext JSON the relay does not interpret. (E2E —
  X25519 per companion — is a later hardening step.)

## Run

```bash
cd server
go mod tidy        # fetch modernc.org/sqlite
go test ./...      # integration tests (auth, gating, sync flow)
go run .           # starts on :8080, DB file ./arc-server.db
```

Config via env:

| var | default | meaning |
|---|---|---|
| `ARC_ADDR` | `:8080` | listen address |
| `ARC_DB` | `arc-server.db` | SQLite file path |
| `ARC_TLS_CERT` / `ARC_TLS_KEY` | – | enable HTTPS directly (else terminate TLS upstream) |

## Wire format

All binary values (public keys, signatures, SHA-256 hashes, nonces, tokens) are
**base64url without padding** — identical to the Flutter client's `_b64u`, so
they round-trip unchanged. `public_id == base64url(SHA-256(public_key))`.

## API (`/v1`)

### Auth — unauthenticated

| method · path | body | returns |
|---|---|---|
| `POST /register` | `{public_id, public_key, display_name?, sig}` | `{public_id}` |
| `POST /auth/challenge` | `{public_id}` | `{nonce, expires_at}` |
| `POST /auth/verify` | `{public_id, nonce, signature}` | `{token, expires_at, public_id}` |

- `register` enforces `public_id == base64url(SHA-256(public_key))` and that
  `sig` (Ed25519 over the `public_id` bytes) verifies — so you can only register
  an identity you hold the private key for. Idempotent.
- `auth/verify` requires the Ed25519 signature over the **nonce string bytes**.
  Challenges are single-use and expire in 2 minutes. Tokens last 30 days.

### Companions — `Authorization: Bearer <token>`

| method · path | body | notes |
|---|---|---|
| `POST /companions/request` | `{peer_id}` | from scanning their QR; if they already requested you, becomes **accepted** |
| `GET /companions` | – | `{companions:[{peer_id, display_name, status, incoming}]}` |
| `POST /companions/accept` | `{peer_id}` | accept a pending incoming request |
| `POST /companions/block` | `{peer_id}` | severs sync both ways |
| `DELETE /companions/{peer}` | – | remove the relationship |

Pairing is **mutual-accept**: data only flows once both sides have accepted.

### Sync — `Authorization: Bearer <token>`

| method · path | body / query | returns |
|---|---|---|
| `POST /sync/push` | `{changes:[{object_type, object_id, payload, deleted, updated_at}]}` | `{results:[{object_id, server_seq}], cursor}` |
| `GET /sync/pull` | `?cursor=N&limit=M` | `{changes:[{owner_id, object_type, object_id, server_seq, payload, deleted, updated_at}], cursor}` |

- `object_type` ∈ `session` (the whole subtree — entries+sets) | `exercise`.
- **Push** always records the caller as `owner_id`; each object gets a fresh
  monotonic `server_seq`. The client clears its `dirty` flags using `results`.
- **Pull** returns only accepted companions' changes with `server_seq > cursor`.
  The client applies them with `owner_id = companion` and resolves conflicts by
  `updated_at` (last-write-wins). One global cursor per device (stored client
  side in `sync_state.scope='self'`) is all the state required — no CRDTs,
  because every row has exactly one writer (its owner).

## Files

```
main.go                 wiring, config, graceful shutdown, janitor
server.go               router (Go 1.22 mux), auth middleware, JSON/logging helpers
crypto.go               base64url / Ed25519 / SHA-256 helpers (match the client)
store.go                SQLite access — users, challenges, tokens, companions, changes
schema.sql              embedded schema
handlers_auth.go        register / challenge / verify
handlers_companions.go  request / list / accept / block / delete
handlers_sync.go        push / pull
server_test.go          end-to-end tests (real Ed25519 client)
```

## Next: the client side

The Flutter app still needs a `SyncService` that: registers + authenticates via
`IdentityService`, calls `push` for `dirty` rows, calls `pull` and applies
changes into the local DB (`owner_id = companion`), and persists the cursor in
`sync_state`. The DB schema already carries the `owner_id/updated_at/deleted/
dirty` columns this requires.
