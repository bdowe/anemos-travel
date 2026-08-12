# Tasks: Retire trip Draft/Planned status

> Executed in one pass on lane `retire-trip-status` (all done; recorded for
> the paper trail).

## Schema & queries

- [x] Migration 00057: `ALTER TABLE trips DROP COLUMN status` (+ down)
- [x] `ListTripsForReminder` — drop status predicates (latest *dated* version)
- [x] `ListUsersForWeeklyNudge` — derived unfinished-work predicate + `today`
- [x] Drop status from CreateTrip / ListLatestTripsByOwner / UpdateTrip /
      ListLatestCollaboratedTripsForUser; `make api-sqlc`

## API (Go)

- [x] trip_handler: response/patch types, validation, persistTrip, mappings
- [x] share_handler copy path, collaborator_handler, mcp_tools, plan get_trip
- [x] trip_review lodging gate → dates-only
- [x] reengagement_checker: `Today` param + doc comments

## Flutter

- [x] Trip model + `.g.dart` regen; patchTrip param
- [x] Header dropdown/pill, trips-list pill, home tile, recent-trip snapshot
- [x] StatusPill → custom-only
- [x] l10n: 5 keys out of both arbs, gen-l10n last

## Tests

- [x] Go seeds/gate tests; stale-client PATCH compat pin; 3 new nudge tests
- [x] Flutter fixture sweep (84 sites) + StatusPill smoke test

## Verification

- [x] `go vet` + full Go suite green
- [x] `flutter analyze` + full Flutter suite green
- [x] Manual e2e on the lane stack (header, PATCH compat, review finding,
      reengagement queries against dev DB)
