-- +goose Up
-- Price alerts removed (2026-08): the feature never watched a real fare on
-- prod (paused since the SerpApi swap; Duffel test-mode before that) and was
-- never used. alert_events drops first: it holds the FK into price_alerts
-- (00033). Historical price_drop rows in `notifications` (00045 backfill) are
-- kept — the notification center still renders them.
DROP TABLE alert_events;
DROP TABLE price_alerts;

-- +goose Down
-- Irreversible removal; restore from a backup or resurrect from git.
SELECT 1;
