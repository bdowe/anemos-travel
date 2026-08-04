# Tasks: Change One Leg's Dates from Chat (`set_leg_dates`)

> Dependency-ordered. Single-agent feature (one lane).

## API (Go)

- [ ] `plan_leg_dates.go`: tool def + `legRuns` + `computeLegDateChange` +
      `runSetLegDatesTool` (tx, endpoint-anchored deltas, clamps,
      auto-draft skip, gap narration, SSE, analytics)
- [ ] Registry tail append (`plan_tool_registry.go`, gate `authedOnly`)
- [ ] Prompt updates in `plan_handler.go` (base + refine suffix routing,
      relay-the-gap, suggest_replies exclusion)
- [ ] `plan_trip_dates.go` delta-0 result steer (result string only)

## Tests

- [ ] `plan_leg_dates_test.go`: unit tables + guards + headline dogfood DB
      test + shrink clamp + collaborator + validation-untouched +
      two-request lineage
- [ ] Update the five registry tail pins (authed slices gain
      `set_leg_dates`; anonymous pins intentionally unchanged)

## Verification

- [ ] `make api-fmt && make api-vet` clean; no `store/`/`migrations/` diffs
- [ ] Full Go test run (`-race`) with the lane `TEST_DATABASE_URL`
- [ ] Manual e2e on the lane stack (:3004): dogfood scenario end to end,
      gap surfaced, whole-trip shift still routes to `set_trip_dates`
- [ ] Friction-log entry for the incident
- [ ] `ship pr` — stop at PR-open (integrator merges)
