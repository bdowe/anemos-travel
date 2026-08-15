# Plan: Shape Before Schedule

## Why a spine and not truly empty days

A trip's cities are **entirely derived from its activity items**. `computeTripLegs`
(`api/trip_render_legs.go`) opens with `if len(items) == 0 { return nil }`, and
its Dart twin (`lib/utils/leg_ranges.dart`) does the same. A trip with zero items
therefore renders a blank page: no cities, no date chips, no map, Bookings tab
hidden, chat FAB hidden. Truly empty days need a stored leg/day entity — the
honest end state, and a lane that would collide head-on with the in-flight
`specs/trip-dates-truth` parity soak.

A **sparse** itinerary renders perfectly, and the date math says exactly where
the places have to go:

- span precedence is confirmed stay > item days > weighted auto-allocation;
- the arrival chain sets a leg's start to the **previous leg's end**, and a
  leg's end is its **max item day**;
- so a city's last item day IS its departure date, and that same date IS the
  next city's arrival date.

### The invariant, as arithmetic

> Every city except the last carries two places: one on the day the traveler
> arrives, one on the day they move on (the same calendar day they arrive in the
> next city). The last city carries one — its arrival — because the day you move
> on from it is the journey home. **A spine of N cities has 2N − 1 places.**

Stating it this way removes the ambiguity for the model, reconciles with the
shipped last-day rule instead of fighting it, and makes the shape checkable: the
count is a total function of the tool payload.

The two places do different jobs, which is why the prompt names them separately:

- **The move-on place dates the city.** Without it the city renders as though
  the traveler left the day they arrived, and the next city absorbs its nights.
  Nothing rescues a missing one.
- **The arrival place** is normally redundant for the dates — except on the last
  city, which has no move-on day. Without it that city has zero items, and a
  city with zero items is not a run at all: it disappears from the trip.

Pinned by `TestComputeTripLegsSparseSpineRanges` and its Dart mirror in
`test/leg_ranges_test.dart`, plus a characterization test on both sides that
pins the WRONG output for arrival-anchors-only — the failure the prompt sentence
prevents.

## Refuse the mechanical mistakes; report the judgement ones

`plan_spine.go` runs before `persistTrip` and before the `done` SSE, so a
refusal leaves the database untouched and no client event fires. Each check is
decidable from the tool input alone, and each is scoped to the failure it
actually prevents rather than being a blanket requirement — an over-broad rule
here would be the last-day arc's draft two, which banned museums on a whole
departure day and was rightly disobeyed:

| Refused | Why, in terms of what the traveler would see |
|---|---|
| `start_date` without `end_date` | `persistTrip` derives a missing end from the highest item day, which on a spine is the FINAL city's *arrival* — the trip saves days short, and a one-city spine saves as a one-day trip. Unconditional. |
| A dated trip with an undated place | That leg falls to the weighted auto-allocation, whose weight is the item COUNT — identical for every city in a spine, so an equal split gets rendered as the nights that were agreed. Scoped to dated trips: an undated draft is a legitimate shape. |
| A **mix** of hub-tagged and untagged places | `renderHubOf` reads `city`/`day_trip_from` and parses no addresses, so an untagged place among tagged ones becomes its own "Other places" leg and splits the trip. Scoped to the mix: an itinerary with no tags anywhere is one coherent unnamed run, which is what legacy trips look like. |

**Deliberately not refused:** a city whose places sit on a single day. That is
usually a missing move-on place and sometimes a genuine same-day stop, and no
payload can tell them apart. It gets two honest channels instead — a warning
line above the leg list in the tool result, and a `warn` Trip Health finding
(`checkLegShape`) — rather than a guess dressed up as a rule.

## The post-state a sparse plan makes load-bearing

`legsRenderSummary` now prints each leg's **range, night count and date source**,
not the range alone: a model reading `2026-06-04 to 2026-06-04` beside a
neighbour's real range would otherwise have to do arithmetic to notice anything
was wrong, and an auto-allocated span is indistinguishable from a chosen one.

`openDaysSummary` names the plannable days that carry nothing, attributed to
their city. It is built from **`walkDayCoverage`**, and that reuse is
load-bearing rather than tidy: that function already drops the trip's last day
("there is nothing to plan on it") and already ignores city fillers, so the
journey-home day is *structurally incapable* of appearing. A hand-rolled loop
would list it and the model would offer to fill the day the traveler flies back
— the 2026-08-15 bug, reopened from the other side. Pinned by a negative
assertion in `TestCreateItineraryResultNamesOpenDays`.

