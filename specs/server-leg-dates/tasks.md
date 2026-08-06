# Tasks: Server-Computed City-Leg Dates

## Landed

- [x] 0a `extract-leg-ranges` — Dart cluster → `utils/leg_ranges.dart` (PR #297)
- [x] 0b `trip-render-legs` — Go module + twin tests + program specs (this PR)

## Wave 2 (three lanes, no hub file, no migrations)

| Lane | Branch | Contents | Depends on |
|---|---|---|---|
| 1a | `legs-payload` | `legs` on trip+shared responses; Dart `TripLeg` model + build_runner | 0b |
| 1b | `legs-go-consumers` | legsRenderSummary/get_trip/section results/print stay-matching → computeTripLegs; golden diff review | 0b |
| 1c | `legs-parity-logger` | kDebugMode payload-vs-local comparison → instrumentation events | 1a |

Gate into wave 3: ≥1 week dogfooding, zero parity-mismatch events.

## Wave 3 (2a is THE hub lane of its wave)

| Lane | Branch | Contents | Depends on |
|---|---|---|---|
| 2a | `legs-client-repoint` | consumers → `trip.legs ?? visibleLegRanges`; duplicated payload-path widget tests | 1a deployed + 1c soak |
| 2b | `shared-leg-dates` (optional) | shared view leg date chips | 1a |

Constraints: at most one in-flight lane touches `trip_detail_screen.dart`;
no `plan_tool_registry.go` definition-byte changes anywhere in this feature
(result strings only).
