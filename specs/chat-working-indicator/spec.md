# Spec: Chat Working Indicator

## Context

Friction log: "Chat sometimes doesn't clearly indicate that it's loading, when
it's actually still working on something." Once a plan turn had streamed any
text, the typing indicator could never return for the rest of that turn, so
the two longest silent stretches — the model writing a large itinerary (tens
of seconds to two minutes) and every between-steps pause before the model's
next reply — showed only a 2.5px blinking caret. The turn looked finished or
stalled while the server was hard at work. Outcome: whenever a plan turn is in
flight, at least one animated indicator is visible in the chat tail, and every
indicator's label and lifetime tell the truth.

## User Stories

- As a **traveler planning a trip**, I want the chat to visibly show it is
  still working during long pauses so that I don't think it silently died and
  re-send or leave.
- As a **traveler watching an itinerary build**, I want the "Building
  itinerary…" chip to appear when the building actually starts and disappear
  when the itinerary is ready, so the status I read matches reality.
- As a **Spanish-language traveler**, I want every working label localized —
  never a raw internal tool name.

## Acceptance Criteria

- [ ] From the moment a message is sent until the turn ends (reply complete,
  stopped, or errored), the chat tail always shows at least one animated
  indicator: typing dots, a spinning tool chip, or the summarizing chip.
- [ ] When the assistant pauses after streaming text (looking something up,
  composing its next step), the typing dots reappear below the streamed text;
  they disappear the instant more text arrives. Dots never overlap an
  actively-streaming reply, a tool chip, or the summarizing chip.
- [ ] A long itinerary build shows its "Building itinerary…" chip as soon as
  the build starts — not after tens of silent seconds — and the chip clears
  when the itinerary-ready banner appears (it must not keep spinning under a
  banner that says finished).
- [ ] Every tool chip shows a human-readable localized label (English and
  Spanish); tools without a bespoke label show a generic "Working…", never a
  raw snake_case name.
- [ ] When a working indicator appears, the chat scrolls it into view — unless
  the user has scrolled up on purpose, which still wins.

## API Surface

No new endpoints. Two additions to the `POST /api/v1/plan` SSE stream:

### `thinking` event
- **Purpose:** announces that the server is waiting on the model (a model call
  is being issued). Emitted before **every** model call in the turn's loop.
- **Payload:** empty object.
- **Post-state / clearing:** it has no terminator of its own — the next event
  of any other type (first token, tool announcement, summarizing, error) ends
  the state, exactly like the existing `compacting` chip's clearing rule. A
  `thinking` frame also serves as the "next event" that retires a stale
  summarizing chip when compaction failed silently.

### Earlier `tool_call` emission
- **Purpose:** the existing `tool_call {name}` event now fires the moment the
  model *starts* writing that tool's input, not after the whole model response
  has streamed — closing the longest silent window (large itinerary inputs).
- **Contract kept:** still exactly one `tool_call` per tool invocation
  (duplicates would leave a chip no `tool_result` clears), still followed by
  the tool's side events and `tool_result` (where applicable). A tool name the
  server doesn't recognize is never announced at all.

## Data Model

None. No persistence changes.

## UI Behavior

- **Typing dots:** shown when a turn is in flight and nothing else owns the
  moment — before the first token (unchanged), in post-tool gaps (unchanged),
  and now also below already-streamed text while the server reports thinking.
- **Tool chips:** unchanged visual; labels now cover local recommendations,
  trip review, weather, and nearby search by name, with a localized generic
  "Working…" for everything else.
- **Auto-scroll:** indicator appearances (chips, dots, summarizing) scroll the
  tail into view under the same stick-to-bottom rule as streamed text; a user
  who scrolled up is never yanked back down.

## Edge Cases & Error States

- Turn ends (stop button, error, stream close) → all indicator state clears
  with the rest of the streaming state; no orphaned dots or chips.
- Compaction failure emits nothing of its own → the next `thinking` frame
  retires the summarizing chip instead of it lingering until the first token.
- A model response with several tool calls announces each chip as the model
  writes it; chips retire one by one as the tools finish executing. Calls that
  render the same label (parallel `search_places`, or two unnamed quick
  writes both showing "Working…") collapse into a single chip that clears
  when the last matching call finishes.
- Older deployed clients that don't know `thinking` ignore unknown SSE event
  types by falling through their event switch — the stream stays compatible.

## Out of Scope

- The composer's stop-button losing its in-flight cue while the user types a
  queued follow-up.
- Any app-level busy cue when the refine panel is closed (or collapsed on
  narrow layouts) mid-stream.
- Detecting a silently dropped stream (no terminal event on the wire).
- The `stays`/`transport` SSE events the client currently ignores.
- Elapsed-time display on tool chips.

## Open Questions

None.
