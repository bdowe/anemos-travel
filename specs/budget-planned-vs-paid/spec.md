# Spec: Planned vs paid expenses

> **WHAT & WHY only.** No tech choices, file names, libraries, or code.

## Context

The Budget tab tracks one number per expense and calls the total "Total spent".
Every expense is money already gone — 00065 states it outright: *"an expense is
money already spent."* But before a trip the only thing a traveler can enter is
an **estimate**, so those estimates are silently filed as spend, and the
question that motivated this cannot be answered:

> "how much money I plan to spend vs what I actually spend when it's all said
> and done" — Brian, 2026-08-15

A status an expense *leaves* on purchase cannot answer it: at the end of a trip
everything is bought, so a planned total defined that way collapses to zero and
there is nothing left to compare. **The plan has to survive the purchase.**

Wording, defaults and backfill were decided with Brian before implementation:
**Planned / Paid**; new expenses default to **Planned**; existing expenses all
become **paid**.

## User Stories

- As a **traveler planning a trip**, I want to type what I expect each thing to
  cost, so the Budget tab reflects my plan without claiming I already spent it.
- As a **traveler mid-trip**, I want to mark a planned line paid — for what I
  actually paid — so I can see where I stand and where I am heading.
- As a **traveler after the trip**, I want to see what I planned against what I
  spent, per line and in total, including money I spent that I never planned.
- As a **traveler**, I want the numbers I already trust (Total spent, the trips
  list pill, the printed packet, the over-budget warning) to keep meaning
  exactly what they meant before.

## Acceptance Criteria

- [ ] An expense carries up to two amounts — planned and paid — and at least
      one is always present.
- [ ] A line's planned amount is never destroyed by marking it paid, by paying
      a different amount, by un-paying it, or by any booking-state change.
- [ ] The Budget tab shows a planned total, a spent total, and — once at least
      one line has both numbers — how far over or under plan the trip is.
- [ ] The planned total does **not** shrink as lines are paid.
- [ ] Money spent that was never planned shows up as a gap between planned and
      spent, not absorbed into the plan.
- [ ] A line shows both numbers only when they differ.
- [ ] `spent` keeps its exact current meaning everywhere it is already shown:
      the tab headline, the trips-list pill, the printed packet, and the
      over-budget health warning.
- [ ] Every expense that exists today reads as paid, and every total on every
      screen is unchanged on the day this ships.
- [ ] Any of those rows can be re-tagged as planned in one tap, reversibly.
- [ ] Marking a booking booked records what it cost as **paid**, and preserves
      any plan already on that line.
- [ ] Un-booking never destroys a plan.
- [ ] Trip health warns — gently, and only when nothing has actually been
      overspent yet — when the trip's projection already exceeds the target.
- [ ] Budget amounts remain single-currency per trip; no FX conversion.
- [ ] A traveler with a viewer role sees the full planned-vs-paid story,
      read-only.

## API Surface

**Record what a line actually cost** — new.
- Request: the expense, plus optionally the amount paid. Omitting the amount
  means "paid exactly what I planned."
- Response: the expense in its post-state, including both amounts and whether
  it is now paid.
- Errors: no amount given and no plan to fall back on; unknown expense;
  read-only or non-collaborator.

**Un-pay a line** — new.
- Request: the expense.
- Response: the expense, still carrying its plan.
- Errors: the line has no plan (un-paying would leave it with no amount at all
  — delete it instead); unknown expense; read-only.

**Add / edit an expense** — extended to carry the two amounts. The single
legacy amount keeps working and keeps meaning money spent, so a cached app
bundle behaves exactly as before.

**Read the budget** — extended with a planned total, a projected total (what
the trip costs if every unpaid line lands at its plan), and how far the paid
lines came in over or under their plans.

## Data Model

An expense line gains **what I meant to spend** and **what it cost**. Either
may be absent; never both. "Paid" is not stored separately — a line is paid
exactly when it has an amount paid.

A plan, once stated, is history: there is deliberately **no way to erase one**
through the API. Delete the line if you want it gone.

## UI Behavior

**Screen-surface:** the Budget tab of a trip.

**Happy path:** the traveler types estimates before the trip (planned by
default, sticky); as things get bought they mark each line paid, adjusting the
amount when it differs; the summary tracks spend against the target with the
still-committed remainder shown behind it, and reports the over/under against
plan.

**States:**
- *Nothing tracked* — unchanged from today, plus the planned/paid choice.
- *All planned* — spend reads zero; the projection carries the story.
- *Mixed* — paid lines and planned lines coexist inside each category group.
- *All paid* — the plan is still there to compare against.
- *No plan anywhere* (including every trip that exists today) — the tab renders
  exactly as it does now.

## Edge Cases & Error States

- A line that was planned at zero (a free walking tour) must stay distinct from
  a line that was never planned.
- Un-paying a line that never had a plan converts it to planned at the amount
  paid rather than failing at the traveler.
- A booking-created line is a purchase by definition; its paid amount belongs
  to the booking (un-booking clears it) while its plan belongs to the traveler
  (un-booking keeps it).
- Offline, read-only, and stale-bundle paths must degrade to today's behavior
  rather than to an error.

## Out of Scope

- Multi-currency budgets or FX conversion.
- Chat-agent budget tools (`log_expense`, `set_budget_target`) — still a
  budget-v2 follow-up. The agent gets the new totals for free through the
  existing trip-review tool.
- Per-category targets, per-day budgets.
- The booking shortlist's "considering" projection — a separate, already-specced
  lane that joins the same summary later.
- Parsing free-text price notes into expenses.

## Open Questions

None. Wording, add-row default, backfill direction, and scope beyond the Budget
tab were settled with Brian before implementation.
