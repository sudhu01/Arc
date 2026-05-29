package main

import (
	"encoding/json"
	"net/http"
	"strconv"
)

const (
	defaultPullLimit = 500
	maxPullLimit     = 1000
)

var allowedObjectTypes = map[string]bool{"session": true, "exercise": true}

type pushChangeWire struct {
	ObjectType string          `json:"object_type"`
	ObjectID   string          `json:"object_id"`
	Payload    json.RawMessage `json:"payload"`
	Deleted    bool            `json:"deleted"`
	UpdatedAt  int64           `json:"updated_at"`
}

type pushReq struct {
	Changes []pushChangeWire `json:"changes"`
}

type pushResult struct {
	ObjectID  string `json:"object_id"`
	ServerSeq int64  `json:"server_seq"`
}

// POST /v1/sync/push — upload my dirty objects. owner is always the caller;
// any client-supplied owner is ignored. Returns the server_seq assigned to each
// object so the client can clear its dirty flags.
func (s *Server) handleSyncPush(w http.ResponseWriter, r *http.Request, me string) {
	var req pushReq
	if !decodeJSON(w, r, &req) {
		return
	}
	in := make([]ChangeIn, 0, len(req.Changes))
	for _, c := range req.Changes {
		if !allowedObjectTypes[c.ObjectType] {
			writeErr(w, http.StatusBadRequest, "unknown object_type: "+c.ObjectType)
			return
		}
		if c.ObjectID == "" {
			writeErr(w, http.StatusBadRequest, "missing object_id")
			return
		}
		payload := "null"
		if len(c.Payload) > 0 {
			payload = string(c.Payload)
		}
		in = append(in, ChangeIn{
			ObjectType: c.ObjectType,
			ObjectID:   c.ObjectID,
			Payload:    payload,
			Deleted:    c.Deleted,
			UpdatedAt:  c.UpdatedAt,
		})
	}

	seqs, maxSeq, err := s.store.PushChanges(r.Context(), me, in)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "push failed")
		return
	}
	results := make([]pushResult, 0, len(seqs))
	for _, c := range in {
		results = append(results, pushResult{ObjectID: c.ObjectID, ServerSeq: seqs[c.ObjectID]})
	}
	writeJSON(w, http.StatusOK, map[string]any{"results": results, "cursor": maxSeq})
}

type pullChangeWire struct {
	OwnerID    string          `json:"owner_id"`
	ObjectType string          `json:"object_type"`
	ObjectID   string          `json:"object_id"`
	ServerSeq  int64           `json:"server_seq"`
	Payload    json.RawMessage `json:"payload"`
	Deleted    bool            `json:"deleted"`
	UpdatedAt  int64           `json:"updated_at"`
}

// GET /v1/sync/pull?cursor=N&limit=M — download accepted companions' changes
// with server_seq > cursor. The client applies them with owner_id = companion
// and resolves by updated_at (last-write-wins).
func (s *Server) handleSyncPull(w http.ResponseWriter, r *http.Request, me string) {
	peers, err := s.store.AcceptedPeers(r.Context(), me)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "pull failed")
		return
	}
	s.writeChangesFor(w, r, peers)
}

// GET /v1/sync/self?cursor=N&limit=M — download the *caller's own* change feed
// with server_seq > cursor. Used to rebuild a device after restoring an
// identity from a recovery phrase: the relay still holds the latest state of
// every object the user pushed (push upserts in place), so a fresh device can
// re-download its own workouts. The client applies these with owner_id = self.
func (s *Server) handleSyncSelf(w http.ResponseWriter, r *http.Request, me string) {
	s.writeChangesFor(w, r, []string{me})
}

// writeChangesFor parses the cursor/limit query params, fetches the change feed
// for the given owners, and writes the standard pull response.
func (s *Server) writeChangesFor(w http.ResponseWriter, r *http.Request, owners []string) {
	cursor, _ := strconv.ParseInt(r.URL.Query().Get("cursor"), 10, 64)
	if cursor < 0 {
		cursor = 0
	}
	limit := defaultPullLimit
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 {
		limit = v
	}
	if limit > maxPullLimit {
		limit = maxPullLimit
	}

	changes, newCursor, err := s.store.PullChanges(r.Context(), owners, cursor, limit)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "pull failed")
		return
	}
	out := make([]pullChangeWire, 0, len(changes))
	for _, c := range changes {
		out = append(out, pullChangeWire{
			OwnerID:    c.OwnerID,
			ObjectType: c.ObjectType,
			ObjectID:   c.ObjectID,
			ServerSeq:  c.ServerSeq,
			Payload:    json.RawMessage(c.Payload),
			Deleted:    c.Deleted,
			UpdatedAt:  c.UpdatedAt,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"changes": out, "cursor": newCursor})
}
