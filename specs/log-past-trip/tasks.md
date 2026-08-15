# Tasks: Log a Past Trip

> Dependency-ordered. `[P]` = can run in parallel with its siblings (no shared
> files / no ordering dependency). Work top to bottom; verification is last.
>
> Single-lane feature: branch `log-past-trip`, no migration, no sqlc regen, no
> `.g.dart` regen, no `plan_tool_registry.go` append, `trip_detail_screen.dart`
> untouched.

## API (Go)

- [x] `maxLoggedDestinations = 50` in `validation.go`
- [x] `CreateTripRequest` / `CreateTripDestination` in `trip_handler.go`
- [x] `createTripHandler` — validate → map destinations onto `persistTrip` →
      read back → `201` full `TripResponse`; "trip limit reached" ⇒ 422
- [x] `trip_created` analytics (`"source": "manual"`) +
      `recordActiveTripsCapSignal` on `newLineage`, both in `safeGo`
- [x] Register `POST /trips` in `main.go` beside the existing GET
- [x] No new env var, no migration, no `make api-sqlc`

## Models & codegen (Flutter)

- [x] No new `@JsonSerializable` model — the response is the existing `Trip`
      and the request is built inline (so no `make flutter-build-models`)
- [x] Contract Parity table in `plan.md` complete (every row ✓)

## UI (Flutter)

- [x] [P] `TripsApiService.createTrip` + `CreateTripException` in
      `services/trips_api_service.dart`
- [x] [P] `providers/log_trip_provider.dart` (`LogTripNotifier`,
      `LogTripState{saving, error}`, reloads `tripsProvider` on success)
- [x] `screens/log_trip_screen.dart` — debounced `placeSearchProvider` picker,
      removable chips, name-only fallback with the no-pin note, required date
      range (`year-60` → today), optional title
- [x] Navigation: `BootUtility.logTrip` in `navigation/app_routes.dart`,
      `openLogTripOnTripsTab` in `navigation/app_nav.dart`, the
      `navigation/url_sync.dart` switch arm
- [x] Entry points in `screens/trips_list_screen.dart`: "Your travels" section
      header action, app-bar `IconButton`, empty-state button
- [x] `logTrip*` keys in `l10n/app_en.arb` **and** `l10n/app_es.arb`
- [x] Loading / disabled / error states per `spec.md`

## Tests

- [x] `api/trip_create_integration_test.go` — happy path (cities + pins),
      name-only destination (city, no pin), the validation 400s, 422 at cap,
      401, `trip_created` event
- [x] [P] `test/log_trip_provider_test.dart`
- [x] [P] `test/log_trip_screen_test.dart`
- [x] [P] `test/trips_list_log_trip_entry_test.dart` (ValueKey finders)
- [x] One case in `test/trip_list_insights_test.dart`: a logged past trip lands
      in `traveled` with `visited: true` pins

## Verification

- [x] `make api-fmt && make api-vet` clean
- [x] `go build ./...` + `go test ./...` (lane `TEST_DATABASE_URL`)
- [x] `make flutter-analyze` clean
- [x] `make flutter-test` passes
- [x] `flutter build web` (the PR-only CI gate) succeeds
- [x] API end-to-end through the lane gateway: `POST /api/v1/trips` returns
      201 with the items in order, the name-only destination stored at the
      (0,0) sentinel, and `GET /trips` carrying 3 `cities` / 2 `city_pins`
- [ ] Visual browser walkthrough of the screen and the three entry points —
      NOT RUN (the Chrome extension was not connected in this session). Every
      other criterion is covered by the widget tests plus the API pass above;
      this one only re-checks rendering.
