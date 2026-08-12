-- +goose Up
-- Per-leg transport-mode override (flight|car|train|bus|ferry) on derived
-- transport todos. NULL = "use the derived default" (Greek pair -> ferry,
-- trips.travel_mode ground mode, else flight). Like booked/auto, this column
-- is deliberately absent from the sync upserts' DO UPDATE set so a re-sync
-- can never clobber a user's override.
ALTER TABLE booking_todos ADD COLUMN mode text;

-- +goose Down
ALTER TABLE booking_todos DROP COLUMN mode;
