# Plan: Per-Trip Departure & Return Airports

Shipped as **two PRs in one lane**, because the second is only safe once the
first has landed. The lane holds both hub-file tokens
(`trip_detail_screen.dart` and the `plan_tool_registry.go` tail).

## Technical Approach

The reported bug is "no tool exists". The bug underneath is "a derived leg's
identity is its airport", and that one is already destroying data in production
through a different door — the Settings home-airport field — so it is fixed
first and separately.

**PR 1 — identity.** A derived home leg keys on a reserved `@home` token whose
*position* in the key carries the direction; the endpoint labels and the leg's
role move to columns. Changing an airport becomes a title/label update the
existing batch upsert already performs in place (`booked`/`auto`/`mode` are
deliberately outside its `DO UPDATE`), and the two directions stay distinct
keys, which is what lets a trip leave from ALB and return into EWR.

`@home` rather than a bare `home`: `namesAPlace` accepts the word "home" as a
city and would leak it into traveler-facing copy, while `@` cannot occur in an
IATA code or a Places label — so one prefix guard covers every reserved token
we ever add.

**Canonicalization lives in the sync handler, not the client.** That is what
makes a stale tab, an old cached bundle, or a collaborator's device land on the
*same* row instead of pruning it, and it is why the change needs no client flag
day. The home legs' labels are then taken from the **trip** rather than from
whoever posted, which is what stops a collaborator retitling the owner's
flights. The client is deliberately not asked to label its own rows: a posted
role would be a second writer of identity that every old bundle omits anyway, so
the server-side inference has to exist and be correct regardless — and two paths
that can disagree is the failure mode this work exists to end.

**PR 2 — the endpoints and the tool.** Two nullable IATA columns on the trip,
written together (a paired CHECK makes that a database invariant, so "null"
never has to be read as "same as the other direction"), plus a tail-appended
`set_trip_origin` agent tool.

### Rejected alternatives

- **Rekey the rows when the origin changes.** Throwaway work — deleted by the
  canonicalization it postpones — and strictly worse under a race: a stale tab's
  next sync deletes the freshly-rekeyed row and its expense link, where
  canonicalization merely rewrites a title. It also cannot close the
  home-airport door at all, because that path has no server write hook to hang a
  rekey on.
- **One airport column, with null meaning "same as departure".** A default
  someone must remember, re-derived at ten call sites across two languages —
  precisely the implicit-convention bug class `docs/zen.md` catalogues.
- **Reuse the free-text origin and sniff "looks like an IATA code".** Puts the
  meaning in the string's *shape*, and cannot represent "Lake George, NY,
  flying from ALB" at all.
- **Positional / leg-index identity.** Inserting a city at position 0 shifts
  every index, so every key changes and the whole checklist is pruned.

## Go API Changes

`src/packages/api/`:

- **Migration `00064_booking_todo_identity.sql`** — `role` / `origin_label` /
  `destination_label` on `booking_todos`; `origin_airport` / `return_airport` on
  `trips` (IATA-shape CHECKs + a paired CHECK). Backfill is entirely
  id-preserving `UPDATE`s, so booked flags, modes, positions and expense links
  survive by construction; a rename blocked by a key collision is a no-op that
  leaves the row `inter_city`, matching the runtime fallback exactly. Role↔key
  CHECKs are added only after the backfill, so a wrong canonicalization fails at
  write time rather than storing a plausible wrong row.
- **`booking_todo_identity.go` (new)** — the one definition of the canonical key,
  the role vocabulary, the classifier, the trip endpoint ladder, and the
  storage↔wire key mapping.
- **`booking_todo_handler.go`** — the sync handler canonicalizes and overrides
  the home legs' labels from trip truth; the response emits the endpoint-labelled
  key (the compat shim, deleted at the `specs/server-booking-todos` flip); the
  prune **demotes** state-carrying rows to manual instead of deleting them.
- **`trip_next_step.go`** — `todoClaimed`, `legEndpoints`, `staySlotCity` and
  `transportSlotStep` read the stored endpoints; `namesAPlace` rejects
  `@`-prefixed tokens.
