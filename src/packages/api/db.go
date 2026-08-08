package main

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"net"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib" // registers the "pgx" database/sql driver for goose
	"github.com/jackc/puddle/v2"
	"github.com/pressly/goose/v3"
)

//go:embed migrations/*.sql
var embeddedMigrations embed.FS

// dbPool is the shared connection pool. It is nil when the API runs in degraded
// mode (no DATABASE_URL, or the database was unreachable at startup).
var dbPool *pgxpool.Pool

// dbConfigured records whether a DATABASE_URL was provided at startup, so the
// health endpoint can distinguish "no database configured" from "configured
// but unreachable" when dbPool is nil. Set once in main before the server
// starts; read-only afterwards.
var dbConfigured bool

// initDB creates and verifies a connection pool. A non-nil error means the
// database is unreachable; callers treat that as degraded mode, not a crash.
func initDB(ctx context.Context, databaseURL string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse DATABASE_URL: %w", err)
	}
	// Pool sizing/liveness tuned for a small single-host (Raspberry Pi)
	// deployment: keep the pool modest, recycle connections so a Postgres
	// restart doesn't leave the pool holding dead sockets, and reap idle
	// connections. HealthCheckPeriod actively pings idle conns so a mid-idle
	// server restart is noticed and the conn replaced before a request grabs it.
	cfg.MaxConns = 10
	// MinConns = 2 keeps a couple of warm connections through quiet periods.
	// With MinConns = 0, MaxConnIdleTime (5m) drains the pool to zero on a
	// quiet single-user deployment, so the first click after any idle stretch
	// paid a fresh TCP + TLS + Postgres-auth handshake before its query ran.
	// The pool's background health check maintains the floor.
	cfg.MinConns = 2
	cfg.ConnConfig.ConnectTimeout = 5 * time.Second
	cfg.HealthCheckPeriod = 30 * time.Second
	cfg.MaxConnLifetime = 1 * time.Hour
	cfg.MaxConnIdleTime = 5 * time.Minute

	// Server-side statement timeout: cap any single query at 15s so a runaway
	// or lock-blocked statement can't pin a connection (and the caller's
	// request) indefinitely. Applied per-connection via a Postgres session
	// GUC, so it covers every query including sqlc-generated ones.
	if cfg.ConnConfig.RuntimeParams == nil {
		cfg.ConnConfig.RuntimeParams = map[string]string{}
	}
	cfg.ConnConfig.RuntimeParams["statement_timeout"] = "15000" // milliseconds

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("create pool: %w", err)
	}

	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping database: %w", err)
	}
	return pool, nil
}

// runMigrations applies all pending migrations using the embedded SQL files.
// It opens its own short-lived database/sql handle via the pgx stdlib driver.
func runMigrations(databaseURL string) error {
	db, err := sql.Open("pgx", databaseURL)
	if err != nil {
		return fmt.Errorf("open db for migrations: %w", err)
	}
	defer db.Close()

	goose.SetBaseFS(embeddedMigrations)
	if err := goose.SetDialect("postgres"); err != nil {
		return fmt.Errorf("set goose dialect: %w", err)
	}
	if err := goose.Up(db, "migrations"); err != nil {
		return fmt.Errorf("apply migrations: %w", err)
	}
	return nil
}

// pingDB reports whether the database is currently reachable. Returns false in
// degraded mode (nil pool).
func pingDB(ctx context.Context) bool {
	if dbPool == nil {
		return false
	}
	pingCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	return dbPool.Ping(pingCtx) == nil
}

// dbErrorStatus classifies a database error into the HTTP status a handler
// should surface. It exists so a transient DB outage (Postgres restarting, the
// pool being closed, a connection refused/reset) is treated as a RETRYABLE
// 503 — "service temporarily unavailable" — instead of leaking out as a 401
// (logging every user out on a blip) or a bare 500.
//
//   - 503: connection-level failure. The query never reached a live server.
//     Detected via pgconn.SafeToRetry (true only when the error occurred
//     before any bytes were sent), a closed pool, or any net error in the
//     chain. These are the "come back in a moment" cases.
//   - 0:   pgx.ErrNoRows — not an outage at all, just an absent row. The
//     caller decides what a missing row means (401/404/etc).
//   - 500: everything else, including a *pgconn.PgError (the server DID
//     respond, with an error code — the connection is alive, so this is a
//     server-side/logic error, not a transient blip). Also covers nil, which
//     no caller should pass but which maps to "not a DB problem".
func dbErrorStatus(err error) int {
	if err == nil {
		return 0
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return 0
	}
	// A PgError means Postgres received the statement and answered with an
	// SQLSTATE — the connection is healthy, so this is not a blip.
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return http.StatusInternalServerError
	}
	// Connection never delivered the query: refused/reset/dead-on-acquire.
	if pgconn.SafeToRetry(err) {
		return http.StatusServiceUnavailable
	}
	if errors.Is(err, puddle.ErrClosedPool) || errors.Is(err, puddle.ErrNotAvailable) {
		return http.StatusServiceUnavailable
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		return http.StatusServiceUnavailable
	}
	var opErr *net.OpError
	if errors.As(err, &opErr) {
		return http.StatusServiceUnavailable
	}
	return http.StatusInternalServerError
}
