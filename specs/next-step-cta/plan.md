# Plan: Next Step CTA

> **HOW.** Translates `spec.md` into a file-level technical approach. Full
> design rationale (alternatives, rejected options) lives in the approved
> session plan; this is the executable summary.

## Technical Approach

Server-side derivation piggybacking on the existing review endpoint: a new pure
function `deriveNextStep` selects the first unmet phase of a fixed 7-phase
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
- **Prefix progress** "Step N of 7": `done` = ladder index; stable total.

## Go API Changes

- **NEW `trip_next_step.go`** — `NextStep`, `PlanProgress`,
  `deriveNextStep(locale, now, data, findings)`; ladder walk; seed templates
  (English consts); unbooked aggregate (non-auto unbooked stays + segments +
  todos not claimed by them via `todo_key` prefixes with `fuzzyMatch` /
  `segmentConnects`); explicit `now` for testability; past-trip nil gate.
- **`trip_review.go`** — pure refactor: extract `emptyDayRuns` /
  `countUnscheduled` from `checkDensity` / `checkUnscheduled`.
- **`review_handler.go`** — `ReviewResponse` gains `next_step` /
  `plan_progress`; handler composes `deriveNextStep` after `reviewTrip`.
- **`plan_tools_extra.go`** — `formatReviewFindings(findings, step)` appends
  "Suggested next step: … [next_step: kind=…]"; `runReviewTripTool` computes
  the step. No registry change.
- **`i18n.go`** — `review.next.*` en+es keys (titles/details per kind).

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
  aggregate dedupe, packing pre-trip gate, all_set 7/7, past-trip nil, locale
  es titles + English seeds, weather/hours invariance.
- `trip_review_integration_test.go`: JSON keys present, check_hours same kind,
  viewer 404 unchanged.
- Formatter test: next-step line + signature.
- NEW `test/next_step_card_test.dart` (pure) + `test/trip_detail_next_step_test.dart`
  (screen: seeding, zero-items guard, direct actions, advancement, all-set,
  viewer/offline, narrow, trip_updated → review refetch).
