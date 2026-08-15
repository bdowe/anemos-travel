# Spec: Collaborator AI Refine

## Context

Co-planners (editor collaborators, specs/collaborative-editing) can hand-edit a
shared trip but cannot use the AI refine agent — refine is owner-only. That
splits the planning experience: the owner gets the product's best tool, invited
friends get manual editing. This feature lets editor collaborators refine the
shared trip with the AI exactly as the owner does, while keeping the trip's
version lineage single and owner-owned. It also fixes a latent concurrency bug
where two simultaneous whole-itinerary rewrites could merge into a duplicated
itinerary.

## User Stories

- As a **co-planner**, I want **to use "Refine with AI" on a trip shared with
  me** so that **I can contribute ideas without asking the owner to run them**.
- As a **trip owner**, I want **a friend's AI refinements to land on my trip in
  place** so that **the trip never forks or duplicates under their account**.
- As a **trip owner**, I want **strangers kept out of the AI agent for my
  trips** so that **sharing never widens write access beyond members**.

## Acceptance Criteria

- [ ] An editor collaborator sees the trip-level Refine entry (the header
      "Refine with AI" button on wide layouts; an app-bar sparkle icon on
      narrow layouts), per-day and per-city refine icons, and the
      trip-assistant chat button on a shared trip, and can run a refinement
      end-to-end.
- [ ] A collaborator's refinement rewrites the owner's trip in place: no new
      trip version, no new trip under the collaborator's account; the owner
      sees the change on next load.
- [ ] A non-member requesting a trip-bound agent session is refused before
      anything streams, with no existence leak.
- [ ] Collaborators never receive the trip's planning-conversation key from
      shared-trip responses.
- [ ] Two simultaneous whole-itinerary writes (refine vs. refine, refine vs.
      reorder) serialize — last write wins cleanly, never a merged/duplicated
      item set.
- [ ] *(Amended by specs/trip-refine-memory: a collaborator's refine
      conversation is no longer ephemeral — it is saved under their own account
      for that trip, visible to no one else, deleted with the trip, and a
      revoked collaborator loses access to it without it being destroyed. It
      still appears in nobody's resumable chats.)*
      A collaborator's refine session is ephemeral: it does not appear in
      anyone's resumable chats.
- [ ] Refine usage is metered against the person pressing the button (their
      own free-tier session count, not the owner's).

## API Surface

No new endpoints. Behavior changes:

### `POST /api/v1/plan` (trip-bound sessions)
- **Purpose:** a session bound to a trip is now authorized for the trip's
  owner **or an active editor collaborator** (previously owner-only).
- **Errors:** unchanged shape — non-members get the same "trip not found"
  stream error as an unknown trip id.
- Inside the session, the agent's trip-read and booking-checklist tools accept
  the bound trip for collaborators; every other trip reference remains
  strictly caller-owned (a collaborator can never list or touch the owner's
  other trips).

### `GET /api/v1/trips/{id}` and `GET /api/v1/trips/shared-with-me`
- **Response:** `chat_id` is null when the caller's access is `editor`
  (still present for owners).

## Data Model

No schema changes. Refinement rewrites the bound trip's itinerary items in
place; whole-itinerary rewrites now hold a trip-level write lock for the
duration of the rewrite so concurrent writers serialize.

## UI Behavior

- **Trip detail (shared, editor access):** the header shows the co-planning
  banner *and* the trip-level Refine entry — the "Refine with AI" button on
  wide layouts, an app-bar sparkle icon on narrow (<800px body) layouts
  (mobile declutter, 2026-07-22). Per-day and per-city refine icons and the
  trip-assistant chat button appear as they do for owners. Per-day/city
  icons and the chat button stay hidden offline; the trip-level entry
  (button or sparkle) renders disabled offline instead of hidden, matching
  the shipped header-button behavior.
- **Happy path:** co-planner opens the shared trip → taps Refine → the refine
  panel streams the agent → the section updates in place → the banner's
  "your changes save for everyone" promise holds for AI edits too.
- **States:** unchanged from the owner refine flow (streaming, error snack,
  offline guard).

## Edge Cases & Error States

- Collaborator removed mid-session: the next tool write fails authorization
  and surfaces the agent's normal error path.
- Owner and collaborator refine simultaneously: writes serialize; the later
  transaction wins wholesale (documented last-write-wins model).
- Signed-out or non-member callers binding a trip id: refused before
  streaming.

## Out of Scope

- Viewer-role membership (separate feature: share-ux-viewer-follow).
- Freshness/notifications when a collaborator refines (separate feature:
  shared-trip-freshness).
- Collaborator access to the owner's planning chat history or resumable chats.
- The legacy owner-only refine-session endpoint (unused by the app) keeps its
  behavior.

## Open Questions

None — resolved during planning: refine cost meters to the caller; chat_id is
withheld from editors; the unused legacy refine endpoint stays owner-only.
