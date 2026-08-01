# Tasks: Find free/cheap parking near beaches

> Dependency-ordered. `[P]` = can run in parallel with its siblings (no shared
> files / no ordering dependency). Work top to bottom; verification is last.

## API (Go)

- [x] `places_service.go`: add `SearchParkingNearby` (location + radius=2000 +
      type=parking, `parking|`-prefixed cache key)
- [x] `parking_service.go` (new): heuristics (`looksFreeParking`,
      `isParkingResult`, `rankParkingResults`), `parkingResult`,
      `haversineMeters`, `findParkingNearBeach`
- [x] `plan_tool_registry.go`: `findParkingTool` def, `runFindParkingTool`
      dispatcher, `placeCard.FreeListed` (omitempty), `parkingCards` with
      `allowPhotoRef`; registry entry **tail-appended** after `searchNearbyTool`
- [x] `plan_handler.go`: car+beach trigger sentence in `basePrompt`
- [x] Tests: append `find_parking` to all three want-slices in
      `plan_tool_registry_test.go`; new `parking_service_test.go` (pure);
      new `plan_parking_test.go` (fake-Anthropic; coords-given / geocode /
      missing-name cases)

## Models & codegen (Flutter)

- [x] `agent_place.dart`: `freeListed` (`free_listed`, defaultValue false)
- [x] `make flutter-build-models` to regenerate `.g.dart`
- [x] Complete the Contract Parity table in `plan.md` (every row ✓)

## UI (Flutter)

- [x] [P] `plan_provider.dart`: `parkingSpots`/`parkingBeach` state +
      `case 'parking':` (no itinerary-turn guard — commented)
- [x] [P] `app_colors.dart`: `toolParking`
- [x] `place_photo_card.dart`: `PlaceCardData.parking` factory
- [x] `chat_panel.dart`: fourth `_ResultStrips` rail + `find_parking` label in
      `_ActiveToolChips`
- [x] l10n: `chatStripParking` / `chatToolFindParking` / `chatCardFreeListed`
      in `app_en.arb` + `app_es.arb`; regen committed localizations
- [x] `test/chat_panel_parking_strip_test.dart` (rail label, free marker, maps
      launch, anonymous hides Add-to-trip)

## Verification

- [x] `make api-fmt && make api-vet` clean
- [x] `make api-test` passes (registry order, prompt, parking unit +
      integration tests)
- [x] `make flutter-analyze` clean; `l10n_untranslated.json` empty
- [x] `make flutter-test` passes
- [x] Manual end-to-end on this lane's stack (`make docker-dev-bg` →
      `http://localhost:3001`): every acceptance criterion in `spec.md`
      checked off (EN + ES, negative flights-only check)
