# Spec: Refine Panel Polish

## Context

The trip-detail "Refine with AI" panel shares the recently polished chat
surface, but the surrounding screen still behaves roughly: every time the
assistant patches the itinerary mid-conversation, the whole page (itinerary
and the open chat) blanks to a loading spinner and remounts; the panel opens
on a huge machine-generated first message full of coordinates; and nothing in
the chat says "your change landed". The outcome: refining a trip feels as calm
as the main planning chat — the itinerary updates in place behind the panel,
the conversation starts with a tidy context marker, and each applied change is
acknowledged inline.

## User Stories

- As a **trip owner refining a day**, I want the itinerary to update in place
  while the assistant works so that the screen never blanks mid-conversation.
- As a **trip owner**, I want the refine chat to open with a short "Refining
  Day 2 — Athens" marker instead of a wall of coordinates so that the
  conversation reads naturally.
- As a **trip owner**, I want an inline "Itinerary updated" acknowledgment so
  that I know a change landed without watching the list behind the panel.

## Acceptance Criteria

- [x] While a refine response streams, the trip screen never shows the
      full-screen loading spinner; the itinerary list/map update in place.
- [x] The chat's scroll position and any half-typed input survive an
      itinerary update.
- [x] The refine conversation opens with a compact context chip (e.g.
      "Refining · Day 2 — Athens"); the raw seed text is not shown.
- [x] The assistant still receives the full seed detail (its edits remain as
      accurate as before).
- [x] An "Itinerary updated" chip appears in the chat when a change is
      applied and clears when the next message is sent.
- [x] Pull-to-refresh on an already-loaded trip shows only the pull indicator,
      never the full-screen spinner, and a failed refresh keeps showing the
      current trip.
- [x] The Agent tab's planning chat is unchanged (no new chips, seeds render
      as before).
- [x] Both layouts behave identically: wide (side dock) and narrow (bottom
      sheet).

## API Surface

No endpoint or SSE changes. The existing mid-stream `trip_updated` event is
consumed differently on the client.

## Data Model

No persisted entities change. The in-memory chat message gains an optional
display label (UI-only; never sent to the server).

## UI Behavior

- **Surface:** trip detail screen (refine panel host) and the shared chat.
- **Happy path:** owner taps Refine → panel opens with the context chip →
  owner asks for a change → assistant streams, patches the section →
  "Itinerary updated" chip appears, itinerary refreshes silently behind the
  panel → conversation continues.
- **States:** first load keeps today's spinner; refresh failures during a
  refine are silent (stale trip stays); the full-screen error state remains
  for the initial load only.

## Edge Cases & Error States

- Several itinerary patches in one assistant turn → refreshes coalesce; the
  final state always reflects the last patch.
- Refresh failing mid-refine must not replace the screen with an error page.
- Re-opening Refine on another section re-seeds; each session starts with its
  own context chip. *(Amended by specs/trip-refine-memory: it re-seeds into the
  SAME conversation, adding a second context chip rather than discarding what
  came before, and the earlier chip's itinerary listing is collapsed so only
  one authoritative listing is ever in play.)*

## Out of Scope

- Silent refresh for user-driven mutations (add/edit/delete/reorder) — they
  keep their current reload behavior this pass.
- Collapsing the Agent tab's trip-reopen seed message.

## Open Questions

None.
