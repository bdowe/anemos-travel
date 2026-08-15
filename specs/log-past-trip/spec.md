# Spec: Log a Past Trip

> **WHAT & WHY only.** No tech choices, file names, libraries, or code. If a
> sentence names a file or a package, it belongs in `plan.md`, not here.

## Context

The "Your travels" section on My Trips presents itself as everywhere the
traveler has ever been — a world map of city dots over Traveled / Planned
totals. It only knows, however, about trips this app planned. A trip taken
before the traveler signed up, or planned somewhere else entirely, contributes
nothing to it. The retrospective half of the page is therefore systematically
short of the truth, and the longer someone travelled before finding the
product, the emptier it looks.

There is also no form-based way to create a trip at all today: every existing
path runs through an AI (finalizing a plan conversation, pasting an external
chat, the connector's create-trip tool) or copies someone else's shared trip.
Spending a model call and dozens of place lookups to extract "Kyoto and Osaka,
March 2019" is disproportionate for three facts the traveler can simply type.

This feature adds a direct way to record a trip that already happened, so the
travel history the section is placed to show is the traveler's real one.

## User Stories

- As a **traveler**, I want to record a trip I took before I used this app so
  that "Your travels" reflects where I have actually been.
- As a **traveler**, I want to name my destinations by searching for them so
  that they land on the travel map instead of being text I have to trust.
- As a **traveler**, I want to log a destination by name when search can't find
  it so that an unusual place is never a dead end.
- As a **traveler**, I want a logged trip to behave like any other trip so that
  I can open it, rename it, add stays to it, and share it later.

## Acceptance Criteria

- [x] A signed-in traveler can create a trip from a form: one or more
      destinations, a travel date range, and an optional name. No AI call is
      involved.
- [x] Each destination may be chosen from place search (carrying its real
      coordinates) or typed by name alone. Both kinds are saved.
- [x] The date range is **required**, and the form says so. A trip with no
      dates cannot count as travel already taken, so allowing one would file
      the entry in the wrong half of the very section it was added to fix.
- [x] The name is optional; leaving it blank produces the same default title
      every other creation path produces.
- [x] Immediately after saving, the traveler lands on the new trip's detail
      view and sees the destinations they entered, in the order they entered
      them.
- [x] The saved trip appears in "Past trips" (when its dates are past) and is
      openable, editable, deletable and shareable exactly like any other trip.
- [x] "Your travels" counts the trip under **Traveled**: its trip count, its
      full day span, and each distinct destination as a city.
- [x] Every destination chosen from search draws a filled ("been there") dot on
      the travel map. A destination typed by name alone still counts as a city
      but draws **no** dot — a location is never invented for it, and the form
      says so before the trip is saved.
- [x] Creating a trip this way is reachable whether the traveler has no trips,
      one trip, or many — "Your travels" itself is hidden below two trips, so
      it cannot be the only way in.
- [x] A traveler at their account trip limit gets a clear, human message rather
      than a generic failure.
- [x] An unauthenticated create request is rejected and creates nothing.

## API Surface

### `POST /api/v1/trips` — create a trip directly

- **Purpose:** Persist a trip the traveler describes themselves, with no AI
  extraction step. This is the first non-AI creation path; the endpoint is
  general ("create a trip"), and *past* is how the client chooses to present
  it, not a rule the contract enforces.
- **Request:**
  - *destinations* (required) — an ordered, non-empty list. Each carries a
    **name** (required) and, when the traveler picked a real place, its
    **place identifier**, **address**, **latitude** and **longitude**. A
    destination with no coordinates is accepted and stored as located-nowhere;
    coordinates are never guessed from the name.
  - *start date* and *end date* (both required) — the days travelled. The end
    date must not precede the start date.
  - *title* (optional) — when omitted, the trip is titled the way every other
    creation path titles an untitled trip.
- **Response:** `201` with the complete new trip, including its identifier and
  its destinations in the order given — the caller sees the post-state it will
  observe rather than inferring it.
- **Errors:**
  - `400` — no destinations; more destinations than the limit; a destination
    with a blank name; an over-long field; coordinates outside valid ranges; a
    missing or malformed date; an end date before the start date.
  - `401` — not signed in.
  - `422` — the traveler is at their account trip limit; the message names the
    limit and what to do about it.
  - `503` — persistence unavailable (degraded mode), as for every other trip
    endpoint.

## Data Model

No new entities and no schema change. A logged trip is an ordinary **Trip**
with ordinary **Itinerary Items** — one item per destination, in the order
entered, each carrying the destination's name as both its own name and its hub
city. That is the whole point of the design: everything downstream (the travel
map, the Traveled totals, the Past-trips grouping, sharing, editing) already
knows how to read that shape, so none of it changes.

Two existing conventions the feature leans on, restated because they are what
make it work:

- A trip counts as **travelled** once its first day is today or earlier. This
  is derived from its dates and never stored — which is why dates are required.
- An itinerary item with no location carries the "no location" sentinel rather
  than a coordinate. Such a destination contributes a city to the totals and no
  dot to the map.

A logged trip is **not** tied to a conversation. It has no chat lineage until
and unless the traveler later refines it in chat, at which point the existing
refine flow assigns one.

## UI Behavior

- **Screen / surface:** a dedicated "Log a past trip" screen on the Trips flow,
  with its own address so a reload returns to it. Reachable from three places,
  because the section it feeds is itself hidden below two trips:
  1. the "Your travels" section header — its contextual home;
  2. the My Trips toolbar — the route for a traveler with exactly one trip;
  3. the empty state — the route for a traveler with none.
- **Happy path:** search a city or country → tap a result → it becomes a
  removable chip → repeat → pick the travel dates → optionally name the trip →
  save → land on the new trip.
- **States:**
  - *Searching* — a spinner under the field while results load.
  - *No results / search unavailable* — the same copy the existing add-a-place
    flow uses, plus the option to add the destination by name alone.
  - *Named-only destination* — the chip is visibly marked as having no map
    location, stated before saving rather than discovered afterwards.
  - *Incomplete* — saving is disabled until there is at least one destination
    and a date range.
  - *Saving* — progress shown, inputs disabled.
  - *Error* — the server's message when it wrote one for people (the trip-limit
    case), otherwise the app's generic failure copy, with the form intact so
    nothing entered is lost.

