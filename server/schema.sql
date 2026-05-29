-- Arc sync server schema (SQLite).
--
-- This is a RELAY, not a database of record: the device's SQLite is the source
-- of truth. The server only stores the public-key registry, short-lived auth
-- artifacts, the companion graph, and an opaque per-user change feed it fans
-- out to accepted companions.

-- Public-key registry. public_id == base64url(SHA-256(public_key)).
CREATE TABLE IF NOT EXISTS users (
  public_id    TEXT PRIMARY KEY,
  public_key   TEXT NOT NULL,          -- base64url Ed25519 public key
  display_name TEXT,
  created_at   INTEGER NOT NULL,
  last_seen    INTEGER
);

-- One-time, short-TTL challenge nonces for proof-of-key-ownership.
CREATE TABLE IF NOT EXISTS challenges (
  nonce      TEXT PRIMARY KEY,
  public_id  TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  used       INTEGER NOT NULL DEFAULT 0
);

-- Opaque bearer session tokens issued after a verified challenge.
CREATE TABLE IF NOT EXISTS tokens (
  token      TEXT PRIMARY KEY,
  public_id  TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tokens_user ON tokens(public_id);

-- Companion graph. A directed request row; mutual-accept flips it to accepted,
-- after which BOTH sides may pull each other's changes.
CREATE TABLE IF NOT EXISTS companions (
  requester_id TEXT NOT NULL,
  peer_id      TEXT NOT NULL,
  status       TEXT NOT NULL,          -- pending | accepted | blocked
  created_at   INTEGER NOT NULL,
  PRIMARY KEY (requester_id, peer_id)
);
CREATE INDEX IF NOT EXISTS idx_companions_peer ON companions(peer_id);

-- The relay feed. One row per (owner, object); server_seq is a global monotonic
-- cursor bumped on every write so companions re-pull updated objects.
-- payload is the JSON session-subtree or exercise (opaque to the server).
CREATE TABLE IF NOT EXISTS changes (
  owner_id    TEXT NOT NULL,
  object_type TEXT NOT NULL,           -- session | exercise
  object_id   TEXT NOT NULL,
  server_seq  INTEGER NOT NULL,
  payload     TEXT NOT NULL,
  deleted     INTEGER NOT NULL DEFAULT 0,
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (owner_id, object_type, object_id)
);
CREATE INDEX IF NOT EXISTS idx_changes_seq ON changes(server_seq);
CREATE INDEX IF NOT EXISTS idx_changes_owner_seq ON changes(owner_id, server_seq);
