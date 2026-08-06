# Plan: Server-Computed City-Leg Dates

## Key decisions (reconciled from the audited divergences)

| Rule | Decision | Why |
|---|---|---|
| Run split | Dart rule: null/empty hub is its own run, groups with hubless neighbors; revisits keyed `City#2` | Payload must reproduce what the screen shows; client collapse keys survive |
| Hub of an item | `day_trip_from ?? city`, trimmed; NO address parsing | Server never second-guesses tags; client's `cityFromAddress` fallback retires at the client repoint (address-only items become "Other places") |
| Stay→leg match | Go rule: fuzzy address, then NAME fallback; non-auto, both dates | Agent-added address-less stays must anchor their leg |
| Span precedence | stay > item days > weighted auto-allocation (ported `_allocateDays`) > none | Existing client semantics, now one implementation |
| First-leg anchor | First leg WITH a span, when item-derived, starts at the trip start | Generalizes the Go `firstDatedRunIdx` rule; avoids anchor/auto overlap pathologies |
| Arrival chain | Go rule: spanless legs are skipped and never reset the chain; zero-night collapse spares stay-anchored legs | The Dart null-reset was the bug-shaped variant |

## Modules

- `src/packages/api/trip_render_legs.go` — `computeTripLegs(trip, items,
  stays) []RenderLeg` + `allocateLegDays` (stage 0b, landed with this spec).
  Twin tests in `trip_render_legs_test.go` hand-mirror
  `flutter-app/test/leg_ranges_test.dart` fixtures (calendar-parity
  convention); the two `diverges:` cases carry the server-side expected
  values. Note the raw-vs-visible lens: the Go module emits only the
  chained/visible output, so three Dart RAW fixtures appear here with their
  visible-lens values (arrival pull-backs).
- `flutter-app/lib/utils/leg_ranges.dart` — the extracted client derivation
  (stage 0a, PR #297): `rawLegRanges` / `visibleLegRanges` / `allocateDays`.

## Remaining lanes (wave 2–3; see tasks.md)

- 1a payload: `legs` field on the trip + shared responses (`RenderLeg` JSON),
  Dart `TripLeg` model on `Trip` (`make flutter-build-models`).
- 1b Go consumers: `legsRenderSummary`/get_trip/section results +
  `print_view_handler.go` stay-matching onto `computeTripLegs`; golden diffs
  reviewed line-by-line against documented divergences only.
- 1c parity logger: `kDebugMode` comparison payload-vs-`visibleLegRanges` in
  the trip provider, mismatches → instrumentation events. Soak gate: ≥1 week
  zero mismatches on real trips.
- 2a client repoint (hub lane): consumers → `trip.legs ?? visibleLegRanges`
  fallback (raw consumers get raw-equivalents from the payload or keep
  `rawLegRanges` until 6a — decide per consumer in the lane brief).
- 2b optional: shared view shows leg dates.

## Verification

Twin unit suites both sides; payload integration test; parity soak via daily
dogfooding; widget tests duplicated to pin fallback AND payload paths before
the repoint merges.
