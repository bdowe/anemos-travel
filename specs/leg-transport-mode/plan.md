# Plan: How a leg travels

## The shape

One resolver, `resolveLegMode` (`leg_transport_mode.go`), is the only answer to
"how does this trip get from A to B". Highest rung first:

1. **`booking_todos.mode`** — a choice somebody made (the row's mode menu, or
   `set_leg_transport_mode`). Always wins.
2. **A bookable ferry pair** — both endpoints resolve to Ferryhopper port codes
   (`isGreekFerryPair`). Above the trip's own mode: you cannot drive between
   islands.
3. **`trips.travel_mode`** when it names a mode. `'mixed'` is not a mode — it is
   the statement that legs differ, so it falls through to geography.
4. **Geography** — `geoLegMode`.
5. **`"flight"`** — the long-haul default, unchanged.

`geoLegMode` is pure and returns `""` (no opinion) unless it is sure:

- Both endpoints need coordinates, taken from `computeTripLegs`' representative
  `Lat`/`Lng`. This is what keeps the two home legs flights — their outer
  endpoint is an IATA code with no coordinate.
- `islandGroup(label)` maps a place to its landmass, `""` for the mainland.
  Same group is fine (`Palermo → Catania` is a train); one endpoint in a group
  and the other outside it is a sea crossing and ends the analysis. **Great
  Britain is deliberately absent** — the Chunnel makes `London → Paris` a train.
- `railRegions` is a table of `{bbox, maxKm}` — Europe+GB and Japan at 550 km —
  so covering another network later is a row plus a fixture, not a branch.

### Why the divergences

- **The Greek test is `ferryPortCode` on both ends**, not `isGreekLocation`
  (which covers every Greek city the events flow knows) and not `checkTransit`'s
  old OR. Athens → Thessaloniki is a train; Athens → Rome was being called a
  ferry. Tying the claim to the port table also keeps the mode honest about the
  link behind it.
- **A sea crossing outside those ports returns `""`, never `"ferry"`** —
  `ferryhopperURL` degrades to a landing page for unknown ports, and a mode we
  cannot route is worse than the flight search that shipped before.
- **550 km** takes Rome → Milan (477), Madrid → Barcelona (505) and Munich →
  Berlin (504); Amsterdam → Berlin (577) stays a flight. Conservative on
  purpose: a miss costs nothing, a false positive costs one tap.

## Storage — migration 00068

`booking_todos.derived_mode` (CHECK-constrained, unlike 00055's Go-only `mode`,
because derivation writes it rather than a validated handler). Two columns, two
meanings:

| column | meaning | on re-sync |
|---|---|---|
| `mode` (00055) | a choice somebody made | preserved — absent from `DO UPDATE` |
| `derived_mode` (00068) | what the server worked out | refreshed, like `provider`/`search_url` |

Readers resolve `mode ?? derived_mode`. `derived_mode` is deliberately NOT in
`DemoteStaleAutoBookingTodos`' predicate: that predicate lists what a traveler
would lose, and a derived value is not something anyone can lose.

## Who calls the resolver

- **`syncBookingTodosHandler`** — resolves each transport row's mode server-side
  and builds `provider`/`search_url` from it, *instead of* from the posted
  provider. Same reason the home legs' endpoints are resolved there (00064): a
  stale tab, an old bundle and a collaborator must land on the same answer. It
  reads the stored overrides back first, which also closes the trade-off logged
  when 00055 shipped ("a stale client's sync rewrites provider/search_url to the
  trip default").
- **`checkTransit`** (`trip_review.go`) — replaces its own `mode := "flight"`
  ladder, so Trip Health's fix says "Add train".
- **`transportSlotMode`** — now `mode ?? derived_mode ?? provider`. The provider
  reverse-map survives only for rows last synced before 00068 and retires with
  them.
- **`legTransportSummary`** (`plan_leg_dates.go`) — the model-facing echo.

## Client

`BookingTodo.derivedMode` + `effectiveMode` (`mode ?? derivedMode`), consumed by
`_deriveTodos`' `modeByKey`, the row's kind icon, and the mode menu's checkmark.
The local `greek ? ferry : (ground ?? flight)` default stays as the **pre-sync
bootstrap** only, and retires with the rest of the client derivation at the
`specs/server-booking-todos` flip.

**The subtle part:** a row's tap target comes from the `_flightLegs`/`_ferryLegs`
registries `_deriveTodos` fills, not from the row. Without re-deriving after the
sync response, a leg registered as a flight keeps opening the in-app flight
search while its row reads "train". `_syncBookingTodos` now re-derives inside the
same `setState` — pinned by "the sync response's derivation reaches the row it
is on", which fails when that line is removed.

## Agent

- **`legTransportSummary`** rides `create_itinerary`, `update_itinerary_section`
  (via `tripLegsRender`, which now returns both blocks) and `get_trip`'s
  checklist lines (`, by train`). One derivation, one renderer, three surfaces.
  A planner that cannot see the app's answer cannot correct it — that is why the
  Italy chat narrated flights.
- **`set_leg_transport_mode`** appended at the registry TAIL, `authedOnly` so the
  anonymous tools array stays byte-identical. It resolves the named leg against
  `computeTripLegs` and **refuses with the trip's real leg list** when it does
  not match, writes `booking_todos.mode` through the same `SetBookingTodoMode`
  the row menu uses, and creates the canonical row when the page has never
  synced. Its result states the post-state: every leg's mode as the traveler
  will now see it.
- **Prompt** (`basePrompt`, before the pinned final sentence): decide the mode
  before planning the leg; plan the train on short rail hops and do not call
  `search_flights` for them; `suggest_transport` with `mode:'ground'` is the
  ground tool (it had never been named in the prompt, which is part of why the
  model reached for flights); correct a wrong echoed leg with the new tool.

## Verification

- `leg_transport_mode_test.go` — the real-coordinate fixture table (Rome →
  Florence train … Barcelona → Palma nothing) plus the ladder's precedence.
- `leg_transport_mode_integration_test.go` — the Italy trip through the real
  sync route, the chosen-mode-survives-a-stale-resync case, the review fix
  label, and both tool paths (writes the canonical row; refuses a leg the trip
  lacks without writing anything).
- `trip_detail_leg_mode_test.go` — derived mode drives the row, a choice beats
  it, and the post-sync registry refresh.
- Mutation-checked: island guard, distance threshold, geography rung, override
  handling and the registry refresh were each reverted in place and confirmed to
  turn the suite red.
- Browser: a seeded Italy trip on the lane stack renders 🚆 `Rome → Florence` →
  "Open in Rome2Rio" with train checked in the menu, while both home legs stay
  flights.
