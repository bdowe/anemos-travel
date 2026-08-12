# Spec: Trip Model

> **WHAT & WHY only.** No tech choices, file names, libraries, or code. If a
> sentence names a file or a package, it belongs in `plan.md`, not here.

## Context

Today the travel agent produces an itinerary at the end of every planning
session, but the moment the user closes the tab or starts a new conversation
that itinerary is gone forever. There is no way to revisit a plan, share it
later, or build on it across sessions. This feature gives each finalized
itinerary a durable home — a **Trip** — owned by the signed-in user, so the
platform has something concrete to attach future pillars to (accommodations,
activities, dining, flights, checklists). Without a persisted Trip record none
of those later phases are possible, making this the foundational object of the
product. Depends on the `data-foundation` (database) and `user-accounts`
(authenticated sessions) Phase-1 features.

## User Stories

- As a **signed-in traveler**, I want the itinerary the agent finalizes to be
  automatically saved as a Trip so that I don't lose my plan when I close the
  app.
- As a **signed-in traveler**, I want to see a list of all my saved trips so
  that I can pick up where I left off.
- As a **signed-in traveler**, I want to open a saved trip and see its full
  itinerary so that I can review and use the plan I built.
- As a **signed-in traveler**, I want to give my trip a title and optional
  travel dates so that I can tell my trips apart at a glance.
- As a **signed-in traveler**, I want to delete a trip I no longer need so that
  my list stays tidy.
- As a **signed-in traveler**, I want to be confident that only I can see or
  modify my own trips so that my travel plans remain private.

## Acceptance Criteria

The definition of done — observable, testable outcomes. A reviewer should be
able to check each one by using the app, with no knowledge of the code.

- [ ] When a **signed-in** user's agent finalizes a plan (`create_itinerary`), a
      new Trip is **auto-saved** and associated with that user, and the `done` SSE
      event carries the new Trip's identifier alongside the itinerary data it
      already returns today. When the caller is **not** signed in, no Trip is
      created and the `done` event omits the identifier (ephemeral, as today).
- [ ] After a Trip is saved, reloading the app or starting a fresh session and
      navigating to that Trip shows the exact same ordered list of places that
      was returned at finalize time — no data is lost between sessions.
- [ ] The "My Trips" list screen displays every Trip owned by the signed-in
      user, showing at minimum each trip's title and creation date.
- [ ] Opening any Trip from the list displays the full, ordered itinerary of
      places (each showing name, address, and coordinates).
- [ ] A user cannot view or modify a Trip that belongs to a different user;
      attempting to do so returns `404` (indistinguishable from a non-existent
      Trip, so existence is never leaked).
- [ ] A user can delete one of their own Trips; the Trip no longer appears in
      their list afterward.
- [ ] A user can set or update a Trip's title.
- [ ] A user can set or update optional start and end dates on a Trip.
- [ ] A new Trip is created with a default status of **draft**; the status is
      visible in the Trip detail view.
- [ ] An unauthenticated request to any Trip endpoint returns an authentication
      error; no Trip data is exposed.

## API Surface

The contract, described behaviorally (not as Go/Dart code). All endpoints
require the caller to be authenticated; an unauthenticated request returns
`401 Unauthorized`.

---

### `POST /api/v1/plan` (existing — behavior change only)

The existing SSE streaming endpoint is unchanged except that, when the agent
calls `create_itinerary`, a Trip is now persisted before the `done` event is
emitted.

- **`done` event change:** the payload gains a `trip_id` field (the stable
  identifier of the newly created Trip). All existing fields (`locations`,
  `summary`) remain unchanged so that current clients do not break.

---

### `GET /api/v1/trips`

- **Purpose:** Return all Trips owned by the signed-in user, newest first.
- **Request:** No body. Authentication token identifies the owner.
- **Response:** An ordered array of Trip summaries. Each summary includes: trip
  identifier, title, optional start date, optional end date, status, and
  creation timestamp.
- **Errors:** `401` if unauthenticated.

---

### `GET /api/v1/trips/{id}`

- **Purpose:** Return the full detail of a single Trip including its complete
  ordered itinerary.
