# Spec: Active Travel Profile (fitness, outdoor intensity, companions)

> **WHAT & WHY only.** No tech choices, file names, libraries, or code.

## Context

The traveler profile knows a spending level, a daily density, a set of interest
tags, a home airport and whether the traveler works on the road. It does not
know how they *move*.

Three gaps follow from that:

- **Fitness is invisible.** A traveler who lifts or runs every morning needs
  something the product has never modeled: a stay with a gym or one within
  walking distance, a runnable route near where they sleep, and an hour left
  alone at the start of the day. Today none of that is expressible, so the
  planner books someone who trains four days a week the same way it books
  someone who doesn't.
- **Interest tags can't express effort.** The profile already offers `hiking`,
  `nature`, `outdoors`, `wildlife` and friends, but a tag only says *what* you
  like, never *how hard* you want it. Trip pace is a different axis — it says
  how many things happen in a day, not how demanding they are — so a traveler
  who wants one relaxed day containing one serious climb cannot say so. Faced
  with "relaxed" and "hiking", the planner guesses, and nothing in the result
  reveals which way it guessed.
- **Companions is asked and then discarded.** The signup quiz already asks who
  the traveler travels with and offers five fixed answers, but the answer is
  folded into the free-text profile notes rather than stored as the fact it is.
  The planner re-reads it as prose, the notes-rewriting process can reword or
  drop it, and the traveler cannot correct it anywhere except by editing prose.

This feature adds three structured facts to the profile — a fitness routine, an
outdoor intensity, and travel companions — each one asked once, editable
forever, learnable mid-conversation, and each one changing what the planner
actually does rather than only how it talks.

## User Stories

- As a **traveler who trains**, I want to say once that I need gym access so
  every trip puts me near one and leaves me the time to use it, without my
  asking again.
- As a **runner**, I want each place I stay to come with somewhere to run, named
  and roughly measured, instead of a promise that "there are parks nearby".
- As a **hiker**, I want to say how hard I like my outdoor days so a
  recommendation is a real match — and I want distances and elevation stated so
  I can tell at a glance when it isn't.
- As a **traveler who wants easy days**, I want to say that too, so the planner
  stops proposing summit pushes it thinks I'll enjoy.
- As a **solo traveler**, I want the planner to stop quoting prices and rooms as
  though someone were with me.
- As a **parent**, I want trips planned around shorter transfers and places that
  work with kids.
- As a **returning traveler**, I want to change any of these later from my
  travel profile, and to have the planner pick them up when I mention them in
  conversation.

## Acceptance Criteria

- [ ] The travel profile gains three settings — a fitness routine (gym access /
      running routes / both / not a factor), an outdoor intensity (easy /
      moderate / challenging) and travel companions (solo / partner / friends /
      family with kids / it varies). Each is optional and unset by default.
- [ ] All three are editable on the Travel profile screen and persist across
      sessions; changing one leaves the others untouched.
- [ ] The signup quiz asks the fitness and outdoor questions in one new step,
      optional and skippable like every other step, and the step indicator
      reflects the new count.
- [ ] Retaking the quiz shows every previously saved answer pre-selected —
      including companions, which today comes back blank — and finishing an
      untouched retake changes nothing.
- [ ] For a traveler needing gym access, plans favor stays with a gym or one a
      short walk away and say which; when neither exists the planner names an
      actual nearby gym rather than asserting that gyms exist.
- [ ] For a runner, each stay comes with a specific named route and a rough
      distance.
- [ ] For either, the day is not scheduled wall-to-wall from waking, and the
      kit needed to train appears in the trip's packing list.
- [ ] Any hike, climb, ride or paddle the planner proposes states its distance,
      its elevation gain and roughly how long it takes — at every intensity —
      so a mismatch is visible instead of implied.
- [ ] Telling the planner something durable about any of the three (e.g. "I run
      every morning") updates the profile and shows the standard profile-updated
      notice.
- [ ] Companions is stored as a fact, not as profile-notes prose. Existing
      travelers whose answer is currently held in their notes keep it: it moves
      to the new setting and stops being duplicated in the notes. A note that
      was reworded and can no longer be read confidently is left exactly as it
      is rather than guessed at.
- [ ] The profile's free-text notes are no longer where companions belongs, and
      the planner is no longer told to record it there.
- [ ] A trip-planning conversation long enough to be compacted still carries the
      fitness, intensity and companion facts afterwards.
- [ ] Everything new is fully localized in English and Spanish.

## API Surface

No new endpoints. Three fields added to existing surfaces.

### `GET /api/v1/preferences`
- **Response:** gains `fitness_routine` (`"gym" | "running" | "both" | "none"`),
  `outdoor_intensity` (`"easy" | "moderate" | "challenging"`) and `companions`
  (`"solo" | "partner" | "friends" | "family_with_kids" | "varies"`); each
  `null` when never set.

### `PUT /api/v1/preferences`
- **Request:** gains the same three as optional fields. Omitted → keep the
  stored value, matching existing per-field merge semantics.
- **Errors:** any other non-empty value → `400`, matching `budget`/`pace`.

### `POST /api/v1/plan` (agent-internal)
- The preference-saving tool accepts all three with the same value sets and
  reports them in its profile-updated notice.
- The post-trip profile distillation may set them when a conversation clearly
  establishes them, and must not set them otherwise.

## Data Model

Three optional fields on the existing one-per-user traveler profile:

- **Fitness routine** — the training the traveler keeps while away. One of
  gym access / running routes / both / not a factor. Deliberately a single
  choice and not a tag list: it is a constraint on where they sleep and how the
  day opens, not a taste. Tastes (yoga, climbing, cycling) remain interests.
  "Not a factor" is a real answer, not an absence — it tells the planner to stop
  raising the subject.
- **Outdoor intensity** — how demanding an active outing should be. One of
  easy / moderate / challenging. Independent of pace: pace is how much happens
  in a day, intensity is how hard it is.
- **Companions** — who the traveler usually travels with. One of solo /
  partner / friends / family with kids / it varies. Already collected at signup;
  this promotes it from prose to a stored fact.

## UI Behavior

- **Travel profile screen:** three more single-select chip rows, alongside the
  existing ones. Companions sits with the other "who you are" answers; fitness
  and outdoor intensity sit together after interests.
- **Signup quiz:** one added step carrying both new questions; companions keeps
  its existing step and simply stores its answer properly now.
- **In the planner:** no new screen. When the planner learns one of these it
  surfaces the same notice it already uses for profile updates.

## Edge Cases & Error States

- Nothing set → the planner behaves exactly as it does today; no clauses about
  gyms, trails or companions appear.
- "Not a factor" is distinct from unset: the traveler has answered, and the
  planner should not volunteer fitness suggestions.
- Invalid value on save → `400`, same as budget and pace.
- Deselecting a chip and saving keeps the stored value rather than clearing it.
  This is the inherited behavior of every choice field on this profile
  (budget, pace, work style) and is out of scope to fix here; "not a factor"
  gives the fitness question a real way out.
- A traveler whose notes hold a companions line the migration cannot confidently
  read keeps the line and gets no stored value — never a guess.
- Anonymous sessions: nothing read, written, or distilled, as today.
