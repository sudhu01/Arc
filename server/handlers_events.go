package main

import (
	"encoding/json"
	"net/http"
	"strconv"
)

const (
	defaultEventLimit = 200
	maxEventLimit     = 500
	maxEventsPerPush  = 100
)

var allowedEventKinds = map[string]bool{"workout_started": true, "pr": true}

type eventWire struct {
	ID        string          `json:"id"`
	Kind      string          `json:"kind"`
	Payload   json.RawMessage `json:"payload"`
	CreatedAt int64           `json:"created_at"`
}

type publishReq struct {
	Events []eventWire `json:"events"`
}

// POST /v1/events — publish my moments. Owner is always the caller. Idempotent
// on the client-generated `id`, so the client's outbox can retry freely.
func (s *Server) handleEventPublish(w http.ResponseWriter, r *http.Request, me string) {
	var req publishReq
	if !decodeJSON(w, r, &req) {
		return
	}
	if len(req.Events) > maxEventsPerPush {
		writeErr(w, http.StatusBadRequest, "too many events in one publish")
		return
	}
	in := make([]EventIn, 0, len(req.Events))
	for _, e := range req.Events {
		if e.ID == "" {
			writeErr(w, http.StatusBadRequest, "missing event id")
			return
		}
		if !allowedEventKinds[e.Kind] {
			writeErr(w, http.StatusBadRequest, "unknown event kind: "+e.Kind)
			return
		}
		payload := "null"
		if len(e.Payload) > 0 {
			payload = string(e.Payload)
		}
		in = append(in, EventIn{
			ID:        e.ID,
			Kind:      e.Kind,
			Payload:   payload,
			CreatedAt: e.CreatedAt,
		})
	}

	cursor, err := s.store.PublishEvents(r.Context(), me, in)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "publish failed")
		return
	}

	// Nudge the people who are allowed to see this. Detached and best-effort —
	// they'd get it on their next poll regardless.
	if cursor > 0 {
		if peers, err := s.store.AcceptedPeers(r.Context(), me); err == nil {
			s.push.Wake(peers)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"cursor": cursor})
}

type eventOutWire struct {
	ID        string          `json:"id"`
	OwnerID   string          `json:"owner_id"`
	OwnerName string          `json:"owner_name"`
	Kind      string          `json:"kind"`
	ServerSeq int64           `json:"server_seq"`
	Payload   json.RawMessage `json:"payload"`
	CreatedAt int64           `json:"created_at"`
}

// GET /v1/events?cursor=N&limit=M — accepted companions' moments, oldest first.
// Gated by exactly the same edge as the change feed: no acceptance, no events.
func (s *Server) handleEventPull(w http.ResponseWriter, r *http.Request, me string) {
	peers, err := s.store.AcceptedPeers(r.Context(), me)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "pull failed")
		return
	}

	cursor, _ := strconv.ParseInt(r.URL.Query().Get("cursor"), 10, 64)
	if cursor < 0 {
		cursor = 0
	}
	limit := defaultEventLimit
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 {
		limit = v
	}
	if limit > maxEventLimit {
		limit = maxEventLimit
	}

	events, newCursor, err := s.store.PullEvents(r.Context(), peers, cursor, limit)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "pull failed")
		return
	}
	out := make([]eventOutWire, 0, len(events))
	for _, e := range events {
		out = append(out, eventOutWire{
			ID:        e.ID,
			OwnerID:   e.OwnerID,
			OwnerName: e.OwnerName,
			Kind:      e.Kind,
			ServerSeq: e.ServerSeq,
			Payload:   json.RawMessage(e.Payload),
			CreatedAt: e.CreatedAt,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": out, "cursor": newCursor})
}

type deviceReq struct {
	Token    string `json:"token"`
	Platform string `json:"platform"`
}

var allowedPlatforms = map[string]bool{"android": true, "ios": true, "web": true}

// POST /v1/devices — claim a push token for this account. Harmless to call on a
// relay with no FCM credentials: the row is simply never read.
func (s *Server) handleDeviceRegister(w http.ResponseWriter, r *http.Request, me string) {
	var req deviceReq
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.Token == "" {
		writeErr(w, http.StatusBadRequest, "missing token")
		return
	}
	if !allowedPlatforms[req.Platform] {
		writeErr(w, http.StatusBadRequest, "unknown platform: "+req.Platform)
		return
	}
	if err := s.store.RegisterDevice(r.Context(), me, req.Token, req.Platform); err != nil {
		writeErr(w, http.StatusInternalServerError, "register failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// DELETE /v1/devices/{token} — release a push token (sign-out, identity swap).
func (s *Server) handleDeviceDelete(w http.ResponseWriter, r *http.Request, me string) {
	token := r.PathValue("token")
	if token == "" {
		writeErr(w, http.StatusBadRequest, "missing token")
		return
	}
	if err := s.store.DeleteDevice(r.Context(), me, token); err != nil {
		writeErr(w, http.StatusInternalServerError, "delete failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
