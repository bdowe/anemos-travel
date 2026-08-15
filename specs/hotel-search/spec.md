# Spec: Hotel Search

> **WHAT & WHY only.** No tech choices, file names, libraries, or code.

## Context

Every other thing a traveler can ask this app about is backed by real data —
flights, events, ferries, places, weather, local picks. Lodging is not. The
only stay tool hands back two generic browse links, so when a traveler asks
*"find me a well-rated hotel in Athens for Sep 3–7 under €150"* the assistant
has nothing to look up and says so. Worse, the app's own "you still need a
place to stay" prompt asks the assistant for *"a few good lodging options at a
couple of price levels, well located for my itinerary"* — something the tool
behind it structurally cannot produce, so the assistant either declines or
invents. This closes the gap: real properties, real nightly rates for the
traveler's real dates, in the chat surface they already use. It is also the
one booking handoff that earns anything (`docs/business-model.md`), and today
that handoff renders nothing at all.

## User Stories

- As a **traveler**, I want to ask for hotels in a city for my dates and see
  real properties with real nightly prices, so I can judge what a trip will
  actually cost.
- As a **traveler**, I want to filter by what I care about — budget ceiling,
  rating — so the list is short enough to decide from.
- As a **traveler**, I want to ask "where should I stay in Athens?" before I
  have dates and still get useful, well-reviewed suggestions.
- As a **traveler**, I want to tap a hotel and land on a booking site with my
  dates already filled in.
- As a **traveler**, I want to put a stay I like onto my trip without
  re-typing its name.
- As a **traveler**, I want to be told plainly when prices could not be
  checked, so I never mistake a suggestion for a quote.

## Acceptance Criteria

- [ ] Asking for hotels in a city **with** check-in/check-out returns real
      named properties with a nightly rate, a total for the stay, a star
      class, a rating and a review count.
- [ ] Prices are shown in one stated currency, and that currency is named
      wherever a price appears.
- [ ] Asking **without** dates still returns real, well-reviewed properties —
      with no prices, and an explicit statement that prices were not checked.
- [ ] The assistant never states or estimates a nightly price for a result
      that came back without one.
- [ ] Results appear as a horizontal card rail in chat, the same card system
      the places and events rails already use.
- [ ] Tapping a card opens a booking site prefilled with the destination and,
      when known, the dates.
- [ ] A result can be added to the open trip as a stay, and it then appears on
      the trip detail page.
- [ ] When the upstream rate provider is unavailable or the day's search
      allowance is spent, the traveler still gets the no-prices tier rather
      than an error.
- [ ] Hotel searching can never exhaust the allowance that flight search
      depends on.
- [ ] The existing browse-links tool renders something visible in chat
      instead of silently producing nothing.

## API Surface

### `GET /api/v1/hotels/search`
- **Purpose:** find stays in a city, with rates when dates are supplied.
- **Request:** `city` (required). `check_in`/`check_out` (`YYYY-MM-DD`,
  optional but required *together* — one without the other is rejected;
  supplying both is what unlocks rates). `adults` (optional, default 2).
  `currency` (optional). Optional budget ceiling and minimum rating.
- **Response:** a list of stays, plus a flag saying whether the list carries
  live rates and, when it does not, a reason. Each stay carries: name, kind
  (hotel or vacation rental), star class, rating, review count, nightly and
  total rate when known, currency when a rate is present, coordinates,
  address or neighbourhood, image URL, amenity highlights, check-in/out
  times, and a booking URL.
- **Errors:** missing `city` → 400. Only one of the two dates → 400. Dates
  that are not real dates, or a check-out on/before check-in → 400. Upstream
  failure never surfaces as an error — it degrades to the no-rates tier.

## Data Model

Nothing is persisted. A **Stay** is a live lookup result, held only for the
turn that produced it, in one shape regardless of which tier answered — so
that the assistant, the card rail and the tool result can never disagree
about what a result is.

- **Stay** — a property offered for the requested nights. Rate and currency
  are **inseparable**: a number with no currency is a number nobody can
  compare, and this app does no currency conversion anywhere. Both are
  absent together on the no-rates tier. `kind` distinguishes a hotel from a
  vacation rental because they are not interchangeable to a traveler.
- **Rates-live flag** — a property of the *result set*, not of a stay: it
  states which question the search actually answered. It is not inferable
  from whether a price happens to be present, and must not be.

## UI Behavior

- **Surface:** the chat result rail, alongside the existing places, local
  picks, events and parking rails.
- **Happy path:** traveler asks for hotels → rail of cards, each showing the
  property photo, name, star class, rating, and nightly rate → tap opens a
  booking site → an add action puts it on the trip.
- **States:** *loading* — the existing working indicator. *Success with
  rates* — price on every card. *Success without rates* — no price, and the
  rail says prices were not checked. *Empty* — the assistant says so in
  prose; no empty rail is drawn. *Error* — never shown for a provider
  failure; that degrades instead.

## Edge Cases & Error States

- One date without the other → rejected, rather than guessing a stay length.
- Check-out on or before check-in → rejected.
- Dates in the past → allowed through to the provider, which is authoritative
  about what it will price.
- A city the provider does not recognise → empty result, not an error.
- Provider outage or spent allowance → the no-rates tier, stated plainly.
- Results mixing hotels and vacation rentals → both shown, each labelled.
- Paid placements in the provider's response are excluded.

## Out of Scope

- In-app booking or payment. We link out; we are not a merchant of record.
- Saving candidates to the per-leg booking shortlist. That is the natural
  home for a hotel a traveler is weighing, but its trip-page surface does not
  exist yet, so saved candidates would render nowhere.
- Per-property availability calendars, room types, or rate breakdowns.
- Any change to how the existing browse-links tool is described to the
  assistant.

## Open Questions

None outstanding. Data depth, tap behaviour, and allowance posture were
decided before implementation.
