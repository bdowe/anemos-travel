-- +goose Up
-- Backfill: chat-session titles are written once and never overwritten
-- (UpsertPlanChatSession omits title from DO UPDATE), so sessions started via
-- the near-me chip before display labels existed are frozen showing raw
-- coordinates. Rewrite them to the chip's seed label. The server normally
-- never writes localized strings (client owns locale), but each template
-- prefix identifies the locale the client used, so the replacement is the
-- exact ARB seed-label value for that same locale.
UPDATE plan_chat_sessions
SET title = 'Near my current location'
WHERE title LIKE 'My current location is latitude %';

UPDATE plan_chat_sessions
SET title = 'Cerca de mi ubicación actual'
WHERE title LIKE 'Mi ubicación actual es latitud %';

-- +goose Down
-- Irreversible data cleanup (original coordinate titles are not retained);
-- intentionally a no-op.
SELECT 1;
