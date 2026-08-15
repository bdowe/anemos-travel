# Plan: Bag-aware flight pricing

## Technical Approach

Three changes that only work together: **store** the tier, **resolve** it in one
place, **send** it to the provider — and state the result everywhere the number
is read.

The guiding constraint is `docs/zen.md`: the bag tier is never implicit. It is
resolved by one function, carried explicitly on the request, echoed in the
response, and labelled in the tool result the model paraphrases (the
`specs/flights-transport` / PR #355 lesson — the chat UI renders no prices, so
the planner's prose is the traveler's only record of what a quote covers).

Key decisions and why:

- **Default becomes `carry_on`, not `personal_item`.** The old default
  short-circuited all bag pricing (`flight_baggage.go`), which is exactly how a
  bare fare got presented as "cheapest". A traveler who really flies with one
  small bag says so and gets the bare fares back.
- **Resolution lives at the two callers with identity, over one helper.**
  `POST /flights/search` is unauthenticated (`main.go`), so the server cannot
  read preferences there; the planner's dispatcher and the Flutter screen both
  resolve and then send an explicit tier. `resolveBaggageTier` is the single
  implementation of the fallback chain.
- **SerpApi's `bags` parameter does the pricing.** Google Flights folds the
  carry-on fee into the quoted price for the number of cabin bags requested, on
  international routes, at no extra quota cost (same one search). This is the
  only mechanism that makes a `carry_on` search mean anything while the swap is
  active — `fetchBagFees` is skipped for SerpApi's synthetic offer ids.
- **Checked bags are priced as far as the provider can and no further.** SerpApi
  exposes only carry-on counts, and Google folds checked fees in on US domestic
  routes only. So a checked search gets cabin-bag-inclusive prices plus an
  explicit "checked fee not included" note. No invented estimate.
- **`baggage_status` gains `in_price`** — the quote already covers the bag,
  amount not itemized — because that is a genuinely different state from
  free-in-fare (`included`) and fare-plus-known-fee (`paid`), and it renders
  differently. It carries a real `effective_price`, so it ranks as a priced
  offer instead of sinking like `unknown`.
- **Tier-level caveats go in the header, not per offer.** They are identical for
  every offer in a search, so they belong stated once — in `summarizeOffers`'
  header for the model and in one `baggage_note` code for the client.

## Go API Changes

`src/packages/api/`:

- **Migration:** `migrations/00066_traveler_baggage.sql` — `ALTER TABLE
  traveler_preferences ADD COLUMN baggage text`. Vocabulary in a trailing
  comment and enforced in Go, like every other enum column on this table.
  (00058 is burned — see `docs/parallel-dev.md`.)
- **Queries:** `query/preferences.sql` — `sqlc.narg`/`COALESCE` pair, then
  `make api-sqlc`. Never hand-edit `store/`.
- **Types & constants** (`duffel_service.go`): `defaultBaggageTier`,
  `baggageStatusInPrice`, `resolveBaggageTier(requested, saved)`;
  `normalizeBaggage("")` returns the default.
- **Handlers:** `preferences_handler.go` (field + shared `normalizeChoice`
  against the existing `allowedBaggageTiers`); `main.go`
  (`FlightSearchResponse.baggage_note`, echo of the resolved tier).
- **Planner:** `plan_tool_registry.go` — `savePrefsTool` gains the field;
  `search_flights`'s `baggage` description states the omitted-means-saved rule;
  `runSearchFlightsTool` resolves through `resolveBaggageTier` (also fixing an
  unvalidated pass-through); `planSession` gains the saved tier, populated in
  `plan_handler.go` where preferences are already loaded.
- **Prompting:** `plan_handler.go` (`personalizedSystemPrompt`,
  `summarizeOffers` header), `plan_compactor.go` preserve list,
  `profile_distiller.go` (so a bag habit learned in chat persists).
- **Provider:** `serpapi_flights_service.go` — extract the passenger maths,
  add `serpapiCarryOnBags`, send `bags`, **add it to the offers cache key**
  (the provider now varies by tier; without this a bare-fare probe would serve a
  bag-inclusive search for the whole TTL), and set `in_price` on mapped offers.
- **Classification:** `flight_baggage.go` — a provider that prices bags into its
  quote is the authority; the classification loop leaves those offers alone.

No new env vars, no new routes.

## Flutter Changes

`src/packages/flutter-app/lib/`:

- **Models:** `models/traveler_preferences.dart` (+ `make flutter-build-models`).
- **Service/provider:** `services/preferences_api_service.dart`,
  `providers/preferences_provider.dart` — one field each.
- **Shared options:** `constants/travel_profile_options.dart` gains the tier
  list + label mapper, and `screens/flight_search_screen.dart`'s private copies
  are deleted in favour of it: three surfaces, one list.
- **Screens:** `preferences_screen.dart` and `onboarding_quiz_screen.dart` gain
  the row/step; `flight_search_screen.dart` seeds the chip from preferences
  (on both seed paths, before its auto-search), always sends the tier, names it
  in the collapsed summary, and renders the checked-bag note.
- **Widgets:** `flight_offer_card.dart` and `flight_details_sheet.dart` gain the
  `in_price` case.
- **l10n:** new keys in `app_en.arb` + `app_es.arb`; `make flutter-gen-l10n`
  **last**.

## Contract Parity

| JSON key | Go type | Dart type | Nullable? | ✓ |
|----------|---------|-----------|-----------|---|
| `baggage` (preferences) | `*string` | `String?` | yes | ☐ |
| `baggage` (flight request) | `string` | `String?` (always sent) | no | ☐ |
| `baggage` (flight response) | `string` | — (unused by client) | no | ☐ |
| `baggage_note` | `string,omitempty` | `String?` | yes | ☐ |
| `baggage_status` | `string,omitempty` | `String?` | yes | ☐ |
| `effective_price` | `float64,omitempty` | `double?` | yes | ☐ |

## Verification

See `tasks.md`; the end-to-end proof is a same-route search at each tier showing
different prices, a `checked_not_priced` note on the checked run, and **two**
upstream provider calls rather than one cache hit.
