-- +goose Up
ALTER TABLE traveler_preferences ADD COLUMN work_style text; -- digital_nomad | workation | leisure_only

-- +goose Down
ALTER TABLE traveler_preferences DROP COLUMN IF EXISTS work_style;
