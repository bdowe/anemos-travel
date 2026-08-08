# Spec: What to wear & pack

## Context

The trip-detail "Packing & prep" section is an empty checklist until someone
fills it, while the screen already knows the weather for every region of the
trip (the per-day chips). Packing decisions start from "what will it be like
there, then?" — so the section should lead with that answer. This feature
merges weather-derived clothing recommendations into the packing section:
per-region guidance on top, the editable checklist below, and a glanceable
one-line summary while collapsed. Direction settled with Brian (2026-08-07):
merge into ONE section (nothing about the checklist retires), render in the
trailing cluster (no inline per-city chrome), deterministic rules — no AI.

## User Stories

- As a **traveler planning a trip**, I want **to see what kind of clothes suit
  each region during my dates** so that **I can pack right without researching
  climate myself**.
- As a **traveler planning months ahead**, I want **seasonal guidance clearly
  framed as "typical", not a forecast**, so that **I trust it appropriately**.
- As a **read-only collaborator on a shared trip**, I want **the same clothing
  guidance even when the owner's checklist is empty**, so that **I can pack
  too**.

## Acceptance Criteria

- [ ] The trailing-cluster row is titled "What to wear & pack" and, when
      weather is available, its collapsed summary shows the cross-region
      temperature envelope and rain signal (e.g. "21°–31° · rain likely").
- [ ] Expanded, the section lists one row per leg visit (a revisited city gets
      one row per visit, disambiguated by date range): region label, date
      range, per-region temperature envelope, and a deterministic phrase built
      from the temperature band plus condition flags (rain, day–night swing,
      extreme heat, freezing nights). The dates shown are the same visible
      ranges the city headers display, so the two never disagree.
- [ ] Legs beyond the forecast horizon show the existing italic "typical for
      these dates" qualifier on their row; the collapsed summary stays
      kind-neutral (no qualifier).
- [ ] The editable packing checklist renders below the recommendations, fully
      intact: add/edit/check/delete, AI-seeded items, Trip-health one-tap
      fixes, export and print packet are all unchanged.
- [ ] The checked-count stays glanceable while collapsed (pill on the row).
- [ ] A read-only viewer with an empty checklist sees the section when weather
      resolves (recommendations only, no add affordance).
- [ ] When no weather resolves (offline, undated trip, provider failure), the
      section gates exactly as today: nothing until the checklist loads,
      hidden for viewers with an empty checklist.
- [ ] Recommendations never contradict Trip-health weather findings shown on
      the same screen (shared edges: extreme heat, freezing, rain-likely).

## API Surface

None. The feature consumes the existing weather lookups the trip screen
already performs per region and date window. No new endpoints, no server
changes.

## Data Model

Nothing stored. Recommendations are a display-only derivation from the weather
report already fetched per region (established precedent: the nights counter
is client display only and not part of any server contract).

## UI Behavior

- **Screen / surface:** trip detail, trailing cluster, the existing packing
  slot. Cluster order Trip health → What to wear & pack → Budget is unchanged.
- **Happy path:** opening the trip fetches weather for each dated region
  (shared with the day chips, so no duplicate lookups); as reports resolve,
  the collapsed summary swaps from the checklist count to the temperature
  envelope, with the checked-count moving to a pill. Expanding shows the
  per-region guidance followed by the checklist.
- **States:** loading = today's behavior (no recommendations yet); success =
  summary + per-region rows; error/offline = weather resolves empty, so
  recommendations are simply absent and behavior is identical to today. The
  section never blocks and never shows an error.

## Edge Cases & Error States

- Undated trip / no dated regions → no weather lookups, checklist-only.
- "Other places" (items with no real city) → skipped; nothing to geocode.
- A region stayed in longer than two weeks → guidance covers the served
  window silently (same accepted limitation as the day chips).
- Mixed near/far regions in one trip (forecast + typical) → per-row
  qualifiers carry the nuance; the collapsed summary makes no forecast claim.
- Revisited city → one row per visit with its own dates.
- Weather provider outage → empty reports by server contract; recommendations
  absent, no error surfaced.

## Out of Scope

- Wind, UV, snow, humidity, or condition icons (daily min/max/precip only).
- Per-day recommendations (per-region granularity only).
- Auto-adding checklist items from recommendations.
- Temperature units preference (°C-only today app-wide; noted as a separate
  follow-up this feature makes more visible).
- Any server-side clothing phrasing (the chat agent already reads raw weather
  and phrases advice itself).

## Open Questions

None — direction settled 2026-08-07. Band edges are product taste pinned by
unit tests; tunable on Brian's visual pass.
