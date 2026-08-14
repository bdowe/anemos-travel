# Plan: Events rail on the trip detail page

How [`spec.md`](spec.md) is built. Read `docs/zen.md` first — this change is
mostly an application of "explicit is better than implicit" and "one obvious
way to do it".

## The two defects, separated

**1. The window (root cause of the report).** `_eventsSliver` and the per-city
weather lookup took their date window from `TripDerivation.groupRanges`, a
`Map<String label, range>` built from `rawLegRanges` and keyed by city LABEL,
last-wins. Two consequences:

- Raw ≠ visible. `visibleLegRanges` is what the city header chip renders (it
  extends a leg back to its arrival, the previous leg's end). Berlin's single
  day-tagged item collapsed its RAW range to Sep 4 while the chip read
  Sep 1 – Sep 4, so the section asked Ticketmaster about one day of a
  four-day stay. Confirmed empirically: the reported five cards reproduce
  exactly against `start_date=end_date=2026-09-04`, while the header's own
  window returns 14 events over all four days.
- Label keying is last-wins, so Fira → Naxos → Fira rendered two identical
  Fira sections, both on the second visit's window.

Fix: delete `groupRanges` entirely — it was a third parallel window shape with
exactly two consumers and no test references. Both consumers read
`derivation.visibleRanges[gi]`, which is index-aligned with `legs` and
`groups` by construction (`locationDates` and `mapDestinations` already rely on
that alignment). One indexed lookup replaces a label map; revisits fall out
correct for free.

`_legClothingRecs` had the same raw-query/visible-display split and moves with
it, which also restores query sharing: the wear sheet and the city group now
build byte-identical `WeatherQuery`s, so the provider family dedups instead of
issuing two windows per city.

`leg_ranges.dart`'s doc comment is updated: anything that makes a promise about
dates ON SCREEN derives from the visible ranges; map pins and the nights
counter stay raw (a pin is a point; nights must not double-count the arrival).

**2. The presentation.** Five full-width `EventCard`s per city, in the plan's
own column, with no count.

## The reuse

The plan chat already renders these exact events as a horizontal poster rail —
`PlacePhotoStrip` + `PlaceCardData.event` (`chat_panel.dart`,
`place_photo_card.dart`), which maps `Event` → card, uses `event.imageUrl`
(populated on the public path by `pickImage` in `events_service.go`), and
carries tap-to-ticket plus the add-to-trip button. Trip detail was the second,
poorer implementation of the same thing: it threw the poster away and re-drew
the data as text rows. The rail is ~196px against ~470px and shows 8 events
instead of 5.

`PlacePhotoStrip` gains one optional `actionLabel` (defaults to the chat's
"View in trip"); nothing else about the shared widget changes, because the chat
depends on its fixed geometry.

## Files

| File | Change |
|---|---|
| `lib/utils/event_picks.dart` | **New, pure.** `spreadEventsByDay(events, limit:)` — bucket by `startDate`, round-robin one slot per day before anyone's second, re-sort chronologically. `kEventRailCards = 8`, `kEventsServerCap = 30`. |
| `lib/widgets/city_events_sheet.dart` | **New.** `showCityEventsSheet` + public `CityEventsSheetBody`, the house sheet recipe (`wear_pack_sheet.dart`). Full list, day headers, `EventCard` rows; pops itself before add-to-trip so the add sheet isn't a modal on a modal. |
| `lib/widgets/event_card.dart` | `eventDayLabel` extracted from `eventWhenLabel` (one definition of the date half); optional `showDate` so cards under a day header show only the time. |
| `lib/widgets/place_photo_card.dart` | Optional `actionLabel` on `PlacePhotoStrip`. |
| `lib/screens/trip_detail_screen.dart` | `_eventsSliver` renders the rail; takes the `Trip` so ticket clicks carry `tripId`. Call sites use `rangeFor(gi)`. `_legClothingRecs` moves to visible ranges. |
| `lib/screens/trip_detail_derivation.dart` | `groupRanges` deleted (field, ctor, construction, pass-through). |
| `lib/utils/leg_ranges.dart` | Doc: which consumers read visible vs raw, and why. |
| `lib/l10n/app_{en,es}.arb` | `tripEventsWhileHereCount` (plural), `tripEventsWhileHereCountCapped`, `tripEventsInCity`, `tripEventsSource`; `tripEventsWhileHere` deleted (last consumer gone). `commonSeeAll` reused. Regen LAST. |
| `src/packages/api/plan_handler.go` | `summarizeEvents` no longer tells the model "the full list is saved with their trip" — nothing persists these. Tool-result body, after the cache breakpoint, so registry byte-stability is untouched. |

## Deliberate calls

- **Selection never filters**, only reorders and truncates — so nothing the
  server returned is unreachable through "See all". A malformed blank date
  keeps its slot and sorts last.
- **The count is the total found, and "30+" at the cap.** The server truncates
  at `maxEvents` silently and the response carries no total, so rendering "30"
  would assert a number nobody promised. `kEventsServerCap` mirrors it, pinned
  on both sides (`event_picks_test.dart` ↔ `TestEventsServerCapIsThirty`).
- **A distinct analytics surface**, `trip_event_card` vs the chat's
  `chat_event_card`, and `tripId` on the click — event handoffs become
  trip-attributable in the attach-rate funnel for the first time.
- The strip's header text is muted where the old one was purple-bold. Calmer,
  and identical to the chat rail. The rarely-co-rendered "Local intel" header
  keeps its own style rather than restyling a shared widget.
- Rail card titles are single-line; long listings truncate there and are shown
  in full in the sheet. `PlacePhotoCard`'s geometry is load-bearing for the
  chat and is not touched.

## Tests

- `test/event_picks_test.dart` — the Berlin distribution (2/3/2/7) yields 2 per
  day; earliest-of-each-day first; chronological output; thin days exhaust into
  busy ones; single-day windows still fill the rail; blank dates keep a slot;
  degenerate inputs; deterministic ties; the server-cap mirror.
- `test/trip_detail_events_rail_test.dart` — one rail and zero `EventCard`s in
  the itinerary; header counts the total; "30+" at the cap; the spread picks by
  name; "See all" opens the full list with day headers and time-only cards, and
  is absent when nothing is hidden; **the query window equals the header's**;
  **a revisited city gets two distinct windows**; empty stays silent.
  Card assertions read `PlacePhotoStrip.cards` — the rail is a lazy
  `ListView`, so counting built widgets would silently depend on viewport
  width.
- `test/trip_detail_wear_section_test.dart` — fixture keys repointed from raw
  to visible windows. Expected display strings are unchanged (they were always
  the visible ranges); the per-visit contract still holds with two distinct
  Paris keys.
- `summarize_events_test.go` — content, the no-persistence guard (twin of
  `TestSummarizeOffersOneWaySolo`'s), empty case, and the cap mirror.

## Verification

`make flutter-test` (1089 pass), `make flutter-analyze` (clean — 3 pre-existing
infos in `route_response.dart`), `go test ./...`, `make api-fmt`, `make
api-vet`. Then the real Berlin trip in the dev stack: the rail spans Sep 1–4
instead of five cards on Sep 4.
