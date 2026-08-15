# Spec: Continue Where You Left Off

## Context

An AI planning conversation persists nothing until the agent decides the plan
is ready and saves an itinerary. A traveler who has a long back-and-forth about
a trip but leaves before that point loses the entire conversation — nothing
appears under their saved trips, and there is no way to pick the discussion
back up. This feature saves the conversation from the first submitted message
and surfaces in-progress ("discussion phase") conversations so the traveler
can resume them, while keeping the trips list itself reserved for trips the
agent actually saved.

## User Stories

- As a **signed-in traveler**, I want **my planning conversation saved as soon
  as I send the first message** so that **leaving mid-discussion never loses my
  progress**.
- As a **signed-in traveler**, I want **a "Continue where you left off" section
  on my trips page** so that **I can resume an unfinished planning conversation
  with its full history**.
- As a **signed-in traveler**, I want **the resumable entry to disappear once
  the conversation produces a saved trip** so that **the trip card takes over
  and I don't see duplicates**.
- As a **signed-in traveler**, I want **to dismiss a resumable conversation I
  no longer care about** so that **the section stays relevant**.

## Acceptance Criteria

- [ ] Sending the first message in an AI planning chat while signed in creates
      a resumable conversation, even if the stream then fails immediately.
- [ ] Each completed turn updates the saved conversation with the assistant's
      reply, so a resume shows everything both sides said.
- [ ] The trips page shows a "Continue where you left off" section above saved
      trips, listing in-progress conversations (most recent first), each with a
      title drawn from the opening message (its display label when one is
      present — seeded chips like "What's near me?" — otherwise its text), a
      preview of the latest reply, and when it was last active.
- [ ] Tapping an entry opens the AI planning tab with the full conversation
      restored; sending the next message continues the same conversation with
      full context.
- [ ] Once the agent saves a trip from a conversation, that conversation no
      longer appears in the section (the trip card represents it).
- [ ] A conversation abandoned while refining an existing saved trip does not
      appear in the section. (Still true since specs/trip-refine-memory, by a
      stronger mechanism: a trip's conversation is stored per (traveler, trip)
      in its own table with no chat id at all, so it is resumed from the trip's
      own page and cannot be named here.)
- [ ] Dismissing an entry removes it immediately.
- [ ] Anonymous users see no section and nothing is saved for them; the chat
      behaves exactly as before.
- [ ] When the database is unavailable, planning chats still work and the trips
      page shows no section (no errors surfaced).

## API Surface

### `GET /api/v1/chats`
- **Purpose:** List the caller's resumable (in-progress) planning conversations.
- **Request:** none (authenticated).
- **Response:** array of summaries: conversation id, title, preview of the
  latest assistant reply, message count, created/last-active timestamps.
  Conversations that already produced a saved trip are excluded. Most recent
  first, capped to a small number.
- **Errors:** 401 unauthenticated; 503 database unavailable.

### `GET /api/v1/chats/{chatId}`
- **Purpose:** Fetch one conversation's full transcript for resuming.
- **Request:** conversation id in the path (authenticated; owner only).
- **Response:** conversation id, title, ordered messages (role + content), and
  the running context summary if the conversation was compacted.
- **Errors:** 401 unauthenticated; 404 not found / not the caller's.

### `DELETE /api/v1/chats/{chatId}`
- **Purpose:** Dismiss a resumable conversation.
- **Request:** conversation id in the path (authenticated; owner only).
- **Response:** 204 on success.
- **Errors:** 401 unauthenticated; 404 not found / not the caller's.

## Data Model

- **Plan chat session** — one per planning conversation per user: the owner,
  the conversation's opaque id, a short title (from the opening message's
  display label when present, otherwise its text), a preview (latest assistant
  reply), the transcript (ordered role/content messages, each with an optional
  display label for seeded chips), the running compaction summary if any,
  message count, and
  created/updated timestamps. Updated wholesale each turn. Deleted on dismiss;
  stale sessions (no activity for ~60 days) are pruned opportunistically.

## UI Behavior

- **Surface:** "Continue where you left off" section at the top of the Trips
  tab, above the saved-trips list; hidden when empty or signed out.
- **Happy path:** traveler chats with the planner, switches to Trips → sees the
  conversation listed → taps it → lands on the planning tab with the transcript
  restored → keeps chatting; when the agent saves the trip, the entry is
  replaced by the trip card on the next refresh.
- **States:** section hidden while loading or on error (fail quiet); entries
  show title, preview, relative time, and a dismiss affordance; trips page
  empty-state still appears when there are no saved trips, below the section
  when resumable chats exist.

## Edge Cases & Error States

- Stream dies mid-turn: the traveler's message is already saved; whatever the
  assistant said before the failure is saved at turn end.
- Conversation reaches the server's history caps on resume exactly as it would
  have live (same friendly error, no special handling).
- Two devices on the same conversation: last writer wins; each write is a
  self-consistent transcript.
- Saving the session fails: the chat turn proceeds normally (persistence is
  best-effort, never user-visible).

## Out of Scope

- Resumable conversations for anonymous users (device-local persistence).
- Server-side rendering of tool results/cards in a resumed transcript — only
  the text conversation is restored.
- Cross-device real-time sync or conflict resolution.
- Resuming trip-bound refine panels — **shipped separately** as
  `specs/trip-refine-memory`, from the trip's own page rather than this section.

## Open Questions

None.
