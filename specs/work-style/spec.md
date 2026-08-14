# Spec: Work Style (Digital-Nomad Travel Support)

## Context

Anemos has no notion of remote-work travel. Digital nomads plan trips
differently — stays need reliable wifi and a workspace, itineraries favor
longer stints in fewer places, days must balance work blocks with exploring,
and long international stays raise visa questions. Today the planner agent
cannot know any of this, so a nomad gets the same vacation-shaped suggestions
as everyone else. Adding a small structured "work style" fact to the traveler
profile — asked once in the onboarding quiz, editable later, and learnable
mid-conversation — lets every future trip be planned around how the traveler
actually travels.

## User Stories

- As a **digital nomad**, I want to tell Anemos once that I work while I
  travel so that every trip plan accounts for wifi, workspaces, and a
  sustainable pace without me repeating it.
- As an **occasional workation traveler**, I want the planner to know I
  sometimes work on trips so that it leaves room for working days when a trip
  calls for them.
- As a **leisure traveler**, I want to say trips are strictly time off so that
  the planner never wastes suggestions on coworking spaces.
- As a **returning user**, I want to change my answer later from my travel
  profile so that the setting tracks my life, not my signup moment.

## Acceptance Criteria

- [ ] The signup onboarding quiz has a new question "Do you work while you
      travel?" with three one-tap choices; it is optional and skippable like
      every other quiz question, and the step indicator reflects the new count.
- [ ] The answer appears on the Travel profile screen as a selectable chip
      row and can be changed and saved there at any time.
- [ ] Retaking the quiz shows the previously saved answer pre-selected, and
      finishing an untouched retake does not wipe it.
- [ ] For a traveler marked digital nomad, the plan chat's suggestions reflect
      remote-work needs (wifi-ready stays, workspace, longer stays, work/
      sightseeing balance, nomad-visa awareness where relevant).
- [ ] Telling the plan agent something durable about working while traveling
      (e.g. "I work remotely as I travel") results in the profile being
      updated and the standard profile-updated notice appearing in chat.
- [ ] The quiz question and profile labels are fully localized in English and
      Spanish.

## API Surface

No new endpoints. One field added to existing surfaces:

### `GET /api/v1/preferences`
- **Response:** gains `work_style` — `"digital_nomad" | "workation" |
  "leisure_only"` or `null` when never set.

### `PUT /api/v1/preferences`
- **Request:** gains optional `work_style` with the same three values.
  Omitted → keep the stored value (existing per-field merge semantics).
- **Errors:** any other non-empty value → 400, matching `budget`/`pace`.

### `POST /api/v1/plan` (agent-internal)
- The `save_preferences` tool accepts `work_style` (same enum) and reports it
  in the `profile_updated` SSE event's changed-fields list. The post-trip
  profile distiller may also set it when a conversation clearly establishes it.

## Data Model

- **Traveler preferences** gains **work style** — whether the traveler works
  remotely while traveling. Three values: `digital_nomad` (works remotely as
  they travel), `workation` (sometimes works on trips), `leisure_only` (trips
  are strictly time off). Optional; absent means unknown, and unknown changes
  nothing about planner behavior.

## UI Behavior

- **Onboarding quiz:** new step 2 of 6 (after travel style, before interests):
  title "Do you work while you travel?", three choice chips. Optional; Back/
  Next/Skip behave as on every other step.
- **Travel profile screen:** new "Work & travel" section between Pace and
  Interests — the same chip row, seeded from the saved profile, saved with the
  existing Save action.
- **States:** no new loading/empty/error surfaces; the field rides the
  existing preferences load/save states.

## Edge Cases & Error States

- Invalid `work_style` on PUT → 400 (shared choice validation). Invalid value
  from the agent tool → silently dropped, matching budget/pace tool behavior.
- Deselecting the chip and saving keeps the stored value (the PUT merge treats
  null as "keep", exactly like budget/pace — there is deliberately no clear
  path from the UI; a clear-to-unknown sentinel across all choice fields is
  future work, not this feature).
- Quiz retake with a saved value must pre-select it (unseeded fields are wiped
  by the full-document save — the existing retake seeding gate covers this).
- Unset value → no prompt text, no behavior change (prompt stays byte-identical
  for travelers who never answered).

## Out of Scope

- No nomad-specific tools (coworking search, visa lookup, long-stay rates) —
  prompt guidance only.
- No filtering/re-ranking of accommodation or flight search results by work
  style.
- No DB CHECK constraint (matches budget/pace: values enforced at the single
  shared API boundary).

## Open Questions

None — field shape (3-way enum) confirmed with the user 2026-08-13.
