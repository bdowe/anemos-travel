# Friction log

Running log of what broke, what dragged, and what kept coming up — feeds the
build queue. Priority when picking work: **breakage > friction in features
actually used > ideas that recur across ≥2 sessions**. Tag entries `[app]`
(dogfooding the product) or `[dev]` (workflow/tooling). Newest first.

## 2026-08-12 — trip-detail dogfooding (bookings view exit)

- **[app] Friction → fixed (Itinerary | Bookings header tabs):** clicking
  "0 of 21 booked" opened the all-bookings view — "interesting view,
  actually" — but there was no visible way back; the only exit was buried
  in the "Filter places" menu (the code comment even admitted "the filter
  menu is the way back out"). The counter was a one-way invisible door.
  Fixed by making the view switch first-class: the header title is now two
  underline tabs, **Itinerary | Bookings · 0/21** — the booked count rides
  the Bookings tab label (the counter it replaced WAS the old door, so the
  thing you tapped before is the thing you tap now), selection is derived
  from `_itemFilter` every build (never stored), and either view is one
  visible tap from the other, including from the lens's empty state. The
  filter menu slimmed to what its tooltip claims — places only — and "Not
  booked yet" moved inside the Bookings view as a scope FilterChip (same
  'unbooked' state, moved entry point; it renders selected above the
  "Everything's booked" celebration as the explicit why + way back). Header
  row grew 36→44px (real tab touch targets, `_listHeaderHeight` 48→56);
  "Add place" is icon-only below 800px — the tab pair + Today + filter +
  a labeled button can't share a 390px Spanish row. Open debt unchanged
  from 08-06: counter counts todos only; lens usage still has zero
  telemetry (`clientEventTypes` whitelist = a Go change).

## 2026-08-11 — trip-detail dogfooding (map day chips)

- **[app] Friction → fixed (day chips → city focus, specs/map-city-focus):**
  on a 10-destination trip the map's "All / Day 1 … Day 14+" strip said
  nothing — day numbers are meaningless when you think in cities, and the
  city groups below were "just a dropdown". Replaced day chips with
  **destination chips** (All + one chip per `tripLegs` run, same keys as the
  group headers) and made focus **two-way**: expanding a city header focuses
  its leg on the map (per-item pins filtered to the leg + covering stays,
  auto-fit); collapsing the focused header restores the All overview; a chip
  tap focuses + expands, and on desktop rests the header right under the
  pinned map. Day-level map filtering retired everywhere (inline,
  full-screen, shared view); single-leg trips drop the strip (below 2 legs
  the overview mode never engaged anyway). Focus identity is the
  full-itinerary leg key — a places lens can merge adjacent runs, so map
  content resolves by the leg's item POSITIONS, never group keys. Camera
  moves stay instant (no animation dep); animated fly-to noted as polish.

- **[app] Friction → fixed (dead "Show more" toggle):** the header overview's
  "Show more" appeared on wide windows even when the whole summary already fit
  the 2-line clamp — clicking flipped it to "Show less" with zero visual
  change. Root cause: the toggle was gated on `text.length > 140`, a
  character-count proxy for "does the clamp clip", which false-positives on
  wide layouts and false-negatives on short newline-heavy summaries (3 hard
  lines, silent clipping, no toggle). Fix: `_OverviewText` now measures —
  LayoutBuilder width + a TextPainter configured exactly as the rendered
  Text's RenderParagraph (DefaultTextStyle merge, boldText, TextScaler
  object, locale, ellipsis) against one shared `_collapsedMaxLines` constant,
  so the toggle renders iff `didExceedMaxLines`. Lesson: **a proxy signal for
  a layout question re-derives the renderer's decision and will drift from
  it — ask the text engine the same question the renderer asks.**

## 2026-08-06 — trip-detail dogfooding (top-level clutter)

