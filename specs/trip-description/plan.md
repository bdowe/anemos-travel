# Plan: A trip's description can be edited

## The shape

Two surfaces, **one write implementation** — the `applyTripEndpoints` pattern
(`plan_trip_origin.go`: *"the two surfaces differ only in how they are authorized
and how they word the answer"*), pinned by a parity test.

```
page:  header pencil → showTripDetailsDialog → PATCH /trips/{id} {title, summary}
                                                        ↘
                                                   applyTripSummary → SetTripSummary
                                                        ↗
chat:  set_trip_description (registry TAIL, authedOnly)─┘
```

`UpdateTrip` is deliberately **not** given a `summary` column. Two reasons, and
the first is the load-bearing one: `col = COALESCE(sqlc.narg('col'), col)` cannot
carry "write NULL", so a description could be set and replaced but never cleared
— the limitation `PatchTripRequest.TravelMode`'s comment already laments and
`query/preferences.sql`'s `clear_home_airport` flag was written to escape. Second,
one column with one writer is what keeps the page and the chat from drifting.

## Storage — migration 00071

| Column | Meaning | On a version save |
|---|---|---|
| `summary` | the prose itself; `""` normalized to NULL so "no description" has one representation | carried forward when the caller supplies none |
| `summary_source` | `'agent'` \| `'traveler'` — **whose words these are**. NULL = written before this was tracked, which is provably not the traveler (no human writer existed until now) | carried with the prose |

The **pair** carries the meaning that neither column holds alone:
`summary IS NULL AND summary_source = 'traveler'` is the traveler having removed
the description on purpose. That is why clearing writes `'traveler'` rather than
NULL — otherwise the next reshape would helpfully re-add a blurb they deleted.

`CHECK (summary_source IN ('agent','traveler'))` in SQL, for 00068's reason: this
column is written by derivation-ish code paths (`persistTrip` stamps it), not only
by a validated request handler, so the schema is the only place a typo stops.

Server-side only — **not on the wire**, so no Dart model change and no
`build_runner` run. Its one consumer that needs to see it is the planner, and it
sees it through `get_trip`.

## Who may write it, and when

`reason` is a **required** input on the tool, so the invariant lives at the
boundary instead of in the system prompt:

| `reason` | existing `summary_source = 'traveler'` | otherwise |
|---|---|---|
| `traveler_asked` | writes, stamps `'agent'` | writes, stamps `'agent'` |
| `trip_changed` | **refuses**, quoting what is there | writes, stamps `'agent'` |

The page always writes `'traveler'`. A refusal is a real tool_result error that
names the next move ("offer the change, don't make it"), so a wrong mental model
cannot survive a string of successful calls.

## Go API

- `query/trips.sql` — `SetTripSummary :exec` (plain `narg`, unscoped by
  `user_id` like `SetTripTravelMode`/`SetTripDates`; the caller authorizes) and
  `GetLatestTripSummaryByChat :one` for the carry-forward. `CreateTrip` gains
  the new column. `UpdateTrip` untouched. `make api-sqlc`.
- `validation.go` — `maxSummaryLen = 2000`, beside `maxNoteLen`.
- `trip_summary.go` (new) — `applyTripSummary(ctx, q, trip, next, source, actor)`:
  trim, `""` → NULL, write, `TouchTrip` with the actor, return the post-state.
  Plus `tripDescriptionSummary(trip)`, the `get_trip` line, copying
  `tripEndpointSummary`'s explicit-about-absence branches. Refusals come in two
  wordings — one to the model, one to the person — per
  `unresolvedAirportReply` ↔ `unresolvedAirportMessage`.
- `trip_handler.go` — `PatchTripRequest.Summary *string` (nil = omitted, `""` =
  clear); `patchTripHandler` bounds it, then runs `applyTripSummary` and
  `UpdateTrip` in one transaction, summary first so the `RETURNING *` row it
  responds with already carries the new text. `persistTrip` stamps `'agent'` on
  the prose it writes and carries the previous version's forward when given none.
- `collaborator_handler.go` — `Summary` added to the `shared-with-me` rows.
- `plan_trip_description.go` (new) — the tool, on `plan_leg_transport_mode.go`'s
  guard ladder: empty text → `!s.authed` → `dbPool == nil` → `reason` enum →
  `resolveDateShiftTrip`. Row lock, shared write, commit, `trip_updated` SSE,
  `agent_trip_description_set` event with an `is_collaborator` dimension,
  `notifyCollabEdit` for a collaborator's write, and a result that states the
  stored text back. Before a trip exists it refuses and names the next move —
  unlike `set_trip_origin` there is nothing to carry on the session, because
  `create_itinerary` already takes `summary`.
- `plan_tool_registry.go` — one entry appended at the **tail**, `authedOnly`, so
  the anonymous tools array stays byte-identical and only the two authed session
  shapes take a one-time cache re-warm.
- `plan_tools_extra.go` — `get_trip` renders `tripDescriptionSummary`;
  `update_itinerary_section`'s result echo carries it too, so a reshape hands the
  model the now-possibly-stale blurb. That echo is what makes the refresh
  reliable without a prompt-only rule — the `legTransportSummary` trick.
- `plan_handler.go` — one `basePrompt` sentence, inserted **before** the pinned
  final sentence.

## Flutter

- `trips_api_service.dart` — `patchTrip` gains `String? summary`;
  `if (summary != null)` so `""` sends as an explicit clear.
- `widgets/trip_details_dialog.dart` (new) — top-level
  `showTripDetailsDialog(...)` returning a `TripDetailsEdit?`, following
  `trip_airports_sheet.dart` (return a choice; the screen owns the save) and
  `budget_target_dialog.dart` (top-level function, not a widget class). The
  description field is `preferences_screen.dart`'s profile-notes field — the
  app's only existing multi-line prose input.
- `trip_detail_screen.dart` — `_editTitle` becomes `_editTripDetails`, prefilled
  from `_overviewText(trip)` so a legacy trip's long `title` is promoted into
  `summary` on first save. The existing pencil, its `trip.canEdit` render gate,
  its `_isOffline` disable and `_guardOffline()` are unchanged. Net line
  reduction on the god screen.
- `app_en.arb` + `app_es.arb` — `tripDetails*` prefix; regenerate
  `app_localizations*.dart` LAST.

## Contract parity

| JSON key | Direction | Go | Dart | Nullable |
|---|---|---|---|---|
| `summary` | response | `*string` `TripResponse.Summary`, omitempty | `String? summary` | yes |
| `summary` | PATCH request | `*string` `PatchTripRequest.Summary` | `String? summary` param | yes — `""` clears |
| `title` | PATCH request | `*string` | `String? title` param | yes |
| `summary_source` | — | `*string`, server-only | absent by design | — |

## Rejected alternatives

- **Its own `PUT /trips/{id}/description`.** The endpoints precedent earned its
  own route because the write relabels derived legs in the same transaction; a
  description has no derived consequences, and it is edited in the same breath as
  the title. Two endpoints would mean two requests for one dialog.
- **Rename the column to `description`.** sqlc expands `SELECT *`, so ADD COLUMN
  is rollback-safe and RENAME is not — and the wire key is consumed by shipped
  clients.
- **A `clear_summary` boolean on `UpdateTrip`** (the `clear_home_airport`
  pattern). It works, but it leaves the column with two writers; a dedicated
  setter gives clearing for free and keeps one.
- **Naming the tool `set_trip_summary`.** One word everywhere is tempting, but
  the compaction state reaches the model as a message literally opening "Summary
  of the conversation so far". The house style already names tools for the
  concept, not the column.
- **Letting the planner rewrite freely, with a prompt rule not to clobber.** A
  rule the model must remember is not an invariant; the leg-dates arc is the
  receipt. Hence the stored source and the server-side refusal.

## Verification

- `plan_trip_description_test.go` — dispatcher tests via `testPlanSession`:
  writes, clears, refuses unauthed, refuses with no saved trip (naming
  `create_itinerary`), refuses `trip_changed` against traveler prose **and
  asserts nothing was written**, and asserts the result text carries the stored
  description. Plus a no-DB table test pinning `tripDescriptionSummary`'s
  absence branches, mirroring `TestTripEndpointSummaryIsExplicitAboutAbsence`.
- `trip_summary_integration_test.go` — PATCH sets/clears; editor collaborator
  may; viewer 404; over-length 400; carry-forward across a version save;
  `shared-with-me` carries `summary`; and
  `TestPageAndChatWriteTheSameDescription`, modelled on
  `TestPageAndChatWriteTheSameEndpoints`.
- Registry pins that move: `TestPlanSessionToolsOrderStable`'s two **authed**
  lists and the authed tools-tail guard in `plan_integration_test.go`. The two
  anonymous pins stay put — that is what the `authedOnly` gate buys. Plus the
  new prompt pin in `TestSystemPromptEnglishUnchanged`.
- `test/trip_details_dialog_test.dart` — on `trip_airports_test.dart`'s shape
  (one `ProviderScope`, tall viewport, capturing fake): edit both fields and
  assert the recorded PATCH payload; clearing sends `""`; no pencil for a viewer.
- Mutation-checked: each new assertion reverted in place and confirmed to turn
  the suite red.
- Browser: edit name + description on a trip and reload; ask in chat to change
  the description; ask for a city to be added and confirm the blurb refreshes;
  then hand-edit the description, add another city, and confirm it is NOT
  overwritten.
