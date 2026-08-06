package main

import (
	"crypto/sha256"
	"errors"
	"net/http"
)

type peerReq struct {
	PeerID string `json:"peer_id"`
}

// companionRequestReq is the request endpoint's own body type (accept/block
// keep the narrower peerReq, since decodeJSON rejects unknown fields).
type companionRequestReq struct {
	PeerID  string `json:"peer_id"`
	PeerKey string `json:"peer_key,omitempty"` // optional, carried by the pairing link
	Strict  bool   `json:"strict,omitempty"`   // user-initiated add → report duplicates
}

// POST /v1/companions/request — ask to pair with peer (scanned their QR or
// pasted their link). If peer already requested me, this reciprocates into an
// accepted edge.
//
// Two callers with different needs share this endpoint. A user-initiated add
// sends strict=true and wants to hear about duplicates, blocks and unknown
// accounts so the app can explain the failure. The background reconciler
// (_pushPendingRequests) re-sends every outstanding request on every sync and
// needs the opposite: silent idempotence, or a stale duplicate would fail the
// whole sync. Only strict callers get the 404/409s.
func (s *Server) handleCompanionRequest(w http.ResponseWriter, r *http.Request, me string) {
	var req companionRequestReq
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.PeerID == "" {
		writeErr(w, http.StatusBadRequest, "invalid peer_id")
		return
	}
	if req.PeerID == me {
		writeErr(w, http.StatusBadRequest, "that's your own link")
		return
	}
	// A public_id is base64url(SHA-256(public_key)) — anything else can never
	// name a real account.
	if raw, err := b64uDecode(req.PeerID); err != nil || len(raw) != sha256.Size {
		writeErr(w, http.StatusBadRequest, "invalid peer_id")
		return
	}
	if req.PeerKey != "" {
		keyBytes, err := b64uDecode(req.PeerKey)
		if err != nil || derivePublicID(keyBytes) != req.PeerID {
			writeErr(w, http.StatusBadRequest, "that link's key doesn't match its id")
			return
		}
	}

	user, err := s.store.GetUser(r.Context(), req.PeerID)
	switch {
	case errors.Is(err, ErrNotFound):
		// Not registered (yet). Strict callers hear about it; the reconciler
		// keeps the request queued so pairing self-heals once they sign up.
		if req.Strict {
			writeErr(w, http.StatusNotFound, "no Arc account for that link yet")
			return
		}
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "could not request")
		return
	case req.PeerKey != "" && user.PublicKey != req.PeerKey:
		writeErr(w, http.StatusBadRequest, "that link doesn't match that account")
		return
	}

	result, err := s.store.RequestCompanion(r.Context(), me, req.PeerID, req.Strict)
	switch {
	case errors.Is(err, ErrCompanionExists):
		writeErr(w, http.StatusConflict, "you're already companions")
		return
	case errors.Is(err, ErrCompanionPending):
		writeErr(w, http.StatusConflict, "request already sent")
		return
	case errors.Is(err, ErrCompanionBlocked):
		writeErr(w, http.StatusConflict, "that companion is blocked")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "could not request")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "result": result})
}

// GET /v1/companions — my edges, including incoming pending requests.
func (s *Server) handleCompanionList(w http.ResponseWriter, r *http.Request, me string) {
	list, err := s.store.ListCompanions(r.Context(), me)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not list companions")
		return
	}
	if list == nil {
		list = []CompanionView{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"companions": list})
}

// POST /v1/companions/accept — accept a pending request peer sent me.
func (s *Server) handleCompanionAccept(w http.ResponseWriter, r *http.Request, me string) {
	var req peerReq
	if !decodeJSON(w, r, &req) {
		return
	}
	err := s.store.AcceptCompanion(r.Context(), me, req.PeerID)
	if errors.Is(err, ErrNoPendingRequest) {
		writeErr(w, http.StatusConflict, "no pending request from that peer")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not accept")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// POST /v1/companions/block — block peer (severs sync both ways).
func (s *Server) handleCompanionBlock(w http.ResponseWriter, r *http.Request, me string) {
	var req peerReq
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.PeerID == "" {
		writeErr(w, http.StatusBadRequest, "invalid peer_id")
		return
	}
	if err := s.store.BlockCompanion(r.Context(), me, req.PeerID); err != nil {
		writeErr(w, http.StatusInternalServerError, "could not block")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// DELETE /v1/companions/{peer} — remove the relationship entirely.
func (s *Server) handleCompanionDelete(w http.ResponseWriter, r *http.Request, me string) {
	peer := r.PathValue("peer")
	if peer == "" {
		writeErr(w, http.StatusBadRequest, "missing peer")
		return
	}
	if err := s.store.DeleteCompanion(r.Context(), me, peer); err != nil {
		writeErr(w, http.StatusInternalServerError, "could not delete")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
