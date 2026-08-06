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

**Amended 2026-08-05** after the same dogfood ask failed a second time: the
trip screen draws a leg as [previous leg's end → its max item day], so v1's
min-day-anchored renumbering and leg-only cascade left the *visible* dates
unchanged (a single-item placeholder leg encodes its DEPARTURE day), and the
"already spans" no-op echoed the requested range while `trip_updated` fired
unconditionally. v2: item renumbering is END-anchored, the previous leg's end
extends to meet a later start in the same transaction, zero-change calls
commit nothing (no SSE) and report actual saved state, and `get_trip` exposes
stay/transport/todo dates so the model can verify what it narrates. The v1
premise "the client re-derives draft stays/segments on refresh" had been
false since PR #274 removed that sync — migration 00053 deletes the frozen
`auto=true` rows and trip health's lodging check now skips `auto`.

**Amended 2026-08-05 (round three)**, after the next dogfood ask: a boundary
extension left the FIRST city's single item on a late day and the leg
rendered as a bare end date ("Aug 27" on an Aug 24 trip) — nothing anchored
the first leg's visible start to the trip start on either side of the render
mirror (the rule previously held only implicitly, via the deleted draft
rows), and the honest no-op reported the same wrong range. Separately, a
move whose new end landed exactly ON the next leg's departure day narrated
nothing (gap/overlap math is silent at n == 0) while visibly consuming all
of that leg's nights. v3: both sides anchor the first dated leg's start to
the trip start (confirmed stay still wins), a first-leg start change steers
to set_trip_dates, and a squeeze NOTE names the consumed next leg and tells
the agent to chain follow-up set_leg_dates calls.

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
- [ ] Moving a leg LATER extends the previous leg's end to the new start in
      the same transaction — its matched confirmed stay's check-out when one
      anchors its span, else its departure-day items — and the result
      narrates it ("Panama City now ends Sep 24 (was Sep 20)"). Moving a leg
      EARLIER (overlap) never shrinks the neighbor; the tool result carries a
      deterministic overlap note the agent relays and offers to fix.
- [ ] A single-item placeholder leg is an end-carrier: "LA Sep 24–27" lands
      its one item on Sep 27 (the departure day the screen renders), not
      Sep 24.
- [ ] A zero-change call commits nothing: no `trip_updated` SSE (no "Trip
      updated" chip), no analytics, no `updated_at` bump, and the result
      reports the ACTUAL saved state (item-day dates, matched stay, previous
      leg's end, derived visible range) — never the requested range echoed
      back.
- [ ] `get_trip` lists saved stays and transport with their dates (auto rows
      excluded) and appends dates to booking-checklist lines, so the model
      can verify the calendar state it narrates.
- [ ] The FIRST dated leg's visible start is the trip's start date unless a
      confirmed stay anchors it — on both sides: the client clamps it in
      `_locationGroupRanges` (header, stay todo, home flight row, map pin,
      weather window) and the server mirrors it in `anchoredLegDisplayRange`
      (no-op report, deltas, leg summaries).
- [ ] Asking to change the first leg's START to anything other than the trip
      start is an honest error steering to `set_trip_dates` (its arrival IS
      the trip start); start == trip start with a new end is the supported
      first-leg edit and moves only the departure.
- [ ] A move whose new end reaches the next leg's end (zero or negative
      nights left) gets a squeeze NOTE naming that leg; the agent offers to
      shift the remaining cities and chains one set_leg_dates call per leg
      (earliest first) in the same turn — no new tool parameters.
- [ ] While a squeeze is unresolved (an INVERTED leg — the previous leg ran
      past its departure day), the page renders it as a zero-night stop at
      its arrival, cascading: stay row, header chip, and both flight dates
      agree, and consecutive squeezed legs chain onto the same arrival
      (client `_visibleGroupRanges` ↔ server `visibleLegDisplayRange`; the
      honest no-op quotes the zero-night render). A confirmed stay's
      explicit dates are never collapsed; partial overlaps (arrival lands
      mid-leg with nights remaining) keep the leg's own start.
- [ ] Auto-suggested (draft) stays/segments are never moved or confirmed by
      the tool; migration 00053 deletes the frozen pre-#274 rows and
      `checkLodging` skips any `auto` row, so a stale draft can't mask
      uncovered nights.
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

No schema changes, no new SQL queries. Reuses `UpdateItineraryItem` (day),
`UpdateAccommodation` (check_in/check_out — also for the previous leg's
check-out extension), `UpdateSegment` (depart/arrive dates), `SetTripDates`
(end extension), all inside one transaction under the `GetTripForUpdate` row
lock; a zero-change call rolls the transaction back. Migration 00053
(data-only) deletes the orphaned `auto=true` accommodation/segment rows the
retired drafts sync left behind. `booking_todos` are left untouched: the
client re-derives auto rows on every trip load, and a leg move changes todo
identity rather than applying a uniform offset.

## UI Behavior

Existing `trip_updated` SSE handling silently refreshes the trip detail
screen; its booking-TODO sync then converges the visible stay/transport rows
on the moved item days. The city header's range start is arrival-adjusted
(`_stayStartFor`), matching the stay rows, so a collapsed leg reads
"Sep 24 – Sep 27" rather than a bare end date.

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

- Shrinking neighboring legs on overlap (decided 2026-08-05: gap extends the
  previous leg; overlap and squeeze narrate and ask; the next leg never
  auto-moves — downstream ripple is agent-chained set_leg_dates calls).
- Rescheduling real provider bookings.
- An `occurrence` parameter for revisited cities (v1 errors and asks).
- Moving the trip's start date via a leg (routes to `set_trip_dates`).

## Open Questions

None — cascade semantics decided 2026-08-04 (leg only + agent asks), revised
2026-08-05 (previous leg's end extends to meet a later start; overlap still
narrate-and-ask).
