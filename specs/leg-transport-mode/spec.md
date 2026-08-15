# Spec: How a leg travels

> **WHAT & WHY only.**

## Context

Planning a week in Italy produced a `Rome → Florence` checklist row whose action
read **"Find flights"** and opened Google Flights — for a city pair 230 km apart
that everyone crosses in 1h35 on a train. The chat pushed flights to match. This
was not a mistake in one place: every rung of the app's mode ladder fell through
to "flight", and the only thing that could switch it off was the traveler saying
a mode out loud ("we're driving"), which sets it for the WHOLE trip. Nothing
anywhere consulted geography, even though every place on the itinerary carries
coordinates.

The outcome: a leg's transport mode becomes a resolved value the whole app
agrees on — geography included — and the planner can correct any leg it
disagrees with. The traveler's own per-leg choice keeps winning, unchanged.

## User Stories

- As a **traveler**, I want a short hop between cities to offer me the train,
  not a flight search, so the app matches how I'd actually make the trip.
- As a **traveler**, I want my own choice for a leg to stick, so an improved
  guess never overrules what I picked.
- As a **traveler planning in chat**, I don't want the assistant hunting
  flights for a two-hour train ride.
- As the **trip assistant**, I want to see how the app has each leg travelling,
  so I can correct the one it got wrong instead of narrating a different plan
  than the page shows.

## Acceptance Criteria

- [ ] A trip with cities a short rail hop apart (Rome → Florence, Florence →
      Venice) shows those legs as trains, linking to a route search rather than
      a flight search — with no traveler input at all.
- [ ] The trip's departure and return legs stay flights: their outer endpoint is
      an airport, not a place on the itinerary.
- [ ] A leg the traveler set by hand keeps that mode and that link through any
      later sync, from any device, including a stale tab.
- [ ] A stated trip-wide mode ("we're driving") still applies to every leg;
      "mixed" lets each leg be judged on its own.
- [ ] Two Greek ports remain a ferry, ahead of any of the above except the
      traveler's own choice.
- [ ] A leg with a sea crossing (Rome → Palermo, Barcelona → Palma) is not
      called a train.
- [ ] Trip health names the same mode the row shows: the fix for a missing
      Rome → Florence leg reads "Add train", not "Add flight".
- [ ] Every leg's mode is visible to the assistant after it writes an
      itinerary, and it can set one leg's mode without touching the others.
- [ ] The assistant does not search flights for a leg that is obviously ground.

## Data Model

- A derived transport leg gains a **derived mode**: what the app worked out for
  it. Distinct from the **chosen mode** (what the traveler or the assistant
  picked), which already exists and always wins. Only the derived one is
  refreshed when the app re-derives, so a better rule reaches trips that already
  exist while nobody's choice is ever overwritten.

## Out of Scope

- A rail booking provider. A train leg hands off to the existing multi-modal
  route search, which covers trains, buses and driving.
- Live schedules or prices for ground transport.
- Rewriting how the trip-wide travel mode is set.
- Any change to how a leg's dates, identity, or booked state work.

## Resolved Decisions

- **Geography answers only when it is sure.** Every case it has no opinion on —
  an unknown region, a distance over the threshold, a sea crossing, a leg with
  no coordinates — keeps exactly the behaviour that shipped before, so the rule
  can only move legs from wrong to right.
- **A sea crossing is never called a ferry outside the Greek ports**, because
  those are the only ones the app can turn into a real ferry route link. A mode
  we cannot book is worse for the traveler than the flight search they had.
- **The assistant corrects; it does not announce.** The app resolves every leg
  and shows the result to the assistant after each itinerary write, so the
  assistant only acts on legs that are wrong.
