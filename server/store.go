package main

import (
	"context"
	"database/sql"
	_ "embed"
	"errors"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

//go:embed schema.sql
var schemaSQL string

var (
	ErrNotFound          = errors.New("not found")
	ErrNoPendingRequest  = errors.New("no pending request to accept")
)

type Store struct{ db *sql.DB }

// OpenStore opens (creating if needed) the SQLite database and applies schema.
func OpenStore(path string) (*Store, error) {
	dsn := "file:" + path +
		"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(ON)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, err
	}
	if _, err := db.ExecContext(context.Background(), schemaSQL); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

func nowMs() int64 { return time.Now().UnixMilli() }

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// ── Users / identity registry ─────────────────────────────────────────

type User struct {
	PublicID    string
	PublicKey   string
	DisplayName string
}

func (s *Store) UpsertUser(ctx context.Context, publicID, publicKey, displayName string) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO users (public_id, public_key, display_name, created_at, last_seen)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(public_id) DO UPDATE SET
			public_key   = excluded.public_key,
			-- Keep the stored name when an (idempotent) re-register sends none,
			-- e.g. a device restored from a recovery phrase before its local
			-- display name is repopulated. Never blank a name companions see.
			display_name = COALESCE(excluded.display_name, users.display_name)`,
		publicID, publicKey, nullIfEmpty(displayName), nowMs(), nowMs())
	return err
}

func (s *Store) GetUser(ctx context.Context, publicID string) (*User, error) {
	var u User
	var name sql.NullString
	err := s.db.QueryRowContext(ctx,
		`SELECT public_id, public_key, display_name FROM users WHERE public_id = ?`,
		publicID).Scan(&u.PublicID, &u.PublicKey, &name)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	u.DisplayName = name.String
	return &u, nil
}

func (s *Store) TouchLastSeen(ctx context.Context, publicID string) {
	_, _ = s.db.ExecContext(ctx,
		`UPDATE users SET last_seen = ? WHERE public_id = ?`, nowMs(), publicID)
}

// ── Auth artifacts ────────────────────────────────────────────────────

func (s *Store) CreateChallenge(ctx context.Context, publicID, nonce string, expiresAt int64) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO challenges (nonce, public_id, expires_at, used) VALUES (?, ?, ?, 0)`,
		nonce, publicID, expiresAt)
	return err
}

// ConsumeChallenge atomically marks a valid, unexpired, unused challenge as used
// and returns the public_id it was issued to.
func (s *Store) ConsumeChallenge(ctx context.Context, nonce string) (string, error) {
	var publicID string
	err := s.db.QueryRowContext(ctx, `
		UPDATE challenges SET used = 1
		WHERE nonce = ? AND used = 0 AND expires_at > ?
		RETURNING public_id`, nonce, nowMs()).Scan(&publicID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return publicID, err
}

func (s *Store) CreateToken(ctx context.Context, token, publicID string, expiresAt int64) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO tokens (token, public_id, expires_at) VALUES (?, ?, ?)`,
		token, publicID, expiresAt)
	return err
}

// UserForToken returns the public_id for a valid, unexpired bearer token.
func (s *Store) UserForToken(ctx context.Context, token string) (string, bool) {
	if token == "" {
		return "", false
	}
	var publicID string
	err := s.db.QueryRowContext(ctx,
		`SELECT public_id FROM tokens WHERE token = ? AND expires_at > ?`,
		token, nowMs()).Scan(&publicID)
	if err != nil {
		return "", false
	}
	return publicID, true
}

// PurgeExpired removes stale challenges and tokens (called by the janitor).
func (s *Store) PurgeExpired(ctx context.Context) {
	now := nowMs()
	_, _ = s.db.ExecContext(ctx, `DELETE FROM challenges WHERE expires_at <= ? OR used = 1`, now)
	_, _ = s.db.ExecContext(ctx, `DELETE FROM tokens WHERE expires_at <= ?`, now)
}

// ── Companion graph (mutual-accept) ───────────────────────────────────

type CompanionView struct {
	PeerID      string `json:"peer_id"`
	DisplayName string `json:"display_name"`
	Status      string `json:"status"`
	Incoming    bool   `json:"incoming"` // peer initiated → I can accept
}

// RequestCompanion records me → peer. If peer already requested me, this
// reciprocates and the edge becomes accepted (natural mutual pairing).
func (s *Store) RequestCompanion(ctx context.Context, me, peer string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	// Reciprocal pending request from peer → me? Accept it.
	res, err := tx.ExecContext(ctx, `
		UPDATE companions SET status = 'accepted'
		WHERE requester_id = ? AND peer_id = ? AND status = 'pending'`, peer, me)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n > 0 {
		return tx.Commit()
	}

	// Otherwise create (or keep) my outbound request. Won't override a block.
	_, err = tx.ExecContext(ctx, `
		INSERT INTO companions (requester_id, peer_id, status, created_at)
		VALUES (?, ?, 'pending', ?)
		ON CONFLICT(requester_id, peer_id) DO NOTHING`, me, peer, nowMs())
	if err != nil {
		return err
	}
	return tx.Commit()
}

// AcceptCompanion accepts a pending request that peer sent to me.
func (s *Store) AcceptCompanion(ctx context.Context, me, peer string) error {
	res, err := s.db.ExecContext(ctx, `
		UPDATE companions SET status = 'accepted'
		WHERE requester_id = ? AND peer_id = ? AND status = 'pending'`, peer, me)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoPendingRequest
	}
	return nil
}

// BlockCompanion marks any edge between me and peer blocked (severs sync both
// ways), creating one if none exists.
func (s *Store) BlockCompanion(ctx context.Context, me, peer string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx, `
		UPDATE companions SET status = 'blocked'
		WHERE (requester_id = ? AND peer_id = ?) OR (requester_id = ? AND peer_id = ?)`,
		me, peer, peer, me)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO companions (requester_id, peer_id, status, created_at)
			VALUES (?, ?, 'blocked', ?)`, me, peer, nowMs()); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) DeleteCompanion(ctx context.Context, me, peer string) error {
	_, err := s.db.ExecContext(ctx, `
		DELETE FROM companions
		WHERE (requester_id = ? AND peer_id = ?) OR (requester_id = ? AND peer_id = ?)`,
		me, peer, peer, me)
	return err
}

