package main

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

// Server holds shared dependencies for the HTTP handlers.
type Server struct {
	store *Store
}

const maxBodyBytes = 4 << 20 // 4 MiB cap on request bodies

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()

	// Auth (unauthenticated).
	mux.HandleFunc("GET /v1/health", s.handleHealth)
	mux.HandleFunc("POST /v1/register", s.handleRegister)
	mux.HandleFunc("POST /v1/auth/challenge", s.handleChallenge)
	mux.HandleFunc("POST /v1/auth/verify", s.handleVerify)

	// Profile (authenticated).
	mux.Handle("GET /v1/me", s.auth(s.handleMe))

	// Companions (authenticated).
	mux.Handle("POST /v1/companions/request", s.auth(s.handleCompanionRequest))
	mux.Handle("GET /v1/companions", s.auth(s.handleCompanionList))
	mux.Handle("POST /v1/companions/accept", s.auth(s.handleCompanionAccept))
	mux.Handle("POST /v1/companions/block", s.auth(s.handleCompanionBlock))
	mux.Handle("DELETE /v1/companions/{peer}", s.auth(s.handleCompanionDelete))

	// Sync (authenticated).
	mux.Handle("POST /v1/sync/push", s.auth(s.handleSyncPush))
	mux.Handle("GET /v1/sync/pull", s.auth(s.handleSyncPull))
	mux.Handle("GET /v1/sync/self", s.auth(s.handleSyncSelf))

	return logging(mux)
}

// authedHandler is a handler that has a verified caller public_id.
type authedHandler func(w http.ResponseWriter, r *http.Request, userID string)

// auth wraps a handler with bearer-token authentication.
func (s *Server) auth(h authedHandler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := bearerToken(r)
		userID, ok := s.store.UserForToken(r.Context(), token)
		if !ok {
			writeErr(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		s.store.TouchLastSeen(r.Context(), userID)
		h(w, r, userID)
	})
}

func bearerToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if after, ok := strings.CutPrefix(h, "Bearer "); ok {
		return strings.TrimSpace(after)
	}
	return ""
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// ── helpers ───────────────────────────────────────────────────────────

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// decodeJSON reads a size-capped JSON body into dst.
func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeErr(w, http.StatusRequestEntityTooLarge, "request body too large")
		} else if errors.Is(err, io.EOF) {
			writeErr(w, http.StatusBadRequest, "empty request body")
		} else {
			writeErr(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		}
		return false
	}
	return true
}

// logging is a minimal request logger / panic guard.
func logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		defer func() {
			if rec := recover(); rec != nil {
				log.Printf("panic %s %s: %v", r.Method, r.URL.Path, rec)
				writeErr(sw, http.StatusInternalServerError, "internal error")
			}
			log.Printf("%s %s %d %s", r.Method, r.URL.Path, sw.status, time.Since(start))
		}()
		next.ServeHTTP(sw, r)
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
	wrote  bool
}

func (w *statusWriter) WriteHeader(code int) {
	if !w.wrote {
		w.status = code
		w.wrote = true
		w.ResponseWriter.WriteHeader(code)
	}
}

func (w *statusWriter) Write(b []byte) (int, error) {
	w.wrote = true
	return w.ResponseWriter.Write(b)
}
