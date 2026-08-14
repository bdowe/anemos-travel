# Spec: Trips Page Insights

## Context

The My Trips page reads as sparse in the common case. Several sections are
conditional and often empty (Happening Now, Continue where you left off,
Shared with you), and the aggregate stats line only renders with 2+ *upcoming*
trips — so with one upcoming and one past trip the page is just the Up-next
hero and a collapsed Past row over a large empty column. The trip list already
knows a lot it never shows: stays, packing progress, budget state, the trip's
summary blurb, and where the traveler has been. Surfacing that turns the page
from a sparse index into a home for the traveler's travel life — with zero
extra requests.

## User Stories

- As a **traveler**, I want a lifetime "Your travels" band (trips · travel
  days · cities, all-time) so that the page reflects my travel history, not
  just what's next.
- As a **traveler**, I want a travel-footprint world map pinning every hub
  city across my trips so that I can see where I've been at a glance.
- As a **traveler**, I want richer trip cards (stays, packing progress,
  budget, the trip's summary blurb) so that I can judge a trip's readiness
  without opening it.
- As a **traveler**, I want a booking-urgency nudge on the Up-next hero
  ("Book transport — first leg departs Aug 24") so that an unbooked
  soon-departing leg can't sneak up on me.
- As a **traveler**, I want the collapsed Past row to summarize its newest
  trip so that the row earns its place even while collapsed.

## Acceptance Criteria

- [x] The owner's trip list carries, per trip: stay counts (confirmed stays
      only — suggested drafts and dismissed drafts never count), packing
      progress, budget target/spent/currency, the earliest unbooked future
      transport departure date, the trip's summary, and the located hub-city
      pins — all from the one existing list request (no extra API calls, no
      N+1).
- [x] Real zeros are visible: a trip with no stays / no checklist / no
      expenses reports explicit `0`s (never a missing field), and a trip with
      no budget row reports no target, `0` spent, and the `USD` default
      currency — matching the budget screen's own defaults.
- [x] The nudge date is the earliest **unbooked, transport-kind, today-or-
      future** booking item; booked items, stay items, and past dates never
      produce it; it is absent when nothing qualifies.
- [x] City pins list only hubs that have at least one located item; a hub's
      pin is its first located item in itinerary order; the day-trip origin
      overrides the item's own city, matching the trip map's grouping; pins
      are absent when the trip has no located items. Pin order and the pin
      set are consistent with the trip's city list (pins ⊆ cities, same
      first-appearance order).
- [x] The shared-with-me list carries **none** of the new fields, for
      editors and viewers alike.
- [x] My Trips shows the five approved surfaces: lifetime stats band,
      footprint map (owned trips only, gated at 2+ owned trips), enriched
      hero + trip cards, the hero booking nudge (within 14 days of
      departure), and the past-row summary — with the old upcoming-only
      stats line removed.

## Data Contract

New per-trip fields on the owner's trip-list response. All are list-only:
the full trip view keeps carrying the real arrays and clients derive from
those (one derivation per fact).

