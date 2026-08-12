-- +goose Up
-- specs/retire-trip-status: the manual draft/planned label is retired. Its
-- three consumers now derive their signal instead: departure reminders fire
-- for any dated trip in the window; the weekly nudge defines unfinished work
-- as an undated trip / an upcoming trip with unbooked todos / a resumable
-- plan chat; the lodging health check runs for any dated trip.
ALTER TABLE trips DROP COLUMN status;

-- +goose Down
-- Restores the column shape only — draft/planned values are unrecoverable
-- (every row comes back 'draft'). Acceptable: the label was cosmetic.
ALTER TABLE trips ADD COLUMN status text NOT NULL DEFAULT 'draft';
