# Tasks: Import a trip from an external AI chat

## API (Go)

- [ ] `trip_import_service.go`: constants, structs, `truncateForImport`,
      `extractImportedTrip`, `plausibleCoords`, `resolveImportedLocations`,
      `importTripCore`
- [ ] `trip_import_handler.go`: `importTripHandler`
- [ ] `main.go`: route `POST /trips/import` (strict + auth)
- [ ] `middleware.go`: 2 MiB body lane for `/api/v1/trips/import`
- [ ] `i18n.go`: `import.*` catalog keys (en+es)
- [ ] [P] `trip_import_test.go`: truncation + coordinate unit tests
- [ ] [P] `trip_import_integration_test.go`: full matrix (see plan.md)
- [ ] `make api-fmt && make api-vet && make api-test` green

## Models & codegen (Flutter)

- [ ] `lib/models/import_trip_result.dart` + `make flutter-build-models`

## UI (Flutter)

- [ ] `trips_api_service.dart`: `importTrip`
- [ ] `lib/providers/import_trip_provider.dart`
- [ ] `lib/screens/import_trip_screen.dart` (copy-prompt, paste, progress,
      warnings, error/retry)
- [ ] Entry points: trips-list app bar action + empty-state action
- [ ] ARB strings en+es (incl. planning prompt) + regenerate l10n
- [ ] `flutter analyze` green

## Verification

- [ ] Manual e2e on docker-dev with real keys (see plan.md)
- [ ] Check `trip_imported` analytics rows land
