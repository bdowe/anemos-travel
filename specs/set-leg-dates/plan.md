# Plan: Change One Leg's Dates from Chat (`set_leg_dates`)

> **HOW.** Translates `spec.md` into a file-level technical approach.

## Technical Approach

One new agent tool `set_leg_dates`, **appended at the registry tail** (after
`set_trip_dates` — prompt-cache byte-stability rule), modeled directly on
`plan_trip_dates.go` (guard ladder → `resolveDateShiftTrip` reused as-is →
one transaction under `GetTripForUpdate` → SSE `trip_updated` + analytics +
collaborator notify). No new HTTP endpoints, no schema migration, **no new
SQL** (existing narg-COALESCE update queries suffice), no Flutter changes.

Key decisions:

- **Endpoint-anchored deltas, never one delta.** `startDelta = newStart −
  oldLegStart`, `endDelta = newEnd − oldLegEnd`; they differ whenever the leg
  length changes (the dogfood case: +4 / +3).
- **Leg = contiguous run of items sharing a hub.** New pure helper
  `legRuns(items)` walks position order splitting on `itemHub` change
  (trip_review.go's `day_trip_from`-else-`city`; empty hub adopts the current
  run). City matched `EqualFold` first, `fuzzyMatch` fallback. Zero matches →
  error listing real legs + date ranges; two+ runs → error asking which
  visit.
- **Current leg dates mirror Flutter's display precedence** (confirmed
  matched stay's check-in/out, else items' day range from the trip anchor) so
  "change LA to X" moves what the traveler *sees*.
- **Leg-only cascade.** Only the run's items, fuzzy-matched confirmed stays,
  and boundary segments move; `trips.end_date` extends when the new leg runs
  past it; `trips.start_date` never moves (leg-start-before-trip is an error
  routing to `set_trip_dates`). Auto drafts are skipped — `UpdateAccommodation`
  / `UpdateSegment` flip `auto=false`, which would silently "confirm" an
  unchosen suggestion; the client re-derives drafts on refetch. Booking todos
  untouched (client re-derives auto rows per load; manual ones are the
  model's `update_booking_todo` job, said in the result).
- **The gap is computed, not hoped for.** The tool result deterministically
  narrates gap/overlap vs. the previous/next run so the prompt's
  "point it out and offer to fix" instruction has reliable input.
- **Honest no-op closed.** `set_trip_dates`' delta-0 result string (not
  cache-relevant) now steers the model to `set_leg_dates` when only one
  city was meant.

## Go API Changes

`src/packages/api/`:

- **`plan_leg_dates.go` (new):** `setLegDatesTool` definition; pure helpers
  `legRuns` + `computeLegDateChange` (indices, deltas, clamp counts, errors);
  `runSetLegDatesTool` (guards → resolution → tx: renumber run items via
  `UpdateItineraryItem`, shift matched confirmed stays via
  `UpdateAccommodation` (check_in += startDelta, check_out += endDelta,
  inversion clamps to check_in+1), classify + shift confirmed boundary
  segments via `UpdateSegment`, `SetTripDates` end-extension, `TouchTrip` →
  commit → SSE `trip_updated`, `s.itineraryEmitted`, `s.tripID`,
  `agent_leg_dates_set` analytics, `notifyCollabEdit`).
- **`plan_tool_registry.go`:** tail append after `setTripDatesTool`, gate
  `authedOnly`, standard tail comment.
- **`plan_handler.go`:** basePrompt one-city routing sentence + relay-the-gap
  instruction after the existing set_trip_dates sentence; same for the
  bound-trip refine suffix; `suggest_replies` exclusion gains
  `set_leg_dates`. All before the pinned "no headings or tables." suffix.
- **`plan_trip_dates.go`:** delta-0 result string only (append the
  set_leg_dates steer). Tool definition stays byte-identical.

## Flutter Changes

None. `trip_updated` handling already refreshes; draft/todo syncs converge.

## Contract Parity

n/a — model-facing tool result text plus the existing `trip_updated` shape.

## Tests

`plan_leg_dates_test.go` (fake-Anthropic harness; DB tests skip without
`TEST_DATABASE_URL`):

1. Unit tables: `computeLegDateChange` (differing deltas, omitted end,
   shrink-clamp, end<start, start-before-trip) and `legRuns`/matching
   (day-trip fold, revisited-city split, empty-hub adoption, fuzzy match).
2. Guard errors via `testPlanSession` (anonymous, no trip, dateless trip,
   missing params, unknown city lists legs, ambiguous city).
3. Headline DB test = the dogfood scenario (PC days 1–6, LA days 6–9,
   confirmed stays, PTY→LA + LA→EWR segments, one auto LA draft): LA rows
   move, PC rows + draft byte-identical, trip end Sep 27, one
   `trip_updated`, next-request body carries the range + "uncovered
   night(s)" + "ORIGINAL dates", `agent_leg_dates_set` recorded.
4. Shrink-leg clamp; editor collaborator; validation-leaves-DB-untouched;
   two-request lineage (second `newFakeAnthropic` for request 2).

Tail pins (the known five): authed + authed-bound want-slices and the authed
tail guard gain `set_leg_dates`; anonymous pins intentionally stay
`find_parking`.

## Coordination

Touches `plan_tool_registry.go` (append) and the `plan_handler.go` prompt
hub — at most one in-flight lane may; this is that lane.