- **Request:** Trip identifier in the path. Authentication token identifies the
  caller.
- **Response:** All Trip summary fields (see `GET /api/v1/trips`) plus the
  full ordered list of itinerary items. Each item includes: name, optional
  Google Places identifier, address, latitude, and longitude — mirroring
  exactly the fields the agent produces today.
- **Errors:** `401` if unauthenticated; `404` if no Trip with that identifier
  exists **or** it belongs to another user (the two are indistinguishable, so
  existence is never leaked).

---

### `PATCH /api/v1/trips/{id}`

- **Purpose:** Update mutable fields on a Trip (title, dates, status).
- **Request:** A partial object; the caller sends only the fields they wish to
  change. Recognized fields: `title` (string), `start_date` (date, optional),
  `end_date` (date, optional), `status` (string, constrained to allowed values).
  Omitted fields are left unchanged.
- **Response:** The updated Trip in full detail (same shape as
  `GET /api/v1/trips/{id}`).
- **Errors:** `400` if a field value is invalid (e.g. `end_date` before
  `start_date`, or an unrecognized `status` value); `401` unauthenticated;
  `404` if not found or not owned by the caller.

---

### `DELETE /api/v1/trips/{id}`

- **Purpose:** Permanently remove a Trip and all its itinerary items.
- **Request:** Trip identifier in the path. Authentication token identifies the
  caller.
- **Response:** `204 No Content` on success.
- **Errors:** `401` unauthenticated; `404` if not found or not owned by the caller.

## Data Model

The entities this feature introduces, described by meaning — not as
struct/class definitions.

- **Trip** — represents a travel plan owned by exactly one user. Key fields:
  - *Identifier* — a stable, opaque ID used in all API calls.
  - *Owner* — the identifier of the user who created the Trip; immutable after
    creation.
  - *Title* — a human-readable name for the trip; mutable; may be set by the
    user at any time. When the user does not supply one, it defaults to the
    agent's `summary` string if present, otherwise to "Trip to {first
    destination}".
  - *Start date* (optional) — the intended first day of travel; may be omitted
    indefinitely.
  - *End date* (optional) — the intended last day of travel; when set, must
    not precede the start date.
  - *Status* — a lifecycle label. Phase 1 supports **draft** (the default on
    creation) and **planned**; transitions are not gated (either value can be set
    freely). Future phases may add values (e.g. **completed**), so the model must
    not assume the set is closed. *(Superseded 2026-08: the manual status was
    retired — see specs/retire-trip-status.)*
  - *Created at* — the timestamp when the Trip was first persisted; immutable.
  - *Updated at* — the timestamp of the most recent change to any Trip field.

