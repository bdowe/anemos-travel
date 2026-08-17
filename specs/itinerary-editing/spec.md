# Spec: Itinerary Editing — Manual Add & In-Place AI Section Refinement

> **WHAT & WHY only.** No tech choices, file names, libraries, or code. If a
> sentence names a file or a package, it belongs in `plan.md`, not here.

## Context

Once the AI agent saves a trip, the itinerary is effectively frozen: the only
way to change it is to reopen a full-screen chat that hides the trip page and
saves an entirely new version of the trip per refinement. Travelers can't make
a small tweak ("add this restaurant my friend recommended", "make Day 2 more
relaxed") without losing sight of the plan they're editing. This feature makes
a saved trip directly editable: travelers can manually add a single place, and
can ask the AI to refine a targeted slice of the itinerary — one day, one city,
or the whole trip — in a chat panel that keeps the trip page visible, with
changes applied to the same trip in place.

## User Stories

- As a **traveler**, I want to **manually add a place to my saved itinerary**
  (picking the day, time of day, and category) so that **recommendations I get
  outside the app make it into my plan**.
- As a **traveler**, I want to **ask the AI to rework just one day or one city
  of my trip** so that **the rest of my plan stays exactly as I approved it**.
- As a **traveler**, I want the **trip page to stay visible while I chat with
  the AI** so that **I can see the changes land as we talk**.
- As a **traveler**, I want refinements to **update my existing trip rather
  than create copies** so that **My Trips doesn't fill with near-duplicate
  versions**.

## Acceptance Criteria

- [ ] The trip detail page has an "Add place" action; the dialog lets me search
      real places (name/address/coordinates auto-filled) and pick a day, time
      of day, and category before saving.
- [ ] If place search finds nothing (or is unavailable), I can still add the
      item by typing a name; it appears in the itinerary but not on the map.
- [ ] A manually added place appears at the end of its chosen day immediately
      after saving and is still there after a reload.
- [ ] Each "Day N" sub-header, each city group header, and the trip header
      offer a "refine" action that opens an AI chat panel.
- [ ] On a wide window (desktop/web), the chat panel docks to the right of the
      itinerary and both stay visible and scrollable. On a narrow window it is a
      draggable bottom sheet that **opens at full height** — a 45% default left
      the transcript ~200px once the panel's own header and composer were
      subtracted — and the itinerary is reached by dragging the sheet down to
      its peek position or closing it.
- [ ] Asking the panel for a change updates only the targeted section; items
      outside the section are unchanged, and the page refreshes in place
      without navigation.
- [ ] Section refinements do not create new trip versions (the trip count in
      My Trips and the admin versions list stay flat).
- [ ] The existing fresh-planning chat (Agent tab) is unaffected: it still
      creates and saves new trips.

## API Surface

### `POST /api/v1/trips/{id}/items`
- **Purpose:** Manually add one itinerary item to an owned trip.
- **Request:** `name` (required); optional `place_id`, `address`, `latitude`,
  `longitude`, `category` (attraction|restaurant), `time_of_day`
  (morning|afternoon|evening), `city`, `day` (1-based). Omitted coordinates
  mean "no location" (item is excluded from the map). Omitted `day` means
  unscheduled (item lands at the end of the trip).
- **Response:** the full updated trip, including all items in order.
- **Errors:** 401 unauthenticated; 404 trip not found or not owned; 400 for
  empty name, unknown category/time_of_day, or `day < 1`.

### `POST /api/v1/plan` (extended)
- **Purpose:** Existing SSE planning chat, now bindable to a saved trip.
- **Request:** adds optional `trip_id`. When present, the caller must be
  authenticated and own the trip; the session then refines that trip **in
  place** and can never create a new trip.
- **Response:** existing SSE stream, plus a new `trip_updated` event emitted
  each time the trip's itinerary is rewritten, carrying the trip id. Clients
  refresh the trip when they see it.
- **Errors:** an SSE `error` event (and no refinement session) when `trip_id`
  is invalid, unowned, or the caller is unauthenticated.

## Data Model

- **Itinerary item** — unchanged shape; this feature adds new writers. A
  manually added item may have no coordinates (rendered in the list but not on
  the map) and no city (grouped by address, or under "Other places").
- **Trip** — unchanged; section refinement rewrites the trip's items in place.
  Item identity is not stable across a refinement (items are replaced as a
  set); nothing external references item ids.
- **Section** — a targeting concept, not a stored entity: one trip day
  (optionally qualified by city, since day numbers can repeat across cities in
  older trips), one city/hub (a city and its day trips), or the whole trip.

## UI Behavior

- **Surface:** the trip detail page.
- **Manual add happy path:** Itinerary header → "Add place" → type a query →
  pick a suggestion (place details auto-fill) → choose day / time of day /
  category → Save → dialog closes, itinerary refreshes with the new item at
  the end of its day.
- **Refine happy path:** tap the refine icon on a day, city, or the trip
  header → chat panel opens (right dock ≥ ~900px, full-height bottom sheet
  below) seeded
  with that section's contents → user types a request → AI streams its
  reasoning, shows an "Updating itinerary…" indicator while applying → the
  itinerary refreshes in place → conversation can continue for further tweaks.
- **States:** dialog shows a spinner while searching/saving and inline errors
  on failure; the panel shows streamed text, active-tool chips, an error
  banner on stream failure, and is closable at any time (the conversation for
  that trip survives close/reopen while the page is open).

## Edge Cases & Error States

- Trip with no items or days yet: "Add place" still works; day picker offers
  "Unscheduled" and "Day 1".
- Place search unavailable (no API key / network failure): the dialog falls
  back to manual name entry rather than blocking.
- The AI targets a day/city that doesn't exist: the tool call fails with the
  valid options and the model self-corrects; the trip is untouched.
- The AI omits items it was told to keep: the section is replaced by what the
  model sends — the prompt demands the complete list; if this proves flaky a
  size guard can be added (see Open Questions).
- "Other places" group (items with no resolvable city) is not refinable as a
  city section; its refine affordance is disabled.
- Manual add while a refinement is streaming: last write wins (the refinement
  rewrites items from its earlier read). Accepted for single-user trips.
- Unauthenticated users: manual add and refinement both require sign-in
  (the trip page itself already does).

## Out of Scope

- Editing or deleting an individual itinerary item by hand (add only).
- Drag-and-drop reordering of items.
- Undo / version history for in-place refinements (snapshots were considered
  and deferred).
- Refining accommodations, booking todos, or flights from the panel.
- Multi-user / concurrent-edit conflict resolution.

## Open Questions

- ~~[NEEDS CLARIFICATION] Persist refinements as new versions or in place?~~
  **Resolved: in place** (user decision, 2026-06-10). Accepted consequence:
  the per-refinement version history stops accumulating and the old
  full-screen refine flow is replaced.
- ~~[NEEDS CLARIFICATION] Manual add: search-backed or freeform?~~ **Resolved:
  Places-search dialog with manual fallback.**
- ~~[NEEDS CLARIFICATION] Panel layout?~~ **Resolved: adaptive** (right dock
  wide, bottom sheet narrow).
- [NEEDS CLARIFICATION → default chosen] Guard against the model dropping kept
  items: ship without a size guard; add one (reject replacement lists smaller
  than ~1/3 of the section) only if real sessions lose items.