- **[app] Friction → fixed (collapse default + All-bookings lens):** on a
  7-destination trip the itinerary's top level was a wall of repeated
  flight/stay pairs ("EWR → Prague · Find flights" / "Stay in Prague · Open
  in Airbnb" × 7) before any actual content. Fixed two ways, per the 08-03
  doctrine (collapse, don't relocate; the menus rejection defended exactly
  this collapsed-rows shape): (1) destination groups now DEFAULT to
  collapsed — the resting view is one place-plus-dates header line per
  destination; a sole group seeds open, and today-mode still force-expands
  today's group on live trips (day-jump targets now come from a build-time
  `_liveDayKeys` registry, since a never-expanded group has no built day
  headers). (2) A new trip-wide "All bookings" filter lens — booked and
  unbooked, destination filter chips, residuals under an Other chip — entered
  from the filter menu or by tapping the "N of M booked" counter. A lens, not
  a section: it REPLACES the list, so booked-state never renders on two
  surfaces at once (the PR #274 bar), and every row keeps the one
  `_setRowBooked` writer. Open debt, on purpose: the counter still counts
  todos only (residual confirmed records were never "to book"), booking→
  destination attribution is still the fuzzy claim-once `_groupedBookings`
  matcher (the lens filters its OUTPUT — a stored leg association is the
  specs/server-leg-dates lane-1a follow-up), and lens/collapse usage still
  has zero telemetry (`clientEventTypes` whitelist makes that a Go change).

- **[app] BREAKAGE same-day → fixed (collapsed headers squished on
  scroll):** first dogfood of the collapsed default found every header
  squishing to a sliver, then a blank still-scrollable area, as the page
  scrolled. Root cause (verified against sliver_tools source): a collapsed
  group was a `MultiSliver(pushPinnedChildren)` whose ONLY child was its
  `SliverPinnedHeader`; the pinned child reports `paintOrigin = overlap`,
  and with no body sliver contributing `paintOrigin: 0`, the pinned
  chrome's overlap gets subtracted from the group's paint AND layout
  extents while scrollExtent stays full. Fix: pin a header only while its
  section is expanded — collapsed cities AND collapsed days (the same
  zero-body shape, latent since before the collapse default) render as
  plain scrolling rows. Lesson: **a pinned sliver only earns its pin while
  it has content to preside over — a zero-body pinned group is a geometry
  hazard, not a no-op.**

## 2026-08-06 — trip-detail dogfooding (leg dates, round five)

- **[app] BREAKAGE → fixed (specs/set-leg-dates round five):** the agent
  looped three turns claiming updates that never appeared, "apologizing"
  that it hadn't called the tool — but analytics show it called
  `update_itinerary_section` scope=trip SEVEN times, each committing. Its
  day→date mental model was wrong (it read a city's item day as the ARRIVAL;
  it's the departure), so its full-trip rewrites re-wrote ≈ the saved day
  numbers — zero visible change — and clobbered an earlier correct
  set_leg_dates move. Nothing it could read exposed rendered ranges: the
  tool's success result was a fixed 47-char sentence and get_trip showed raw
  day numbers, so the wrong model was unfalsifiable and the least-wrong
  story became "I never called it." Fix: `legsRenderSummary` (render truth
  via `visibleLegDisplayRange`) in BOTH the get_trip output and every
  update_itinerary_section result, plus the day-semantics rule and a
  do-not-resend steer in the result and refine prompt. Dev replay: the
  seven-turn loop's exact ask now resolves in one turn with two
  set_leg_dates calls. Lesson: **a mutating tool whose result carries zero
  derived state lets a wrong mental model survive any number of successful
  calls — every write result must echo the post-state the USER will see.**

## 2026-08-05 — trip-detail dogfooding (leg dates, round four — later still)

- **[app] Minor error → fixed (specs/set-leg-dates v4):** "Medellín should get
  5 nights" worked and the squeeze was narrated + offered for fixing (round
  three machinery), but the interim inverted state rendered "Medellín →
  Quito, Sep 14" directly above "Stay in Quito, Sep 13" — check-in before
  the flight lands. The arrival-adjustment only let the arrival win when it
  was EARLIER than the leg's own start, and inter-city flight rows read the
  previous leg's RAW end, so no local patch could make the chain coherent.
  Fix: one shared visible-ranges derivation (`_visibleGroupRanges` client /
  `visibleLegDisplayRange` server) — a squeezed leg collapses to a
  zero-night stop at its arrival, cascading so downstream flights and
  headers follow; confirmed stays never collapse; the honest no-op quotes
  the zero-night render. Lesson: **when data can be legitimately
  inconsistent mid-conversation, the renderer needs an explicit rule for the
  inconsistent state too — "it can't happen" states that CAN happen
  transiently still get looked at.**

## 2026-08-05 — trip-detail dogfooding (leg dates, round three — late)

- **[app] BREAKAGE → fixed (specs/set-leg-dates v3):** after the Kraków move,
  Prague rendered as a bare "Aug 27" on an Aug 24 trip, and asking to "update
  Prague to Aug 24–27" no-opped with the tool agreeing with the wrong
  rendering ("holding Prague at Aug 27–27") — the agent then suggested a full
  rebuild and manual trip-page edits. The DATA was right all along (in Prague
  Aug 24–27): nothing anchored the FIRST leg's visible start to the trip
  start on either side — a rule that had held only implicitly via the draft
  stay rows migration 00053 deleted. Separately, Kraków's extension landed
  exactly ON Berlin's departure day and consumed all its nights silently
  (gap/overlap narration is mute at n == 0). Fix: first-leg trip-start
  anchor in `_locationGroupRanges` + `anchoredLegDisplayRange` (confirmed
  stay still wins), first-leg start changes steer to set_trip_dates, squeeze
  NOTE + prompt nudge so the agent chains set_leg_dates down the affected
  legs. Lessons: **an invariant that exists only implicitly (via rows that
  can be deleted) must be explicit on both sides of the render mirror**, and
  **boundary narration must cover the == case, not just gap and overlap**.

## 2026-08-05 — trip-detail dogfooding (leg dates, round two)

- **[app] BREAKAGE → fixed (specs/set-leg-dates v2):** the SAME "change LA to
  Sep 24–27" ask failed again after PR #287 — now the tool "succeeded" (or
  honestly no-opped: "already spans Sep 24–27") while the page still showed
  Sep 20–24, plus a "Trip updated" chip on pure no-ops. Root cause: the
  screen derives a leg's visible dates as [previous leg's end → its max item
  day] and rebuilds the stay/flight rows (booking_todos) from item days on
  every load, but the tool moved a different axis — min-day-anchored
  renumbering on a placeholder trip whose single item day encodes the
  DEPARTURE, and a leg-only cascade that left Panama City's end (= LA's
  visible start) untouched. The no-op branch echoed the requested range and
  `trip_updated` fired before the change check. Compounding: PR #287's
  "client re-derives drafts on refetch" premise had been false since PR #274
  removed the drafts sync — frozen auto=true stays also masked trip-health
  lodging gaps. Fix: end-anchored item renumbering, previous-leg end extends
  to meet a later start in the same tx (decision 2026-08-05; overlap still
  narrate-and-ask), zero-change calls commit nothing (no SSE) and report
  actual saved state, `get_trip` now lists stay/transport/todo dates,
  migration 00053 deletes the frozen drafts + `checkLodging` skips auto,
  and the city-header range is arrival-adjusted to match the stay rows.
  Lessons: **a write tool must move the axis the UI renders — verify against
  the derived view, not the storage model**, and **no-op results must
  describe post-state read back from the DB, never echo the request**.

