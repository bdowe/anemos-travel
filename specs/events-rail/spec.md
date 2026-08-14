# Spec: Events rail on the trip detail page

## Context

Dogfooding, 2026-08-14: on the trip detail Itinerary tab, a 3-night Berlin leg
whose plan was two rows (the inbound flight and the stay) carried five
full-width event suggestion cards under them — roughly 470px of listings under
120px of plan, repeated for every city on an 8-stop trip. Scrolling the trip
had become scrolling a listings page.

Tracing it turned up a second, worse problem underneath. Every one of those
five events fell on Fri Sep 4 — the day the traveler leaves Berlin — while the
leg header above them read "Sep 1 – Sep 4 · 3 nights". The section was not
clustering; it had only *asked* about Sep 4. The header renders one derivation
of "when am I in this city" and the events lookup used a different one, so a
section promising "Events while you're here" queried dates the traveler was
never shown. Verified against the live API: the same city and the header's own
window returns 14 events spread across all four days.

Events are a live per-city lookup and are never persisted — they are
suggestions until the traveler adds one to the trip. The page did not express
that; it gave them the weight of committed plan rows.

## User Stories

- As a traveler, I want the events for a city to be **for the dates I'm
  actually there**, so a section titled "while you're here" is telling me the
  truth.
- As a traveler, I want suggestions to **take less room than my plan**, so the
  itinerary still reads as my trip.
- As a traveler, I want the handful I'm shown to **cover my whole stay**, not
  whichever single day happens to be busiest.
- As a traveler, I want to know **how many events were found** and to be able
  to see all of them, so a short list never reads as "that's all there is".

## Acceptance Criteria

- [ ] A city's events section occupies one fixed-height row of cards, whatever
      the city and however many events it has.
- [ ] The events shown for a city are drawn from the same date window the
      city's header chip displays.
- [ ] With events on several days, the shortlist covers every day of the stay
      before showing anyone's second event.
- [ ] The section header states how many events were found in total, not how
      many cards are on screen.
- [ ] When the lookup returns the server's per-city maximum, the count is
      shown as "30+" — never a total the server never promised.
- [ ] "See all" opens the complete list, grouped by day; it is absent when the
      row already shows everything.
- [ ] Each event can still be opened at the ticket seller and added to the
      trip, from the row and from the full list.
- [ ] A city visited twice gets one section per visit, each on its own dates.
- [ ] A city with no events shows nothing at all (Greek cities keep their
      curated source links).
- [ ] The AI planner no longer tells travelers their events were saved with
      their trip.

## UI Behavior

- **Surface:** inside each expanded city group on the trip detail Itinerary
  tab, below the city's plan rows and its local recommendations.
- **Happy path:** the traveler sees a labelled row of event posters, swipes it
  sideways, taps one to open the ticket page, or taps its add button to put it
  on the trip. "See all" opens the full list as a sheet.
- **States:**
  - *Loading* — a single quiet line, "Finding events in <city>…".
  - *Empty / error* — nothing, except Greek cities, which show curated
    event-discovery links as before.
  - *Success* — the poster row with a counted header.
  - *Everything already visible* — same row, no "See all".

## Edge Cases & Error States

- A city with no dates, or the "Other places" bucket: no lookup, no section.
- A leg that collapses to a zero-night stop: the window is that single day,
  which is now the correct answer rather than an accident.
- An event with a malformed date keeps its place in the list rather than being
  dropped — it can never silently hide a good one.
- Adding to the trip from the full list closes that list first, so the
  confirmation is not stranded behind it.

## Out of Scope

- **Ranking events by the traveler's stated interests.** Only a handful of the
  interest bank maps onto the listings provider's four coarse categories, the
  mapping would be hand-maintained, and the effect would be invisible to the
  user and unfalsifiable in dogfooding. Worth its own lane, with a visible
  "matches your interests" signal.
- **Down-weighting the departure day.** With the window bug fixed the picks
  already span the stay; we do not know the traveler's departure time, and an
  evening flight leaves a whole usable day. Excluding would be a guess.
- **The "Local intel" section**, which has the same shape but is empty for
  almost every city and carries no photos on this path.
- **Attaching events to the day they fall on** inside the itinerary.
- **Persisting events** as first-class itinerary items.