- **`trip_review.go`** — `fuzzyMatch` matches short tokens as whole words, so a
  three-letter code can't substring-claim a longer place name.
- **`plan_trip_origin.go` (new)** — `set_trip_origin`, modelled on
  `plan_trip_dates.go`: `authedOnly` in the registry **and** a runtime auth
  check, trip resolution via `resolveDateShiftTrip`, `GetTripForUpdate` for the
  write, `trip_updated` + `touchTripAs` + `recordEvent`, and a result that states
  both endpoints, the exact rows renamed and their booked state.
- **`trip_handler.go`** — `tripEndpoints` replaces `persistTrip`'s bare origin
  string, applying the length bound and the paired airport rule in one place.
- **`share_handler.go`** — the endpoints travel with a duplicated trip.

`UpdateTrip` / `PATCH /trips/{id}` are deliberately untouched.

## Flutter Changes

`src/packages/flutter-app/`:

- **`models/trip.dart`** — `originAirport` / `returnAirport` (regen `.g.dart`).
- **`screens/trip_detail_screen.dart`** — `_deriveTodos` reads one explicit
  ladder per direction; a `ref.listen` mirrors a live home-airport change onto
  the open page.
- **`widgets/trip_map.dart` / `screens/trip_map_screen.dart`** — the overlay
  becomes a list of journey endpoints with an explicit kind for the tooltip, a
  per-entry antimeridian guard plus a new cross-entry one, and independent
  resolution so one pin survives the other failing.
- **`providers/plan_provider.dart`** — `profile_updated` carries a `fields`
  list; a named field triggers a real preferences re-read.
- **l10n** — `mapDepartureAirport` / `mapReturnAirport` in `app_en.arb` and
  `app_es.arb`; regenerate last.

## Testing

- Go: the canonicalization table (asymmetric, single-city, one-way, empty stay
  set, revisited city, "Other places", foreign key shape, collision fallback);
  the display-key round trip; the endpoint ladder; short-token `fuzzyMatch`;
  reserved-token rejection. Integration: identity survives a home-airport
  change with flag/mode/expense intact; asymmetric independence; demote-vs-delete;
  the tool's rename-in-place, ground refusal, unresolvable-code refusal, and
  session carry.
- Dart: the derivation ladder per direction; two pins; per-pin failure; the
  mid-session preferences change reaching an open page.
- Registry pins that move: `TestPlanSessionToolsOrderStable` (authed lists
  only), the tools-tail guard. The anonymous tail stays `find_parking`, which is
  what the `authedOnly` gate buys.

Each headline test was verified to FAIL with its fix removed.

## Rollout

PR 1 deploys and soaks first: with the prune hardened, nothing later can destroy
traveler state even if it is wrong. Prod is a single-container swap, so no old
API replica can prune freshly-canonicalized rows mid-deploy; the web bundle
ships with the server, and stale cached bundles are exactly what the
canonicalizer makes harmless.

Worth running before the deploy, as the honest accounting of what the bug has
already cost:

```sql
SELECT count(*) FROM trip_expenses e WHERE e.source_kind='booking_todo'
  AND NOT EXISTS (SELECT 1 FROM booking_todos b WHERE b.id = e.source_id);
```

---

# Plan: Wave 2 — the page control

One PR, no migration. The write already exists and is already safe; this wave
gives it a second front door and closes the one that looked like it.

## Technical Approach

**One write, two callers.** `runSetTripOriginTool` interleaved session concerns
with the write, so the write moves out into `applyTripEndpoints` — the ground
refusal against the saved travel mode, `SetTripEndpoints`, the owner-home
lookup, `tripEndpointLabels`, `relabelHomeLegs`, `TouchTrip` — and the tool and
the new handler each keep only what is theirs. Copying it instead would have
recreated the failure mode 00064 exists to end: two paths that can disagree
about what changing an airport means. `TestPageAndChatWriteTheSameEndpoints`
pins it.

