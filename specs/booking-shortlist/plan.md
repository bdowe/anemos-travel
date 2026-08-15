# Plan: Booking shortlist

> **HOW.** See `../../CLAUDE.md` for repo conventions and `docs/zen.md` for the
> principles the data-model decisions below trace back to.

## Technical Approach

One new table, `booking_options`, hanging off `booking_todos` — the row that
already *is* a leg's identity since migration 00064. A candidate carries what
you compare on (title/price/link) and what promotion needs (dates, endpoints,
mode); choosing one is a single server transaction that materializes the real
`accommodations`/`trip_segments` row, links it back, flips the leg booked and
records the spend.

Key decisions and why:

- **The leg reference is a FK to `booking_todos.id`, NOT the `todo_key`
  string.** Keying on the key would make every write post a *client-derived*
  key the server must canonicalize — a second path computing identity from a
  payload, which is the failure `booking_todo_identity.go` exists to end — and
  would bake in `displayBookingTodoKey`, a spelling that dies at
  specs/server-booking-todos.
- **NOT NULL + CASCADE.** A candidate with no leg has no renderer and no prune
  rule. Deleting a leg takes its shortlist, which is the right semantic; the
  *stale-key prune* is handled separately (below) because dropping a city from
  the itinerary is not the same act as deleting the leg.
- **`DemoteStaleAutoBookingTodos` gains a fourth predicate.** A leg with saved
  options is traveler state, exactly like a booked flag, a mode override or a
  linked expense — it demotes to `auto = false` instead of being deleted. This
  is the one line that stops a removed city silently destroying research.
- **No `kind` column.** An option's kind is its leg's kind. Stored twice it
  could drift (`UpdateBookingTodo` permits kind edits on `auto = false` rows,
  and demoted legs are `auto = false`), and `choose` would promote a stay into
  a segment.
- **`price` and `currency` are a both-or-neither pair** (CHECK + handler),
  because there is no FX anywhere in this app (00042) and an unsummable number
  is worse than none.
- **Promotion stamps `auto_key` with the leg's storage key.** Load-bearing:
  `_computeGroupedBookings` matches a stay by `autoKey == 'stay:<label>'` first
  and only then by a name/address `contains` against the city label, which
  "Loft near Old Town" fails. Without the stamp every promoted record renders
  in "Other bookings" instead of under its leg.
- **Promotion is an upsert on `(trip_id, auto_key)`**, so switching winners
  rewrites one row rather than growing a second stay for one city. That is also
  what makes "the leg already has a record from Add details…" a non-case.
- **Two typed FK columns for the winner link**, diverging from 00061's untyped
  `(source_kind, source_id)` pair. 00061 has no FK because its targets are
  re-synced and deletable; a promoted record is `auto = false`, outside sync
  ownership, so `ON DELETE SET NULL` safely gives un-choose for free.

## Go API Changes

`src/packages/api/`:

- **Migration:** `migrations/00065_booking_options.sql` (00058 stays burned).
- **Queries:** new `query/booking_options.sql`; `query/booking_todos.sql` gains
  `GetBookingTodo` and the demote predicate; `query/accommodations.sql` and
  `query/segments.sql` gain `Promote*FromOption`. `make api-sqlc` regenerates
  `store/`.
- **Handlers:** `booking_option_handler.go` (CRUD, validation, caps),
  `booking_option_choose.go` (the transaction + un-choose),
  `link_preview_handler.go`.
- **Service:** `link_preview.go` — the SSRF-guarded fetcher and `<meta>`
  scanner.
- **Shared:** `upsertLinkedExpense` extracted from `addExpenseHandler` in
  `budget_handler.go` so `choose` consumes it instead of reimplementing it.
- **Routes + startup log:** `main.go`, including `previewLimiter` — link
  preview gets its own IP bucket because every call is an outbound fetch.
- **Payload:** `trip_handler.go` returns `booking_options` behind the same
  `Access != "viewer"` gate as `booking_todos`.
- **Caps:** `validation.go` — `MAX_BOOKING_OPTIONS_PER_TODO` (20),
  `MAX_BOOKING_OPTIONS_PER_TRIP` (200).

No new env vars are required. No `plan_tool_registry.go` change.

## Flutter Changes

**Not in this lane** — `trip_detail_screen.dart`, `trip_detail_derivation.dart`,
`booking_todo_card.dart` and both `.arb`s are held by the in-flight
`trip-airports-on-page` lane, and `docs/parallel-dev.md` §3 allows only one lane
per wave on the god-screen. The client half is a follow-up lane against this
contract: a `BookingOption` model on `Trip`, a `BookingOptionRow` sibling of
`BookingDetailRow`, an "N saved" affordance on the subtitle line of
`BookingTodoRow`/`BookingTodoCard`, the save sheet, a "considering" projection
in `BudgetSection` (min/max per leg — never a naive sum), `amount` on
`BookedExpensePrefill`, and a "Save to trip" action on `FlightOfferCard`.

## Contract Parity  ← anti-drift gate

`BookingOptionResponse` ↔ `booking_option.dart` (client lane):

| JSON key | Go type | Dart type | Nullable? | ✓ |
|---|---|---|---|---|
| `id` | `string` | `String` | no | ☐ |
| `booking_todo_id` | `string` | `String` | no | ☐ |
| `title` | `string` | `String` | no | ☐ |
| `subtitle` | `*string` | `String?` | yes | ☐ |
| `url` | `*string` | `String?` | yes | ☐ |
| `provider` | `*string` | `String?` | yes | ☐ |
| `notes` | `*string` | `String?` | yes | ☐ |
| `image_url` | `*string` | `String?` | yes | ☐ |
| `price` | `*float64` | `double?` | yes | ☐ |
| `currency` | `*string` | `String?` | yes | ☐ |
| `start_date` | `*string` (YYYY-MM-DD) | `String?` | yes | ☐ |
| `end_date` | `*string` | `String?` | yes | ☐ |
| `origin` | `*string` | `String?` | yes | ☐ |
| `destination` | `*string` | `String?` | yes | ☐ |
| `mode` | `*string` | `String?` | yes | ☐ |
| `chosen` | `bool` | `bool` | no | ☐ |
| `promoted_accommodation_id` | `*string` | `String?` | yes | ☐ |
| `promoted_segment_id` | `*string` | `String?` | yes | ☐ |
| `position` | `int32` | `int` | no | ☐ |
| `saved_at` | `string` (RFC3339 Z) | `String` | no | ☐ |

`TripResponse` gains `booking_options` → `[]BookingOptionResponse` /
`List<BookingOption>?`, `omitempty`, editor-only.

`ChooseBookingOptionResponse`: `option` (object), `options` (array),
`booking_todo` (object), `accommodation`/`segment` (object, one or neither),
`replaced_option_id` (`*string`/`String?`), `expense` (object, nullable),
`expense_skipped` (`*string`/`String?`, one of `no_budget|no_price|
currency_mismatch`).

`LinkPreview`: `ok` (`bool`/`bool`), `url` (`string`/`String`), `title`,
`description`, `image_url`, `site_name`, `provider`, `currency`, `reason`
(all `*string`/`String?`), `price` (`*float64`/`double?`).

## Verification

- `make api-fmt && make api-vet` clean; `make api-sqlc` regenerates cleanly.
- `go test ./...` — `booking_option_integration_test.go` (14 outcome tests) and
  `link_preview_test.go` (guard + parser).
- Manual via the lane gateway: save two options on a leg, choose one, confirm
  the stay lands under its city rather than in "Other bookings", delete the
  stay and confirm the option un-chooses while the leg stays booked.