## 2026-08-04 — trip-detail dogfooding (map home legs)

- **[app] Friction re-filed → fixed (shipped-but-unreachable):** "Map doesn't
  show arrows to and from home airport" came back hours after PR #286 shipped
  the home-airport legs — because they render only on the full-screen map,
  whose sole entry points (tap-to-expand + fullscreen button) are phone-only
  (`expandable` is gated on `< 800px`). At the desktop widths the app is
  dogfooded at, the feature was structurally invisible; the item also never
  made it into this log, so nothing flagged the gap. Fix: the inline
  trip-detail card now draws the legs itself (same All/Day 1/last-day gating,
  whole-journey fit) and the wide card gets a fullscreen control beside the
  zoom column, so the big map is finally reachable on desktop. Lesson: **a
  feature scoped to one surface must ship with a reachability check on every
  breakpoint** — "the tap-to-expand map" didn't exist at ≥800px.

## 2026-08-04 — trip-detail dogfooding (cluster order)

- **[app] Friction recurred → fixed (reorder, not relocation):** the 08-03
  "keep Packing & prep / Budget inline" resolution flagged reachability as
  the residual risk, and it recurred the very next day — on a long trip,
  two empty rows ("No items yet" / "Not tracked yet") sat ABOVE an amber
  11-to-review Trip health row. Fixed per that entry's own remedy: the
  trailing cluster now leads with Trip health, so actionable review state
  is met right after the itinerary and the empty rows trail at the true
  page bottom (one-line reorder + an order-contract widget test). Menus
  were re-considered and re-rejected for the same reasons as 08-03:
  glanceable state, the screen deliberately has no overflow menu, the
  share menu's gating (owner-only, hidden offline) can't host
  viewer-visible sections, and there is still zero usage telemetry.

## 2026-08-04 — trip-detail dogfooding (late night)

