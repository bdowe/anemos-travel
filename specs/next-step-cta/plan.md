# Plan: Next Step CTA

> **HOW.** Translates `spec.md` into a file-level technical approach. Full
> design rationale (alternatives, rejected options) lives in the approved
> session plan; this is the executable summary.

## Technical Approach

Server-side derivation piggybacking on the existing review endpoint: a new pure
function `deriveNextStep` selects the first unmet phase of a fixed 6-phase
ladder, reusing `reviewTrip`'s findings plus signals health doesn't cover
(zero items, unbooked booking to-dos, empty packing checklist — all already on
`exportData`). Result rides the existing `ReviewResponse` envelope (designed to
grow, `review_handler.go` header), so there are zero new requests and the
`review_trip` agent tool gets the step for free. Chat seed prompts are
server-built canonical English (the server owns the agent-tool vocabulary);
titles/details are localized via the `i18n.go` catalog. No new agent tool —
the `/plan` registry is untouched (prompt-cache prefix stability).

Key decisions:
- **One-place doctrine** (docs/zen.md): the ladder consumes findings by
  category; empty-day/unscheduled logic is extracted into shared helpers
  (`emptyDayRuns`, `countUnscheduled`) rather than sniffed from finding
  conventions.
- **Deterministic across `check_hours` variants**: weather/hours findings are
  ignored, so both client cache keys agree on the step.
- **Mixed actions** (Brian, 2026-08-13): planning steps seed the trip chat;
  mechanical steps (dates, bookings lens, packing sheet) act directly.
- **Prefix progress** "Step N of 6": `done` = ladder index; total is a wire
  field, not a client constant, so the ladder can be renumbered without a
  lockstep client release (it was: 7 → 6, see the decision record).

## Go API Changes

- **NEW `trip_next_step.go`** — `NextStep`, `PlanProgress`,
  `deriveNextStep(locale, now, data, findings)`; ladder walk; seed templates
  (English consts); unbooked aggregate (non-auto unbooked stays + segments +
  todos not claimed by them via `todo_key` prefixes with `fuzzyMatch` /
  `segmentConnects`); explicit `now` for testability; past-trip nil gate.
  Phase 3 is the **booking-slot walk**: `nextOpenBookingSlot` (position-order
  scan of the derived `stay:`/`transport:` todos), `bookingSlotClaimed` /
  `stayNightsCovered` (date-aware stay claim), `bookingSlotStep` →
  `transportSlotStep` / `staySlotStep`, plus the convention parsers
  `legEndpoints` / `staySlotCity` / `stayCitySet`, `transportSlotMode`
  (per-leg override → provider → trip travel mode) and `slotDay` (anchor with
  a trip-range guard).
- **`trip_review.go`** — pure refactors: extract `emptyDayRuns` /
  `countUnscheduled` from `checkDensity` / `checkUnscheduled`; extract
  `nightCovered` from `checkLodging` and `transportFixLabel` from
  `checkTransit` so the walk shares one definition of "this night has lodging"
  and one mode→label map. `checkLodging` / `checkTransit` semantics unchanged —
  Trip Health keeps full fidelity on gaps the walk considers settled.
- **`review_handler.go`** — `ReviewResponse` gains `next_step` /
  `plan_progress`; handler composes `deriveNextStep` after `reviewTrip`.
- **`plan_tools_extra.go`** — `formatReviewFindings(findings, step)` appends
  "Suggested next step: … [next_step: kind=…]"; `runReviewTripTool` computes
  the step. No registry change.
- **`i18n.go`** — `review.next.*` en+es keys (titles/details per kind), incl.
  the walk's `bookStay.title` and mode/home-aware `bookTransport.*` family.

## Flutter Changes

- **Models** (`models/trip_finding.dart`): `NextStep`, `PlanProgress`,
  `TripReview{findings, nextStep?, planProgress?}`; regen via
  `make flutter-build-models`.
- **Service** (`services/trip_review_api_service.dart`): `getReview` returns
  `TripReview`.
