package main

import (
	"errors"
	"net/http"
)

type peerReq struct {
	PeerID string `json:"peer_id"`
}

// POST /v1/companions/request — ask to pair with peer (scanned their QR).
// If peer already requested me, this reciprocates into an accepted edge.
func (s *Server) handleCompanionRequest(w http.ResponseWriter, r *http.Request, me string) {
	var req peerReq
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.PeerID == "" || req.PeerID == me {
		writeErr(w, http.StatusBadRequest, "invalid peer_id")
		return
	}
	if err := s.store.RequestCompanion(r.Context(), me, req.PeerID); err != nil {
		writeErr(w, http.StatusInternalServerError, "could not request")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
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
