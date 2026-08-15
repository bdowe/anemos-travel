# Tasks: Booking shortlist

> Dependency-ordered. `[P]` = parallel-safe with its siblings.

## API (Go) — lane `booking-shortlist-api`, THIS PR

- [x] Migration `00065_booking_options.sql` (reserved; 00058 stays burned)
- [x] `query/booking_options.sql` + `GetBookingTodo` + the demote predicate +
      `PromoteAccommodationFromOption` / `PromoteSegmentFromOption`
- [x] `make api-sqlc`
- [x] `booking_option_handler.go` — CRUD, validation, per-leg/per-trip caps
- [x] `booking_option_choose.go` — the choose/un-choose transaction
- [x] Extract `upsertLinkedExpense` from `addExpenseHandler` and consume it
- [x] `booking_options` on `TripResponse`, behind the viewer boundary
- [x] `link_preview.go` + `link_preview_handler.go` with the SSRF guard
- [x] Routes, own rate-limit bucket, startup log lines
- [x] Caps in `validation.go`; `booking_options` in `resetDB`
- [x] Integration tests (14) + link-preview tests
- [x] `make api-fmt`, `make api-vet`, full `go test ./...`

## UI (Flutter) — follow-up lane, BLOCKED

Blocked on `trip-airports-on-page`, which currently holds
`trip_detail_screen.dart`, `trip_detail_derivation.dart`,
`booking_todo_card.dart` and both `.arb`s (`docs/parallel-dev.md` §3: ≤1 lane
per wave on the god-screen). Start once it merges.

- [ ] `models/booking_option.dart` + `bookingOptions` on `Trip`; `make
      flutter-build-models`
- [ ] Complete the Contract Parity table in `plan.md` (every row ✓)
- [ ] [P] `services/booking_options_api_service.dart`
- [ ] [P] `services/link_preview_api_service.dart`
- [ ] `openOptionsFor` on `TripDerivation` — **including the `matches()` line**,
      or option edits render stale silently
- [ ] `widgets/booking_option_row.dart`; promote `kBookingRowDetailIndent` and
      share it with `BookingDetailRow`
- [ ] "N saved" affordance on the subtitle line of `BookingTodoRow` **and**
      `BookingTodoCard` (demoted legs render as the card)
- [ ] `widgets/booking_option_sheet.dart` — paste-URL → preview → prefill
- [ ] `_bookingOptions` + `_expandedOptionLegs` (keyed by `todoKey`) in
      `trip_detail_screen.dart`; rows emitted inside `_bookingRowWidgets`;
      `_chooseOption` calls `_invalidateReview()` and never `_setRowBooked`
- [ ] "Considering" projection in `BudgetSection` — min/max per leg, currency
      mismatches named not summed
- [ ] `amount` on `BookedExpensePrefill`
- [ ] `onSave` on `FlightOfferCard`; `saveTarget` on `FlightSearchScreen`
- [ ] l10n under the `bookingOption*` prefix; regenerate localizations LAST
- [ ] Widget tests; `make flutter-analyze`; `make flutter-test`

## Lanes

| Lane | Branch | Tasks | Migration # | Registry tail? | ARB key prefix | trip_detail? | Depends on |
|------|--------|-------|-------------|----------------|----------------|--------------|------------|
| A | `booking-shortlist-api` | API section | **00065** | no | — | no | — |
| B | `booking-shortlist-ui` | UI section | — | no | `bookingOption` | **yes** | A (contract) + `trip-airports-on-page` releasing the screen |

**Conflict manifest (lane A, this PR)** — existing files touched:
`main.go`, `trip_handler.go`, `budget_handler.go`, `validation.go`,
`integration_test.go`, `query/booking_todos.sql`, `query/accommodations.sql`,
`query/segments.sql`, `store/*` (regenerated, never hand-merged).
