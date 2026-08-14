# Spec: Next Step CTA

> Trip detail gains a "Next Step" card that names the single next
> unplanned/unhandled part of the trip and prompts the traveler to complete it,
> advancing phase by phase until the trip is fully planned and booked.

## Context

Trip Health lists everything wrong with a trip, but nothing orders those
findings into a journey or tells the traveler what to do *next*. Planning a
trip has a natural phase order — dates, itinerary, booking the trip leg by
leg, scheduling, bookings, packing — and travelers stall when the next move
isn't obvious. The Next Step card turns the existing health signals (plus a few gaps
health doesn't cover) into a one-step-at-a-time guide: planning steps open the
trip chat pre-seeded with a prompt for that section; mechanical steps jump
straight to the right control.

## User Stories

- As a **trip owner**, I want the trip page to tell me the next thing my trip
  is missing so that I never have to hunt through tabs to figure out what's
  left.
- As a **trip owner**, I want tapping the step to drop me into the AI chat
  already primed for that exact gap (find lodging in Athens for these dates) so
  that finishing the step is one conversation, not a cold start.
- As a **trip owner**, I want mechanical steps (pick dates, review bookings,
  start the packing list) to open the right control directly so that two-tap
  jobs stay two taps.
- As a **trip owner**, I want to see how far along the planning journey I am
  ("Step 3 of 6") so that finishing feels within reach.
- As a **trip owner**, I want to open that counter and see what the six steps
  actually are so that "3 of 6" tells me something instead of raising a
  question I can't answer (Brian, 2026-08-14).
- As a **trip owner**, I want a clear "you're all set" moment when nothing is
  left so that I know the trip is genuinely ready.

## Acceptance Criteria

- [ ] A trip with unfinished planning shows one Next Step card at the top of
      the trip detail page (above the view tabs, visible from every tab), with
      an eyebrow "Next step · N of 6", a title, an optional detail line, and a
      primary action.
- [ ] The step is the FIRST unmet phase of this fixed ladder, in order:
      1. **Set dates** — trip has no start/end dates.
      2. **Add your destinations** — trip has no places, or none is assigned to
         a day. The test is deliberately weak (one dated place clears it), so
         the rung is NAMED for it. It used to be labelled "Plan your days",
         which promised a filled calendar and then checked itself off against
         ten bare city pins over 37 empty days (Brian, 2026-08-14). A rung's
         label is a promise about its test. City-filler rows — the placeholders
         the app hides, whose name is just their city — count here, because a
         filler is still a destination pin.
      3. **Book travel & stays, in itinerary order** — walks the synced
         booking checklist (outbound leg → stay → next leg → … → return leg,
         the order the trip is actually travelled) and names the first OPEN
         slot: not checked off, and not covered by a real accommodation or
         segment. Emitted as an `add_transport` or `add_lodging` step with
         mode-aware copy ("Book your flight to Prague", "Book your ferry
         home"). Trips with no synced checklist — imported, MCP- or
         agent-created, never opened in the app — fall back to the lodging-
         then-transport health findings. A satisfied walk never falls back: a
         checked slot with no matching row means booked elsewhere.
      4. **Plan your days** — places with no day, or days with nothing planned.
         One walk defines "a planned day", and Trip Health's empty-day findings
         read the same one: a day counts planned when it carries a non-filler
         itinerary item OR a real transport segment (travel days are planned
         days — otherwise the rung calls the day you fly to Kraków empty). The
         window is the WHOLE trip minus its departure day — its nights — not
         the first-to-last scheduled day, which let one dated item declare a
         37-day trip scheduled and hid every day past the last one. The step
         is titled "Tidy up your schedule" when loose places drive it and
         "Plan your days" when an empty day does.
      5. **Book everything** — any unbooked stay/segment/booking to-do remains.
      6. **Start packing** — packing checklist is empty (only before the trip
         starts).
- [ ] The eyebrow's "N of 6" counter is a tap target at EVERY width (the
      trailing entries are dropped when the card compacts; the counter is not)
      and opens a **Plan progress** sheet: all six rungs in server order, the
      completed ones checked, the current one marked and carrying the card's
      own step title/detail, the rest shown as *later* — never as failures,
      since prefix progress cannot speak for phases past the current one. A
      payload with no ladder (older server, cached response) simply renders the
      plain eyebrow.
