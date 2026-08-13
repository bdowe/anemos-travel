# Spec: Next Step CTA

> Trip detail gains a "Next Step" card that names the single next
> unplanned/unhandled part of the trip and prompts the traveler to complete it,
> advancing phase by phase until the trip is fully planned and booked.

## Context

Trip Health lists everything wrong with a trip, but nothing orders those
findings into a journey or tells the traveler what to do *next*. Planning a
trip has a natural phase order — dates, itinerary, lodging, transport,
scheduling, bookings, packing — and travelers stall when the next move isn't
obvious. The Next Step card turns the existing health signals (plus a few gaps
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
  ("Step 3 of 7") so that finishing feels within reach.
- As a **trip owner**, I want a clear "you're all set" moment when nothing is
  left so that I know the trip is genuinely ready.

## Acceptance Criteria

- [ ] A trip with unfinished planning shows one Next Step card at the top of
      the trip detail page (above the view tabs, visible from every tab), with
      an eyebrow "Next step · N of 7", a title, an optional detail line, and a
      primary action.
- [ ] The step is the FIRST unmet phase of this fixed ladder, in order:
      1. **Set dates** — trip has no start/end dates.
      2. **Plan itinerary** — trip has no places, or none is assigned to a day.
      3. **Add lodging** — some night has no confirmed stay (per-city ranges).
      4. **Add transport** — a city-to-city hop has no connecting segment.
      5. **Tidy schedule** — places with no day, or empty days mid-trip.
      6. **Book everything** — any unbooked stay/segment/booking to-do remains.
      7. **Start packing** — packing checklist is empty (only before the trip
         starts).
- [ ] Planning steps (2–5) open the trip-bound chat pre-seeded with a prompt
      specific to the gap (city + dates for lodging, origin/destination for
      transport, the empty days for scheduling); the seed renders as a compact
      context chip, not a wall of text.
- [ ] Mechanical steps act directly: Set dates opens the date picker; Book
      everything switches to the "Not booked yet" bookings lens; Start packing
      opens the packing sheet.
- [ ] Completing a step (via chat, via a direct action, or via a Trip Health
      fix) advances the card to the next step without a manual reload — even
      while the chat panel is open beside the trip.
- [ ] When every phase is complete, the card shows a celebratory "You're all
      set" state, dismissible; a trip opened already-complete shows no card at
      all.
- [ ] Past trips (end date before today) never show the card.
- [ ] Viewers (read-only access) never see the card; offline, the card is
      visible but its actions are disabled.
- [ ] The `review_trip` chat tool mentions the suggested next step, so the
      agent gives the same guidance the card does.
- [ ] Trip Health (badge, sheet, findings, fixes) is unchanged apart from the
      payload growing; the health count never includes "steps".
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
  (total is 7). Both omitted for past trips. The step is identical whether or
  not `check_hours` is requested.
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
