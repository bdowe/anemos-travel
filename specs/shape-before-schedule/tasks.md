# Tasks: Shape Before Schedule

One lane. `trip_detail_screen.dart` is a ≤1-lane-per-wave hub file and this
change claims it; `plan_handler.go`'s `basePrompt` is a single ~9 KB line, so no
other in-flight lane may edit it (a second editor conflicts unresolvably by
diff).

## Server

- [x] `plan_spine.go` — the three mechanical refusals, run before `persistTrip`
      and before the `done` SSE, reading the params `itemParamsFromLocation`
      already produces so validation and storage cannot drift.
- [x] `create_itinerary` — agreement gate in the tool description; `end_date`
      description says why deriving it is wrong for a spine.
- [x] `legsRenderSummary` — range + nights + date source per leg, with a warning
      above the list for a collapsed or guessed leg.
- [x] `openDaysSummary` (beside `walkDayCoverage`, reusing it) +
      `tripPostStateRender`; both writers echo it.
- [x] `checkLegShape` — `warn` finding; `ZeroNight`'s first consumer.
- [x] `update_itinerary_section` — refuse an empty `items` list; give the
      section-miss error its remediation.
- [x] `set_leg_dates` — the rendered range on the SUCCESS path, not only the
      no-op branch.
- [x] `basePrompt` — the two passes, the tool ban scoped to place research, the
      spine's arithmetic, the reconciled "fill the real days first" clause, the
      trip-bound refine suffix.
- [x] `plan_compactor.go` — preserve the agreed shape, its approval state, and
      which cities are still spine.
- [x] `trip_next_step.go` — per-city schedule seed when the gaps are one city's;
      shape-first empty-trip seed.

## Client

- [x] `CityGroup.emptyDays` + one planned-day set feeding it and `liveDayKeys`.
- [x] Empty-day placeholder rows, merged in day order.
- [x] City-header count line — a second row, never inside the aligned chip Row.
- [x] Zero-item "Refine with AI" opens the seeded chat; `_buildSectionSeed`
      stops lying on an empty trip; the empty state gets its action.
- [x] ARB keys (en + es); `tripAddPlacesBeforeRefine` deleted with its caller.

## Tests

- [x] Refusals, echo, open days, leg shape, prompt pins, compactor (Go).
- [x] Spine + one-city + arrival-anchors-only fixtures, mirrored Go ↔ Dart.
- [x] Shape-turn server contract, with an honest header on what a scripted fake
      cannot prove.
- [x] Empty-day rows, ordering, city line, city-scoped seed, empty-trip doors.
- [x] Mutation-checked: refusals, the journey-home exclusion, `emptyDays`, the
      empty-trip refine.

## Still open

- [ ] **The live run.** The acceptance criteria that depend on the MODEL
      choosing to withhold `create_itinerary` cannot be proven by a scripted
      fake — the last-day arc's first prompt draft passed review and then
      contradicted its own tool call. Run a real multi-city ask on the lane
      stack and check: no place searches on turn 1, chips present, nothing
      saved; then 2N − 1 places after approval, and leg dates matching the
      shape prose.
- [ ] Confirm on the real app that filler-only days rendering as placeholders
      reads right on an existing trip.
