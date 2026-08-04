# Tasks: Shift Trip Dates from Chat (`set_trip_dates`)

> Dependency-ordered. Single-agent feature (one lane).

## API (Go)

- [ ] `SetTripDates` in `query/trips.sql`; `Shift*Dates :execrows` in
      `query/accommodations.sql`, `query/segments.sql`,
      `query/booking_todos.sql`; `make api-sqlc`
- [ ] `plan_trip_dates.go`: tool def + `computeTripDateShift` +
      `runSetTripDatesTool` (resolution ladder, tx cascade, SSE, analytics)
- [ ] Registry tail append (`plan_tool_registry.go`, gate `authedOnly`)
- [ ] Prompt updates in `plan_handler.go` (bound suffix, base prompt,
      anti-fabrication, suggest_replies exclusion)
- [ ] `formatReviewFindings` hint for `fix=set_dates` (`plan_tools_extra.go`)

## Tests

- [ ] `plan_trip_dates_test.go`: unit table + DB cascade + no-anchor +
      validation + fresh-chat same-turn + lineage next-turn + collaborator
- [ ] Update the five registry tail pins (authed slices gain
      `set_trip_dates`; anonymous pins intentionally unchanged)

## Verification

- [ ] `make api-sqlc && make api-fmt && make api-vet` clean
- [ ] Full Go test run with the lane `TEST_DATABASE_URL`
- [ ] Manual e2e on the lane stack: refine shift, dateless set,
      fresh-chat next-turn shift (spec.md acceptance criteria)
- [ ] `ship pr` — stop at PR-open (integrator merges)
