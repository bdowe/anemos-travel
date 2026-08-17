# Spec: A trip's description can be edited

> **WHAT & WHY only.** Implementation lives in `plan.md`.

## Context

A trip's prose overview — the paragraph under the title on the trip page — is
`trips.summary` (migration 00013: *"A short prose overview of the trip, shown
under the title"*). It is written **once, at row creation**, and after that
nobody can change it:

- Its only writer is `CreateTrip`, reached only through `persistTrip`. The
  agent's `create_itinerary` supplies the text; paste-import and the MCP
  `create_trip` tool do the same; `POST /trips` passes `""`.
- `UpdateTrip` omits it from its COALESCE set, so `PATCH /trips/{id}` cannot
  touch it, and `PatchTripRequest` has no field for it.
- Once a trip is bound to a refine session, `create_itinerary` is gated OFF and
  the only itinerary writer is `update_itinerary_section`, which never touches
  the `trips` row's content columns.
- `get_trip` never renders it, so the planner cannot read back what it wrote.

So the overview is frozen the moment the trip is saved — and it goes stale as
soon as the itinerary is reshaped. A trip that grew from three cities to five
still describes three, in prose the traveler cannot correct and the planner
cannot see.

Two adjacent defects surfaced while tracing the field, and both belong here
because they are about the same sentence surviving:

1. `persistTrip` always INSERTs. A new version of a lineage does **not** inherit
   the previous version's summary — it gets whatever the caller passed, NULL if
   omitted. A trip can lose its description today with no UPDATE statement
   existing anywhere in the codebase.
2. `GET /trips/shared-with-me` builds its rows without `Summary`, though the DB
   row carries it. A co-planner's trip cards show no blurb where the owner's do.

## User Stories

- As a traveler, I want to fix or rewrite my trip's description myself, because
  the planner's first attempt describes a trip I have since changed.
- As a traveler, I want to remove the description entirely and have it stay
  removed — including after the planner reshapes the trip.
- As a traveler, I want to ask in chat — "change the description to say we're
  celebrating our anniversary" — and have the page reflect it.
- As a traveler, I want the planner to refresh a description IT wrote when the
  trip's shape changes, so the blurb never contradicts the itinerary.
- As a traveler, I want the planner to never overwrite words I wrote myself.
- As the trip assistant, I want to see the trip's current description and who
  wrote it, so I can tell "stale text I authored" from "the traveler's own
  words" instead of guessing.

## Acceptance Criteria

- [ ] The trip page's header pencil edits the trip's **name and description**
      together; saving both takes one request.
- [ ] Saving an empty description clears it, and the cleared state survives a
      later planner reshape.
- [ ] Editing is available to the owner and to editor collaborators, and absent
      for viewers and while offline — the same gating every other trip-page
      edit control uses.
- [ ] A legacy trip, whose prose lives in `title` because it predates 00013,
      opens the editor pre-filled with that prose; saving promotes it into
      `summary`.
- [ ] The planner has a tool that sets a saved trip's description, and it states
      the stored text back rather than reporting bare success.
- [ ] The planner **refuses** to overwrite a traveler-written description when
      it is acting on its own initiative, and says what is there so it can offer
      the change instead. An explicit request from the traveler always writes.
- [ ] `get_trip` shows the planner the current description and who wrote it,
      including an explicit statement when there is none — distinguishing
      "never written" from "the traveler removed it".
- [ ] A new version of a trip lineage keeps the previous version's description
      when the caller supplies none.
- [ ] `GET /trips/shared-with-me` carries `summary`.
- [ ] One write implementation serves both the page and the chat; a parity test
      proves the same input leaves two trips in the same state.

## Data Model

- `trips.summary` is unchanged: nullable `text`, and `""` is normalized to NULL
  so "no description" has exactly one representation.
- New `trips.summary_source` (`'agent'` | `'traveler'`, nullable) records
  **whose words these are**. The pair carries the meaning: `summary IS NULL`
  with `summary_source = 'traveler'` is the traveler having removed the
  description on purpose, a state one column could not express. NULL source
  means "written before this was tracked", which is provably not the traveler —
  until now no human writer existed.

## Out of Scope

- Showing authorship in the UI ("written by you" / "written by the planner").
  The column exists so the planner can behave correctly, not to be rendered.
- Editing the description from the trips list, the hero card, or the
  shared/public trip view.
- A description on manually logged trips at creation time (`POST /trips` still
  passes no summary); they can be given one afterwards like any other trip.
- Localizing the description, or any per-locale variants of it.
- The `.ics` export continues to use the trip's **title** for its `SUMMARY`
  property — an unrelated field that happens to share the word.

## Resolved Decisions

- **The word.** Storage, wire and the existing `create_itinerary` input stay
  `summary`; the traveler-facing label is "Description"; the agent tool is
  `set_trip_description`. The tool is named for the concept rather than the
  column — as `set_trip_origin` is, writing three columns named after none —
  because the compaction state already reaches the model as a message opening
  *"Summary of the conversation so far"*, and a tool called `set_trip_summary`
  invites exactly that confusion.
- **Not its own endpoint.** Unlike the endpoint airports, a description has no
  derived consequences: nothing is relabelled, no leg moves. It is a `PATCH
  /trips/{id}` field, like `title`, and it is edited in the same dialog as
  `title` because they are one thought.
- **Authorship is stored, not inferred from a prompt rule.** The planner's tool
  takes a required `reason`, and the server — not the system prompt — refuses
  the initiative-taking case against a traveler-written description.
- **The overview is not renamed in the schema.** A column RENAME is not
  rollback-safe (sqlc expands `SELECT *`; ADD COLUMN is, RENAME is not), and the
  wire key is consumed by shipped clients.
