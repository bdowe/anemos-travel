-- +goose Up
-- Where the traveler sets out from on THIS trip ("we're driving up from Lake
-- George"). Free text, resolved to nothing — it names a place the way the
-- traveler said it, and the booking legs use it verbatim. NULL = never
-- stated, which keeps the legacy behavior of assuming the saved home airport.
--
-- Deliberately write-once (set at trip creation, absent from PATCH): the
-- derived transport todos take their identity from this string
-- (`transport:<origin>>><dest>`), so changing it later would orphan the old
-- rows — DeleteStaleAutoBookingTodos removes them, taking the booked flag,
-- any per-leg mode override, and any linked expense's source with them.
ALTER TABLE trips ADD COLUMN origin text;

-- +goose Down
ALTER TABLE trips DROP COLUMN IF EXISTS origin;
