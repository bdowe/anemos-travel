# Plan: Chat Working Indicator

## Approach

Two explicit server signals close the silent windows (zen: explicit over
implicit — no client-side "no bytes for N seconds" timers), plus client
rendering/lifetime fixes. The tool registry's serialized definitions (the
prompt-cache prefix) are untouched — SSE side events are not part of the
prompt.

## Server (`src/packages/api/plan_handler.go`)

- **`thinking` emit** — `sendSSE(w, "thinking", …)` immediately before every
  `client.Messages.NewStreaming` call, mirroring the `compacting` precedent
  (payload-less status event before slow work; the client clears it on the
  next event of any other type). Emitting before iteration 1 too is what
  retires a stale summarizing chip after a silent compaction failure.
- **Early announcement** — the stream loop gains an
  `anthropic.ContentBlockStartEvent` arm: when the starting block is a
  `ToolUseBlock` whose name exists in `planToolByName`, emit
  `tool_call {name}` right away and record the block index in an `announced`
  set (reset per model call).
- **Dedupe + unknown-tool fix** — the execution loop iterates with the index,
  skips its `tool_call` emit for announced blocks, and checks `entry == nil`
  *before* emitting (an unknown tool must never get a chip: no `tool_result`
  would clear it). `planToolCalls` counting is unchanged.
- Single-goroutine SSE writer preserved: every new emission comes from the
  existing agent-loop goroutine. No heartbeat goroutine, no mutex needed.

## Client (`src/packages/flutter-app`)

- `lib/providers/plan_provider.dart` — `PlanState.isThinking`, set by the
  `thinking` case, auto-cleared in the pre-switch block on any other event
  (same pattern as `isCompacting`), and cleared on all four turn-teardown
  paths (success close, SSE error, transport catch, stop). The `done` case
  additionally removes `create_itinerary` from `activeTools` — `done` IS that
  tool's result (the server keeps suppressing its `tool_result`).
- `lib/widgets/chat_panel.dart` —
  - `_TypingIndicatorBubble` gate: dots show when
    `isStreaming && activeTools.isEmpty && !isCompacting &&
    (streamingText empty || isThinking)`. `text_delta` clears `isThinking`,
    so dots never coexist with live streaming.
  - `_toolLabel`: named labels added for `search_local_recommendations`,
    `review_trip`, `get_weather`, `search_nearby`; the default branch returns
    the localized `chatToolWorking` instead of the raw snake_case name.
  - `ref.listen` autoscroll triggers added for `activeTools.length`,
    `isThinking`, `isCompacting`; `_scrollToBottom` itself still honors the
    user's upward-scroll disarm.
- l10n: `chatToolLocalRecs`, `chatToolReviewTrip`, `chatToolWeather`,
  `chatToolSearchNearby`, `chatToolWorking` in `app_en.arb`/`app_es.arb`;
  `flutter gen-l10n` regenerates.

## Tests

- Go (`plan_integration_test.go`, fake-Anthropic seam):
  `TestPlanThinkingFramesAndEarlyToolAnnouncement` (one `thinking` per model
  call; exactly one `tool_call` despite the dual emit paths) and
  `TestPlanUnknownToolEmitsNoToolCall`. The pre-existing
  `TestPlanToolLoopRoundTripsToolResult` doubles as a dedupe pin.
- Flutter: `chat_panel_typing_indicator_test.dart` gains the dots-return-on-
  `thinking` and thinking-yields-to-chip scenarios;
  `chat_panel_tool_chip_test.dart` (new) pins done-clears-create_itinerary,
  the generic label, and the local-recs label.

## Spec amendments

`specs/chat-polish/spec.md`'s mutual-exclusion sentence is amended: dots may
appear below a *stalled* streamed reply when the server signaled `thinking`.
