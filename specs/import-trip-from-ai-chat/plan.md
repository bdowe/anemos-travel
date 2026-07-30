# Plan: Import a trip from an external AI chat

## Technical Approach

```
paste text ──POST /trips/import──▶ importTripHandler
                                        │
                                        ▼
                          importTripCore (trip_import_service.go)
                            1. truncateForImport (head 10k + tail 50k)
                            2. extractImportedTrip — ONE forced-tool Claude call
                               (Sonnet 4.6, ToolChoice=import_trip, 120s)
                            3. resolveImportedLocations — Google Places per place
                               (≤50 lookups; verified / approximate / dropped)
                            4. persistTrip(userID, "chat-<token>", …)
                            5. analytics (trip_created + trip_imported)
                                        │
                                        ▼
                     201 {trip_id, title, item_count, warnings[]}
```

Design decisions:
- **Sonnet 4.6, not Haiku**: one-shot user-visible result with no chat loop to
  repair it; the agent already emits this exact location shape on Sonnet 4.6.
  ~$0.07 typical / ≤$0.17 worst case. Model is a file-level const for a later
  Haiku downgrade once eval fixtures exist.
- **Head+tail truncation** (not head-only like local ingest): destination and
  dates live at the start of a conversation, the final itinerary at the end.
- **Tiered coordinates**: Google hit → verified; miss but plausible model
  coords (range-checked, not (0,0)) → kept + "approximate" warning; neither →
  dropped + warning. Degraded (no `GOOGLE_PLACES_API_KEY`): everything rides
  the model tier + one aggregate warning. `itinerary_items.latitude/longitude`
  are NOT NULL, and a (0,0) pin ruins the map; but failing the whole import in
  degraded mode would be worse. Unlike the local-content publish gate this is
  the user's own private trip, so approximate+flagged is acceptable.
- **chat_id yes, plan_chat_sessions row no**: `trips.chat_id` alone makes
  refine-in-chat work (plan_handler binds by chat_id) and keeps the trip out of
  the resumable-chats list (`NOT EXISTS trips.chat_id` filter); the first
  refine turn upserts the session row naturally.
- **Warnings localized server-side** via the existing `tr()` catalog
  (`import.*` keys, en+es) since they are displayed verbatim.

## Go API Changes

### Routes
- `POST /api/v1/trips/import` — `strict(authMiddleware(importTripHandler))`
  (each request = 1 Claude call + ≤50 Places calls; deliberate rare action,
  same tier as `/trips/{id}/refine`).
- `bodyLimitMiddleware`: new `/api/v1/trips/import` lane at 2 MiB
  (`importMaxRequestBodyBytes`) — long transcripts blow the 256 KiB default.

### New files
- `trip_import_service.go` — constants (`importToolName`, `importTimeout=120s`,
  `importMaxChars=60000`, `importHeadChars=10000`, `importMaxLocations=80`,
  `importMaxPlaceLookups=50`, `importModel`), `ImportedTrip`/`ImportedLocation`
  structs, `truncateForImport`, `extractImportedTrip` (forced-tool call
  mirroring `extractLocalContent`), `plausibleCoords`, `resolveImportedLocations`
  (Places loop mirroring `ingestLocalHandler` stage 3, reusing `placeQuery`),
  `importTripCore` (the unit Track 2's MCP `create_trip` tool will reuse).
- `trip_import_handler.go` — decode/validate, `newAnthropicClient`, call core,
  map typed errors to 422/502, respond 201.

### Reused
`persistTrip`, `placeQuery`, `placesService.SearchPlaces`,
`generateSessionToken` (chat token), `itemParamsFromLocation` (inside
persistTrip), `recordEvent`/`recordActiveTripsCapSignal`/`safeGo`,
`newAnthropicClient` (keeps the `ANTHROPIC_BASE_URL` fake seam), `tr()`.

### Tool schema (model-facing)
Envelope: `title`*, `summary`, `start_date`/`end_date` (YYYY-MM-DD, only if
stated), `travel_mode` (enum flight|car|train|bus|ferry|mixed);
`locations[]`*: `name`*, `city`*, `search_hint`*, `day` (1-based int),
`time_of_day` (morning|afternoon|evening), `category` (attraction|restaurant),
`day_trip_from`, `latitude`/`longitude` (approximate, only if confident).
Grounding prompt: ONLY places named in the text; call the tool exactly once;
empty locations when no trip is present.

## Flutter Changes

### Models
`lib/models/import_trip_result.dart` — `@JsonSerializable`
(`trip_id`, `title`, `item_count`, `warnings`) → `make flutter-build-models`.

### Service
`trips_api_service.dart`: `importTrip(String text, {String? source})` →
`ImportTripResult` (template: `duplicateSharedTrip`).

### Provider
`lib/providers/import_trip_provider.dart` — StateNotifier: idle → importing →
success(result)/error(message); invalidates `tripsProvider` on success.

### Screens
`lib/screens/import_trip_screen.dart` — explainer + copy-prompt button +
paste field (`maxLines: null`) + import button + staged progress + error state.
Entry points: Trips list app-bar `IconButton` and empty-state action.
Planning prompt text = ARB constant (en+es), asks for a final "TRIP SUMMARY"
(Day N — City; Morning/Afternoon/Evening entries as "Place — City"; dates;
day trips; inter-city travel mode).

## Contract Parity

| JSON key | Go type | Dart type | Nullable? | ✓ |
|---|---|---|---|---|
| trip_id | string | String | no | ✓ |
| title | string | String | no | ✓ |
| item_count | int | int | no | ✓ |
| warnings | []string | List<String> | no (may be empty) | ✓ |
| text (req) | string | String | no | ✓ |
| source (req) | string | String? | yes | ✓ |

## Cross-cutting

- No new env vars; behavior with missing `ANTHROPIC_API_KEY` (503) and missing
  `GOOGLE_PLACES_API_KEY` (degraded, warnings) documented in spec.
- nginx: no change (`client_max_body_size` already ≥ 20 MiB).
- Server i18n: new `import.*` keys in the `messages` catalog (i18n.go), en+es.

## Verification

- `trip_import_test.go` (pure): truncation head+tail behavior, coordinate
  plausibility check.
- `trip_import_integration_test.go` (Postgres + fake Anthropic via
  `newFakeAnthropic(t).scriptNonStreamingTool("import_trip", …)` + fake Places
  via `swapPlacesService` with a canned-JSON RoundTripper): happy path rows +
  chat_id + coercion; approximate-kept warning; dropped warning; degraded
  no-key mode; empty text 400; no-trip 422; unauth 401; trip cap 422;
  resumable-chats unaffected; analytics rows; oversized-input truncation.
- `make api-fmt && make api-vet && make api-test`.
- Manual: `make docker-dev`, real keys — copy prompt → ChatGPT → paste →
  verify map/day rendering, warnings, refine-in-chat binding, item editing,
  second import creates a separate lineage.
