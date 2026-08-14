-- +goose Up
-- Uptime history for the admin Health pane's 90-day status strip
-- (specs/uptime-history). The first persisted ops signal: everything else the
-- ops stack knows about itself is process-lifetime (ops_metrics.go) or
-- in-memory (healthMonitor.lastReasons), and production recreates the API
-- container on every push to main — 6-12 times a day — so none of it survives
-- long enough to fill a bar. This revisits ops_monitor.go's "not worth a
-- table" call: the alerting dedup still doesn't need one, but a graph does.
--
-- EVERY ROW IS AN INTERVAL WITH A STATE. covers_from..observed_at is the span
-- the row accounts for, so the rollup (ops_uptime.go) sums labeled intervals
-- and infers nothing. Two consequences that are the whole point:
--   * Changing HEALTH_TICK_MINUTES cannot retroactively re-score history —
--     each row already states its own span, so no denominator is derived from
--     today's environment.
--   * "A missing row means downtime" never becomes a convention someone has to
--     remember. The sampler cannot observe its own downtime, so at boot it
--     writes an explicit 'gap' row for the span since the last observation
--     (docs/zen.md: conventions get promoted to storage).
--
-- SINGLE-OBSERVER STREAM: rows here mean "what THIS process observed about
-- itself" — which is blind to a gateway, tunnel, or edge outage, and the pane
-- says so. An observation made from outside the process (an external prober)
-- is a different kind of fact — HTTP reachability of a URL, not a component
-- boolean — and gets its own table. Do not merge two observers in here.
CREATE TABLE health_samples (
    -- The instant of the observation, and the end of the span it covers. This
    -- IS the identity: every read is an ordered walk over it, so the natural
    -- key gives us the only index we need on a ~29k-row append-only series
    -- that nothing ever looks up by id.
    observed_at TIMESTAMPTZ PRIMARY KEY,
    covers_from TIMESTAMPTZ NOT NULL,

    -- 'tick' — a self-check: the three booleans below hold for the interval it
    --          closes (attributed BACKWARD; the observation closes the span it
    --          describes, so a signal that broke mid-interval is charged to the
    --          whole interval rather than credited as healthy).
    -- 'gap'  — time nobody observed, written at boot for the span since the
    --          previous row. gap_cause says whether that absence is explained.
    kind TEXT NOT NULL CHECK (kind IN ('tick', 'gap')),

    -- SENTRY_RELEASE at write time (empty outside CI builds). The boot gap's
    -- cause is decided by comparing it with the previous row's: a changed
    -- release is a deploy, an unchanged one is a crash, OOM, or host reboot.
    release TEXT NOT NULL DEFAULT '',

    -- gap rows only. 'deploy' is unobserved time (counted in neither half of
    -- the ratio — 6-12 deploys/day would otherwise invent ~4%/day of phantom
    -- downtime); 'unknown' is downtime, and is the only thing that can paint a
    -- bar red without a health signal actually having failed.
    gap_cause TEXT CHECK (gap_cause IS NULL OR gap_cause IN ('deploy', 'unknown')),

    -- tick rows only: the three signals computeHealthState (ops_health.go)
    -- already evaluates, stored as SEPARATE booleans and never as a joined
    -- reasons string. That is what makes it structurally impossible for a
    -- stale backup — ops hygiene, not unavailability — to tint the API bar.
    db_ok BOOLEAN,
    ai_ok BOOLEAN,
    backups_ok BOOLEAN,

    CHECK (covers_from <= observed_at),
    CHECK ((kind = 'tick') = (db_ok IS NOT NULL AND ai_ok IS NOT NULL AND backups_ok IS NOT NULL)),
    CHECK ((kind = 'gap') = (gap_cause IS NOT NULL))
);

-- +goose Down
DROP TABLE health_samples;