- **Provider** (`providers/trip_review_provider.dart`): family type becomes
  `TripReview`; consumers switch to `.findings`.
- **Widget** (NEW `widgets/next_step_card.dart`): pure/provider-free card;
  tinted-banner idiom (brandTint), eyebrow "Next step · N of 7", per-kind icon
  + action label, "View all" → health sheet, all-set variant
  (successContainer + dismiss X), `compact` mode for narrow.
- **Screen** (`screens/trip_detail_screen.dart`, hub file — surgical):
  `_nextStepArea` slot after `_buildHeaderCard`; `_onNextStepAction`
  dispatcher (set_dates → `_editDates`, book_trip → `'unbooked'` lens,
  add_packing → `showWearPackSheet`, chat kinds → `_openSeededChat`);
  `_openSeededChat` = `_openRefine` guards minus items-empty;
  staleness fixes: `_invalidateReview()` in `_refresh()` and after a changed
  `_syncBookingTodos` result.
- **l10n**: `nextStep*` keys (eyebrow, progress, view-all, per-kind action
  labels, all-set dismiss) in both ARBs + `make flutter-gen-l10n`.

## Contract Parity  ← anti-drift gate

| JSON key | Go type (`trip_next_step.go`) | Dart type (`trip_finding.dart`) | Nullable? | ✓ |
|----------|-------------------------------|----------------------------------|-----------|---|
| `next_step` | `*NextStep` on `ReviewResponse` | `NextStep? nextStep` on `TripReview` | yes (past trip) | |
| `plan_progress` | `*PlanProgress` | `PlanProgress? planProgress` | yes (with next_step) | |
| `kind` | `string` | `String` | no | |
| `title` | `string` | `String` | no | |
| `detail` | `string` (omitempty) | `String?` | yes | |
| `day` | `*int` | `int?` | yes | |
| `count` | `*int` | `int?` | yes | |
| `fix` | `*FindingFix` | `FindingFix?` (existing type) | yes | |
| `seed_prompt` | `string` (omitempty) | `String?` | yes | |
| `done` / `total` | `int` / `int` | `int` / `int` | no | |

## Sequencing

PR #362 (calm health badge) touches `trip_review_section.dart` +
`trip_detail_screen.dart`; per the one-lane hub rule the provider type change
and screen wiring land only after #362 merges (rebase this lane on it). Go
side + models/service/widget/l10n are conflict-free and proceed now.

## Testing

- NEW `trip_next_step_test.go`: every ladder rung, first-match precedence, book
  aggregate dedupe, packing pre-trip gate, all_set 6/6, past-trip nil, locale
  es titles + English seeds, weather/hours invariance (asserted on BOTH phase-3
  paths). Walk pins: flight-before-stay with the outbound leg first, cased
  endpoints recovered from the todo title, checkbox-advances-with-no-rows,
  date-aware partial-stay claim, draft segments never claim, return-home copy,
  never-falls-through-to-findings, mode variants, slot-parse fallbacks.
- `trip_review_integration_test.go`: JSON keys present, check_hours same kind,
  viewer 404 unchanged; `TestTripReview_NextStepWalkIntegration` drives the
  walk through the real stack (sync checklist → flight step → PATCH booked →
  stay step).
- Formatter test: next-step line + signature.
- NEW `test/next_step_card_test.dart` (pure) + `test/trip_detail_next_step_test.dart`
  (screen: seeding, zero-items guard, direct actions, advancement, all-set,
  viewer/offline, narrow, trip_updated → review refetch, and the transport
  handoff: matching flight leg → in-app search, ferry leg → ferry path, no
  matching todo → seeded chat).

## Decision Record

### Booking-slot walk replaces phases 3 + 4 (Brian, 2026-08-14)

Dogfooding "Big Summer Adventure 2026": the card read *"Book a place to stay"*
for Prague's first night while the flight **to** Prague was still unbooked,
because the old ladder ranked every lodging finding above every transit one.
Worse, `checkTransit` only walks city→city hops, so the home-departure leg was
invisible to the ladder entirely.

