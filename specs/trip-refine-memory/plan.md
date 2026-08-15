# Plan: Trip Refine Memory

## Technical Approach

Four load-bearing decisions; the rest follows.

### 1. Its own table, `trip_refine_sessions`, keyed `UNIQUE (user_id, trip_id)`

Not a nullable `trip_id` on `plan_chat_sessions`, and emphatically not
`trips.chat_id`.

- The product decision ("one running chat per trip") becomes a **constraint the
  database enforces**, not a convention the client maintains.
- A refine transcript then has **no chat id anywhere** — not in the table, not
  on the wire — so `GET /chats/{chatId}` and `/plan/<chatId>` *structurally
  cannot* address it. "A trip chat can never be resumed into the unbound Agent
  tab, silently dropping the trip binding" stops being a filter someone can
  delete and becomes a fact about the schema.
- A nullable column would instead require `AND trip_id IS NULL` remembered in
  five places: `ListResumablePlanChatSessions`, `GetPlanChatSessionByChatID`,
  `DeleteStalePlanChatSessions`, the weekly-nudge predicate in
  `query/reengagement.sql`, and the upsert's conflict target. `docs/zen.md`:
  promote the convention to storage.
- **Reusing `trips.chat_id` is a data-loss bug, not a smell.** That key already
  owns a `plan_chat_sessions` row — the freeform chat that created the trip —
  so refine turns would `ON CONFLICT DO UPDATE` over the original planning
  transcript. It is also non-unique (one lineage, N version rows), NULL for
  imported and logged trips, deliberately withheld from collaborators
  (`trip_handler.go`), and already used to resolve a trip in
  `plan_trip_dates.go`.
