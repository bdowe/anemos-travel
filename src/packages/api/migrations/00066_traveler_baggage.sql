-- +goose Up
ALTER TABLE traveler_preferences ADD COLUMN baggage text; -- personal_item | carry_on | checked

-- +goose Down
ALTER TABLE traveler_preferences DROP COLUMN IF EXISTS baggage;
