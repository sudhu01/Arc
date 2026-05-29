package main

import (
	"errors"
	"net/http"
	"time"
)

const (
	challengeTTL = 2 * time.Minute
	tokenTTL     = 30 * 24 * time.Hour
)

type registerReq struct {
	PublicID    string `json:"public_id"`
	PublicKey   string `json:"public_key"`
	DisplayName string `json:"display_name"`
	Sig         string `json:"sig"` // signature over public_id, proves key ownership
}

// POST /v1/register — announce a public key. Idempotent. The server enforces
// public_id == base64url(SHA-256(public_key)) and a self-signature so a caller
// can only register an identity it actually holds the private key for.
func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req registerReq
	if !decodeJSON(w, r, &req) {
		return
	}
	pubBytes, err := b64uDecode(req.PublicKey)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid public_key encoding")
		return
	}
	if req.PublicID == "" || req.PublicID != derivePublicID(pubBytes) {
		writeErr(w, http.StatusBadRequest, "public_id does not match public_key")
		return
	}
	if !verifySig(req.PublicKey, req.Sig, []byte(req.PublicID)) {
		writeErr(w, http.StatusBadRequest, "signature does not verify")
		return
	}
	if err := s.store.UpsertUser(r.Context(), req.PublicID, req.PublicKey, req.DisplayName); err != nil {
		writeErr(w, http.StatusInternalServerError, "could not register")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"public_id": req.PublicID})
}

// GET /v1/me — the caller's own profile. Used by a restored device to bring
// its display name back locally (the change feed carries workouts, not the
// profile name).
func (s *Server) handleMe(w http.ResponseWriter, r *http.Request, me string) {
	user, err := s.store.GetUser(r.Context(), me)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "lookup failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"public_id":    user.PublicID,
		"display_name": user.DisplayName,
	})
}

type challengeReq struct {
	PublicID string `json:"public_id"`
}

// POST /v1/auth/challenge — issue a one-time nonce for a registered identity.
func (s *Server) handleChallenge(w http.ResponseWriter, r *http.Request) {
	var req challengeReq
	if !decodeJSON(w, r, &req) {
		return
	}
	if _, err := s.store.GetUser(r.Context(), req.PublicID); err != nil {
		writeErr(w, http.StatusNotFound, "unknown public_id; register first")
		return
	}
	nonce, err := randB64u(32)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not create challenge")
		return
	}
	expiresAt := time.Now().Add(challengeTTL).UnixMilli()
	if err := s.store.CreateChallenge(r.Context(), req.PublicID, nonce, expiresAt); err != nil {
		writeErr(w, http.StatusInternalServerError, "could not create challenge")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"nonce": nonce, "expires_at": expiresAt})
}

type verifyReq struct {
	PublicID  string `json:"public_id"`
	Nonce     string `json:"nonce"`
	Signature string `json:"signature"`
}

// POST /v1/auth/verify — exchange a signed nonce for a bearer session token.
func (s *Server) handleVerify(w http.ResponseWriter, r *http.Request) {
	var req verifyReq
	if !decodeJSON(w, r, &req) {
		return
	}
	owner, err := s.store.ConsumeChallenge(r.Context(), req.Nonce)
	if errors.Is(err, ErrNotFound) || owner != req.PublicID {
		writeErr(w, http.StatusUnauthorized, "invalid or expired challenge")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "verify failed")
		return
	}
	user, err := s.store.GetUser(r.Context(), req.PublicID)
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "unknown public_id")
		return
	}
	if !verifySig(user.PublicKey, req.Signature, []byte(req.Nonce)) {
		writeErr(w, http.StatusUnauthorized, "signature does not verify")
		return
	}
	token, err := randB64u(32)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not issue token")
		return
	}
	expiresAt := time.Now().Add(tokenTTL).UnixMilli()
	if err := s.store.CreateToken(r.Context(), token, req.PublicID, expiresAt); err != nil {
		writeErr(w, http.StatusInternalServerError, "could not issue token")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"token":      token,
		"expires_at": expiresAt,
		"public_id":  req.PublicID,
	})
}
