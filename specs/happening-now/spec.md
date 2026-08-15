# Spec: Happening Now

## Context

Today-mode (specs/today-mode) made the *trip detail screen* live-trip aware —
but the user still has to find and open the trip themselves. Mid-trip, the app
should meet them at the front door: the home screen and the trips list should
surface "the trip you are on right now" as the single most prominent object,
one tap from today's plan. And once inside, the day being lived deserves one
more piece of glanceable context: where you're sleeping tonight. This spec
covers both: the **Happening now card** (PR 1) and the **Tonight caption**
inside today's day section (PR 2).

## User Stories

- As a **traveler mid-trip**, I want the app's home screen and trips list to
  lead with the trip I'm on so that today's plan is one tap away, not a search.
- As a **traveler mid-trip**, I want that card to tell me where I am in the
  trip ("Day 3 of 7") so that I get my bearings at a glance.
- As a **traveler mid-trip**, I want today's section of the itinerary to name
  tonight's accommodation so that "where am I sleeping?" never needs scrolling
  to a different section.

## Acceptance Criteria

### Liveness (shared by both PRs)

- [ ] A trip is **live** when the device's local calendar date falls inside
      its date range — start day and end day inclusive (same rule that drives
      today-mode's auto-scroll: today's trip-day exists). A trip with a start
      date but no end date is live from its start day onward.
- [ ] Undated trips and trips with unparseable dates are never live.
- [ ] Trip status (draft/planned) plays no part — a draft you're on is live.
- [ ] When several owned trips are live at once, the one with the **latest
      start date** wins; trips sharing a start date tie-break by their order
      in the trips list. Exactly one card is ever shown.
- [ ] Only **owned** trips are considered; trips shared *with* the user never
      produce a card.

### Happening now card (PR 1)

- [ ] **Trips list:** when a live trip exists, a promoted card renders at the
      very top of the list — above "Continue where you left off" and above
      "My Trips". The live trip still appears in "My Trips" below (the card
      is a shortcut, not a filter). *(Amended 2026-08-15 — the second
      sentence is superseded; see the amendment at the end of this file.)*
- [ ] **Home screen:** the same card renders in the recent-trip slot. When
      the most-recently-viewed trip *is* the live trip, only the live card
      shows; when they differ, the recent-trip tile renders below it.
- [ ] The card reads: a "HAPPENING NOW" eyebrow, the trip's destination
      summary (its cities, falling back to the title), a "Live" pill, and
      "Day N of M" ("Day N" alone when the trip has no end date). It carries
      the brand-gradient emphasis treatment so it reads as the top-priority
      object on both surfaces.
- [ ] Tapping the card opens the trip detail screen, which (per today-mode)
      auto-scrolls to today's day section.
- [ ] With no live trip, both surfaces render exactly as before.
- [ ] The trips-list card still appears when the list is served from the
      offline cache.

### Tonight caption (PR 2)

- [ ] Inside a live trip's detail screen, today's day section shows a
      **"Tonight: <stay name>"** caption as the **first content row** of the
      section — under the day header, above today's first item. It scrolls
      with the content (never pinned).
- [ ] Tonight's stay is the accommodation covering **tonight** checkout-
      exclusively: check-in ≤ today < check-out. A stay never claims its own
      checkout night.
- [ ] When today's day is rendered in more than one city group, the caption
      appears only in the **first** group containing it — never duplicated.
- [ ] A covering stay with an empty name is skipped (no "Tonight:" with
      nothing after it); with no covering stay, no caption renders at all.
- [ ] Non-live trips, shared read-only views, and days other than today never
      show the caption.

## API Surface

None. Everything derives client-side from data the app already receives. The
trips-*list* payload intentionally carries no itinerary items or
accommodations, which is why the card shows trip-level facts only.

## Data Model

No persisted entities change. Client-side derived concepts:

- **Live trip** — the single owned trip whose date range contains the device's
  local date today, chosen by latest start date (then list order) among
  candidates.
- **Trip progress** — "Day N of M": N is today's 1-based trip day, M the date
  span in days; M is unknown (omitted) for open-ended trips.
