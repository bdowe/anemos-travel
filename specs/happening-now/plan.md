# Plan: Happening Now

> **HOW.** See `spec.md`. Flutter-only; no Go, endpoint, model-codegen, or env
> changes (API Surface: none). Ships in two PRs: (1) the Happening now card on
> the trips list and home screen, (2) the Tonight caption in the trip detail's
> today section.

## Technical Approach

Everything derives from data the app already holds. The decisions, and why:

1. **Liveness reuses `tripDayOn` (`lib/utils/trip_days.dart`).** "Live" is
   defined as `tripDayOn(startDate, endDate, now) != null` — the exact
   predicate today-mode uses to auto-scroll, so the card and the destination
   screen can never disagree about whether a trip is "on". End-day inclusive
   and open-ended (null end) semantics come for free.
2. **Pure selector + thin provider.** `liveTripOf(List<Trip>, DateTime)` is a
   pure function (unit-testable without Riverpod); `liveTripProvider` is a
   plain `Provider<Trip?>` deriving from `tripsProvider` via a **narrow
   select on its trips list** (chat-panel invariant: never watch the whole
   state — loading flips must not rebuild the card). Latest-startDate wins;
   list order breaks ties.
3. **No fetch from home.** AppShell's `IndexedStack` mounts `TripsListScreen`
   eagerly, whose `initState` `loadTrips()` populates `tripsProvider`
   app-wide — home only watches. Offline works because `tripsProvider`
   already falls back to `TripCache`.
4. **Build-time "now".** Liveness is sampled when the provider (re)computes —
   on every trips-list (re)load — matching today-mode's build-time "today".
   No midnight timer (documented limitation in spec.md).
5. **Card = gradient sibling of `_RecentTripCard`.** Same
   `AppColors.brandGradient` + shadow + `InkWell` conventions
   (home_screen.dart), with a white-tinted `StatusPill.custom` "Live" pill —
   top-priority visual object on both surfaces.
6. **Tonight caption (PR 2) reuses `stayCoversDate`.** Checkout-exclusive
   (`checkIn <= today < checkOut`), the same helper the map's day filter
   uses. Rendered as the first content row of today's day section (non-
   pinned, scrolls with items) in `trip_detail_screen.dart`; when the day is
   split across city groups, only the first group containing today renders
   it; a stay with an empty name is skipped.

## Go API Changes

None.

## Flutter Changes

`src/packages/flutter-app/`:

### PR 1 — Happening now card

- **`lib/providers/live_trip_provider.dart`** (new): `liveTripOf(trips, now)`
  pure function + `liveTripProvider` (`Provider<Trip?>` over
  `tripsProvider.select((s) => s.trips)`).
- **`lib/widgets/live_trip_card.dart`** (new):
  `LiveTripCard({required Trip trip, required VoidCallback onTap})` —
  eyebrow "HAPPENING NOW", title `citiesLabel(trip.cities) ?? trip.title`,
  white "Live" `StatusPill.custom`, "Day N of M" via `tripDayOn` +
  `dayCount` (M omitted when `dayCount` is 0, i.e. no end date; the list
  payload has no items, so `itemDays` is empty).
- **`lib/utils/trip_format.dart`**: `citiesLabel(List<String>?)` — moved
  from `trips_list_screen.dart`'s private `_locationLabel` so the card and
  the trip card share one formatter (behavior-neutral refactor).
- **`lib/screens/trips_list_screen.dart`**: render `LiveTripCard` as the
  first `ListView` child (above the resumable-chats section); tap →
  existing `_openTrip`. The trip stays in "My Trips". *(Amended 2026-08-15:
  the hero REPLACES the trip's plain card — see spec.md's amendment.)*
- **`lib/screens/home_screen.dart`**: watch `liveTripProvider`; render the
  card in the recent-trip slot, with `_RecentTripCard` below it only when
  `recentTrip.tripId != liveTrip.id`. No `loadTrips()` call from home.

### PR 2 — Tonight caption

- **`lib/screens/trip_detail_screen.dart`**: in the day-section builder,
  when `day == todayDay` and this is the first group containing that day,
  prepend a caption row "Tonight: <name>" for the accommodation matching
  `stayCoversDate(checkIn, checkOut, DateTime.now())`; skip when no match
  or the name is empty.

## Contract Parity  ← anti-drift gate

No request/response pair changes — nothing to reconcile.

| JSON key | Go type | Dart type | Nullable? | ✓ |
|----------|---------|-----------|-----------|---|
| — (no API changes) | — | — | — | ☑ |

## Cross-cutting

- **Env vars:** none.
- **Gateway:** no new paths.

## Verification

- `make flutter-analyze` clean; `make flutter-test` green.
- `test/live_trip_provider_test.dart`: none/one/two live, latest-startDate
  win, list-order tiebreak, undated skipped, ends-today live,
  ended-yesterday / starts-tomorrow not live.
- `test/trips_list_live_test.dart`: card above the continue section and
  "My Trips"; "Day N of M" + "Live"; tap pushes `TripDetailScreen`; absent
  when nothing is live; still renders from the offline cache.
- Home widget test: live card shown; recent tile hidden when it is the live
  trip, shown when different.
- Manual: `make docker-dev`, sign in with a trip spanning today → home and
  trips list lead with the card; tap lands on today's section.