- **This does not contradict migration 00031's header**, which chose read-time
  graduation over a column. That was a *derived, racy* question ("has this chat
  produced a trip?") about a text key with a competing writer
  (`create_itinerary`). "Which trip is this conversation about?" is validated
  request input, resolved before a byte streams, and immutable for the row's
  life. Storing an identity is not the thing 00031 argued against.
- **Retention is the trip**, not 60 days: a trip planned in August for next
  March must still have its chat in November. `ON DELETE CASCADE` is the whole
  GC story — enforced by the database rather than by a janitor rule.
- Cost accepted: two tables share transcript shape. Paid for by extracting one
  derivation, `planTranscriptFields`, used by both savers and pinned by a
  parity test (`docs/zen.md`: a second implementation owes a parity contract).

### 2. The panel header is a function of the transcript

`_refineTarget` was screen state whose only job was the panel title — and the
title is already in the transcript, since every seed message carries a
`displayLabel` that `chat_panel.dart` renders as a context chip. Deleting it
makes `_panelOpen` the panel's only state, so back has exactly one thing to
undo, and the "restore a header if the screen was rebuilt" hack disappears.

### 3. Appending a section seed stubs the earlier ones

`_buildSectionSeed` dumps every item with coordinates and tags. Repeating that
per ✨ tap would leave the agent holding N near-duplicate itinerary snapshots
with no way to tell which is current — the failure class behind the
`update_itinerary_section` scope bugs. On append, each *earlier* labeled user
message's `content` is rewritten **in place** to a one-line "superseded" stub
while its `displayLabel` is kept, so exactly one authoritative listing is ever
in context. Nearly free, because seed content is never rendered.

**Rewrite, never remove**: `compactedCount` is a start-anchored index into
`messages`, so deleting a message would misalign the wire history.

### 4. Freshness is the server's job, unconditionally

A resumed conversation that rebuilt a section from its remembered listing would
silently revert hand edits and a co-planner's changes. Fixed in the bound
system prompt plus `get_trip` — not with a client-side re-seed.
`specs/conversation-compaction` already claimed trip-bound sessions "re-read
authoritative trip state via tools"; this makes it true. Applied to every bound
session, not just resumed ones, so there is no special case to remember — and
it is already correct for fresh ones, since a co-planner can edit mid-chat.

## Go API Changes

`src/packages/api/`

- **Migration** `migrations/00069_trip_refine_sessions.sql` (00058 stays
  burned). Header carries decision 1 verbatim.
- **Queries** appended to `query/chat_sessions.sql`, then `make api-sqlc`
  (never hand-edit `store/`): `UpsertTripRefineSession`,
  `GetTripRefineSession`, `GetTripRefineSessionSummary` (summary columns only —
  the transcript can run to hundreds of KB and must not ride every trip load),
  `DeleteTripRefineSession`.
- **`chat_session_handler.go`**: extract `planTranscriptFields` (image-byte
  stripping, title, preview) — one derivation, two savers.
- **New `trip_refine_handler.go`**: `saveTripRefineSession` (best-effort +
  logged, like its sibling), `getTripRefineChatHandler`,
  `deleteTripRefineChatHandler`, and the response types. Both handlers resolve
  access with `editableTrip`, so a revoked collaborator gets the same 404 as a
  stranger with no extra check. Routes registered in `main.go` with startup log
  lines.
- **`plan_handler.go`**: the persistence gate splits into `persistPlan`
  (unbound, needs `chat_id`) and `persistRefine` (bound, needs no chat id at
  all — the client's per-session one is meaningless here) resolving a single
  `saveTurn` closure. The existing two-write block — `startSaved` ordering, the
  5 s background contexts, the pre-compaction snapshot rule — is reused
  verbatim. One implementation, two destinations.
- **`trip_handler.go`**: `TripResponse.RefineChat` (`json:"refine_chat"`),
  filled by one more `g.Go` in `getTripHandler`'s existing errgroup, gated on
  `Access != "viewer"`, assigned outside the branch that nils `ChatID` so the
  two visibly never travel together. Named `refine_chat`, not `last_chat`:
  "last" implies a series, which implies a picker this design does not have.
- **`plan_tools_extra.go`**: `runGetTripTool` with no `trip_id` in a bound
  session returns *that* trip instead of listing. Today it lists
  `ListLatestTripsByOwner(uid)`, which for a collaborator is their own other
  trips and never the trip being refined — a live bug. Tool description updated
  to match (one deliberate prompt-cache re-warm).

## Flutter Changes

`src/packages/flutter-app/lib/`

- **Models**: `models/trip_refine_chat.dart` (summary + detail; the detail
  reuses `ChatSessionMessage` — same wire shape, consume the first
  implementation) and `Trip.refineChat`. `make flutter-build-models`.
- **Service**: `getTripRefineChat` / `deleteTripRefineChat` in
  `services/trips_api_service.dart`, throwing `ApiException` **with the status
  code** so "gone" is decidable from "failed".
- **Provider**: `providers/plan_resume.dart` grows `planMessagesFrom` (extracted
  from `resumePlanChat`) and `resumeTripRefineChat`, so both resume paths share
  one mapping by construction. `resumeConversation`'s `chatId` becomes optional.
- **Notifier**: `beginSectionRefinement` → `appendSectionRefinement` (no
  `reset()`, stubs earlier seeds) and `startOver`.
- **Screen**: `PopScope` + Escape; the `trip_updated` listener moves from the
  panel to the screen (a patch landing after back closed the panel must still
  refresh the trip — a bug the back fix would otherwise introduce); a
  `_ensureRefineHydrated` gate every entry funnel awaits and **aborts on**; a
  Continue-chat row below the Next Step card; the FAB's `items.isNotEmpty` gate
  widened so a zero-item trip's chat is reachable.
- **Panel**: nullable target, a New-chat action with a confirm, and the
  restoring / expired / failed states.

## Contract Parity

| JSON key | Go type | Dart type | Nullable? | ✓ |
|---|---|---|---|---|
| `refine_chat` | `*TripRefineChatSummary` | `TripRefineChat?` | yes | ☐ |
| `refine_chat.message_count` | `int` | `int` | no | ☐ |
| `refine_chat.preview` | `string` | `String` | no | ☐ |
| `refine_chat.updated_at` | `time.Time` | `String` | no | ☐ |
| `trip_id` (detail) | `string` | `String` | no | ☐ |
| `summary` (detail) | `string` | `String` | no | ☐ |
| `messages` (detail) | `[]PlanChatMessage` | `List<ChatSessionMessage>` | no | ☐ |
| `message_count` (detail) | `int` | `int` | no | ☐ |
| `updated_at` (detail) | `time.Time` | `String` | no | ☐ |

## Decision records (divergences, per `docs/zen.md`)

- **`DELETE …/refine-chat` returns 200 when nothing existed**, unlike
  `DELETE /chats/{chatId}`'s 404. Clearing state the caller cannot observe
  beforehand must be idempotent — "New chat" tapped on a conversation that
  never completed a turn is not an error. Pinned by
  `TestDeleteTripRefineChatIsIdempotent`.
- **Two transcript tables.** Justified above; the parity contract is
  `TestTranscriptFieldsParity` (Go) and the shared `planMessagesFrom` (Dart).
- **No URL for the open panel.** Trip detail is a pushed route, so URL sync
  reads the route name and cannot see panel state; reflecting a *pane* would
  need a new seam plus a third `BootTarget` axis. With the chat persisted and a
  visible row, a refresh costs one tap on a card that proves the transcript
  survived. Pinned by a test so it cannot drift in by accident.

## Cross-cutting

- No new env vars, no gateway changes (new paths are under `/api/v1/`).
- New l10n keys in `app_en.arb` **and** `app_es.arb`; regenerate
  `app_localizations*.dart` LAST if this lane rebases.
- Specs amended: `continue-where-you-left-off`, `collaborator-refine`,
  `refine-panel-polish`, `url-page-persistence`, `conversation-compaction`.

## Verification

See `tasks.md`.
