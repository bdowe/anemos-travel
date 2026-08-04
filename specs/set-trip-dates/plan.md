# Plan: Shift Trip Dates from Chat (`set_trip_dates`)

> **HOW.** Translates `spec.md` into a file-level technical approach.

## Technical Approach

One new agent tool `set_trip_dates`, **appended at the registry tail** (after
`find_parking` — prompt-cache byte-stability rule, CLAUDE.md → Key
Constraints), modeled on `set_travel_mode`'s handler shape (unscoped
single-purpose query + `TouchTrip` + SSE `trip_updated`). No new HTTP
endpoints, no schema migration, no Flutter changes (`trip_updated` handling
already refreshes the trip).

Key decisions:

- **Gate is `authedOnly`, target-trip resolution lives in the handler.** The
  tools array is built once per request *before* the agent loop
  (`plan_handler.go` → `planSessionTools`), so a gate on the mid-request
  `s.tripID` can never fire, and regenerating tools per iteration would break
  the prompt-cache prefix. `authed` never flips mid-conversation → each
  session shape's tools array stays fixed.
- **Resolution ladder** (no `trip_id` input param): bound trip
  (`GetEditableTripByID`, owner or editor collaborator) → trip persisted
  earlier this request by `create_itinerary` (`s.tripID`) → newest version of
  the chat's lineage (`ListTripVersionsByChat`, owner-scoped) → instructive
  error pointing at `create_itinerary`'s `start_date`.
- **Whole-trip cascade in one transaction.** Delta = new start − old start
  (civil dates). `GetTripForUpdate` row lock (same as `replaceTripSection`)
  serializes against concurrent rewrites. Child tables shift with set-based
  UPDATEs (`date + int`); NULL dates stay NULL. No anchor (previously dateless
  trip) → set trip dates only.
- **`SetTripDates` is deliberately unscoped** (WHERE id only): `UpdateTrip` is
  owner-scoped but editor collaborators may shift — authz happens in the
  handler, the `SetTripTravelMode` precedent.
- **Honesty guardrail in the prompt**: the model must never claim a saved-trip
  change happened unless a tool call succeeded that turn.

## Go API Changes

`src/packages/api/`:

- **`plan_trip_dates.go` (new):** `setTripDatesTool` definition
  (`start_date` required, `end_date` optional, YYYY-MM-DD);
  `computeTripDateShift(oldStart, oldEnd, newStart, newEnd, maxDay)` pure
  helper (end omitted → preserve old duration, else derive `start + maxDay−1`;
  error when end < start); `runSetTripDatesTool` handler (guard ladder →
  resolution ladder → tx: `GetTripForUpdate`, `SetTripDates`, three `Shift*`
  queries when anchored and delta ≠ 0, `TouchTrip` → commit → SSE
  `trip_updated`, `s.itineraryEmitted = true`, `s.tripID = &tid`, analytics
  event `agent_trip_dates_set`, collaborator-edit notification).
- **`query/trips.sql`:** `SetTripDates :exec` (unscoped, comment mirrors
  `SetTripTravelMode`).
- **`query/accommodations.sql` / `query/segments.sql` /
  `query/booking_todos.sql`:** `Shift*Dates :execrows` — `SET <col> = <col> +
  sqlc.arg(days)::int` guarded `WHERE trip_id = … AND (<col> IS NOT NULL OR
  …)` so execrows is an honest shifted-rows count. Auto/dismissed rows shift
  too (post-shift they agree with the new dates → client sync converges).
  Regen with `make api-sqlc`.
- **`plan_tool_registry.go`:** tail append after `findParkingTool` with the
  standard comment; gate `authedOnly`.
- **`plan_handler.go`:** bound-trip suffix gains a date-change sentence; base
  prompt gains a post-save date-change sentence + the anti-fabrication
  sentence; `suggest_replies` exclusion extended with `set_trip_dates`. All
  insertions BEFORE the final "no headings or tables." sentence
  (`TestSystemPromptEnglishUnchanged` pins the suffix).
- **`plan_tools_extra.go`:** `formatReviewFindings` closing hint lists
  `set_trip_dates` for `fix=set_dates`.

## Flutter Changes

None. `plan_provider.dart` already refreshes on `trip_updated`; no models or
l10n touched.

## Contract Parity

n/a — no new wire types; the tool result is model-facing text and the SSE
event is the existing `trip_updated` shape.

## Tests

`plan_trip_dates_test.go` (fake-Anthropic harness, `plan_parking_test.go`
style; DB tests skip without `TEST_DATABASE_URL`):

1. `computeTripDateShift` unit table (±N preserving duration, explicit end,
   end<start error, no-anchor, derive-from-maxDay incl. empty itinerary).
2. Bound-session DB cascade: all four tables' non-null dates +7, NULLs
   untouched, `trip_updated` SSE, result text counts + rebooking reminder,
   analytics event.
3. No-anchor: dates set, children untouched.
4. Validation errors leave the DB unchanged.
5. Fresh-chat same-turn (`create_itinerary` → `set_trip_dates`).
6. Fresh-chat next-turn (same `chat_id`, lineage resolution).
7. Editor collaborator can shift the bound trip.

Tail pins (five, per registry rule): authed + authed-bound want-slices in
`plan_tool_registry_test.go` and the authed tail guard in
`plan_integration_test.go` gain `set_trip_dates`; the anonymous want-slice and
the anonymous tail guard in `plan_quick_replies_integration_test.go`
intentionally stay `find_parking` (gate is authed-only).

## Coordination

PR #278 (trip-health range grouping) is open and touches trip-health findings
formatting — if it merges first, rebase the `formatReviewFindings` edit over
it (or let `/integrate` order the merges).
