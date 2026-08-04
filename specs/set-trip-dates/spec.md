# Spec: Shift Trip Dates from Chat (`set_trip_dates`)

## Context

Dogfooding (2026-08-03): in refine chats the AI agent reordered an itinerary
but could not shift the trip's dates, twice *claimed* date changes were saved
without any tool call, then apologized for fabricating. The agent has no way
to change when a saved trip happens — the only date-carrying tool creates a
brand-new trip. Travelers change dates constantly ("shift everything a week
later", "we actually leave June 12"); the agent must be able to do it in one
step, honestly.

## User Stories

- As a **traveler refining a saved trip in chat**, I want to say "move my trip
  one week later" and have the whole plan — dates, stays, transport legs,
  booking to-dos — shift together, so the trip stays internally consistent.
- As a **traveler planning a new trip in chat**, I want to change the dates
  after the itinerary is saved without the agent rebuilding it from scratch.
- As a **traveler with a dateless trip**, I want the agent to set dates when I
  finally know them (including when a trip health review flags missing dates).
- As a **traveler**, I want the agent to never claim a change was saved when
  it wasn't.

## Acceptance Criteria

- [ ] In a refine chat, asking to shift the trip N days moves the trip's
      start/end and every dated accommodation, transport segment, and booking
      to-do by exactly N days, in one step; the trip page refreshes.
- [ ] Undated stays/legs/to-dos are left untouched by a shift.
- [ ] A trip that previously had no dates gets its dates set without any
      child rows being moved.
- [ ] Changing only the trip length (same start) does not move child rows.
- [ ] The agent's reply reminds the traveler that anything already booked with
      a real provider keeps its original dates and should be re-checked.
- [ ] In a fresh planning chat, a date change after the itinerary was saved
      updates the existing trip — no duplicate trip is created.
- [ ] The trip-health "no dates" finding is fixable by the agent in chat.
- [ ] An editor collaborator can shift a shared trip; others cannot.
- [ ] The agent never states a saved-trip change happened unless the
      corresponding tool call succeeded in that turn.

## API Surface

No new HTTP endpoints. One new `/plan` agent tool:

### Tool `set_trip_dates` (POST /api/v1/plan tool registry)
- **Purpose:** Move or set the travel dates of the traveler's saved trip.
- **Request:** `start_date` (required, YYYY-MM-DD — new day 1); `end_date`
  (optional, YYYY-MM-DD — omitted preserves the trip's current length, or
  derives it from the itinerary's day span when the length is unknown).
- **Response (tool result):** what changed — new date range, how many stays /
  legs / to-dos shifted, and the re-check-real-bookings reminder. Existing
  `trip_updated` SSE event fires so clients refresh.
- **Errors:** invalid/missing dates; end before start; not signed in;
  persistence offline; no saved trip yet (directed to give dates to
  `create_itinerary` instead). All returned as tool errors the agent must
  relay honestly.

## Data Model

No schema changes. Existing columns only: `trips.start_date/end_date` (the
calendar anchor; itinerary items are day-relative), plus absolute dates on
accommodations (check-in/out), transport segments (depart/arrive), and booking
to-dos (depart/return) — all shifted by the same day delta when the anchor
moves.

## UI Behavior

- **Surface:** existing plan chat (Agent tab) and trip refine panel; no new UI.
- **Happy path:** traveler asks to move the trip → agent calls the tool →
  trip page/dates refresh via the existing `trip_updated` handling → agent
  confirms with the booking re-check reminder.
- **States:** unchanged from existing chat (streamed reply, refreshed trip).

## Edge Cases & Error States

- Shift backwards (earlier dates) works the same as forwards.
- Trip with no prior start date: dates are set, children untouched (no anchor
  to compute a delta from).
- New end before new start → tool error, nothing changes.
- Anonymous sessions: tool absent (no saved trips to move).
- Concurrent edits (section rewrite in another chat) are serialized; the
  shift is all-or-nothing (single transaction).
- End date shorter than the itinerary's day span is allowed (matches manual
  editing); the trip health review flags it afterwards.

## Out of Scope

- Rescheduling real provider bookings (flights/hotels/ferries) — the agent
  only reminds the traveler to re-check them.
- Per-day reordering or moving individual items between days (existing tools
  cover this).
- Improving the agent's cross-session memory of earlier discussion
  (compaction behavior) — this spec fixes capability + honesty, not recall.

## Open Questions

None — cascade semantics decided: shifting trip dates shifts everything by
the same delta.
