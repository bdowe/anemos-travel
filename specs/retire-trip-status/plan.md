# Plan: Retire trip Draft/Planned status

Implemented in one lane (branch `retire-trip-status`, migration slot 00057 —
00056 was claimed by the concurrent price-alerts-removal lane).

## Schema & queries

- `migrations/00057_retire_trip_status.sql` — `ALTER TABLE trips DROP COLUMN
  status`; down re-adds `text NOT NULL DEFAULT 'draft'` (labels lost).
- `query/reengagement.sql`:
  - `ListTripsForReminder` — status predicates removed; "latest dated version
    of the lineage" is the only version filter. Params/row shape unchanged.
  - `ListUsersForWeeklyNudge` — the `EXISTS(status='draft')` arm replaced by
    the three-part derived predicate (undated lineage-latest trip / upcoming
    lineage-latest trip joined to an unbooked `booking_todos` row / resumable
    chat). New `today` date param, supplied by the checker from its
    injectable clock (`reengagement_checker.go` `runWeeklyNudge`).
- `query/trips.sql` (CreateTrip, ListLatestTripsByOwner, UpdateTrip) and
  `query/collaborators.sql` drop their status columns; `make api-sqlc` regen.

## API

- `trip_handler.go`: `TripResponse.Status`, `PatchTripRequest.Status`,
  `allowedStatuses`, and the PATCH validation removed. Unknown JSON keys are
  ignored by the decoder, so stale `{"status": ...}` PATCH bodies still 200 —
  pinned by `TestTripOwnerCRUD` (also asserts the response has no status key).
- `share_handler.go` copy path and `persistTrip` no longer write a status.
- `mcp_tools.go` `list_trips` and `plan_tools_extra.go` `get_trip` no longer
  render one.
- `trip_review.go` `checkLodging`: the dates guard is the only gate.

## Flutter

- `models/trip.dart` loses `status` (+ `trip.g.dart` regen); `patchTrip`
  loses the param; the header dropdown/pill, trips-list pill, home tile
  label, and `recent_trip_provider` snapshot field are removed; old persisted
  snapshots with a stray `status` key parse fine (extra keys ignored).
- `widgets/status_pill.dart` keeps only `StatusPill.custom` (same name, so
  its ~17 chrome call sites are untouched).
- l10n: `tripChangeStatus`, `tripStatusDraft`, `tripStatusPlanned`,
  `homeStatusDraft`, `homeStatusPlanned` removed from both arb files; l10n
  regenerated last.

## Tests

- Go: seed helpers drop status; reminder tests unchanged in spirit
  (`seedDepartingTrip`); three new weekly-nudge predicate tests (unbooked
  upcoming todo ⇒ nudged; booked ⇒ not; past-trip-only ⇒ not); lodging gate
  tests re-pinned to dated/undated semantics; stale-client PATCH compat pin.
- Flutter: fixture `status:` args removed (~84 sites); the pill localization
  group replaced by a `StatusPill.custom` smoke test.
