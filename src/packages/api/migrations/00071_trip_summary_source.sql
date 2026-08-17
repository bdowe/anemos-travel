-- +goose Up
-- Whose words a trip's description is (trips.summary, 00013 — the prose overview
-- shown under the title). Until this migration the question could not come up:
-- summary was write-once at CreateTrip, so the only author was ever the AI.
-- specs/trip-description gives both the traveler and the planner a way to change
-- it, and the planner is allowed to refresh a stale blurb IT wrote — which it can
-- only do safely if "the traveler wrote this" is written down rather than guessed.
--
--   'traveler'  a person typed these words on the trip page.
--   'agent'     the planner composed them (create_itinerary, an import, the MCP
--               create_trip tool, or set_trip_description).
--   NULL        written before this was tracked. Provably NOT the traveler: no
--               human writer existed, so the planner may refresh it.
--
-- The PAIR carries a meaning neither column holds alone: `summary IS NULL` with
-- `summary_source = 'traveler'` is the traveler having REMOVED the description on
-- purpose. Clearing therefore stamps 'traveler' rather than NULL — otherwise the
-- next reshape would helpfully re-add a blurb they had just deleted, and the
-- deletion would be unfalsifiable.
ALTER TABLE trips ADD COLUMN summary_source text;

-- Constrained in SQL rather than Go alone, for 00068's reason: this column is
-- stamped by persistTrip on paths that never see a validated request body
-- (create_itinerary, paste-import, MCP create_trip), so the schema is the only
-- place a typo stops.
ALTER TABLE trips ADD CONSTRAINT trips_summary_source
    CHECK (summary_source IS NULL OR summary_source IN ('agent', 'traveler'));

-- +goose Down
ALTER TABLE trips DROP CONSTRAINT IF EXISTS trips_summary_source;
ALTER TABLE trips DROP COLUMN IF EXISTS summary_source;