- [ ] **Rungs with an exact denominator carry their own tally** ("4 of 11",
      "0 of 36"): a many-city trip closes eleven booking slots and fills
      thirty-six days under two rungs, so the ladder's "3 of 6" cannot move for
      weeks and the sub-progress is the only honest signal of movement — and on
      the days rung it is what makes "nothing planned yet" visible while the
      rung is still ahead. Each tally's Done is counted by the very test that
      decides its rung is satisfied — a booking slot closed either way the walk
      closes it, a day planned either way the day walk fills it — so a tally
      and its rung can never disagree. Rungs without an exact denominator
      (destinations, the book_trip aggregate) show no tally rather than a
      made-up one; a trip with no derived slots and an undated trip show none.
- [ ] The card's secondary entry names its destination — "Trip health", the
      title of the sheet it opens — rather than "View all", which beside a step
      counter promised the steps and delivered the findings list.
- [ ] Booking guidance follows the trip, not the category: the outbound flight
      surfaces before the first stay, and ticking a slot's checkbox advances
      the card even when no accommodation or segment row exists.
- [ ] Planning steps open the trip-bound chat pre-seeded with a prompt
      specific to the gap (city + dates for lodging, the empty days for
      scheduling, origin/destination for a transport step that has no synced
      row to hand off to); the seed renders as a compact context chip, not a
      wall of text.
- [ ] Mechanical steps act directly: Set dates opens the date picker; Book
      everything switches to the "Not booked yet" bookings lens; Start packing
      opens the packing sheet. A transport slot hands off exactly like its
      checklist row — in-app flight search, Ferryhopper, or the ground link —
      while stay slots keep the seeded chat (Brian, 2026-08-14).
- [ ] Completing a step (via chat, via a direct action, or via a Trip Health
      fix) advances the card to the next step without a manual reload — even
      while the chat panel is open beside the trip.
- [ ] When every phase is complete, the card shows a celebratory "You're all
      set" state, dismissible; a trip opened already-complete shows no card at
      all.
- [ ] Past trips (end date before today) never show the card.
- [ ] Viewers (read-only access) never see the card; offline, the card is
      visible but its actions are disabled — except the progress sheet, which
      is a pure render of the payload already on screen and keeps working.
- [ ] The `review_trip` chat tool mentions the suggested next step, so the
      agent gives the same guidance the card does.
- [ ] Trip Health (badge, sheet, findings, fixes) is unchanged apart from the
      payload growing and the card's entry to it being renamed; the health
      count never includes "steps".
- [ ] Card copy is localized (en + es); chat seed prompts remain canonical
      English.

## API Surface

### `GET /api/v1/trips/{id}/review` (existing endpoint, payload grows)
- **Purpose:** unchanged (health findings); now also reports the next planning
  step and phase progress.
- **Response additions:** `next_step` — the first unmet phase: kind, localized
  title/detail, optional day anchor, optional count (e.g. unbooked items),
  optional structured fix (same shape findings use), and a canonical-English
  `seed_prompt` for chat-driven steps. `plan_progress` — `done`/`total` phases
  (total is 6) plus `phases[]`, the ladder itself: `{id, label}` per rung, in
  order, ids stable across rewordings and locales (`dates`, `itinerary`,
  `bookings`, `schedule`, `confirm`, `packing` — the ids did NOT move when
  rungs 2 and 4 were renamed; ids are identity, labels are copy), labels
  localized. No per-rung DONE state ships: `done` already defines it (index <
  done complete, == done current, > done later), so the client derives it in one
  place. A rung MAY carry `progress: {done, total}` — its internal tally,
  present only where the denominator is exact: the bookings rung's derived slots
  (absent when the trip has none) and the schedule rung's plannable days (absent
  when the trip is undated). Both omitted for past trips. The step is identical
  whether or not `check_hours` is requested.
- **Errors:** unchanged (404 for viewers/missing trips).

## Data Model

No new tables, columns, or migrations. The next step is a read-time projection
over existing data: trip dates, itinerary items, confirmed accommodations and
segments, booking to-dos, and the packing checklist. Phase progress is the
count of consecutively complete phases from the top of the ladder.

## Out of Scope

- Budget, weather, and opening-hours signals as steps (optional or
  non-deterministic — they remain health findings only).
- Per-step dismissal (steps have no stable identity).
- Exact parity between the "book everything" count and the bookings tab's
  claim-once row partition (the trigger is exact; the count is motivational).
- Home-screen / weekly-nudge reuse of the step (follow-up candidates).
