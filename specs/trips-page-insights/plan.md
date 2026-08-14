# Plan: Trips Page Insights

> **HOW.** Translates `spec.md` into a file-level technical approach. See
> `../../CLAUDE.md` for repo conventions referenced below.

## Technical Approach

Everything rides the existing one-query list contract: the new facts are
laterals / correlated subqueries over indexed FKs inside
`ListLatestTripsByOwner` (`src/packages/api/query/trips.sql`), so the list
payload stays one query — no N+1, no per-trip fanout. The handler maps the
new row columns onto pointer fields of `TripResponse` (explicit zeros
survive `omitempty`; nil = full view / old server / shared row). The Flutter
side mirrors the fields nullable, computes the page-level aggregates in one
pure utility, and composes the five surfaces on the trips list screen. No
schema change, no migration number consumed.

Key decisions (approved; don't re-litigate):

- **Stays = confirmed only** (`auto = false AND NOT dismissed`, the
  `ListConfirmedAccommodationsByTrip` rule) — drafts churn with itinerary
  sync and would make the count flap.
- **Pins ride the existing `c` lateral** as a second jsonb aggregate over
  the same scan — one itinerary pass, and pins ⊆ cities alignment is
  structural, not coincidental (parallel arrays can't express "city without
  coords").
- **Pin coordinate = first non-(0,0) item by position** — mirrors
  `computeTripLegs` (`trip_render_legs.go`); `itinerary_items.latitude/
  longitude` are NOT NULL with (0,0) as the no-location sentinel.
- **`ex` (expenses) joins separately from `tb` (budget row)** so a trip with
  expenses but no budget row still reports spent; currency defaults to USD,
  matching `buildBudgetResponse`.
- **Shared-with-me untouched**: `ListLatestCollaboratedTripsForUser` and
  `listSharedWithMeHandler` gain nothing (v1 exclusion).

## Go API Changes

`src/packages/api/`:

- **`query/trips.sql`** — rewrite `ListLatestTripsByOwner`: extend the `c`
  lateral with a `city_pins` jsonb aggregate; extend `bt` with
  `next_transport_depart` (`min(depart_date)` over unbooked future
  transport); new `st` (confirmed stays) and `pk` (checklist) laterals; new
  `tb` LEFT JOIN (`trip_budgets`, trip_id UNIQUE) + separate `ex` lateral
  (expense sum); add `summary` to both select lists (inner DISTINCT ON and
  outer). COALESCE + cast per house style so sqlc emits non-pointer types
  where zero is meaningful. Rewrite the invariant comment (the "budget
  totals stay off" claim was stale) documenting the (0,0)-sentinel pin rule
  and the confirmed-stays filter.
- **`query/collaborators.sql`** — comment-only: the "same shape as
  ListLatestTripsByOwner" note on `ListLatestCollaboratedTripsForUser` is
  amended (the owner list now carries insight fields this query deliberately
  omits).
- **`store/`** — `make api-sqlc` regen. Expected row additions:
  `Summary *string`, `CityPins []byte` (jsonb), `NextTransportDepart
  pgtype.Date`, `StayTotal/StayBooked/PackingTotal/PackingDone int32`,
  `BudgetTarget *float64`, `BudgetSpent float64`, `BudgetCurrency string`.
  The two other consumers (`mcp_tools.go`, `plan_tools_extra.go`) access
  row fields by name — additive columns are invisible to them.
- **`trip_handler.go`** — `CityPinResponse{City, Lat, Lng}` beside
  `TripLegResponse`; new pointer fields on `TripResponse` (json tags in the
  parity table below); `listTripsHandler` maps the row (Summary into the
  `store.Trip` literal, explicit-zero pointers for the counts,
  `dateToPtr` for `NextTransportDepart`, `json.Unmarshal` of `CityPins` —
  the notifications-Payload jsonb precedent). The list-row enrichment doc
  comment on `TripResponse` is updated. `listSharedWithMeHandler` untouched.

## Flutter Changes

`src/packages/flutter-app/lib/`:

- **Models**: new `models/city_pin.dart` (`@JsonSerializable CityPin{city,
  lat, lng}`); `models/trip.dart` gains the nullable mirrors (below);
  `make flutter-build-models`. `TripCache` round-trips the new fields with
  zero changes.
- **Derivations**: new `utils/trip_list_insights.dart` (pure, payload-only):
  `lifetimeStats`, `footprintPins`, `bookingNudgeDate` +
  `kBookingNudgeWindowDays = 14`. `upcomingStats()` in
  `utils/trip_list_order.dart` is deleted (one-derivation rule).
- **UI** (`screens/trips_list_screen.dart` + new
  `widgets/travel_footprint_card.dart`, `widgets/stat_tile_row.dart`;
  enriched `widgets/up_next_trip_card.dart` and `_TripCard`): the five
  surfaces per spec.md, old stats line removed.
- **L10n**: new `tripsList*` keys in `app_en.arb`/`app_es.arb`;
  `tripsListStatsUpcoming` deleted; regen in the lane worktree.

## Contract Parity  ← anti-drift gate

| JSON key | Go type (`trip_handler.go`) | Go field | Dart type (`models/trip.dart`) | Dart field | Nullable? | ✓ |
|----------|------------------------------|----------|--------------------------------|------------|-----------|---|
| `summary` | `*string` | `TripResponse.Summary` | `String?` | `Trip.summary` | yes | ☑ |
| `stay_total` | `*int` | `TripResponse.StayTotal` | `int?` | `Trip.stayTotal` | yes | ☑ |
| `stay_booked` | `*int` | `TripResponse.StayBooked` | `int?` | `Trip.stayBooked` | yes | ☑ |
| `packing_total` | `*int` | `TripResponse.PackingTotal` | `int?` | `Trip.packingTotal` | yes | ☑ |
| `packing_done` | `*int` | `TripResponse.PackingDone` | `int?` | `Trip.packingDone` | yes | ☑ |
| `budget_target` | `*float64` | `TripResponse.BudgetTarget` | `double?` | `Trip.budgetTarget` | yes | ☑ |
| `budget_spent` | `*float64` | `TripResponse.BudgetSpent` | `double?` | `Trip.budgetSpent` | yes | ☑ |
| `budget_currency` | `*string` | `TripResponse.BudgetCurrency` | `String?` | `Trip.budgetCurrency` | yes | ☑ |
| `next_transport_depart` | `*string` (YYYY-MM-DD) | `TripResponse.NextTransportDepart` | `String?` | `Trip.nextTransportDepart` | yes | ☑ |
| `city_pins` | `[]CityPinResponse` | `TripResponse.CityPins` | `List<CityPin>?` | `Trip.cityPins` | yes | ☑ |
| `city_pins[].city` | `string` | `CityPinResponse.City` | `String` | `CityPin.city` | no | ☑ |
| `city_pins[].lat` | `float64` | `CityPinResponse.Lat` | `double` | `CityPin.lat` | no | ☑ |
| `city_pins[].lng` | `float64` | `CityPinResponse.Lng` | `double` | `CityPin.lng` | no | ☑ |

Rules: every new Go field is a pointer/`omitempty` → every Dart mirror is
nullable; absent = hide, never derive locally. Pin object fields are
non-null (a pin without coordinates is never emitted).

## Cross-cutting

- **Env vars:** none.
- **Migrations:** none (00058 stays burned/off-limits either way).
- **Gateway:** no new paths.

## Verification

**Go** (extend `trip_list_enrichment_test.go`; lane DB via
`TEST_DATABASE_URL`):

- Insight enrichment: confirmed-booked + confirmed-unbooked + auto-draft +
  dismissed stays ⇒ `stay_total=2, stay_booked=1`; 3 checklist / 1 checked ⇒
  `3/1`; budget 2000 EUR + expenses 150+50 ⇒ target 2000, spent 200, "EUR";
  summary present.
- Zeroes serialize: no budget row ⇒ `budget_target` absent, `budget_spent`
  explicit 0, "USD"; empty stays/checklist ⇒ explicit 0s.
- `next_transport_depart`: earliest unbooked **future transport** (ignores
  booked, stay-kind, past dates); absent when none qualify.
- City pins: located hubs only, first-appearance order, first non-(0,0)
  coord per hub, `day_trip_from` override respected; absent when no located
  items.
- Shared-with-me boundary: all new fields ABSENT for editor and viewer rows.

**Flutter**: unit tests for `trip_list_insights.dart` and `Trip.fromJson`
round-trips (old-server tolerance); widget tests for the footprint card,
stat tiles, hero pills/nudge, row chips + hide rules, past-row summary, and
the removed stats line; migrate `trip_list_order_test.dart`.

**Both**: `make api-fmt && make api-vet`, `go build ./...`, Go tests;
`make flutter-analyze` + `make flutter-test`; browser smoke via the lane's
dev stack (seeded upcoming + past trip; footprint renders from the list
payload alone — no extra API bursts).