- **[app] BREAKAGE → fixed (specs/set-leg-dates):** asked the refine chat to
  "change the dates for LA to Sep 24–27" on the Panama City → LA trip; the
  agent kept saying it was doing it, nothing changed. Root cause: no tool
  could move ONE leg — `set_trip_dates` (shipped that same day) is a rigid
  whole-trip shift, and calling it with the trip's unchanged start is a
  delta-0 *success* ("dates already match"), so the anti-fabrication prompt
  line never fired while nothing moved. A per-leg change needs endpoint-
  anchored deltas (Sep 20→24 is +4 on check-in, Sep 24→27 is +3 on
  check-out), item-day renumbering, boundary-segment moves, and a trip-end
  extension. Fix: new `set_leg_dates` tool (leg only + agent narrates the
  gap it opens — cascade decision 2026-08-04), plus the delta-0 result now
  steers the model to it. Lesson for future tools: **a tool that can succeed
  without doing what the traveler asked defeats the honesty guardrail** —
  results must say what did NOT move.

## 2026-08-03 — trip-detail dogfooding

- **[app] Resolved question (no change):** should "Packing & prep" and
  "Budget" live under different menus instead of below the itinerary? **No —
  keep them inline.** The trailing cluster (Packing & prep / Budget / Trip
  health) is three collapsed one-line `CollapsibleSection` rows (~150px
  total) whose value is glanceable state — "No items yet", "Not tracked
  yet", the amber Trip-health review pill — which a menu would hide; the
  screen also has no overflow menu today (the share menu is owner-only and
  hidden offline). Residual friction to watch: on a long trip the cluster
  sits below the entire itinerary and is only met by scrolling past
  everything. If that recurs, the fix is **reachability, not relocation** —
  jump-to chips near the header or surfacing the health pill higher.

## 2026-08-01 — parallel-lanes build session (late night)

- **[dev] BREAKAGE (self-inflicted, fixed same night):** first draft of
  `wt-rm` tore down the **main** dev stack and deleted its
  `development_postgres_data` volume — the test worktree was branched off
  pre-parameterization main, so its compose file ignored `GTT_PROJECT` and
  resolved to project `development`. Local dev DB was recreated empty; the
  other checkout's `development-chrome-1` browser-rig container was also
  removed (recreate if still used). Fix shipped in #259: teardown is
  label-based (`docker compose -p gtt-…`) and refuses non-`gtt-*` projects.
- **[dev] Trap (hit it myself minutes after writing the warning):** bare
  `docker compose -p <lane> up` without `.wt.env` sourced still interpolates
  default ports and tried to bind the main stack's 5432. In a lane, use the
  make targets; for bare commands `set -a; . .wt.env; set +a` first.
- **[dev] Silent default:** the API falls back to `PUBLIC_BASE_URL=
  http://localhost:3000` when unset — on a lane gateway (:3001) that failed
  all 8 MCP/OAuth discovery smoke checks. `wt-new` now retargets the copied
  `.env` (ports + pinned `PUBLIC_BASE_URL`); lane smoke then ran 39/0/3.
- **[dev] tmux env poisoning:** `set -a`-sourcing `.wt.env` in `tmux-dev.sh`
  seeds the tmux *server* environment — every later session (including the
  main checkout's) inherits the lane's `GTT_*` and hijacks its stack. Parse
  values instead of exporting; session targets need exact-match
  (`-t "=$SESSION"`) because tmux prefix-matches names.
- **[dev] Worktree rebase gotcha (encoded in `/integrate`):** a lane branch is
  checked out in its worktree, so `git checkout <branch>` in the main checkout
  refuses — the integrator rebases *inside* the lane's worktree.
- **[dev] Duplicate goose migration numbers** merge cleanly in git and only
  explode at deploy — now guarded in CI (migrations job, runs on the PR merge
  ref) plus reserve-at-planning convention.
- **[dev] Agent-review caveat:** the PR #260 review workflow hit a session
  limit mid-verify (13/17 agents died) and its verdicts were artifacts of the
  failures — when a workflow reports `<failures>`, re-verify findings by hand
  before trusting confirmed/refuted splits.
- **[dev] 1Password signing:** transient "failed to fill whole buffer" on
  commit; immediate retry succeeded (known pattern — never disable signing).
- **[dev] Open follow-ups:** trim `Bash(gh pr *)` from
  `.claude/settings.local.json` (pre-approves `gh pr merge`, defeating the
  lane-agent stall); local dev DB is empty — reseed if anything mattered;
  first real wave should exercise `/integrate` end to end.
