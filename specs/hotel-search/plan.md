# Plan: Hotel Search

> **HOW.** See `../../CLAUDE.md` for repo conventions. Ancestor:
> `specs/accommodation-search` (2026-05) shipped the links-only handoff and
> left the `AccommodationProvider` seam open "for a future listing-returning
> provider" — this fills it.

## Key decisions and why

- **Two tiers behind one tool, not two tools.** SerpApi Google Hotels answers
  "what and how much"; Google Places `type=lodging` answers "which are good".
  They are one question to a traveler, so they are one tool — and the second
  is the degrade path for the first. Verified: the rates provider **requires**
  `check_in_date` (a dateless call errors), and Places returns `price_level:
  null` on every hotel, so neither tier can do the other's job. The split is
  the shape of the data, not a preference.
- **`HotelStay` is one type both tiers produce.** If the dispatcher,
  summarizer or SSE payload had to branch on provider, there would be two
  definitions of "a stay" (zen: one obvious way). The tier shows up as one
  flag on the *result set*, never as a shape difference.
- **`RatesLive` is explicit, not inferred from "is Price non-nil".** A caller
  that infers it would silently mislabel a rates-tier result whose price
  happened to be missing. The tool result and the cards both read this flag.
- **Price and currency are a both-or-neither pair**, matching
  `booking_options` (00065) and 00061: no FX exists in this app, so a bare
  number is worse than no number.
- **Separate daily counter from flights.** `search_flights` is on the same
  SerpApi key and the same 250/month free tier. A shared counter would let a
  hotel-heavy session take flight search down with it.
- **Distinct naming from the temporary flights swap.** The flights seam is
  scheduled for deletion by `grep serpapiFlights`; this feature is permanent.
  It must not share that prefix or its `Active()` gate.
- **Registry append-only.** `suggest_stays` stays byte-identical — the tools
  array is the prompt-cache prefix.

## Go API Changes

`src/packages/api/`:

- **`hotel_search_service.go`** (new) — `HotelStay` + `HotelSearchRequest` /
  `HotelSearchResult` types; `SerpapiHotelsService` singleton
  (`newUpstreamClient`, `newTTLCache`, `newDailyCounter`,
  `upstreamCallCounters`); `Configured()` as a **call-time** env read;
  `searchHotels` as the tier-picking seam. `redactTransportError` on both the
  request-build and `Do` paths (the key rides in the query string). Excludes
  `ads[]`. Empty results are **not** cached — see the divergence note in the
  file header.
- **`places_service.go`** — `SearchLodging`, a `SearchParkingNearby`-shaped
  variant: `type=lodging` through the existing `extraParams` hook, own
  `lodging|` cache-key prefix.
- **`hotel_handler.go`** (new) — `hotelsSearchHandler`; validates city and the
  paired dates.
- **`plan_tool_registry.go`** — `searchHotelsTool` + `runSearchHotelsTool`,
  **appended at the tail**.
- **`plan_handler.go`** — `summarizeHotels`, beside `summarizeOffers` /
  `summarizeEvents`.
- **`main.go`** — `GET /hotels/search` + startup log line.
- **`.env.sample` / `CLAUDE.md`** — `SERPAPI_HOTEL_SEARCHES_PER_DAY`,
  `HOTEL_RATES_CURRENCY`, and a note that this shares `SERPAPI_API_KEY` with
  the temporary flights swap but is **not part of it**.

## Flutter Changes

- `models/hotel_stay.dart` (+ `make flutter-build-models`).
- `providers/plan_provider.dart` — `hotels` / `hotelsCity` /
  `hotelsRatesLive` on `PlanState`; `case 'hotels':`; whole-list replace.
- `widgets/place_photo_card.dart` — `PlaceCardData.hotel(...)` factory + one
  nullable `priceLabel`; card geometry unchanged.
- `widgets/chat_panel.dart` — fifth strip; `_toolLabel` case; **plus** the
  missing `stays` / `transport` chips (`docs/friction-log.md:533`).
- `theme/app_colors.dart` — `toolAirbnb` → `toolStays` (one call site).
- `l10n/app_en.arb` + `app_es.arb`; regenerate localizations **last**.

## Contract Parity

| JSON key | Go | Dart | Nullable |
|---|---|---|---|
| `name` | `string` | `String` | no |
| `kind` | `string` | `String` | no |
| `star_class` | `*int` | `int?` | yes |
| `rating` | `*float64` | `double?` | yes |
| `reviews` | `*int` | `int?` | yes |
| `rate_per_night` | `*float64` | `double?` | yes |
| `total_rate` | `*float64` | `double?` | yes |
| `currency` | `*string` | `String?` | yes (paired with rates) |
| `latitude` / `longitude` | `*float64` | `double?` | yes |
| `address` | `string` | `String` | no (may be empty) |
| `image_url` | `string` | `String` | no (may be empty) |
| `booking_url` | `string` | `String` | no |
| `amenities` | `[]string` | `List<String>` | no (may be empty) |
| `check_in_time` / `check_out_time` | `string` | `String` | no (may be empty) |
| `rates_live` *(result-level)* | `bool` | `bool` | no |
| `rates_note` *(result-level)* | `string` | `String` | no (may be empty) |

## Verification

- `make api-fmt && make api-vet`; `go test ./... -race`.
- `make flutter-build-models && make flutter-analyze && make flutter-test`.
- E2E through this lane's gateway (`http://localhost:3004`): rates path,
  dateless path, `SERPAPI_HOTEL_SEARCHES_PER_DAY=0` degrade path with
  `search_flights` still working.
