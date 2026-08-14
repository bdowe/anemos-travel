-- Uptime history for the admin Health pane's 90-day status strip
-- (specs/uptime-history). Written by the health monitor (ops_monitor.go), read
-- once per graph request by ops_uptime.go, pruned hourly by janitor.go.
-- Nothing else touches health_samples.

-- name: InsertHealthSample :exec
-- One observation interval. ON CONFLICT DO NOTHING because two writers can
-- collide on the natural key: the retry buffer flushes a held sample while a
-- live tick is in flight, and Postgres stores timestamptz at microsecond
-- resolution. A dropped duplicate costs nothing — the rollup reads the stream,
-- never an individual row.
INSERT INTO health_samples (observed_at, covers_from, kind, release, gap_cause, db_ok, ai_ok, backups_ok)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
ON CONFLICT (observed_at) DO NOTHING;

-- name: HealthSamplesSince :many
-- The sample stream for the graph window, plus ONE anchor row from before it.
-- The anchor is load-bearing: a row covers the span ending at observed_at, so
-- the row that straddles the window's opening midnight is the only evidence
-- for the first minutes of day zero. Without it every window would open as
-- "no data" until its first tick. Ascending — the rollup is one forward walk.
SELECT s.observed_at, s.covers_from, s.kind, s.gap_cause, s.db_ok, s.ai_ok, s.backups_ok
FROM health_samples s
WHERE s.observed_at >= COALESCE(
        (SELECT max(a.observed_at) FROM health_samples a WHERE a.observed_at < sqlc.arg(since)),
        sqlc.arg(since))
ORDER BY s.observed_at;

-- name: LastHealthSample :one
-- The newest observation, read once at boot: its timestamp opens the boot gap,
-- and its release decides whether that gap was a deploy or something
-- unexplained. pgx.ErrNoRows means monitoring simply starts now.
SELECT observed_at, release FROM health_samples ORDER BY observed_at DESC LIMIT 1;

-- name: EarliestHealthSample :one
-- The first observation ever recorded, so the pane can say "monitoring since
-- <date>" and a grey bar reads as "before we were watching" rather than as an
-- outage. pgx.ErrNoRows means day one, or a fresh restore.
SELECT observed_at FROM health_samples ORDER BY observed_at LIMIT 1;

-- name: DeleteOldHealthSamples :exec
-- Retention: 100 days — the 90-day window plus ten days of slack, so the
-- oldest bar is never half-pruned and day zero always still has its anchor.
-- ~29k rows steady state at the default 5-minute cadence.
DELETE FROM health_samples WHERE observed_at < now() - interval '100 days';