- **Itinerary Item** — one place in an ordered sequence attached to a Trip.
  Each item carries:
  - *Order position* — an explicit ordering index so the sequence survives
    storage and retrieval intact.
  - *Name* — the human-readable place name (required; mirrors the `name` field
    the agent produces).
  - *Google Places identifier* (optional) — the `place_id` returned by Google
    Places, if available; may be absent for places the agent resolved by name
    only.
  - *Address* — a formatted address string (optional; may be absent for
    name-only places).
  - *Latitude* and *Longitude* — decimal coordinates (required, matching the
    agent's contract today).

  The itinerary items of a Trip are immutable after creation in this phase.
  Future phases will allow the user to add, reorder, and remove items; the
  model must support that without a redesign (i.e. the ordering index must be
  mutable and items must be individually addressable).

  A Trip is designed to later host additional entity types — accommodations,
  activities, dining reservations, flights, and checklist steps — each
  associated with the Trip by its identifier. None of those associations are
  implemented in this phase; the data shape described here must not foreclose
  them.

## UI Behavior

### My Trips — list screen

- **How to reach it:** a "My Trips" navigation entry is always visible to
  signed-in users (e.g. a bottom-nav tab or drawer item).
- **Happy path:** the screen loads and shows a card or list row per Trip,
  ordered newest-first, displaying the title and creation date. Tapping a row
  navigates to that Trip's detail view.
- **Empty state:** when the user has no Trips yet, the screen shows an
  encouraging prompt (e.g. "Start planning — chat with the agent to create your
  first trip").
- **Loading state:** a progress indicator while the list is fetching.
- **Error state:** a message and retry action if the list cannot be loaded.

### Trip detail view

- **How to reach it:** from the My Trips list, or immediately after the agent
  finalizes an itinerary (the app navigates the user here automatically).
- **Happy path:** the Trip's title, optional dates, status, and the full
  ordered itinerary of places are displayed. Each itinerary item shows the
  place name and address.
- **Edit title / dates:** the user can edit the title and set or clear dates
  inline or via a dialog; changes are saved immediately.
- **Delete:** a delete action (e.g. a menu item or button) prompts the user for
  confirmation, then removes the Trip and returns the user to the list.
- **Loading state:** a progress indicator while the Trip is being fetched.
- **Error states:** a message if the Trip cannot be loaded, or if a save/delete
  operation fails.

### Agent screen — post-finalize behavior

- When the agent's `done` event arrives, the app saves (or confirms the server
  has saved) the Trip and shows the user a navigable link or button to open the
  newly created Trip detail view. The existing display of the itinerary in the
  chat remains visible.

## Edge Cases & Error States

- **Finalizing while signed out:** if the `/plan` endpoint is called without
  authentication, Trip persistence is skipped entirely and the `done` event is
  returned without a `trip_id`. The agent conversation still completes; no data
  is lost from the SSE stream, but the itinerary is ephemeral as it is today.
- **Empty itinerary:** if `create_itinerary` is called with zero locations, the
  Trip is still created but its itinerary is empty. The list and detail views
  must handle zero-item itineraries without crashing.
- **Very large itineraries:** the system must handle itineraries of at least
  50 locations (matching the existing route optimizer limit) without truncation
  or error.
- **Duplicate trip titles:** multiple Trips may share the same title; the title
  is not a unique key.
- **`end_date` before `start_date`:** rejected with `400`; the existing dates
  are unchanged.
- **Opening another user's Trip by guessing the ID:** returns `404`, identical to
  a non-existent Trip, so existence is never leaked.
- **Deleting a Trip that is already deleted:** returns `404`.
- **Network failure during post-finalize navigation:** the agent's `done` event
  has already been emitted; if the subsequent GET to load the detail view fails,
  the app shows an error with a retry option. The Trip has been persisted
  server-side regardless.

## Out of Scope

- Editing itinerary items (reordering, adding, removing places) after a Trip is
  saved — planned for a later phase.
- Sharing a Trip with another user or generating a public link.
- Duplicate / copy a Trip.
- Attaching accommodations, activities, dining, flights, or checklist items to
  a Trip — the data model accommodates these but they are not built here.
- Offline access or local-draft persistence when the user is signed out.
- Pagination of the My Trips list (a reasonable upper bound of trips per user
  is assumed for this phase).
- Search or filter within the My Trips list.
- Collaborative or multi-user editing.

## Resolved Decisions

- **Auto-save vs. explicit save — auto-save.** A signed-in user's finalized
  itinerary is persisted automatically the moment the agent calls
  `create_itinerary`; the user can delete it later if unwanted.
- **Unauthenticated `/plan` calls — anonymous allowed, no persistence.** The
  agent stays usable without an account (try-before-signup); persistence happens
  only when the caller is signed in. The `/plan` endpoint is **not** made
  auth-required.
- **Another user's Trip — `404`.** Not-found and not-owned are indistinguishable,
  so the API never leaks whether a Trip exists.
- **Default trip title — agent `summary` if present, else "Trip to {first
  destination}".**
- **Hand-editing the itinerary — deferred.** Itinerary items are immutable after
  save in Phase 1 (add/remove/reorder comes in a later phase). The model keeps an
  explicit, mutable order index so editing can be added without a redesign.
- **Status values — `draft` (default) and `planned`; transitions not gated.**
  Either value can be set freely; no precondition (e.g. dates required) is
  enforced this phase. The value set is left open for future additions.
  *(Superseded 2026-08: the manual status was retired and its consumers now
  derive their signals — see specs/retire-trip-status.)*
