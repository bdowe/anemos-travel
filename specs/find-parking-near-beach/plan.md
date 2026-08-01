# Plan: Find free/cheap parking near beaches

> **HOW.** Translates `spec.md` into a file-level technical approach. Every
> decision should trace back to an acceptance criterion. See `../../CLAUDE.md`
> for repo conventions referenced below — don't restate them, point to them.

## Technical Approach

A new `find_parking` tool in the `/plan` agent registry, backed by Google
Places Text Search (existing `placesService`, existing key — no new provider or
env var). Two location-biased queries per call ("free parking near <beach>" +
"parking near <beach>", `type=parking`, 2 km bias), merged/deduped, post-
filtered to parking-shaped results, ranked free-first then by distance. The
free flag is a **name heuristic** (`free_listed`), reinforced as
"listed as free — verify locally" in the tool description, tool_result prefix,
and system prompt — never presented as verified pricing. Results ride a new
`parking` SSE side event as photo cards (same wire struct + photo-ref gate as
`places`) and render as a fourth `PlacePhotoStrip` rail in the chat.

Key decisions:
- **Tool input:** `beach_name` required; `latitude`/`longitude` optional.
  Optional coords avoid coordinate hallucination — the model passes coords it
  already has (0 extra Google calls); otherwise the tool geocodes once via
  `SearchPlaces`.
- **No `enabled` gate** — keeps every session shape's tools array a pure
  append (prompt-cache rule, same reasoning as `suggest_replies`).
- **No `itineraryThisTurn` guard** on the Flutter side — unlike
  `search_places`, `find_parking` never runs as itinerary geocoding, so the
  rail is real advice even on a trip-building turn (matches ferries/events).
- **System-prompt sentence** = deliberate one-time prompt-cache re-warm
  (precedent: suggest_replies, `plan_language_integration_test.go`).

## Go API Changes

`src/packages/api/` (all `package main`); no new routes, no migration, no env
vars:

- **`parking_service.go` (new):** pure heuristics `looksFreeParking`,
  `isParkingResult`, `rankParkingResults` (pinned keyword slices, unit-testable
  without network); `parkingResult` (embeds `PlaceSearchResult` + `free_listed`
  + `distance_meters`; embedding preserves the `json:"-"` photo fields so the
  model-facing tool_result stays photo-free); `haversineMeters` helper;
  orchestrator `findParkingNearBeach` (two queries, tolerates one failing,
  errors only if both fail). Deliberately **no singleton** — no provider
  config/state of its own; it orchestrates `placesService`.
- **`places_service.go`:** `SearchParkingNearby(ctx, query, lat, lng)`
  mirroring `SearchPlacesNearby` via `textSearch`, with `location`,
  `radius=2000`, `type=parking`, cache key prefixed `parking|`.
- **`plan_tool_registry.go`:** `findParkingTool` definition + entry
  **tail-appended** after `searchNearbyTool` (registry order = prompt-cache
  prefix); `placeCard` gains `FreeListed bool` `json:"free_listed,omitempty"`
  (client-only struct; omitempty keeps existing `places`/`local_recs` payloads
  byte-identical); `parkingCards()` mirroring `placeCards()` incl. the
  `allowPhotoRef` billing gate; dispatcher `runFindParkingTool` (geocode
  fallback, `parking` SSE event only when non-empty, disclaimer-prefixed
  tool_result).
- **`plan_handler.go`:** one sentence in `basePrompt` triggering the tool for
  car+beach contexts with the verify-locally phrasing.

## Flutter Changes

`src/packages/flutter-app/lib/`:

- **Models:** `agent_place.dart` gains
  `@JsonKey(name: 'free_listed', defaultValue: false) final bool freeListed;`
  → `make flutter-build-models`. Reuses `AgentPlace` (one Go wire struct ↔ one
  Dart model; Add-to-trip plumbing unchanged).
- **Provider:** `plan_provider.dart` — `parkingSpots`/`parkingBeach` state
  (sentinel copyWith, null-reset in `_sendNow`, whole-list replacement),
  `case 'parking':`.
- **UI:** `chat_panel.dart` — fourth rail in `_ResultStrips` +
  `find_parking` case in `_ActiveToolChips._toolLabel`;
  `place_photo_card.dart` — `PlaceCardData.parking` factory (hardcoded
  `Icons.local_parking` fallback + accent; card geometry untouched);
  `theme/app_colors.dart` — `toolParking` (blue-grey 700).
- **l10n:** `chatStripParking` (plural), `chatToolFindParking`,
  `chatCardFreeListed` in both `app_en.arb` and `app_es.arb` + regenerated
  committed `app_localizations*.dart`.

## Contract Parity  ← anti-drift gate

| JSON key | Go type (`plan_tool_registry.go`) | Dart type (`agent_place.dart` / provider) | Nullable? | ✓ |
|----------|-----------------------------------|-------------------------------------------|-----------|---|
| `beach` (event) | `string` | `String?` (`parkingBeach`) | yes | ☑ |
| `spots` (event) | `[]placeCard` | `List<AgentPlace>?` (`parkingSpots`) | yes | ☑ |
| `free_listed` | `bool` `omitempty` | `bool` `@JsonKey(name:'free_listed', defaultValue:false)` | absent-when-false | ☑ |
| (existing `placeCard` keys: `name`, `place_id`, `address`, `lat`, `lng`, `rating`, `price_level`, `category`, `photo_ref`, `photo_attribution`) | already parity-checked with `AgentPlace` | — | — | ☑ |

Rules: optional Go fields (pointers / `omitempty`) → nullable-or-defaulted
Dart fields; JSON tag on the Go side must equal the `@JsonKey` name on the
Dart side.

## Cross-cutting

- **Env vars:** none new (reuses `GOOGLE_PLACES_API_KEY`).
- **Gateway:** no new paths; the `parking` event rides the existing `/plan`
  SSE stream.
- **Billing posture:** 2 Text Search calls per invocation (3 with geocode
  fallback), absorbed by the shared 1 h `searchCache` (parking-prefixed keys);
  the tool is prompted only for car+beach context.
- **Prompt cache:** registry entry tail-only; the `basePrompt` sentence is a
  one-time cache re-warm, frozen after merge.

## Verification

(Mirrored into `tasks.md` as the final tasks.)

- `make api-fmt && make api-vet && make api-test` — includes the pinned
  registry-order test, parking heuristic unit tests, and fake-Anthropic
  integration tests for the tool.
- `make flutter-build-models` → `make flutter-analyze` → `make flutter-test`;
  `l10n_untranslated.json` empty after gen-l10n.
- Manual end-to-end on this lane's dev stack (`make docker-dev-bg`, gateway
  `http://localhost:3001`): walk each acceptance criterion in `spec.md` — chat
  "We're driving to Barcelona and want a beach day at Barceloneta — where can
  we park for free?"; repeat in Spanish; negative-check a flights-only trip.
