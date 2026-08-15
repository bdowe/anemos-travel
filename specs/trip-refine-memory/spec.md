# Spec: Trip Refine Memory

## Context

The trip-detail refine panel is where a traveler edits a saved trip by talking
to the assistant — and today that conversation is the most fragile thing on the
page. It lives only in memory, so a refresh or a deploy loses it. Five of the
six ways to open the panel silently wipe it before you can say anything. And
because the panel is drawn inside the screen rather than pushed as its own
route, pressing back — the obvious gesture for something that looks like a
sheet — throws away the whole page, chat included. Dogfooding on 2026-08-15:
*"I've accidentally clicked the back button and had to restart a chat several
times."* The outcome: a trip has **one running conversation** that is saved for
as long as the trip exists, is visible on the trip page, survives a refresh,
and is discarded only when the traveler explicitly asks for a new one.

## User Stories

- As a **traveler editing a trip**, I want back to close the chat rather than
  the page, so that a misfired gesture costs me nothing.
- As a **traveler**, I want to come back tomorrow and pick up the same
  conversation about my trip, so that I don't re-explain what I already said.
- As a **traveler**, I want to switch the chat's focus from one day to another
  without losing what we already discussed, so that the conversation reads as
  one thread.
- As a **traveler**, I want to see on the trip page that a conversation is
  waiting, so that I don't have to remember which button is the safe one.
- As a **traveler**, I want a deliberate way to start fresh, so that "one
  conversation" never becomes a conversation I can't escape.
- As a **co-planner**, I want my own conversation about a shared trip, so that
  the owner and I never read or overwrite each other's chats.

## Acceptance Criteria

- [ ] With the chat panel open, back (system, browser, or the app-bar chevron)
      closes the panel and leaves the trip on screen; a second back leaves the
      trip. Escape does the same on desktop.
- [ ] Closing the panel — by back or by ✕ — never cancels a turn in flight, and
      an itinerary change that lands after the panel closed still refreshes the
      trip.
- [ ] While a turn streams with the panel closed, the chat button shows the
      turn is still running.
- [ ] Tapping ✨ on a day, a city, or the whole trip adds a new context marker
      to the existing conversation; nothing already said is removed.
- [ ] After a full page reload, the trip page shows that a conversation exists
      (with its last reply and how long ago), and opening it restores the
      transcript — context markers intact, images as placeholders.
- [ ] The chat is reachable the same way on a trip that has no places yet.
- [ ] "New chat" asks first, then clears the conversation; the trip is
      unaffected and the page stops advertising a saved chat.
- [ ] A trip's conversation never appears in "Continue where you left off", and
      the Plan tab can never be made to open it.
- [ ] The assistant re-reads the trip before applying a change, so resuming an
      older conversation cannot revert edits made since.
- [ ] Deleting a trip deletes its conversations.
- [ ] The owner and each editor co-planner have separate conversations about
      the same trip; neither can see the other's. A revoked collaborator loses
      access to theirs without it being destroyed.
- [ ] Offline, the trip page offers no chat entry it cannot honor.

## API Surface

### `GET /api/v1/trips/{id}/refine-chat`
- **Purpose:** the caller's saved conversation about this trip, in full.
- **Request:** authenticated; the caller must be allowed to edit the trip.
- **Response:** the trip it belongs to, the running compaction summary, the
  message list (roles, text, context labels, image placeholders), how many
  messages, and when it was last touched.
- **Errors:** 404 when the caller has no conversation about this trip, when the
  trip does not exist, or when the caller may not edit it — the three are
  deliberately indistinguishable. 401/503 as elsewhere.

### `DELETE /api/v1/trips/{id}/refine-chat`
- **Purpose:** discard the conversation ("New chat").
- **Request:** authenticated; caller must be allowed to edit the trip.
- **Response:** 200 stating the post-state the caller will observe — the trip,
  and no conversation. **Idempotent:** succeeds whether or not one existed,
  because the caller cannot know beforehand and clearing nothing is not an
  error.
- **Errors:** 404 only when the trip is unreachable to this caller.

### `GET /api/v1/trips/{id}` (changed)
Full trip responses gain an optional **refine chat** object: how many messages,
the last assistant reply as a preview, and when it was last touched — presence
and freshness only, never the transcript, and deliberately carrying no
identifier. It is per-caller: an owner and each co-planner see only their own,
and it is absent when they have none. It is **not** the trip's existing
conversation key, which identifies the owner's itinerary version lineage and is
withheld from collaborators.

### `POST /api/v1/plan` (behavior change, no wire change)
A turn bound to a trip is now saved. Free planning chats are unchanged.

## Data Model

- **Trip refine session** — one traveler's conversation about one trip. Its
  identity is the pair (traveler, trip): there is at most one, which is what
  makes "the trip's chat" a fact rather than a convention. It holds the
  transcript, the running compaction summary, a preview of the last reply, a
  message count, and timestamps. It deliberately has **no conversation id** —
  nothing outside the trip can name it, so it can never be opened as a free
  planning chat, which would silently drop the trip binding. It has no title:
  the trip's title names it. It lives as long as the trip and is deleted with
  it; unlike free planning chats it is never pruned on age, because a trip
  planned in August for next March must still have its chat in November.

## UI Behavior

- **Surface:** trip detail. The panel is docked beside the itinerary on wide
  layouts and a drag sheet on narrow ones, unchanged.
- **Happy path:** the trip page shows a "Continue chat" row when a conversation
  exists → tap it (or the chat button) → the transcript is restored → ask for a
  change → the itinerary updates behind the panel → press back → the panel
  closes and the trip is still there.
- **States:** *restoring* — the panel opens immediately showing that it is
  restoring, with no composer, so nothing can be sent before the history is
  back. *expired* — the conversation is gone; say so and offer a new chat, not
  a retry. *failed* — say so, offer retry and a new chat. *none* — the ordinary
  fresh chat, exactly as today.
- The panel's title follows the newest context marker in the conversation, so
  it is a function of what was said rather than of screen state that a gesture
  can destroy.

## Edge Cases & Error States

- **Restore fails and the traveler types anyway** — impossible by construction:
  the composer does not exist until the transcript is in. Sending onto an empty
  panel would overwrite the stored conversation with two messages.
- **Trip deleted mid-conversation** — the turn finishes; the save is dropped.
- **No database (degraded mode)** — the chat works and simply isn't remembered.
- **Two devices** — last writer wins, as for free planning chats.
- **A new itinerary version** — a conversation belongs to the version it was
  about; a brand-new version starts a fresh one.
- **A very long conversation** — existing compaction applies unchanged; the
  superseded itinerary listings inside old context markers are collapsed as
  each new one is added, so only one authoritative listing is ever in play.

## Out of Scope

- A per-trip chat history or picker — there is one running conversation.
- Giving the open panel its own URL, so that a refresh reopens it.
- Any client-side mirror of the transcript for offline use.
- Reviving the unused "reopen this trip in the Plan tab" path.

## Open Questions

None.
