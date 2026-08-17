# Spec: Daily food & drink budget, per city

> **WHAT & WHY only.** No tech choices, file names, libraries, or code.

## Context

The Budget tab can now tell a **plan** from a **payment** (specs/budget-planned-vs-paid),
but a traveler still has to invent every planned number from nothing. The one
line everybody guesses at is food: it is the largest uncommitted cost of a trip
and the only one with no booking to autopopulate it. Both earlier budget specs
deferred exactly this — *"Per-category targets, per-day budgets"* sits in the
Out-of-Scope list of `budget-v2` and `budget-planned-vs-paid`.

So the Budget tab grows a **Daily food & drink** section: one row per city on
the trip, with a per-person daily estimate for that city, and one tap to file
`rate × nights × travelers` as a planned food expense.

Asking a chatbot "what should I budget for food in Rome?" gets you a number you
then retype. The point here is that the number lands *in* the budget, raises the
trip's projection, and the real receipts then accumulate against it as variance
with no typing. That comparison is the thing planned-vs-paid was built for and
currently has nothing to compare against.

**The number is an estimate, and the feature says so.** There is no free,
global, currency-denominated meal-price source to look one up in, and the place
data this app already buys returns an ordinal price *level*, not money. Rather
than skip the feature or take on a paid data subscription for one figure, the
estimate is produced by the app's own light model and is labelled as an estimate
everywhere it appears.

## User Stories

- As a **trip owner planning ahead**, I want a realistic daily food & drink
  figure for each city on my trip, so my budget reflects the largest cost that
  has no booking to fill it in.
- As a **trip owner**, I want to accept a suggestion in one tap, so the estimate
  becomes a planned line I can track against instead of a number I retype.
- As a **traveler with a spending style**, I want the suggestion to match how I
  actually eat, and to see which level produced it.
- As a **traveler with company**, I want the figure to cover everyone eating,
  not just me.
- As a **traveler**, I want to know this is an estimate and never mistake it for
  a looked-up price.

## Acceptance Criteria

- [ ] The Budget tab shows a **Daily food & drink** section listing one row per
      city on the trip, each with that city's nights and a per-person daily
      amount in the budget's currency.
- [ ] The section states, every time it renders, that the figures are typical
      local prices per person and an estimate rather than a quote.
- [ ] A city's nights match the nights shown on that city's header on the
      Itinerary tab, and the per-city nights add up to the trip's own length.
- [ ] The spending level is resolved from the traveler's saved budget level when
      they have one, and the section says when that is what produced it. It can
      be changed for the trip without altering the saved profile.
- [ ] A travelers count on the section multiplies every city's total. It starts
      at one and is never inferred from the traveler's profile.
- [ ] "Add to plan" files that city's total as a **planned** food expense: the
      planned total and the projection rise, and the spent total does not.
- [ ] Accepting a city's suggestion twice never produces two lines — the second
      attempt returns the line that already exists.
- [ ] A city already in the plan shows the amount on that line (including one the
      traveler has since edited), not the suggestion, and offers no add button.
- [ ] A food expense that is not tied to a city — including one whose label
      happens to name the same city — is never mistaken for that city's plan.
- [ ] The section is absent entirely for viewers, offline, and whenever no
      estimate could be produced. Nothing errors, and no other part of the
      Budget tab changes.
- [ ] Every existing budget number keeps its exact meaning; a trip that never
      uses this feature renders identically to before.
- [ ] Budget amounts remain single-currency per trip; no FX conversion.
- [ ] English and Spanish both fit a 360px phone.

## API Surface

**Read the daily spend guide for a trip** — new.
- **Request:** the trip, plus optionally the spending level to price at.
- **Response:** the budget's currency; the **resolved** spending level and what
  resolved it (a stated one, the saved profile, or the default); the basis of
  the figures; and one entry per city — its identity, its display label, its
  nights, the per-person daily amount, and a short phrase naming the meals the
  amount covers.
- **Behaviour:** editor-only, since accepting a suggestion is a write and
  producing one costs a model call. It **degrades rather than errors**: no
  configured model, an upstream failure, or a trip with no dated cities all
  answer normally with an empty city list and a stable reason code.
- **Errors:** only a spending level the caller named that we do not recognize.

**Add an expense** — extended to optionally carry **which city leg** the line
plans for.
- **Behaviour:** the server confirms the city against the trip's real cities and
  refuses one it does not recognize. A second add for a city that already has a
  line returns the existing line untouched — never a duplicate, never an error.
  A city plan cannot also be a booking-linked line; requests naming both are
  refused. Such a line is traveler-owned, never system-managed.
- **Response:** unchanged, plus the city the line belongs to.

**Edit an expense** — unchanged. There is deliberately **no way to move a line
to another city**, in the same way there is no way to erase a plan.

## Data Model

An expense line may name **the city leg it plans for**. The reference is a
snapshot, not an enforced relationship: if that city is renamed or dropped from
the trip, the line simply becomes an ordinary food expense and the suggestion is
offered again. At most one line per city per category.

The suggestion itself is **not stored**. It is looked up, cached for a long
while because city food costs move slowly, and only becomes durable data when a
traveler accepts it — at which point it is an ordinary planned expense they own
and can edit or delete.

## UI Behavior

- **Screen / surface:** the Budget tab of a trip, below the totals and above the
  add-expense row — it is an input to planning, and it must never push the real
  numbers down the page.
- **Happy path:** the traveler opens Budget on a dated multi-city trip, sees a
  row per city with a rate and a total, adjusts the travelers count and the
  spending level if they want, and taps "Add to plan" on the cities they care
  about. Each becomes a planned food line in the list above.
- **States:**
  - *Loading* — nothing. There is no section until there is an answer; a
    suggestion is not worth a spinner over someone's money.
  - *Empty / unavailable* — nothing, for every reason.
  - *Accepted* — that city shows the amount on its line instead of a button.
  - *Read-only or offline* — nothing.

## Edge Cases & Error States

- A city the model does not recognize, or answers with an implausible figure, is
  **dropped** — never given a neighbouring city's number or an average.
- A city with no dates, or a pass-through with no nights, is not listed: there is
  no day of eating to plan for and no total to file.
- A trip with no budget currency set uses the same default the rest of the
  Budget tab does.
- Accepting a suggestion when the trip is already at its expense cap fails the
  way the add row already does.
- A stale tab naming a city the trip no longer has is refused rather than filed.

## Out of Scope

- A chat-agent tool for this — still the budget-v2 agent-tools follow-up.
- Daily budgets for anything but food & drink.
- Per-category budget targets.
- Persisting the chosen spending level or the travelers count.
- Multi-currency budgets or FX conversion.
- Replacing the estimate with a paid cost-of-living data source. The basis is
  carried explicitly so this can change later without changing meaning silently.

## Open Questions

None. Data source, payoff, tier resolution, party size and the nights-vs-days
multiplier were all settled with Brian before implementation.
