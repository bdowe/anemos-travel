-- +goose Up
-- The traveler's saved conversation ABOUT ONE TRIP (specs/trip-refine-memory):
-- the chat behind the trip-detail refine panel, so closing that panel — or
-- hitting back, which used to pop the whole page — never loses it.
--
-- Its own table, not a nullable trip_id on plan_chat_sessions, for three
-- reasons:
--
--   * Identity differs. A plan chat is identified by an opaque client-minted
--     chat id, and its lifecycle question ("did it graduate into a trip?") is
--     derived, racy, and rightly answered at read time — that is what 00031
--     argued, and it still holds. "Which trip is this conversation about?" is
--     the opposite kind of fact: validated request input (plan_handler.go
--     resolves and authorizes req.trip_id before a byte streams) that is
--     immutable for the row's life. Storing an identity is not the thing
--     00031 argued against.
--   * Addressability is a boundary, not a preference. A refine conversation
--     has NO chat id — not here, not on the wire. GET /chats/{chatId} and
--     /plan/<chatId> therefore CANNOT reach it, so a trip-bound transcript can
--     never be resumed into the unbound Agent tab, where the trip binding
--     would silently vanish and the agent would fall back to create_itinerary.
--     Structural, rather than a filter someone can delete.
--   * A nullable column would instead have required "AND trip_id IS NULL"
--     remembered in five places: ListResumablePlanChatSessions,
--     GetPlanChatSessionByChatID, DeleteStalePlanChatSessions, the weekly-nudge
--     predicate in query/reengagement.sql, and the upsert's conflict target.
--     docs/zen.md: promote the convention.
--
-- UNIQUE (user_id, trip_id) IS the product decision — one running conversation
-- per trip — enforced by the database instead of maintained by the client. The
-- owner and each editor co-planner keep their OWN conversation about the same
-- trip, visible to no one else.
--
-- trip_id points at one trips ROW (one itinerary version), not at the chat_id
-- lineage: a conversation belongs to the itinerary it was about, and a bound
-- session cannot create a new version anyway (the tool registry swaps
-- create_itinerary for update_itinerary_section).
--
-- No title column — the trip's own title names this conversation. No
-- time-based prune either, unlike plan_chat_sessions' 60-day janitor rule:
-- retention is the trip's lifetime, because a trip planned in August for next
-- March must still have its chat in November. ON DELETE CASCADE is the whole
-- GC story.
CREATE TABLE trip_refine_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    trip_id UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
    preview TEXT NOT NULL DEFAULT '',
    summary TEXT NOT NULL DEFAULT '',
    messages JSONB NOT NULL,
    message_count INT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, trip_id)
);

-- Postgres does not index FK columns automatically and the unique index above
-- is user-leading. DeleteTrip removes an entire version lineage in one
-- statement; without this the cascade check seq-scans this table per row.
CREATE INDEX trip_refine_sessions_trip_idx ON trip_refine_sessions (trip_id);

-- +goose Down
DROP TABLE trip_refine_sessions;