## Edge Cases & Error States

- **No destinations, or no dates** — saving stays disabled, and the server
  rejects the request too, so a stale client cannot create a half-trip.
- **Search unavailable** (no place-provider key, or the provider is down) — the
  screen still works end to end through name-only destinations.
- **The same destination entered twice** — accepted; the totals count the city
  once and the map draws one dot, exactly as they already do for a city visited
  twice in one itinerary.
- **A country picked as a destination** ("Japan") — accepted and treated as any
  other destination: one city in the totals, one dot at whatever coordinates
  the place provider returns.
- **Dates far in the past** — accepted; the picker reaches back decades.
- **A date range that has not finished yet** — the picker does not offer it;
  logging is for travel that has happened, and a trip still under way belongs
  in the planner.
- **Account trip limit reached** — the same human message the import flow
  shows, not a generic error.
- **Offline** — saving needs the network; the failure is surfaced and the form
  is preserved.

## Out of Scope

- Any notes, summary, budget, packing list or per-destination date ranges on
  the logging form — a logged trip records *where and when*, and every other
  field is already editable on the trip afterwards.
- A separate "places I've been" store that is not a trip.
- Countries as a counted dimension. The travel totals count cities; a
  country-level destination is simply one more city. A real country count would
  need country data on every existing trip, which this feature does not create.
- Bulk import (spreadsheets, mail scraping, third-party travel logs).
- Editing an existing trip through this screen — it creates; the trip's own
  detail view edits.
- Schema changes; this feature consumes no migration number.

## Open Questions

None. The trip-shaped model (rather than a separate visited-places store), the
cities-only totals, and the minimal three-field form were all decided at
approval.
