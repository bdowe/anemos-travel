# Spec: Shape Before Schedule

> **WHAT & WHY only.** No tech choices, file names, libraries, or code.

## Context

Friction, 2026-08-15: *"When planning a trip, sometimes it pulls the list of
activities to do without confirming with me or asking. I feel like I just want
to get the high level structure of the trip done first, then figure out the
details of each day in the city later."*

Two complaints in one sentence — **no confirmation**, and **wrong altitude**.
The planner was told to research places and then save the whole trip, once,
unprompted; the decision to write was its own to make, based on whether it felt
it had found enough places. Nothing in its instructions described a trip's
*shape*, and nothing asked the traveler before committing one.

The app already believed in confirming: every prompt the trip page hands the
assistant gates on *"when I confirm…"*. Only the place where trips are actually
born — a fresh planning conversation — was never told.

**Intended outcome:** the first reply is the trip's shape, with one-tap
adjustments and no writes. Nothing is saved until the traveler agrees. What
lands then is a spine — the cities, their dates and the transport between them,
with each city's middle days deliberately left open — and the traveler fills
those days in later, one city at a time, from the trip page.

## User Stories

- As a **traveler**, I want to agree which cities I'm visiting and for how long
  *before* anything is saved, so a plan is never presented to me as settled when
  I never settled it.
- As a **traveler**, I want the trip's structure first and the day-by-day later,
  so I can book flights and stays against real dates without wading through
  activities I haven't thought about yet.
- As a **traveler**, I want to see which days are still open and fill one city
  at a time, at my pace.
- As a **traveler** who wants the whole thing planned in one go, I want to say
  so and get it — after agreeing the shape.

## Acceptance Criteria

- [ ] A new planning conversation's first substantive reply is the trip's shape
      — cities in order, nights in each, the dates those imply, and how the
      traveler moves between them — with tappable adjustments.
- [ ] No trip is created in that turn, and the conversation is resumable later.
- [ ] The same holds when only one city is involved: the shape is its dates and
      its length, and it is still confirmed before anything is saved.
- [ ] On agreement, exactly one trip is created, carrying each city's dates and
      transport with the middle of every stay deliberately open.
- [ ] The trip page shows the correct city date ranges, night counts, booking
      checklist and map for that trip — a sparse plan renders like a full one.
- [ ] A day with nothing planned appears on the trip page, says so, and offers
      to be planned; before this it was invisible.
- [ ] A city with open days says how many, and offers to plan them.
- [ ] Filling a city's days leaves every other city untouched, and does not move
      any city's dates.
- [ ] A trip with no places at all offers a way into planning instead of
      refusing, from every control that appears to offer one.
- [ ] The day the traveler travels home is never offered as a day to plan.
- [ ] A traveler who asks up front for the full day-by-day still gets it.

## Out of Scope

- Storing a trip's cities and dates as their own records, so a trip could exist
  with no activities at all. That is the honest end state and is written up in
  `plan.md`; it collides with the in-flight trip-dates work and is not attempted
  here.
- Changing what the traveler sees in exports (calendar, print packet) when a
  plan is sparse. Both degrade legibly rather than lying; see `plan.md`.
