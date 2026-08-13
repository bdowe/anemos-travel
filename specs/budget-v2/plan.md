# Plan: Budget v2 — top-level tab + autopopulate on booking

> **HOW.** See `spec.md` for what/why. Repo conventions: `../../CLAUDE.md`,
> `../../docs/zen.md`. Delivered as **two stacked PRs from one lane**
> (`budget-v2`): PR A = tab promotion + read/refresh fixes, PR B =
> autopopulate. Migration **00058** is reserved for PR B.

## Technical Approach

Promote the existing self-contained `BudgetSection` to the third arm of the
trip-detail view switch, keeping the screen's derived-selection invariant
(selection is computed from the single `_itemFilter` string every build —
`'budget'` becomes a new value; **no stored tab index**). Autopopulate hooks
the one lockstep booked-writer (`_setRowBooked`) after its PATCHes succeed and
records the expense through an upsert-by-source POST, with linkage made a DB
invariant (partial unique index) rather than a read-then-write. The reserved
`trip_expenses.auto` column (00042) gains its contract: `auto=true` =
system-managed mirror of the source row's booked state (unbook deletes);
user edit of category/label/amount flips it false (manual takeover; unbook
then leaves it). Server rules, never client-writable — Zen: semantics live in
the schema/handler, not conventions.

## PR A — Budget tab

**Go** — `budget_handler.go`: the two GET handlers switch `editableTrip` →
`viewableTrip` (viewer 404 bug); mutations unchanged; header comment updated.
`budget_integration_test.go` gains the viewer-GET-200 assertions its comment
already claims.

**Flutter** — `trip_detail_screen.dart`:
- `_inBudgetView => _itemFilter == 'budget'`; third `_headerTab` labeled
  `budgetTitle`; Itinerary `selected: !_inBookingsView && !_inBudgetView`.
- Gating: editors always (never load-state-dependent); viewers when budget
  non-empty OR already on the tab (anti-stranding). Place-less trips render
  an Itinerary | Budget pair (Bookings' view can't render there); if Budget
  is also gated off → plain title as today.
- `_scrollToDay` force-exit covers Budget; add-CTA slot empty in Budget view;
  body chain gains an `else if (_inBudgetView)` plain-box sliver (no pinned
  header → zero-body hazard never arises; `_listHeaderHeight` untouched);
  `trip_detail_derivation.dart` maps `'budget'` to the all-items arm;
  trailing cluster gated `!_inBudgetView` and shrunk to packing-only;
  `_budgetSectionRow` deleted.
- `budget_section.dart` upgraded in place: `showHeader` retired, spend
  headline + `LinearProgressIndicator` (error color when over), viewer-empty
  EmptyState, category dropdown items get icon+label (closed state icon-only).
- Fixes: `_refresh()` invalidates both budget providers; the two target
  dialogs unify into `showBudgetTargetDialog` (invalidates both providers;
  health `raise_budget` fix gains currency editing).
- l10n: no new required keys; orphans (`tripSetBudgetTarget`,
  `tripBudgetTargetLabel`, `tripBudgetTargetHint`, `budgetSummaryEmpty`)
  deleted from both arbs; regen LAST.
- Narrow-fit contingency: narrow tests gain a TextPainter no-truncation
  assertion; if 390px Spanish truncates, the Bookings tab drops its `· n/m`
  counter on narrow only.

## PR B — Autopopulate

**Migration 00058** (`00058_expense_booking_link.sql`): `trip_expenses` +
nullable `source_kind text` + `source_id uuid` (no FK — snapshot pattern),
CHECK both-or-neither, partial unique index
`(trip_id, source_kind, source_id) WHERE source_kind IS NOT NULL`.

**Go**: `CreateExpense` gains auto/source; new `GetExpenseBySource`;
`UpdateExpense` gains `auto` narg (`make api-sqlc`). POST upsert-by-source:
exists&auto → update 200; exists&!auto → untouched 200; else create 201
(cap on create only; unique-violation race → re-lookup). PATCH touching
category/label/amount sets `auto=false` (position-only doesn't). Server-side
`recordEvent("expense_added", {category, auto, source_kind?})` on create.

**Flutter**: `Expense` + sourceKind/sourceId (build_runner); `addExpense`
gains link params, accepts 200|201, throws `ApiException`; category constants
lift to `lib/widgets/budget_categories.dart`; new
`lib/widgets/booked_expense_prompt.dart` (pure `deriveBookedExpensePrefill` —
confirmed record beats todo; stay→lodging+name, segment→flights|transport+
"origin → destination", todo by kind/mode — plus the Save/Skip dialog with
autofocused amount labeled with the budget currency). Wire:
`_maybePromptBudgetExpense` after `_setRowBooked`'s `Future.wait` succeeds
(false→true only, dedupe by linked ids first, Undo snackbar deletes);
`_removeLinkedAutoExpense` on true→false (auto rows only, best-effort);
health `mark_booked` fix gets the same prompt and its Undo removes the
expense. `AddSegmentSheet` gains the `price_note` field (droppable). l10n:
`budgetPrompt*` keys, both arbs.

## Verification

Per approved plan: `flutter analyze` + full `flutter test`; `make api-sqlc`,
`go vet`, `make test-db && make api-test-go`, `make api-test`; manual 390px
Spanish pass, viewer share link, booked-flip → expense → unbook round trip.

## Follow-ups (out of scope)

Agent tools `log_expense` / `set_budget_target` (registry lane, 5 test pins);
flight-offer price prefill (stash last "Book"-tapped offer).
