# Spec: Booking shortlist (saved flight & stay options)

> **WHAT & WHY only.**

## Context

The trip detail page records what you **have** booked. Nothing records what you
are **deciding between**. Each leg gets one derived booking row — "Stay in
Prague · Open in Airbnb", "EWR → Prague · Find flights" — whose only outbound
action is a search link, and flight offers are never persisted at all. So the
middle of trip planning (three Airbnbs open in tabs, two flights being weighed)
happens entirely outside the app, and the traveler comes back to a page that
knows nothing about the decision they just spent an hour on.

This adds a **per-leg shortlist**: saved candidates that hang off the leg's
existing booking row, comparable side by side, with a **Choose this** that
promotes the winner into the real record and marks the leg booked.

## User Stories

- As a **traveler**, I want to save an Airbnb or flight I'm considering onto the
  leg it's for, so I can compare candidates without keeping ten tabs open.
- As a **traveler**, I want to paste a listing link and have the app fill in
  what it can, so saving is quick and I only type what's missing.
- As a **traveler**, I want to pick a winner in one action and have the trip
  reflect it — the stay recorded, the leg booked, the price in my budget.
- As a **traveler**, I want the ones I didn't pick to stay until I clear them,
  because "decided" often becomes "undecided" again.
- As a **traveler**, I want to see what the trip would cost if I took what I'm
  considering, alongside what I've actually committed.
- As a **traveler**, I don't want removing a city from my itinerary to silently
  destroy the research I did for it.

## Acceptance Criteria

- [ ] A saved option belongs to exactly one booking row (leg) on one trip.
- [ ] A leg with saved options shows how many, collapsed by default; expanding
      lists them with title, price and a link out.
- [ ] Choosing an option records the real stay/transport for that leg, marks
      both the leg and the record booked, and leaves the other candidates in
      place.
- [ ] The promoted record appears **under its leg**, never in "Other bookings".
- [ ] Choosing a different option for the same leg replaces the first — one leg
      never ends up with two stay records.
- [ ] Un-choosing reverses the booking but keeps the record and anything the
      traveler typed into it.
- [ ] Removing a bookmark that is currently the chosen one is refused with an
      explanation rather than silently unbooking the leg.
- [ ] Choosing an option whose price is in the budget's currency records the
      spend; a price in another currency is reported as skipped, never
      converted.
- [ ] Pasting a listing link fills in title/image/price when the site allows it,
      and silently falls back to manual entry when it doesn't.
- [ ] Dropping a city from the itinerary keeps that leg's saved options.
- [ ] Changing the trip's departure airport does not disturb saved options.
- [ ] A viewer following a shared trip never sees the owner's shortlist.

## API Surface

### `POST /api/v1/trips/{id}/booking-options`
- **Purpose:** save a candidate against a leg.
- **Request:** the leg it belongs to (required, must be on this trip); a title
  (required); optional link, provider, subtitle, note, image, price+currency
  (both or neither), dates, endpoints, transport mode.
- **Response:** the saved option, including whether it is the chosen one.
- **Errors:** unknown leg → not found; price without currency (or vice versa) →
  bad request; per-leg or per-trip limit reached → unprocessable.

### `PATCH|DELETE /api/v1/trips/{id}/booking-options/{optionId}`
- **Purpose:** edit or remove a candidate.
- **Errors:** deleting the currently chosen option is refused as a conflict —
  un-choose it first.

### `POST|DELETE /api/v1/trips/{id}/booking-options/{optionId}/choose`
- **Purpose:** promote a candidate to the leg's real booking, or reverse that.
- **Response:** the chosen option, the leg's full post-state option list, the
  leg, the record that was created or updated, which option was replaced, and
  either the expense recorded or the reason none was.
- **Errors:** a leg that is neither a stay nor transport → unprocessable.

### `GET /api/v1/link-preview?url=`
- **Purpose:** read a pasted booking link's own metadata to prefill the save
  form.
- **Response:** always a well-formed answer — either the details found, or a
  refusal naming the reason. Never an error the form has to handle.
- **Errors:** only a missing `url`.

Saved options are returned with the trip itself (`GET /trips/{id}`), not from a
list endpoint: a shortlist is only ever read alongside the legs it hangs off.

## Data Model

- **Booking option** — one candidate for one leg. Carries what you need to
  compare (title, subtitle, price + currency, link, image, provider, note),
  what promotion needs (dates, endpoints, transport mode), and which record it
  became if it won. Price and currency are inseparable — a number nobody can
  add up is worse than no number. Its kind is its leg's kind; it is never
  stored twice.

## UI Behavior

- **Surface:** the trip detail page's booking rows, in every view that shows
  them.
- **Happy path:** open "Save an option…", paste a link, fill in the rest, pick
  the leg, save → the leg shows "2 saved" → expand, compare, Choose → the leg
  goes booked with the record filled in and the budget prompt pre-filled.
- **States:** a leg with no options looks exactly as it does today; a link
  preview shows a spinner, then either prefilled fields or a quiet note that
  the details need typing.

## Edge Cases & Error States

- The leg already has a record (from "Add details…"): choosing replaces it,
  after a confirmation naming what it is replacing.
- A listing site blocks the preview: expected, not an error — the form works.
- The traveler renames a city: the old leg keeps its shortlist and moves to
  "Other bookings"; a fresh leg appears. Nothing is silently rematched.
- The traveler deletes a leg outright: its options go with it, so the client
  confirms first and says how many.

## Out of Scope

- No price watching — a saved price is a snapshot, shown with the date it was
  saved.
- No new "next step" ladder rung.
- No agent tool this pass; the planner cannot save or choose options.
- Print packet, calendar export and map pins ignore options.

## Open Questions

None outstanding — shape, placement, capture paths, link enrichment and budget
treatment were all decided before implementation.
