# Tasks: Import a trip from an external AI chat

## API (Go)

- [x] `trip_import_service.go`: constants, structs, `truncateForImport`,
      `extractImportedTrip`, `plausibleCoords`, `resolveImportedLocations`,
      `importTripCore`
- [x] `trip_import_handler.go`: `importTripHandler`
- [x] `main.go`: route `POST /trips/import` (strict + auth)
- [x] `middleware.go`: 2 MiB body lane for `/api/v1/trips/import`
- [x] `i18n.go`: `import.*` catalog keys (en+es)
- [x] [P] `trip_import_test.go`: truncation + coordinate unit tests
- [x] [P] `trip_import_integration_test.go`: full matrix (see plan.md)
- [x] `make api-fmt && make api-vet && make api-test` green

## Models & codegen (Flutter)

- [x] `lib/models/import_trip_result.dart` (plain model, no codegen)

## UI (Flutter)

- [x] `trips_api_service.dart`: `importTrip`
- [x] `lib/providers/import_trip_provider.dart`
- [x] `lib/screens/import_trip_screen.dart` (copy-prompt, paste, progress,
      warnings, error/retry)
- [x] Entry points: trips-list app bar action + empty-state action
- [x] Entry points v2: Agent empty-state button + Home new-user hero line,
      all via the shared `openImportOnTripsTab` helper (app_nav.dart)
- [x] ARB strings en+es (incl. planning prompt) + regenerate l10n
- [x] `flutter analyze` green

## Verification

- [ ] Manual e2e on docker-dev with real keys (see plan.md)
- [ ] Check `trip_imported` analytics rows land
