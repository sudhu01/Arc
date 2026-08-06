package main

// Total weight lifted ("volume") was removed from Arc: it is no longer shown
// anywhere in the app and is no longer a quantity the product tracks.
//
// It was always a *derived* number (Σ weight × reps) rather than a column, so
// the relay never had a volume field of its own to drop. What it does hold is
// the opaque session payload clients push — and an older app version is free to
// embed a precomputed volume in there. So the relay carries two safeguards:
//
//  1. sanitizeLegacyVolume strips the keys from every incoming push, so an old
//     client can never (re)introduce the value; and
//  2. Store.PurgeLegacyVolume rewrites any rows that already carry them, so the
//     value is purged for every user already in the database.
//
// Older app versions degrade gracefully rather than erroring: the key is simply
// absent from the JSON object they receive, which decodes to null (Dart
// `payload['volume']` → null, Go → zero value) instead of throwing.

import (
	"context"
	"encoding/json"
	"strings"
)

// metaKeyVolumePurged marks the one-shot purge as done in the `meta` table.
const metaKeyVolumePurged = "legacy_volume_purged"

// Every spelling of the field that has shipped in a client payload, plus the
// obvious variants, so nothing survives on a naming technicality.
var legacyVolumeKeys = map[string]bool{
	"volume":         true,
	"Volume":         true,
	"total_volume":   true,
	"totalVolume":    true,
	"totalVol":       true,
	"total_vol":      true,
	"session_volume": true,
	"sessionVolume":  true,
}

// mightContainLegacyVolume is a cheap pre-filter so the common case (a clean
// payload) never pays for a decode/re-encode round trip.
func mightContainLegacyVolume(payload string) bool {
	return strings.Contains(payload, "vol") || strings.Contains(payload, "Vol")
}

// stripLegacyVolume removes legacy volume keys from a decoded JSON value,
// recursing through nested objects and arrays (entries carried their own copy
// in some client builds). Reports whether anything was removed.
func stripLegacyVolume(v any) bool {
	switch t := v.(type) {
	case map[string]any:
		removed := false
		for k := range t {
			if legacyVolumeKeys[k] {
				delete(t, k)
				removed = true
			}
		}
		for _, child := range t {
			if stripLegacyVolume(child) {
				removed = true
			}
		}
		return removed
	case []any:
		removed := false
		for _, child := range t {
			if stripLegacyVolume(child) {
				removed = true
			}
		}
		return removed
	}
	return false
}

// sanitizeLegacyVolume returns payload with any legacy volume keys removed.
// A payload the relay can't parse is returned verbatim: this is a store-and-
// forward service and must never corrupt data it doesn't understand.
func sanitizeLegacyVolume(payload string) string {
	if !mightContainLegacyVolume(payload) {
		return payload
	}
	var v any
	if err := json.Unmarshal([]byte(payload), &v); err != nil {
		return payload
	}
	if !stripLegacyVolume(v) {
		return payload
	}
	out, err := json.Marshal(v)
	if err != nil {
		return payload
	}
	return string(out)
}

// PurgeLegacyVolume strips legacy volume keys from every change row already in
// the database, for all owners. It runs once (guarded by the `meta` table) and
// is safe to re-run: a second pass simply finds nothing to rewrite.
//
// server_seq and updated_at are deliberately left alone. Bumping them would
// re-fan the whole feed out to every companion just to communicate the absence
// of a field nobody reads — and would make every device redownload its history.
func (s *Store) PurgeLegacyVolume(ctx context.Context) (int, error) {
	var done string
	err := s.db.QueryRowContext(ctx,
		`SELECT value FROM meta WHERE key = ?`, metaKeyVolumePurged).Scan(&done)
	if err == nil {
		return 0, nil // already purged
	}
	if !isNoRows(err) {
		return 0, err
	}

	// LIKE is case-insensitive for ASCII in SQLite, so one pattern catches
	// `volume`, `Volume`, `totalVol`, … Narrowing here keeps the rewrite off
	// the (much larger) set of already-clean rows.
	rows, err := s.db.QueryContext(ctx,
		`SELECT owner_id, object_type, object_id, payload
		 FROM changes WHERE payload LIKE '%vol%'`)
	if err != nil {
		return 0, err
	}
	type row struct{ owner, typ, id, payload string }
	var dirty []row
	for rows.Next() {
		var r row
		if err := rows.Scan(&r.owner, &r.typ, &r.id, &r.payload); err != nil {
			rows.Close()
			return 0, err
		}
		if clean := sanitizeLegacyVolume(r.payload); clean != r.payload {
			r.payload = clean
			dirty = append(dirty, r)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	for _, r := range dirty {
		if _, err := tx.ExecContext(ctx, `
			UPDATE changes SET payload = ?
			WHERE owner_id = ? AND object_type = ? AND object_id = ?`,
			r.payload, r.owner, r.typ, r.id); err != nil {
			return 0, err
		}
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO meta (key, value) VALUES (?, ?)
		 ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
		metaKeyVolumePurged, "1"); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return len(dirty), nil
}