`checkLegShape` gives `RenderLeg.ZeroNight` its first consumer. It has ridden the
trip payload since the leg-dates work with no reader anywhere, while a zero-night
leg draws no nights label at all — and the booking walk reads a zero-length stay
slot as *vacuously covered* (`stayNightsCovered`), so Next Step silently stops
asking the traveler to book that city while Trip Health's night walk still says
there is no lodging. This finding is what makes those two agree.

## Which days are a leg's empty days (client)

Both obvious answers are wrong, checked against the existing Paris→Rome fixture
in `test/trip_detail_grouping_test.dart`:

- **visible range, unfiltered** → the previous leg's departure day is drawn as
  unplanned under *both* cities, and the journey home is offered;
- **raw range** → a day genuinely inside the stay the header advertises is
  silently missed.

**The rule: the leg's VISIBLE range, minus the shared arrival day (the one equal
to the previous leg's visible end) and minus the trip's final day.** Visible is
the base because the header chip is what promises the stay, and anything
speaking about the dates on screen derives from the dates on screen. The two
exclusions are not exceptions to that — they are the two days the visible window
knowingly borrows.

"Has items" uses the screen's own predicate (`!isCityFiller && day != null`), so
the placeholder rows and the day headers cannot disagree about which days are
planned.

**Deliberate behaviour change:** on legacy trips, a day whose only item is an AI
city filler now shows the placeholder instead of rendering nothing. A filler day
*is* an unplanned day — the tile is suppressed and the server has always
discounted it — and two existing tests were updated to say so.

## An empty day is not a section

`spliceSection` errors when a selector matches nothing, so
`update_itinerary_section` with `scope='day'` **cannot** fill a day that has no
items — the exact thing "Plan this day" asks for. Filling an empty day is a
**city-scoped** rewrite, and the trip page's seed says so; the miss error also
gained the remediation it was missing, so a model that tries `scope='day'` is
told the call that works instead of improvising. Teaching `spliceSection` to
create a day is a follow-up, not this change.

The empty-day and city affordances therefore do **not** share a helper with the
per-day sparkle: that one refines a populated day (`scope='day'`, correct), this
one fills an empty one (`scope='city'`).

## Contract parity

No wire-format changes: no new JSON fields, no migration. `CityGroup.emptyDays`
is client-internal, derived from data already on the payload. The two
cross-language contracts this change touches are both fixture-mirrored:

| Rule | Go | Dart |
|---|---|---|
| Leg spans for a sparse spine | `trip_render_legs_test.go` | `test/leg_ranges_test.dart` |
| Arrival-anchors-only failure | same (characterization) | same (characterization) |

## Known debt, left deliberately

- **A stored leg/day entity** (truly empty days). The end state; collides with
  the trip-dates parity soak.
- **A guard against a new trip version dropping cities.** After
  `create_itinerary`, a plan chat stays unbound, so "now fill in Lisbon" can only
  be answered by another `create_itinerary` — which saves a new VERSION of the
  whole trip. If the model sent only Lisbon, the newest version would *be* a
  one-city trip. Held today by prompt copy, the tool description, and the visible
  legs echo. A server-side warning when a version drops cities the previous one
  had is the obvious follow-up.
- **Anonymous sessions get no post-state echo** (`s.tripID` is nil), so they run
  on the pre-persist refusals and prompt discipline alone.
- **`.ics` per-leg events, print-packet blank days, final-leg map pin date
  labels.** All degrade legibly on a sparse plan; none lie.
- **`tripDayOn`'s DST hazard** — it measures with `difference().inDays` on local
  midnights while day-header formatting uses `add(Duration(days:))`. This change
  inherits it *consistently* rather than inventing a third variant; the fix
  belongs inside `tripDayOn`, in its own lane.

## Prompt-cache cost

Editing `basePrompt` and the `create_itinerary` definition re-warms the same
system-prompt prefix once per session shape — the documented, deliberate cost
(precedent: `specs/find-parking-near-beach/plan.md`). No tool was added, so the
registry order is byte-stable and `TestPlanSessionToolsOrderStable` is untouched.