| JSON field | Type | Meaning | Null/absent semantics |
|---|---|---|---|
| `summary` | string | The trip's summary blurb (already on full views; now on list rows) | Absent when the trip has no summary |
| `stay_total` | int | Confirmed stays (suggested drafts and dismissed drafts excluded) | Explicit `0` when none; absent = not a list row / old server / shared row |
| `stay_booked` | int | Confirmed stays marked booked | Same as `stay_total` |
| `packing_total` | int | Packing-checklist items | Explicit `0` when none; absent as above |
| `packing_done` | int | Checked packing items | Same as `packing_total` |
| `budget_target` | float | Budget target amount | Absent when no target is set (no budget row, or a budget with no ceiling) |
| `budget_spent` | float | Sum of expense amounts (single-currency by design) | Explicit `0` when nothing spent; absent = not a list row |
| `budget_currency` | string | Budget currency code | `"USD"` when no budget row exists (the budget feature's default) |
| `next_transport_depart` | string (YYYY-MM-DD) | Earliest unbooked future transport departure | Absent when nothing qualifies |
| `city_pins` | array of `{city, lat, lng}` | Located hub cities in first-appearance order (subset of `cities`) | Absent when the trip has no located items |

Clients treat absence as "unknown — hide the surface"; they never derive a
substitute locally.

## Shared-With-Me Exclusion

The shared-with-me list adds **none** of these fields in v1 — stricter than
the existing viewer boundary (which already hides booking state from viewers
but shows item counts to everyone). Rationale: budget and packing are the
owner's private planning state; stays reveal booking posture; "Your travels"
is a lifetime aggregate of **owned** trips, so shared rows contribute
nothing to it and need no pins. Editors lose nothing they can't see on the
full trip view they already have access to.

## UI Behavior

(Owned by the companion app work; listed here as the contract's consumers.)

- **Lifetime stats band** — "Your travels": trips · travel days · cities,
  all-time over owned trips; replaces the upcoming-only stats line.
- **Travel footprint map** — one static world-map band pinning every hub
  city across all owned trips, shown from 2 owned trips; renders purely from
  the list payload.
- **Trip cards** — stays / packing / budget chips plus the summary blurb;
  chips hide on null (old server, shared row) and on zero.
- **Booking urgency nudge** — hero-only banner when the next transport
  departure is within 14 days.
- **Past collapsed row** — summary slot shows the most recent past trip
  ("Lisbon & Porto · 12 days").

## Edge Cases & Error States

- A trip with expenses but no budget row still reports its spent total (with
  the default currency).
- A hub whose items are all unlocated appears in `cities` but not in
  `city_pins` — pin coordinates are never invented, and the itinerary's
  (0,0) "no location" sentinel never becomes a pin in the Atlantic.
- Old servers / stale caches: every new field is optional; clients hide the
  new surfaces when fields are absent.
- Degraded mode (no DB) is unchanged — the list endpoint already requires
  the DB.

## Out of Scope

- Any new field on the shared-with-me list (v1 exclusion above).
- Trip health / next-step ladders on list rows (not expressible inside the
  one-query list contract).
- Cross-currency budget summing (single-currency by design, as in the budget
  feature).
- A second booked-progress pill for stays in the UI (`stay_booked` ships in
  the payload; the booking pill already carries progress).
- Schema changes — this feature consumes no migration number.

## Open Questions

None — the five surfaces, the shared-with-me exclusion, the confirmed-stays
rule, the 14-day nudge window, and the 2+-trips footprint gate were all
decided at approval.

## Amendment 2026-08-14 — "Your travels" splits traveled from planned

**Supersedes the "all-time" wording above** (the lifetime-band user story, its
acceptance criterion, and the UI-behavior bullet). The band shipped as one
all-time total over every owned trip, which counted a trip starting next month
as travel already taken: an account with a 2-day past trip and two upcoming
ones reported *40 travel days*, of which 2 had happened. The map had the same
defect — every located city drew the same "been there" dot. Both contradicted
what this section is placed to be: the retrospective, where the page turns from
plans to history.

The corrected contract (client-side only — no payload, SQL, or migration
change; `utils/trip_list_insights.dart` remains the one derivation site):

- **Two labeled groups, traveled and planned**, and a group with **no trips
  does not render**. That single rule replaces every special case: a planner
  who has taken no trips yet sees only "Planned" instead of a row of zeros, an
  account with nothing upcoming sees only "Traveled", and under the unchanged
  2+-owned-trips gate at least one group always renders because every trip
  lands on exactly one side.
- **Bucket** — a trip is traveled once it has *started* (`tripHasStarted`:
  first day = `start_date ?? end_date`, today or earlier). Future trips and
  undated drafts are planned. Mirrors `tripIsPast`'s last-day rule, so every
  trip filed under "Past trips" is also counted as travelled.
- **Travel days** — traveled counts only days already lived through, so an
  in-progress trip's counter ticks up daily rather than banking all 35 days on
  day one; planned counts the full span of trips that haven't started. The
  remaining days of an in-progress trip are on neither side: each group stays
  consistent with the trips shown beside it, which is the arithmetic a reader
  can check, and the old grand total is no longer on screen.
- **Cities** — traveled wins the overlap, so a city on both a past and a
  future trip counts once, as visited. The two counts partition.
- **Map pins** — solid dot = visited, ring = still ahead, with the state in
  the tap tooltip ("Kraków · Planned") because two dot styles are a fast read,
  not a precise one. `visited` is taken from the set of cities on started
  trips, **never** from whichever trip supplied the winning coordinate: server
  order is newest-created-first, so a planned trip routinely lands ahead of the
  past trip that earned the dot.
