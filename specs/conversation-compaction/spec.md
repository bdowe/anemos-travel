# Spec: Conversation Compaction

## Context

Long planning chats currently die with "This conversation is too long to
continue. Please start a new chat to keep planning." — a hard cap on how many
messages the planner accepts, added to bound cost (the whole history is
re-billed on every agent step). Travelers hit it mid-trip, exactly when the
conversation is most valuable, and "Try again" cannot recover because the
transcript is still too long. Instead of forcing a new chat, the planner
should automatically condense the older part of the conversation into a
compact summary and keep going.

## User Stories

- As a **traveler deep into planning a trip**, I want **the chat to keep
  working no matter how long the conversation gets** so that **I never lose my
  planning context or have to start over**.
- As a **traveler**, I want **decisions I made early in the chat (dates,
  travelers, chosen flights, rejected ideas) to still be respected late in the
  chat** so that **the assistant doesn't re-ask or contradict them**.
- As the **operator**, I want **long conversations to cost less, not more**,
  so that **the feature removes the cost problem the old cap papered over**.

## Acceptance Criteria

- [ ] A conversation that previously hit the "too long" error can continue
      past that point with no user action.
- [ ] When compaction happens, the full visible transcript is unchanged — the
      user sees every message they and the assistant ever exchanged.
- [ ] After compaction, the assistant still recalls decisions made in the
      summarized portion (dates, traveler count, constraints, chosen options).
- [ ] While the conversation is being summarized, the chat shows a brief
      status indicator ("Summarizing earlier conversation…").
- [ ] If summarization fails, the turn still completes normally (no error
      shown; the system just tries again on a later turn).
- [ ] Older app builds that don't understand compaction keep working for many
      more turns than before (the server compacts on their behalf), and only
      truly runaway conversations are rejected.

## API Surface

### `POST /api/v1/plan` (existing SSE endpoint — additions only)

- **Request:** gains optional `summary` — the compacted context from earlier
  turns, previously handed to the client by this endpoint. When present, the
  server treats it as established conversation context preceding `messages`.
  Rejected with a friendly error if it exceeds the per-message length limit.
- **New SSE events:**
  - `compacting` `{}` — emitted just before summarization starts (drives the
    status indicator).
  - `compacted` `{"summary": string, "through_index": int}` — emitted after a
    successful compaction. `summary` replaces any summary the client held;
    `through_index` is how many of the messages the client just sent are now
    covered by the summary and must be excluded from future requests.
- **Behavior:** when the incoming message count reaches the compaction
  threshold, the server summarizes all but the most recent messages (merging
  any incoming `summary`) before running the turn. The hard message cap
  remains, raised, as a runaway/abuse backstop only.
- **Errors:** unchanged, plus oversized `summary` → the existing friendly
  "too long" style SSE error.

## Data Model

Nothing persisted. The summary lives in the client's in-memory chat state and
travels with each request, like the rest of the transcript.

## UI Behavior

- **Surface:** the existing plan chat panel; no new screens.
- **Happy path:** the user chats normally; around the threshold the
  "Summarizing earlier conversation…" chip appears for a couple of seconds,
  then the reply streams as usual. Subsequent turns are faster/cheaper because
  the request carries a summary plus recent messages.
- **States:** compacting (chip visible), normal streaming, error (existing
  banner; compaction failure itself never surfaces as an error).

## Edge Cases & Error States

- Summarization call fails or times out → the turn proceeds on the full
  (still-capped) history; the client's state is untouched; compaction retries
  next turn.
- The turn errors after compaction succeeded → the client keeps the new
  summary state; retry benefits from it.
- Retry ("Try again") after any error → resends the compacted projection; the
  kept-recent window always includes the retried user message, so retry can
  never cut into summarized history.
- Messages queued while streaming → each send reads the compaction state
  current at send time.
- The long refinement seed message eventually falls into the summary; trip-
  bound sessions re-read authoritative trip state via tools, so no special
  casing. *(specs/trip-refine-memory made this true rather than assumed: the
  bound system prompt now requires get_trip before any edit, and each new
  section seed collapses the earlier ones' listings.)*
- The summary itself can never exceed the per-message limit (the server caps
  and truncates its own output defensively).

## Out of Scope

- Persisting chat transcripts or summaries server-side.
- Compacting based on token counts rather than message counts.
- User-visible controls over compaction (manual "compact now", viewing the
  summary).
- Anthropic's server-side compaction beta (targets ~150K-token contexts and an
  opaque block format; wrong scale and shape for this chat).

## Open Questions

None — resolved during planning.
