-- +goose Up
-- The mode the SERVER derived for a transport leg (leg_transport_mode.go:
-- a bookable ferry pair, the trip's stated travel mode, or geography — a short
-- hop inside a rail region is a train, which is what an Italy trip's
-- Rome -> Florence row was missing when it offered a flight search).
--
-- Two columns, two meanings, and the difference is the point:
--   mode         a choice SOMEBODY MADE — the traveler in the row's mode menu,
--                or the planner via set_leg_transport_mode. Absent from the
--                sync upserts' DO UPDATE set (00055) so a re-sync can never
--                clobber it.
--   derived_mode what the server WORKED OUT. Derived content like provider and
--                search_url, and refreshed with them on every sync, so an
--                improved rule reaches existing trips instead of being
--                outvoted by a stale guess.
-- Readers resolve `mode ?? derived_mode` (transportSlotMode) and never invert
-- it. Deliberately NOT added to DemoteStaleAutoBookingTodos' predicate: that
-- predicate lists what a traveler would lose, and a derived value is not
-- something anyone can lose — a stale row carrying only this is still deleted.
ALTER TABLE booking_todos ADD COLUMN derived_mode text;

-- Constrained in SQL, unlike mode (00055, Go-only via allowedLegModes), for
-- the reason 00065 gave: this column is written by derivation rather than by a
-- validated request handler, so the schema is the only place a typo stops.
ALTER TABLE booking_todos ADD CONSTRAINT booking_todos_derived_mode
    CHECK (derived_mode IS NULL OR derived_mode IN ('flight','car','train','bus','ferry'));

-- +goose Down
ALTER TABLE booking_todos DROP CONSTRAINT IF EXISTS booking_todos_derived_mode;
ALTER TABLE booking_todos DROP COLUMN IF EXISTS derived_mode;