func (s *Store) ListCompanions(ctx context.Context, me string) ([]CompanionView, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT
			CASE WHEN c.requester_id = ? THEN c.peer_id ELSE c.requester_id END AS other,
			c.status,
			CASE WHEN c.peer_id = ? THEN 1 ELSE 0 END AS incoming,
			COALESCE(u.display_name, '')
		FROM companions c
		LEFT JOIN users u
			ON u.public_id = CASE WHEN c.requester_id = ? THEN c.peer_id ELSE c.requester_id END
		WHERE c.requester_id = ? OR c.peer_id = ?
		ORDER BY c.created_at DESC`,
		me, me, me, me, me)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []CompanionView
	for rows.Next() {
		var v CompanionView
		var incoming int
		if err := rows.Scan(&v.PeerID, &v.Status, &incoming, &v.DisplayName); err != nil {
			return nil, err
		}
		v.Incoming = incoming == 1
		out = append(out, v)
	}
	return out, rows.Err()
}

// AcceptedPeers returns the public_ids I'm allowed to pull changes from.
func (s *Store) AcceptedPeers(ctx context.Context, me string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT peer_id FROM companions WHERE requester_id = ? AND status = 'accepted'
		UNION
		SELECT requester_id FROM companions WHERE peer_id = ? AND status = 'accepted'`,
		me, me)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var peers []string
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, err
		}
		peers = append(peers, p)
	}
	return peers, rows.Err()
}

// ── Change feed (relay) ───────────────────────────────────────────────

type ChangeIn struct {
	ObjectType string `json:"object_type"`
	ObjectID   string `json:"object_id"`
	Payload    string `json:"-"` // raw JSON, stored verbatim
	Deleted    bool   `json:"deleted"`
	UpdatedAt  int64  `json:"updated_at"`
}

type ChangeOut struct {
	OwnerID    string `json:"owner_id"`
	ObjectType string `json:"object_type"`
	ObjectID   string `json:"object_id"`
	ServerSeq  int64  `json:"server_seq"`
	Payload    string `json:"-"` // raw JSON
	Deleted    bool   `json:"deleted"`
	UpdatedAt  int64  `json:"updated_at"`
}

// PushChanges upserts a batch of the caller's own objects, assigning each a new
// monotonic server_seq. Returns the seq assigned per object_id and the max.
func (s *Store) PushChanges(ctx context.Context, owner string, in []ChangeIn) (map[string]int64, int64, error) {
	results := make(map[string]int64, len(in))
	var maxSeq int64

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, 0, err
	}
	defer tx.Rollback()

	for _, c := range in {
		var seq int64
		if err := tx.QueryRowContext(ctx,
			`SELECT COALESCE(MAX(server_seq), 0) + 1 FROM changes`).Scan(&seq); err != nil {
			return nil, 0, err
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO changes (owner_id, object_type, object_id, server_seq, payload, deleted, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(owner_id, object_type, object_id) DO UPDATE SET
				server_seq = excluded.server_seq,
				payload    = excluded.payload,
				deleted    = excluded.deleted,
				updated_at = excluded.updated_at`,
			owner, c.ObjectType, c.ObjectID, seq, c.Payload, b2i(c.Deleted), c.UpdatedAt); err != nil {
			return nil, 0, err
		}
		results[c.ObjectID] = seq
		if seq > maxSeq {
			maxSeq = seq
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, 0, err
	}
	return results, maxSeq, nil
}

// PullChanges returns changes owned by the given peers with server_seq > cursor.
func (s *Store) PullChanges(ctx context.Context, owners []string, cursor int64, limit int) ([]ChangeOut, int64, error) {
	if len(owners) == 0 {
		return nil, cursor, nil
	}
	placeholders := strings.Repeat("?,", len(owners))
	placeholders = placeholders[:len(placeholders)-1]

	args := make([]any, 0, len(owners)+2)
	args = append(args, cursor)
	for _, o := range owners {
		args = append(args, o)
	}
	args = append(args, limit)

	rows, err := s.db.QueryContext(ctx, `
		SELECT owner_id, object_type, object_id, server_seq, payload, deleted, updated_at
		FROM changes
		WHERE server_seq > ? AND owner_id IN (`+placeholders+`)
		ORDER BY server_seq ASC
		LIMIT ?`, args...)
	if err != nil {
		return nil, cursor, err
	}
	defer rows.Close()

	out := []ChangeOut{}
	newCursor := cursor
	for rows.Next() {
		var c ChangeOut
		var deleted int
		if err := rows.Scan(&c.OwnerID, &c.ObjectType, &c.ObjectID, &c.ServerSeq,
			&c.Payload, &deleted, &c.UpdatedAt); err != nil {
			return nil, cursor, err
		}
		c.Deleted = deleted == 1
		out = append(out, c)
		if c.ServerSeq > newCursor {
			newCursor = c.ServerSeq
		}
	}
	return out, newCursor, rows.Err()
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}
