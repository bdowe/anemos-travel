-- +goose Up
-- PR #274 retired the client's booking-drafts sync, so auto=true rows in
-- accommodations and trip_segments are frozen relics nothing re-dates. Every
-- render path already filters them out; the one consumer that didn't — trip
-- health's lodging check — let a stale draft mask real uncovered nights.
-- Delete them, dismissal tombstones included: with no sync left to re-seed a
-- draft, the tombstones guard against nothing.
DELETE FROM accommodations WHERE auto = true;
DELETE FROM trip_segments WHERE auto = true;

-- +goose Down
-- Irreversible data cleanup; intentionally a no-op.
SELECT 1;