Guidance now follows the trip: **flight to Prague → stay in Prague → flight to
Kraków → …**. Phase 3 walks the booking todos the client already syncs in that
exact order (`_deriveTodos`, position ASC) and surfaces the first open slot.
The server **consumes** that ordering rather than re-deriving legs from items —
docs/zen.md's one-derivation rule; a second leg-ordering implementation is
precisely the "five ways to group a leg" failure the doc was written after.

- **Open** = `!booked && !claimed`. Stay slots claim date-aware — every night
  in `[depart, return)` needs a real (non-auto) stay, so partial coverage keeps
  the slot open where `todoClaimed`'s fuzzy city match would have called one
  covered night "done". Undated stays and all transport slots delegate to
  `todoClaimed`, keeping ONE claim vocabulary. Transport claims count non-auto
  segments only — deliberately stricter than `checkTransit`, which also lets an
  auto draft suppress its finding: a suggestion is not a commitment.
- **Fallback, never mixed.** Trips with zero derived slots keep the old
  findings behavior verbatim. A *satisfied* walk never falls through to the
  findings: a checked checkbox with no accommodation row is the traveler
  telling us they booked elsewhere. Trip Health still reports the gap — that is
  its job, and the two surfaces are allowed to differ here.
- **Ladder 7 → 6.** `PlanProgress.Total` was already a wire field, so the UI
  renumbers itself with no client release.
- **Convention now has three readers.** Derived todo titles/keys
  (`"<Origin> → <Destination>"` / `"Stay in <City>"`, `transport:a>>b` /
  `stay:x`) are written by `_deriveTodos` and read by `_addDetailsFromTodo`,
  `todoClaimed`, and now the walk. Endpoint casing survives only on the title
  (origin/destination are not columns), so `legEndpoints` prefers the title and
  falls back to the lowercase key — pinned by `TestNextStep_WalkFlightBeforeStay`.
- **Accepted cost.** Todos re-sync when the trip screen loads, so a slot can be
  stale between opens (a removed city, a shifted date). Bounded by `slotDay`'s
  trip-range guard on the scroll anchor and by the sync's own stale-row prune.
- **Client handoff** (Brian's call): transport steps act like the checklist
  row — in-app flight search / Ferryhopper / ground link — because the row
  already knows how; stay steps keep the seeded chat, where suggesting places
  to sleep is genuinely better than a raw search page.

### Review corrections (2026-08-14, adversarial pass)

Four defects the first cut of the walk shipped with, all now fixed and pinned:

- **The walk can only speak for nights a slot spans.** A leg range ends at its
  last scheduled item, so a trip's trailing nights can belong to NO slot —
  nobody ever asked about them, which is the opposite of "booked elsewhere".
  A satisfied walk now surfaces the lodging finding for *unslotted* nights
  only (`firstUnslottedLodging` / `slotSpansNight`), so "You're all set" can
  never contradict the health sheet. The never-mix rule still holds exactly
  where it was designed to: a night a slot does span is the walk's to answer.
- **Grouping placeholders are not places.** `kOtherPlacesLabel` ("Other
  places", never translated by contract) and the server's own "Itinerary" hub
  reached the card as a city — and, worse, the canonical-English seed, sending
  the agent to find hotels in a city that does not exist. `namesAPlace` now
  rejects both, matching the silence `checkLodging` / `checkTransit` already
  keep for a hubless group.
- **The booked flip is the card's advance signal** — phase 3 walks the booked
  flags — but `_setRowBooked` never re-read the review, so the card kept
  recommending the slot just checked off. It now invalidates after the server
  accepts (never on a rolled-back optimistic flip). Pinned by a mutation-
  verified widget test.
- **The button must name what the tap does.** The label was derived from
  `fix.mode` alone, but `checkTransit` always sets a mode, so a *fallback*
  step promised "Find flights" and opened a chat. The screen now injects
  `transportHandsOff` from the same lookup the tap performs, and `_setRowMode`
  invalidates the review (the sync's `_sameTodoState` gate compares only
  key+booked, so a mode-only edit never re-read it).
