# Spec: Budget v2 — top-level tab + autopopulate on booking

> **WHAT & WHY only.** No tech choices, file names, libraries, or code.

## Context

Budget shipped as an honest v1 (wave 15): a collapsed row at the very bottom
of the trip screen, manual entry only, disconnected from the bookings the
traveler already tracks there. In practice it stays empty — the row is out of
sight, and every price a traveler confirms (a flight, a stay) has to be
retyped by hand into a different part of the screen. Budget v2 makes spend
tracking a first-class view of the trip and captures prices at the moment the
traveler already has them in hand: the instant they mark something booked.

## User Stories

- As a **trip owner**, I want the budget to be a top-level view beside
  Itinerary and Bookings so that my spending is as visible as my plans.
- As a **trip owner**, I want the app to ask for the price right when I mark
  a flight/stay/transport as booked so that my budget fills itself as I book.
- As a **trip owner**, I want an expense created from a booking to disappear
  if I un-book it (unless I've edited it myself) so the budget mirrors
  reality without double entries.
- As a **viewer of a shared trip**, I want to see the trip's budget read-only
  so I understand the trip's costs.

## Acceptance Criteria

- [ ] Trip detail shows an **Itinerary | Bookings | Budget** tab row; the
      Budget view shows target + progress toward it, per-category groups,
      the expense list, and an add-expense row.
- [ ] The three tabs fit a 390px-wide phone in both English and Spanish
      without truncation.
- [ ] The bottom-of-page Budget row is gone; Packing remains.
- [ ] On a trip with no places yet, the Budget view is still reachable.
- [ ] Ticking a booking row "booked" opens a small **Add to budget?** dialog
      with the amount focused, the category pre-picked (flight→Flights,
      stay→Lodging, other transport→Transport), and the label prefilled from
      the booking. Save adds the expense; Skip adds nothing. The booked state
      itself is never blocked by the dialog.
- [ ] The created expense is marked as system-added and linked to its
      booking: re-ticking the same booking never creates a duplicate.
- [ ] Un-ticking the booking removes that expense — unless the traveler had
      edited it (category/label/amount), in which case it stays.
- [ ] A collaborator with view-only access can open the Budget view and see
      target/expenses, with no edit affordances (today this 404s).
- [ ] Pull-to-refresh (and a collaborator's edit) refreshes budget numbers.
- [ ] Budget amounts remain single-currency per trip; no FX conversion.

## API Surface

### `GET /trips/{id}/budget`, `GET /trips/{id}/budget/expenses`
- **Change:** readable by anyone who can view the trip (owner, editor, or
  viewer). Mutations remain editor-only.

### `POST /trips/{id}/budget/expenses`
- **Change:** accepts an optional **source link** (the kind and id of the
  booking row that spawned the expense — booking todo, accommodation, or
  transport segment). Both fields together or neither; unknown kinds and
  malformed ids are rejected.
- **Behavior:** a linked create marks the expense system-added. Re-posting
  the same link updates the existing expense if still system-added, and
  leaves it untouched if the traveler has taken it over — never a duplicate,
  never an error. Responses expose the link fields.
- **Errors:** unchanged (per-trip expense cap, validation).

### `PATCH /trips/{id}/budget/expenses/{expenseId}`
- **Change:** any edit of category, label, or amount flips the expense to
  traveler-owned (reordering does not). Not a client-settable field.

## Data Model

An expense may carry a reference to the booking row it was created from
(which kind of row, and which one). The reference is a snapshot, not an
enforced relationship: deleting the booking leaves the expense as a plain
line item. The existing "auto" marker now means exactly: *system-managed
mirror of the source row's booked state* — created when booked, removed when
un-booked, and released to the traveler on their first edit. At most one
expense per booking row per trip.

## Non-Goals

- Multi-currency budgets or FX conversion.
- Chat-agent budget tools (`log_expense`, `set_budget_target`) — follow-up.
- Prefilling the amount from a flight offer the traveler viewed — follow-up.
- Parsing free-text price notes into expenses.
- Per-category targets, per-day budgets, URL persistence of the selected tab.
