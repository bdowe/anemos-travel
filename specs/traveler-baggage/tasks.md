# Tasks: Bag-aware flight pricing

> Dependency-ordered. `[P]` = parallelizable with its siblings.
> Single lane (`traveler-baggage`) — no wave table.

## Storage & preferences (Go)

- [x] `migrations/00066_traveler_baggage.sql`
- [x] `query/preferences.sql` narg/COALESCE pair → `make api-sqlc`
- [x] `preferences_handler.go`: response, request, mapper, normalize, upsert
- [x] `plan_tool_registry.go`: `save_preferences` schema + dispatcher touchpoints
- [x] `plan_handler.go`: `personalizedSystemPrompt` parts + note
- [x] [P] `plan_compactor.go` preserve list
- [x] [P] `profile_distiller.go` six touchpoints

## Tier resolution (Go)

- [x] `duffel_service.go`: `defaultBaggageTier`, `baggageStatusInPrice`,
      `resolveBaggageTier`, `normalizeBaggage` default
- [x] `plan_tool_registry.go`: `planSession.bagPref`; `runSearchFlightsTool`
      resolves + validates before building the request; `baggage` property text
- [x] `plan_handler.go`: populate `session.bagPref` where prefs are loaded

## Provider pricing (Go)

- [x] `serpapi_flights_service.go`: `serpapiPax` extraction +
      `serpapiCarryOnBags`
- [x] `serpapi_flights_service.go`: send `bags`, **add it to the cache key**
- [x] `serpapi_flights_service.go`: set `in_price` + `effective_price` on mapped
      offers; rewrite the stale "no baggage data" comment
- [x] `flight_baggage.go`: classification loop respects a provider-set status

## Saying what the price covers (Go)

- [x] `plan_handler.go`: `summarizeOffers` bag-basis header + `in_price` suffix
- [x] `main.go`: `FlightSearchResponse.baggage_note`, resolved-tier echo

## Flutter

- [x] `models/traveler_preferences.dart` → `make flutter-build-models`
- [x] [P] `services/preferences_api_service.dart`
- [x] [P] `providers/preferences_provider.dart`
- [x] `constants/travel_profile_options.dart` shared list + labels
- [x] `screens/preferences_screen.dart` row
- [x] `screens/onboarding_quiz_screen.dart` step (+ step count)
- [x] `screens/flight_search_screen.dart`: seed from prefs on BOTH paths before
      the auto-search, always send the tier, summary line, checked note
- [x] `widgets/flight_offer_card.dart` + `widgets/flight_details_sheet.dart`
      `in_price` case
- [x] `app_en.arb` + `app_es.arb` → `make flutter-gen-l10n` (LAST)

## Tests

- [x] Go: `resolveBaggageTier` table; `serpapiCarryOnBags`; `bags` present for
      carry-on, absent for personal-item and indicative; **cache key splits by
      tier**; `in_price` ranks as priced; `summarizeOffers` header per tier;
      handler echo + note; preferences normalize/round-trip/prompt cases
- [x] Go: update `flight_baggage_test.go`'s no-tier case to state
      `personal_item` (the default moved)
- [x] Go: `go test -race` — SerpApi stub counters must be atomic
- [x] Flutter: prefs row seeds/saves canonical value; quiz step count; flight
      screen seeds + always sends; `in_price` badge
- [x] Flutter: add the new param to all 10 `PreferencesApiService` fakes

## Verification

- [x] `make api-fmt && make api-vet` clean; `go test -race ./...` green
      (`make flutter-analyze` reports only the 3 pre-existing
      `route_response.dart` infos that are already on main)
- [x] `make flutter-test` green — 1345 tests
- [x] **Live provider proof** (LGW→BCN 2026-10-12, real SerpApi): bare fare
      ranked Vueling at USD 47 with no baggage fields; the carry-on search
      returned USD 92 for the same carrier with `baggage_status:"in_price"` and
      `effective_price == price` — the cabin-bag fee this feature exists to
      surface. The checked run added `baggage_note:"checked_not_priced"`, and an
      omitted tier resolved to `carry_on`. **Two** upstream searches served all
      four requests (bare vs bagged split the cache; checked and omitted hit
      it), so the split costs no quota.
- [x] **Browser** (headless Chrome, lane stack): the quiz's new step renders
      ("What do you fly with?", step 7 of 8), selecting Carry-on and finishing
      persisted `traveler_preferences.baggage = carry_on` in Postgres, and the
      Travel profile then showed the new row with Carry-on pre-selected.
- [x] DB round-trip + rejection covered by `traveler_baggage_integration_test.go`
      against the lane's Postgres (migration 00066 applied on boot).
- [ ] NOT done in a live chat session: the agent path is covered by
      `traveler_baggage_test.go` (dispatcher resolves the saved tier, sends
      `bags`, and the tool result states the basis) rather than by driving a
      real conversation. Same for the flight SCREEN's note/summary, which four
      widget tests pin but no browser pass exercised (it is reachable only from
      a trip page, which would need a seeded trip).