**A dedicated endpoint, not a PATCH field.** `PUT /trips/{id}/endpoints`. The
spec rules PATCH out and `TestPatchTripCannotSetOrigin` pins it, but the better
reason is the body: this endpoint states the whole post-state, and **a one-sided
body is a 400**. That puts `CHECK trips_endpoint_airport_pair` on the wire
rather than leaving it as a rule the client has to remember — without it,
`columns()` quietly copies one end onto the other, so "change the outbound"
would silently rewrite the leg home. The response is the post-state, not an
echo: both stored airports plus every row that moved and whether it is still
booked (an empty list is the honest "no derived leg yet" case).

**`role` on the booking-todo wire.** The client has to know which two rows are
the journey's ends. The server already computes that as identity, so it is
emitted rather than re-inferred — and the case that settles it is the one the
server handles alone: a canonicalization collision demotes a home leg to
`inter_city`, where no relabel will ever reach it, and any client-side guess
would offer a control that does nothing.

**The details form stops owning endpoints it doesn't own.** `AddSegmentSheet`
gains `endpointsLocked`; `_addDetailsFromTodo` passes `todo.auto`. Free-form
segments from "+ Add booking → Transport" stay fully editable — that path really
does define its own endpoints.

**The page's claim rule joins the server's.** `_computeGroupedBookings` matched
an arrival on the segment's destination alone (and a departure on its origin
alone), so `ALB → Amsterdam` nested under `EWR → Amsterdam` and read as covered
while `todoClaimed` — which has always required both ends — went on counting the
flight as a gap. `segmentConnectsLeg` / `fuzzyMatch` / `legEndpoints` are now a
Dart twin of the Go rule, with the SAME fixture table on both sides
(`test/segment_connects_test.dart` ↔ `TestSegmentConnectsBothEnds`). A segment
that doesn't cover the leg falls to "Other bookings", which is true rather than
tidy.

### Rejected alternatives

- **Let the details form's From/To write the trip's airport.** Puts a second
  writer on the endpoints, and makes a form field mean two different things
  depending on which row opened it.
- **Infer the two home legs client-side** (first arrival, last departure). It is
  the derivation's own construction order, so it is nearly always right — but
  "nearly" is the problem, and the server already has the answer as a column.
- **Seed the sheet from the fallback** (the stated origin / saved home airport).
  Opening the sheet and pressing Save would then promote a fallback into a fixed
  per-trip choice nobody asked for.
- **Loosen the server's claim rule to match the page's** instead of the reverse.
  The page's rule was the wrong one: it is what let a contradiction render as a
  confirmation.

## Changes

`src/packages/api/`: `plan_trip_origin.go` (extract `applyTripEndpoints`,
`groundTripAirportError`, ctx-based `resolveEndpointAirport`/`relabelHomeLegs`),
`trip_endpoints_handler.go` (new), `main.go` (one route),
`booking_todo_handler.go` (`role` on the response).

`src/packages/flutter-app/`: `models/booking_todo.dart` (`role` + `isHomeLeg`),
`services/trips_api_service.dart` (`updateTripEndpoints` + result/exception
types), `widgets/trip_airports_sheet.dart` (new), `widgets/booking_todo_card.dart`
(second menu item), `widgets/booking_sheets.dart` (`endpointsLocked`),
`screens/trip_detail_screen.dart` (`_openTripAirports`, row + app-bar entries,
the locked details sheet), `screens/trip_detail_derivation.dart` (the claim
rule + the Go twin), l10n.

## Testing

Go: the paired-body 400, the ground refusal, an unresolvable code (including a
bad *return* airport leaving the departure unwritten), rename-in-place with
booked + mode + expense intact, asymmetric independence across two consecutive
writes, clearing back to the fallback, a non-member 404, the page↔chat parity
contract, and `role` on the wire.

Dart: the menu appears on the two home legs only; the sheet's unresolved-edit
refusal, its same-airport mirroring and its fallback line; the locked details
form and its "Change airport" hand-off; the both-ends claim rule at the
derivation level and in the twin fixture table.

Each headline test was verified to FAIL with its fix removed.
