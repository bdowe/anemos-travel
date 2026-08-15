# Tasks: Hotel Search

> Dependency-ordered. `[P]` = parallel-safe. Verification last.
> One lane (`hotel-search`) — it appends to `plan_tool_registry.go`, so no
> other in-flight lane may.

## Go — service & providers
- [ ] `hotel_search_service.go`: `HotelStay` / request / result types,
      `SerpapiHotelsService`, `searchHotels` tier seam, quota + cache
- [ ] `places_service.go`: `SearchLodging` (`type=lodging`, `lodging|` cache prefix)
- [ ] `hotel_handler.go`: `hotelsSearchHandler` (city required; dates paired)
- [ ] `main.go`: register `GET /hotels/search` + startup log

## Go — agent
- [ ] `plan_tool_registry.go`: `searchHotelsTool` + dispatcher, **tail-appended**
- [ ] `plan_handler.go`: `summarizeHotels` (states which tier answered)

## Go — tests
- [ ] `hotel_search_service_test.go`: mapping, currency stamping, `ads[]`
      excluded, cache hit burns no quota, empty NOT cached, outage not cached
- [ ] key never in errors — both the build and `Do` paths
- [ ] dateless input never calls the rates provider
- [ ] quota exhaustion degrades and leaves `search_flights` untouched
- [ ] `summarizeHotels` pins the "prices NOT checked" sentence
- [ ] registry: `search_hotels` last, `suggest_stays` bytes unchanged

## Flutter
- [ ] [P] `models/hotel_stay.dart` + `make flutter-build-models`
- [ ] [P] `theme/app_colors.dart`: `toolAirbnb` → `toolStays` (+ `trip_map.dart`)
- [ ] `providers/plan_provider.dart`: state fields + `case 'hotels'`
- [ ] `widgets/place_photo_card.dart`: `PlaceCardData.hotel` + `priceLabel`
- [ ] `widgets/chat_panel.dart`: hotels strip, `_toolLabel`, **`stays`/`transport` chips**
- [ ] `l10n/app_en.arb` + `app_es.arb`; regenerate localizations LAST

## Docs
- [ ] `.env.sample` + `CLAUDE.md`: new env vars; note the shared-key/separate-feature distinction
- [ ] `docs/friction-log.md`: close the dropped-`stays`-event OPEN item

## Verify
- [ ] `make api-fmt`, `make api-vet`, `go test ./... -race`
- [ ] `make flutter-analyze`, `make flutter-test`
- [ ] E2E on `http://localhost:3004`: rates / dateless / quota-0 degrade
