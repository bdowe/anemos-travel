# Tasks: Trips Page Insights

> Dependency-ordered. `[P]` = can run in parallel with its siblings (no shared
> files / no ordering dependency). Work top to bottom; verification is last.

## API (Go)

- [x] Rewrite `ListLatestTripsByOwner` in `query/trips.sql` (extended `c`
      lateral with `city_pins`, extended `bt` with `next_transport_depart`,
      new `st`/`pk` laterals, `tb` LEFT JOIN + separate `ex` lateral,
      `summary` in both select lists) + rewrite the invariant comment
- [x] Amend the stale "same shape" comment on
      `ListLatestCollaboratedTripsForUser` in `query/collaborators.sql`
- [x] `make api-sqlc`; verify the regenerated row struct types
- [x] `trip_handler.go`: `CityPinResponse`, new `TripResponse` pointer
      fields, `listTripsHandler` wiring, updated enrichment doc comment
      (`listSharedWithMeHandler` untouched)
- [x] Extend `trip_list_enrichment_test.go` with the five verification cases

## Models & codegen (Flutter)

- [x] New `models/city_pin.dart`; nullable mirrors on `models/trip.dart`
- [x] `make flutter-build-models`
- [x] Contract Parity table in `plan.md` every row ✓

## Derivations & UI (Flutter)

- [x] `utils/trip_list_insights.dart` (`lifetimeStats`, `footprintPins`,
      `bookingNudgeDate`, `kBookingNudgeWindowDays`); delete
      `upcomingStats()` from `utils/trip_list_order.dart` + call site
- [x] [P] `widgets/stat_tile_row.dart`
- [x] [P] `widgets/travel_footprint_card.dart`
- [x] Hero enrichment (`up_next_trip_card.dart`): pills, summary, nudge row
- [x] `_TripCard` chips + summary line; past-row summary; remove the old
      upcoming stats line (`trips_list_screen.dart`)
- [x] L10n keys (en + es) + lane-worktree regen; delete
      `tripsListStatsUpcoming`

## Verification

- [x] `make api-fmt && make api-vet` clean; `go build ./...`
- [x] Go tests green (lane `TEST_DATABASE_URL`)
- [ ] `make flutter-analyze` clean; `make flutter-test` green
- [x] Browser smoke via the lane's dev stack: five surfaces, hide rules,
      no extra API bursts for the footprint map
