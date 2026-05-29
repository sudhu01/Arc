// Command arc-server is the Arc companion-sync relay: a thin store-and-forward
// service that verifies device signatures and fans each user's change feed out
// to their accepted companions. Device SQLite remains the source of truth.
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	addr := env("ARC_ADDR", ":8080")
	dbPath := env("ARC_DB", "arc-server.db")
	tlsCert := os.Getenv("ARC_TLS_CERT")
	tlsKey := os.Getenv("ARC_TLS_KEY")

	store, err := OpenStore(dbPath)
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	defer store.Close()

	srv := &Server{store: store}
	httpServer := &http.Server{
		Addr:              addr,
		Handler:           srv.routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	// Janitor: periodically purge expired challenges/tokens.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go janitor(ctx, store)

	// Start serving.
	go func() {
		var serveErr error
		if tlsCert != "" && tlsKey != "" {
			log.Printf("arc-server listening on %s (TLS)", addr)
			serveErr = httpServer.ListenAndServeTLS(tlsCert, tlsKey)
		} else {
			log.Printf("arc-server listening on %s (plain HTTP — terminate TLS upstream)", addr)
			serveErr = httpServer.ListenAndServe()
		}
		if serveErr != nil && serveErr != http.ErrServerClosed {
			log.Fatalf("serve: %v", serveErr)
		}
	}()

	// Graceful shutdown.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	log.Println("shutting down…")

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
}

func janitor(ctx context.Context, store *Store) {
	ticker := time.NewTicker(15 * time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			store.PurgeExpired(ctx)
		}
	}
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