- **Tonight's stay** — the accommodation whose check-in/check-out window
  covers tonight, checkout-exclusively (same rule as today-mode's map stays).

## UI Behavior

- **Surfaces:** trips list (top of list), home screen (recent-trip slot), and
  — for PR 2 — the trip detail itinerary's today section.
- **Happy path:** traveler opens the app mid-trip → home leads with
  "HAPPENING NOW · Paris & Lyon · Live · Day 3 of 7" → tap → trip detail
  auto-scrolls to Day 3, whose first row reads "Tonight: Hôtel du Petit
  Moulin" → the whole question "what am I doing today and where am I
  sleeping?" is answered without a single scroll.
- **States:** no live trip → surfaces unchanged; offline → card still derived
  from the cached trips list; open-ended trip → "Day N" without a total.

## Edge Cases & Error States

- **Midnight rollover:** liveness and "Day N" are computed when the surfaces
  build (list load/refresh), consistent with today-mode's build-time "today".
  A trip that goes live at midnight appears on the next refresh — the app
  does not spontaneously re-render at 00:00.
- **Timezones:** "today" is the device's local calendar date; trip dates are
  date-only strings read as local dates. Same convention as today-mode.
- Trip ends today → still live (end-day inclusive); ended yesterday or
  starting tomorrow → not live.
- Trip with cities data shows the cities summary; legacy trips without it
  fall back to the title.
- Back-to-back stays tonight (A checks out today, B checks in today) →
  checkout-exclusivity means only B covers tonight.

## Out of Scope

- Any Go API or payload change (including adding items/accommodations to the
  trips-list response).
- Per-trip city-of-the-day or stay details **on the card** — the list payload
  has no items/accommodations, and the card stays trip-level by design.
- Trips shared with the user (sharedWithMe) as live-card candidates.
- Live re-rendering at midnight (timer-driven recompute).
- Notifications/reminders about the live trip.

## Open Questions

None.

## Amendment 2026-08-15 — the live trip renders exactly once

**Supersedes the trips-list acceptance criterion above** ("The live trip still
appears in 'My Trips' below (the card is a shortcut, not a filter)") and the
matching line in `plan.md`.

As shipped, a trip happening today rendered **twice** on one screen: in the
HAPPENING NOW hero and again as a plain card under a header reading
"Upcoming" — a trip already under way, filed under the word *upcoming*, beside
a copy of itself. "Shortcut, not a filter" was written when the list below was
one flat run called "My Trips" and this card carried three facts (eyebrow,
headline, Live · Day N of M): it genuinely showed *less* than the plain card,
so leaving the card was the only way not to lose the date range, the booking
progress and the item count. The "Up next" hero (specs/trips-page-insights)
later established the better rule, and the sections it arrived with are what
made the old one wrong.

- **A promoted trip renders exactly once.** The hero REPLACES the live trip's
  plain card; the Upcoming run never repeats it.
- **Promotion requires the hero to show at least what the card showed.** The
  Happening-Now card therefore carries the full list-card fact set — cached
  route band, date range, booking/packing pills, stays, Shared, places, cities
  line, summary — with the Live pill and "Day N of M" in the countdown's slot,
  and the trip's own duration chip suppressed because "Day 1 of 3" already
  names the span.
- **The route band is the trips list's, not Home's.** The live card is the
  one card that renders on both surfaces at once (AppShell's IndexedStack
  keeps both alive), and two flutter_map instances racing for the same tiles
  cancel each other's requests until BOTH render blank — verified A/B/A in a
  browser. The trips list keeps the band; Home's copy carries the same facts
  without it. The Up-next hero, which lives on one surface, is unaffected.
- **The booking nudge stays off a started trip.** It is pre-departure copy
  ("first leg departs …"), and its window gate fires on any unbooked future
  departure — including a return leg, mid-trip. It was hero-only, never on the
  plain card, so suppressing it loses nothing the replacement owed. A mid-trip
  urgency surface, with its own wording, is the deferred option.
- **Exactly one promoted object** is unchanged: a live trip still suppresses
  the Up-next hero, and a second overlapping in-progress trip keeps its plain
  card in the Upcoming run (`liveTripOf` promotes exactly one).
- **One name for the promoted trip.** The screen derives a single
  `promotedId` — the live trip if there is one, else the Up-next hero — and
  subtracts that from the Upcoming run. The duplication existed because there
  were two notions of "promoted" and only one was subtracted.
- **Known gap, unchanged:** the admin version-history expander has no hero
  equivalent, so a promoted trip doesn't offer it on this screen. Pre-existing
  for the Up-next hero since specs/trips-page-insights; admin-only.
