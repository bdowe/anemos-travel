# Spec: Change One Leg's Dates from Chat (`set_leg_dates`)

## Context

Dogfooding (2026-08-04, the day `set_trip_dates` deployed): on a multi-city
trip (Panama City Sep 15–20 → Los Angeles Sep 20–24 → LA→EWR flight Sep 24),
asking the refine chat to "change the dates for LA to Sep 24–27" produced
repeated claims of success with no actual change. `set_trip_dates` moves the
WHOLE trip by one delta; calling it with the trip's unchanged start date is a
delta-0 *success* ("dates already match"), so the anti-fabrication guardrail
never fires while nothing moves. No tool can change one leg: itinerary items
are day-index-relative to `trips.start_date`, and no agent tool updates an
existing accommodation's or segment's dates at all.
`specs/set-trip-dates/spec.md` explicitly deferred per-leg work; this spec is
that follow-up.

A real per-leg change is a coordinated edit: renumber the leg's item days,
move its stay's check-in/check-out by **different** deltas (Sep 20→24 is +4,
Sep 24→27 is +3 — endpoint-anchored), move the transport into and out of the
city, and extend the trip's end date when the leg now runs past it.

## User Stories

- As a **traveler refining a saved multi-city trip in chat**, I want to say
  "make LA Sep 24 to 27" and have that city's days, stay, and connecting
  transport move together — without the rest of the trip moving.
- As a **traveler**, when moving one leg opens a gap or overlap with a
  neighboring city, I want the agent to point it out and offer to fix it,
  not silently leave a hole.
- As a **traveler**, I want the agent to never claim a leg's dates changed
  when they didn't — including the "successful no-op" case.

## Acceptance Criteria

- [ ] In a refine chat, "change Los Angeles to Sep 24–27" on the scenario
      above moves the LA items' days, the LA stay (check-in Sep 24 /
      check-out Sep 27), the arriving segment (Sep 24), and the departing
      segment (Sep 27), extends the trip end to Sep 27, and leaves every
      Panama City row byte-identical. The trip page refreshes.
- [ ] The agent's reply surfaces the Sep 20–24 gap with Panama City and
      offers to fix it (tool result carries a deterministic gap/overlap note).
- [ ] Auto-suggested (draft) stays/segments are never moved or confirmed by
      the tool; the client re-derives them on refresh.
- [ ] Omitting `end_date` keeps the leg's current length.
- [ ] Shrinking a leg clamps trailing items onto its new last day and says so.
- [ ] A leg start before the trip's first day is an honest error directing
      the model to `set_trip_dates` (day indices anchor to the trip start).
- [ ] A dateless trip is an honest error directing the model to set trip
      dates first.
- [ ] An unknown city errors and lists the trip's actual legs with dates; a
      city visited twice errors and asks which visit.
- [ ] Whole-trip moves still route to `set_trip_dates`; the delta-0 result of
      `set_trip_dates` now steers the model toward `set_leg_dates` when only
      one city was meant.
- [ ] An editor collaborator can move a leg on a shared trip; others cannot.
- [ ] The reply reminds the traveler that real provider bookings keep their
      original dates.

## API Surface

No new HTTP endpoints. One new `/plan` agent tool, appended at the registry
tail (after `set_trip_dates`).

### Tool `set_leg_dates`
- **Request:** `city` (required — as it appears in the itinerary),
  `start_date` (required, YYYY-MM-DD), `end_date` (optional — omit to keep
  the leg's length; must not precede `start_date`).
- **Response (tool result):** new leg range, moved counts (items / clamps /
  stays / segments), trip-end extension note, deterministic gap/overlap
  narration vs. the neighboring legs, re-check-real-bookings reminder.
  Existing `trip_updated` SSE event fires.
- **Errors:** invalid params; not signed in; persistence offline; no saved
  trip; dateless trip; unknown or ambiguous city; leg start before trip
  start. All tool errors the agent must relay honestly.

## Data Model

No schema changes, no new SQL. Reuses `UpdateItineraryItem` (day),
`UpdateAccommodation` (check_in/check_out), `UpdateSegment`
(depart/arrive dates), `SetTripDates` (end extension), all inside one
transaction under the `GetTripForUpdate` row lock. `booking_todos` are left
untouched: the client re-derives auto rows on every trip load, and a leg move
changes todo identity rather than applying a uniform offset.

## UI Behavior

No new UI. Existing `trip_updated` SSE handling silently refreshes the trip
detail screen; its booking-draft/todo syncs then converge on the new dates.

## Edge Cases & Error States

- Leg identified as a contiguous run of items sharing a hub
  (`day_trip_from` else `city`); day-trip items move with their hub.
- Stays match by fuzzy address-then-name against the hub; segments classify
  arrival (destination matches) / departure (origin matches) / intra-leg
  (both) and shift by start / end / start delta respectively.
- Confirmed stays whose dates would invert clamp check-out to check-in + 1.
- A run whose items have no day numbers is not addressable (reads as
  unknown city).
- Concurrent edits serialize on the trip row lock; all-or-nothing tx.

## Out of Scope

- Auto-shifting neighboring legs (decided: leg only; the agent offers
  follow-up fixes and trip health flags leftovers).
- Rescheduling real provider bookings.
- An `occurrence` parameter for revisited cities (v1 errors and asks).
- Moving the trip's start date via a leg (routes to `set_trip_dates`).

## Open Questions

None — cascade semantics decided 2026-08-04: leg only + agent asks.
