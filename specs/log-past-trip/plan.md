# Plan: Log a Past Trip

> **HOW.** Translates `spec.md` into a file-level technical approach. See
> `../../CLAUDE.md` for repo conventions referenced below.

## Technical Approach

A logged trip is an ordinary trip, so the entire feature is one new write path
plus one new screen. The server maps each destination onto the location map
`persistTrip` already consumes, with the destination's own name as the item's
`city`. That single choice is what makes the existing `c` lateral in
`query/trips.sql` emit `cities` and `city_pins` for a logged trip — which in
turn makes `utils/trip_list_insights.dart` light up the "Your travels" band with
**no change to any derivation**, no SQL change, no migration, and no new sqlc
query.

Key decisions (approved; don't re-litigate):

- **A real Trip, not a parallel visited-places store.** A second source of
  truth for "where have I been" would put a second derivation beside
  `trip_list_insights.dart` — the exact thing `docs/zen.md` exists to prevent.
  Reusing `persistTrip` also inherits the title fallback, lineage detection,
  the `maxTripsPerUser()` cap and the bulk item COPY for free.
- **Cities only.** No `country` column and no Countries tile. A country-level
  Places pick ("Japan") is just another destination. A real country count would
  need country data on every *existing* trip, which this feature can't create.
- **Dates are required.** `tripHasStarted` (`utils/trip_days.dart`) buckets on
  `start_date ?? end_date`, so an undated trip can never be "traveled". A
  dateless entry would land in the Planned half of the section it was added to
  fix. The form requires the range; the server requires it too, so a stale
  client can't write a half-trip.
- **The endpoint is general, the screen is "past".** `POST /trips` validates
  only `end >= start`; the *past* framing lives in the Flutter date picker's
  `lastDate`. Encoding a UI rule in the contract would make the first manual
  creation endpoint unusable for anything else later.
- **`chat_id` stays NULL.** `chat_id` means "this trip came from that
  conversation, and refinements append versions to it"; a logged trip has no
  conversation. `persistTrip` treats a chat-less save as a new lineage, and
  `refineTripHandler` already assigns a chat id lazily to legacy trips, so
  nothing is foreclosed. (Import mints `chat-<token>` because it *wants*
  refine-in-chat to bind immediately.)
- **No `day` on the items.** A logged trip records where, not a day-by-day
  plan; synthesizing day numbers would be fabricated data. Because both dates
  are always sent, `persistTrip`'s `maxDay`-based end-date derivation never
  runs.

## Go API Changes

`src/packages/api/`:

- **`validation.go`** — new `maxLoggedDestinations = 50` beside the existing
  per-trip volume caps. A form-entered trip realistically has a handful;
  `importMaxLocations` (80) is the comparable AI-path bound.
- **`trip_handler.go`** — `CreateTripRequest` / `CreateTripDestination` beside
  `PatchTripRequest`, and `createTripHandler`. House order: decode → validate
  (`boundedString`, `boundedOptional`, `validateCoords`, `parseDateParam`,
  `end >= start`) → build `[]map[string]any` → `persistTrip` → read back with
  `GetTripByIDAndOwner` + `GetItineraryItemsByTrip` → `writeJSON(201,
  toTripResponse(...))`. `persistTrip`'s "trip limit reached" error is mapped
  to **422** with the message passed through, the `trip_import_handler.go`
  precedent. Analytics mirror `mcp_tools.go`: `recordEvent(..., "trip_created",
  ..., {"item_count", "source": "manual"})` and, on `newLineage`,
  `recordActiveTripsCapSignal` — both inside `safeGo`.
- **`main.go`** — one route beside the existing GET:
  `api.Handle("/trips", authMiddleware(http.HandlerFunc(createTripHandler))).Methods("POST")`.
  Plain `authMiddleware`, not `importTier`: no model call, no third-party call,
  one transaction — the same cost profile as `addItineraryItemHandler`.
- **`store/`** — untouched. No new query, so **no `make api-sqlc`**.
- **Migrations** — none. 00064 stays free.

The destination → location mapping (the load-bearing part):

```go
loc := map[string]any{"name": d.Name, "city": d.Name}
if d.Latitude != nil && d.Longitude != nil {
    loc["latitude"], loc["longitude"] = *d.Latitude, *d.Longitude
}
```

`city = name` because the form asks "Where did you go?" — the thing the
traveler picked *is* the hub. Omitting the coordinates leaves
`itemParamsFromLocation` at the `(0,0)` no-location sentinel, so a name-only
destination appears in `cities` and is filtered out of `city_pins`: a city that
counts and draws no dot, never a pin in the Atlantic.

## Flutter Changes

`src/packages/flutter-app/lib/`:

- **Models** — none. The request is built inline (the `addItineraryItem`
  precedent) and the response is the existing `Trip`. **No
  `make flutter-build-models`.**
- **`services/trips_api_service.dart`** — `createTrip({destinations, startDate,
  endDate, title})` → `Trip`, throwing `CreateTripException(statusCode,
  message)` so the 422 cap message can be shown verbatim (the
  `ImportTripException` precedent).
- **`providers/log_trip_provider.dart`** — `LogTripNotifier` /
  `LogTripState{saving, error}`, `StateNotifierProvider.autoDispose`, modelled
  on `import_trip_provider.dart`; reloads `tripsProvider` before returning so
  the list is warm on the way back.
- **`screens/log_trip_screen.dart`** — the form. Destination picker reuses
  `add_itinerary_item_dialog.dart`'s 350 ms debounce over
  `placeSearchProvider`; picks become removable `InputChip`s; "add by name"
  fallback marks the chip as having no map location.
  `showDateRangePicker(firstDate: year-60, lastDate: today)`.
  On success `pushReplacement` to `TripDetailScreen` (the import precedent).
  Uses `/places/search` (Text Search), **not** `/places/autocomplete` —
  autocomplete returns `place_id`/`description`/`types` only, so every pick
  would cost a second `/places/details` round trip for coordinates.
- **Navigation** — `BootUtility.logTrip` in `navigation/app_routes.dart`
  (`/log-trip`, restored onto `AppTab.trips`), `openLogTripOnTripsTab` in
  `navigation/app_nav.dart`, and the `url_sync.dart` switch arm. Exactly the
  `importTrip` shape.
- **`screens/trips_list_screen.dart`** — three entry points: the "Your travels"
  `SectionHeader`'s `action`, a second app-bar `IconButton`, and a third
  empty-state button. Three because "Your travels" is gated at 2+ owned trips,
  so an action placed only there is invisible to accounts with 0 or 1 trip —
  precisely the ones most likely to want it.
- **L10n** — new `logTrip*` keys in `app_en.arb` **and** `app_es.arb`; reuse
  `itemDialogNoResults`, `itemDialogSearchUnavailable`, `commonCancel`,
  `errorGeneric` rather than duplicating strings.

## Contract Parity  ← anti-drift gate

| JSON key | Go type (`trip_handler.go`) | Go field | Dart type | Dart site | Nullable? | ✓ |
|---|---|---|---|---|---|---|
| `title` | `*string` | `CreateTripRequest.Title` | `String?` | `createTrip(title:)` | yes | ☑ |
| `start_date` | `string` | `CreateTripRequest.StartDate` | `String` | `createTrip(startDate:)` | no | ☑ |
| `end_date` | `string` | `CreateTripRequest.EndDate` | `String` | `createTrip(endDate:)` | no | ☑ |
| `destinations` | `[]CreateTripDestination` | `CreateTripRequest.Destinations` | `List<Map<String, dynamic>>` | `createTrip(destinations:)` | no | ☑ |
| `destinations[].name` | `string` | `.Name` | `String` | `LogTripDestination.name` | no | ☑ |
| `destinations[].place_id` | `*string` | `.PlaceID` | `String?` | `LogTripDestination.placeId` | yes | ☑ |
| `destinations[].address` | `*string` | `.Address` | `String?` | `LogTripDestination.address` | yes | ☑ |
| `destinations[].latitude` | `*float64` | `.Latitude` | `double?` | `LogTripDestination.lat` | yes | ☑ |
| `destinations[].longitude` | `*float64` | `.Longitude` | `double?` | `LogTripDestination.lng` | yes | ☑ |
| *response* | `TripResponse` (existing) | — | `Trip` (existing) | — | — | ☑ |

Coordinates are pointers on both sides so "not provided" stays distinguishable
from `0` — the `Location.Latitude` rule in CLAUDE.md, and the reason a name-only
destination can be stored honestly rather than pinned at (0,0) on the map.

## Cross-cutting

- **Env vars:** none.
- **Migrations:** none (00064 stays free).
- **Gateway:** no new paths — `POST /api/v1/trips` rides the existing proxy.

## Verification

**Go** (`trip_create_integration_test.go`, lane DB via `TEST_DATABASE_URL`):

- Happy path: two located destinations + dates ⇒ `201`, two items in order, and
  the `GET /trips` row carries both cities and both pins.
- Name-only destination ⇒ present in `cities`, absent from `city_pins`.
- Validation 400s: no destinations, over-cap count, blank name, over-long name,
  out-of-range coordinates, missing/malformed dates, `end < start`.
- `MAX_TRIPS_PER_USER=1` at cap ⇒ `422` carrying the cap message.
- Unauthenticated ⇒ `401`.
- `trip_created` analytics event recorded.

**Flutter**: `log_trip_provider_test.dart` (success reloads trips; failure sets
error), `log_trip_screen_test.dart` (pick adds a chip, remove works, save gated
on destination + dates, correct body), `trips_list_log_trip_entry_test.dart`
(all three entry points, found by `ValueKey` so they hold in Spanish), and one
added case in `trip_list_insights_test.dart` pinning that a logged past trip
lands in `traveled` with `visited: true` pins.

**Both**: `make api-fmt && make api-vet`, `go build ./...`, Go tests;
`make flutter-analyze` + `make flutter-test`; browser smoke on the lane's dev
stack walking every acceptance criterion.
