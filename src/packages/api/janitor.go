package main

import (
	"context"
	"log"
	"log/slog"
	"math/rand"
	"time"

	"travel-route-planner/store"
)

// Background janitor (perf: hot-path tax removal). The expired-session and
// stale-plan-chat prunes used to run opportunistically inside every
// authenticated request (authMiddleware) and every GET /chats — a DELETE tax
// on the hot path. They now run here, once an hour, off the request path.
// Auth correctness is untouched: authMiddleware still rejects expired
// sessions by timestamp comparison before any request proceeds; this loop
// only reclaims dead rows. The opportunistic janitor call in
// oauth_provider_handler.go is intentionally left in place — /oauth/authorize
// is a rare path, not a hot one.
//
// Loop shape cloned from ops_monitor.go: jittered first tick (so restarts
// don't synchronize prunes across processes), time.NewTicker, panic-safe per
// tick via safeRun, context cancel for shutdown, dbPool-nil guard.

const (
	janitorInterval = time.Hour

	// janitorTickTimeout bounds one tick's DB work so a wedged database can't
	// pin a tick past its usefulness; the next tick retries anyway.
	janitorTickTimeout = 30 * time.Second
)

// startJanitor launches the background loop. No-ops (with a log line) when
// persistence is unavailable — with no DB there is nothing to prune; the
// janitor resumes on next boot once a database is configured, exactly like
// startHealthMonitor.
func startJanitor(ctx context.Context) {
	if dbPool == nil {
		log.Printf("janitor: disabled (no database)")
		return
	}
	go runJanitor(ctx)
	log.Printf("janitor: started (tick %s)", janitorInterval)
}

func runJanitor(ctx context.Context) {
	// Jitter the first tick so restarts don't synchronize a burst of prunes.
	select {
	case <-ctx.Done():
		return
	case <-time.After(time.Duration(rand.Int63n(int64(janitorInterval)))):
	}
	ticker := time.NewTicker(janitorInterval)
	defer ticker.Stop()
	for {
		// Guard each tick: a panic in one cycle must not kill the ticker (and
		// with it the whole process). Log-and-continue to the next tick.
		safeRun("janitor tick", func() { janitorTick(ctx) })
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// janitorTick runs both prunes under one bounded context. The sqlc queries
// are :exec (no affected-row count comes back), so the debug lines record
// that the prune ran, not how many rows it reclaimed.
func janitorTick(ctx context.Context) {
	tickCtx, cancel := context.WithTimeout(ctx, janitorTickTimeout)
	defer cancel()
	q := store.New(dbPool)
	if err := q.DeleteExpiredSessions(tickCtx); err != nil {
		slog.Warn("janitor: delete expired sessions failed", "error", err)
	} else {
		slog.Debug("janitor: pruned expired sessions")
	}
	if err := q.DeleteStalePlanChatSessions(tickCtx); err != nil {
		slog.Warn("janitor: delete stale plan chat sessions failed", "error", err)
	} else {
		slog.Debug("janitor: pruned stale plan chat sessions")
	}
}
