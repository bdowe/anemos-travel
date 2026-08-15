# Spec: Bag-aware flight pricing

## Context

A traveler booked the cheapest flight the planner found and then paid an extra
€53 at the airline for a personal item and a carry-on. The fare we quoted was a
bare fare, so the option we ranked cheapest was not the cheapest thing to buy.

The app already knows how to rank on a total that includes the bag — it just
never does it: the default bag tier is "personal item", which skips bag pricing
entirely, and nothing anywhere records what this traveler actually flies with.
Meanwhile the live flight-data source *can* fold a cabin-bag fee into the price
it quotes, and we don't ask it to.

This feature stores the traveler's bag habit on their travel profile and prices
every flight search for the bags they actually bring — and, wherever a fee can't
be priced, says so instead of quietly leaving it out.

## User Stories

- As a **traveler who always brings a carry-on**, I want flight prices to
  already include the cabin-bag fee, so the option the planner calls cheapest is
  the one that's actually cheapest to buy.
- As a **traveler**, I want to tell the app once what I fly with, so I don't
  have to repeat it in every conversation.
- As a **traveler who checks a bag**, I want to be told plainly when a
  checked-bag fee could not be included in a quote, so I'm not surprised at the
  airport.
- As a **traveler who really does fly with one small bag**, I want to say so and
  see the bare fares, so the app doesn't inflate every price for me.

## Acceptance Criteria

- [ ] The travel profile has a bag setting with three choices — personal item /
      carry-on / checked bag — that persists and reloads.
- [ ] The signup quiz asks it too, as a skippable step.
- [ ] Telling the planner in chat ("I only ever fly carry-on") saves it to the
      profile, and it survives into later conversations.
- [ ] A flight search run without stating a tier is priced for the traveler's
      saved setting; with no saved setting, it is priced for a carry-on.
- [ ] With the current data provider, a carry-on search returns prices that
      include the cabin-bag fee where the airline charges one, and those prices
      differ from the personal-item prices for the same route.
- [ ] Every flight result the planner quotes states what the price covers
      (one-way/round-trip, party size — already true — **and now bags**).
- [ ] A checked-bag search states plainly that the checked-bag fee is not
      included and could not be priced. No estimated fee is ever invented.
- [ ] The flight search screen pre-selects the traveler's saved tier, names the
      tier in its collapsed summary line, and shows the checked-bag caveat when
      it applies.
- [ ] A tier the planner sends that isn't one of the three is rejected rather
      than silently treated as some other tier.

## API Surface

### `POST /api/v1/flights/search`
- **Request:** unchanged except that `baggage` — `personal_item` | `carry_on` |
  `checked` — now defaults to **carry-on** when omitted (it defaulted to
  personal item). An unrecognized value is still a 400.
- **Response:** `baggage` echoes the tier the results were actually priced for.
  New optional `baggage_note` carries a stable code (not prose) when something
  about the request could not be priced — currently only "the checked-bag fee
  could not be included". Each offer keeps `baggage_status` / `bag_fee` /
  `effective_price`, and `baggage_status` gains a value meaning **the quoted
  price already covers the bag, without itemizing the fee**.

### `PUT /api/v1/preferences`
- **Request/Response:** one new optional field for the bag setting, same
  omitted-means-keep semantics as every other preference.

### `search_flights` (planner tool)
- Omitting the bag tier means "use the traveler's saved setting"; stating one
  means the traveler said so for this trip. The result text states the bag basis
  of the prices it lists.

### `save_preferences` (planner tool)
- Learns and stores the bag setting like any other durable traveler fact.

## Data Model

- **Traveler preferences** gain **bag setting** — what this traveler usually
  flies with. Optional; absent means "never said", which is priced as a
  carry-on rather than pretending they carry nothing.
- **Flight offer** — `baggage_status` describes the *quoted price*, not the
  fare: free-in-fare, we-added-a-known-fee, already-covered-by-the-quote, or
  not-covered-and-unpriceable. The first three all mean "this total is what
  you'd pay"; only the last is a warning.

## UI Behavior

- **Settings → travel profile:** a three-choice row with a one-line
  explanation, beside the existing pace/budget/work-style rows.
- **Signup quiz:** the same row as one more skippable step.
- **Flight search screen:** the existing bag chips pre-select the saved setting;
  the collapsed summary row names the tier that produced the results; a
  checked-bag caveat renders above the results when the provider couldn't price
  it. Cards show that the price covers the bag.
- **Chat:** unchanged in shape (a count chip, no prices) — the planner's prose
  carries the bag basis, because that prose is the traveler's only record of
  what a quote covers.

## Edge Cases & Error States

- No saved setting → carry-on. Stated in the result, never silent.
- Provider can't price the requested bag (checked bags outside US domestic) →
  price what it can, name what it couldn't. Never estimate.
- Provider fails entirely → unchanged: the existing deep-link degrade path.
- A tier the planner invents → rejected, falls back to the saved setting.
- A cached search must never serve prices priced for a different tier.

## Out of Scope

- Carrying a searched offer's price into the trip budget (the booked-expense
  amount is still typed by hand) — that belongs to the booking-shortlist UI.
- Itemizing the cabin-bag fee: the provider returns a bag-inclusive total, not a
  breakdown.
- Pricing checked bags on international routes — the provider cannot.
- Showing prices on the chat's flight chip.
