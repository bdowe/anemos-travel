# Friction log

Running log of what broke, what dragged, and what kept coming up — feeds the
build queue. Priority when picking work: **breakage > friction in features
actually used > ideas that recur across ≥2 sessions**. Tag entries `[app]`
(dogfooding the product) or `[dev]` (workflow/tooling). Newest first.

## 2026-08-13 — trip-detail dogfooding (Bookings tab counter → pill)

- **[app] Friction → fixed (counter styling unified):** with the wear/pack
  checked-count now a StatusPill in its sheet header, the Bookings tab's
  inline "Bookings · 0/3" label was the last count not wearing the shared
  pill chrome. The count moved out of the label into a `StatusPill.custom`
  beside it (same surfaceContainerHighest/onSurfaceVariant pair as the
  wear-sheet and checklist headers; `_headerTab` grew a `trailing` slot
  inside the underlined region so the underline spans label + pill). On
  **narrow** the pill is dropped entirely — the tab trio + counter was
  exactly what pushed the FittedBox into visible scale-down at phone
  widths (the narrow-header test's documented tripwire), and the count is
  one tap away inside the view. `tripTabBookingsCounted` deleted from
  both ARBs (dead key).

## 2026-08-13 — trip-detail dogfooding (expanded groups + navigable map)

- **[app] Friction → fixed (decoupled expansion, supersedes the 08-1x
  "accordion city focus" contract):** the single-open accordion didn't
  survive daily use either — landing on a trip showed a wall of collapsed
  headers, and because the open group WAS the map selection, every list
  action moved the camera and vice versa. Third iteration of this contract
  (08-11 partial coupling → accordion full coupling → now full
  DEcoupling), and this one is directional: **expansion is list-only
  state; focus is map-only state; the map's region pins are how the map
  drives the list.** Concretely: all city groups land EXPANDED
  (`_collapsedGroups`, inverted like `_collapsedDays` — empty set = the
  default, so new cities from a refine arrive open and keys staled by a
  lens switch fail safe as expanded); a header tap toggles only its own
  group and never touches the map; `_focusedLegKey` survives as
  notifier-only map state (chips, camera fit, per-leg pin filtering) with
  one slim writer (`_setMapFocus`); chip taps keep the combined gesture
  (focus map + un-collapse + desktop rest-under-chrome scroll) while the
  All chip resets the map ONLY; and destination pins on the All overview
  became navigation — tap scrolls the list to that region's group, with
  deliberately NO focus write (focusing would swap the overview to
  per-item pins and delete the very pin under the pointer). In the
  full-screen map a region-pin tap focuses that city in place (the
  chip-equivalent — there's no list to scroll), and the report-back now
  pre-scrolls the list on phones too, so closing the modal lands on the
  region. The accordion machinery went with the contract: the derived
  `_openGroupKey`, the reveal-only `_unfocusedOpenLegKey` hatch, the
  sole-group seed, and the one-writer assert are all deleted. N groups now
  pin N city headers concurrently — safe because each group's containing
  `MultiSliver` pushes its own header off at the group's end
  (contacts-style handoff; verified against sliver_tools 0.2.12 source):
  the OUTER groups `MultiSliver` must stay non-containing or every header
  would pin to the itinerary's end and stack. The zero-body pinned-header
  rule below (2026-08-0x entry) still governs collapsed rows verbatim.

## 2026-08-13 — trip-detail dogfooding (wear & pack → app-bar icon)

- **[app] Friction → fixed (packing dropdown → app-bar icon + sheet):**
  "What to wear and pack shouldn't be a separate dropdown" — with health in
  the app bar and Budget a header tab, the lone collapsed row at the page
  tail read as leftover chrome. It followed health's exact path: an
  **app-bar luggage icon** (right of health, every breakpoint, still there
  in the Budget view) opening a **bottom-sheet modal**
  (`showWearPackSheet`); the trailing-cluster scaffolding
  (`_sectionCluster`/`_expandedSections`) retired with its last row. The
  old collapsed summary (temp envelope · rain) and checked/total pill
  moved into the sheet header. Deliberately **no badge** on the icon —
  health's severity count sits next door, and two adjacent numbers would
  compete for the glance. Two mechanics diverge from the health sheet:
  weather **regions are a press-time snapshot** (the screen's
  `_legClothingRecs` stays the one producer; the checklist half stays
  live via its provider — a checkbox ticked in the sheet updates the
  header pill in place), and the scrollable pads by `viewInsets.bottom`
  because this sheet hosts a TextField (the add-item row) and
  `showModalBottomSheet` applies no keyboard insets itself.
  `ChecklistSection.isOffline` became a live callback (the
  TripReviewSection trade). Known debt carried over, slightly widened:
  the checklist's offline/error snackbars render behind the sheet barrier
  — for health only success-path snackbars were affected; here errors
  are too. Accepted because the live list is the primary feedback (a
  failed toggle visibly doesn't stick); a sheet-local inline note like the
  hours-check revert is the named follow-up if it bites.

## 2026-08-12 — trip-detail dogfooding (trip health modal)

- **[app] Friction → fixed (health row → app-bar icon + badge, the 08-03
  remedy delivered):** the 08-03 resolution kept Trip health inline for
  glanceability and named the fix if reachability recurred — "surfacing the
  health pill higher"; the 08-04 cluster reorder was the stopgap. This is
  the full remedy: Trip health left the trailing cluster for a fact-check
  **app-bar icon with a severity-colored count badge** — visible from the
  first frame on every breakpoint, which answers the 08-03 "a menu would
  hide glanceable state" objection (count + worst severity are MORE
  glanceable in the app bar than below the whole itinerary). Tapping opens
  a **bottom-sheet modal** (`showTripHealthSheet`) whose body is
  `TripReviewSection` (its body-only `showHeader` knob retired with the
  row); fix flows stack their own sheets above it on the same tab
  navigator, and the list + badge live-update through the one provider
  invalidation; tapping a day-anchored finding pops the sheet, then
  scrolls. The badge needed **solid** color pairs (`AppColors.warningSolid`
  + neutral) — the .20-alpha container amber vanishes on the teal gradient.
  Cluster is now Packing → Budget. Sheet feedback contract (post-review
  hardening): a FAILED fix throws out of `_applyFix` and the sheet closes
  itself so the error snackbar is seen (never a silent no-op); a failed
  hours-check reverts to the cached list with an inline note instead of
  blanking the modal; `isOffline` is a live callback, not a bool frozen at
  open. Known debt: success-path Undo snackbars still render behind the
  open sheet on phones (primary feedback = the finding dropping off the
  list), and there is still zero usage telemetry on any of these surfaces.

## 2026-08-12 — trip-detail dogfooding (add-CTA declutter)

- **[app] Friction → fixed (one add CTA per view):** the itinerary tail
  carried three CTAs — Add stay / Add transport / Add booking — "seems
  like a lot - no need for 3 ctas here." The row was never designed into
  that spot: it's where the retired Bookings section's buttons landed when
  the section died (fad88e3), and meanwhile the new Bookings tab (#335)
  shipped with no add affordance at all. Fixed with a swap that gives each
  tab exactly one add CTA: the Itinerary keeps **Add place**, the Bookings
  view's header slot gets **+ Add booking** — a MenuAnchor fanning out to
  Stay / Transport / Other, wired to the unchanged `_addStay` /
  `_addSegment` / `_addBooking` handlers (icon-only below 800px, same rule
  and reason as Add place). The itinerary tail now shows only residual
  "Other bookings" content. Removing the row entirely was rejected: every
  other creation path is conditional (health fixes need a finding, row
  "Add details…" needs an existing todo, chat is NL-only), so the menu is
  the one unconditional path — now living where a user hunting for
  bookings actually is.

## 2026-08-12 — trip-detail dogfooding (bookings view exit)

- **[dev] Friction → watch (two in-flight lanes touched the hub file
  `trip_detail_screen.dart`):** the parallel-dev rule is "at most one
  in-flight lane may touch `trip_detail_screen.dart`" (docs/parallel-dev.md
  §Parallel Development), but the accordion-focus lane (#339) and the
  retire-trip-status lane (#338) were both open against it at once. It
  integrated cleanly *this time* — #339 merged first, then #338 rebased onto
  it with **zero git conflicts** because the two changed disjoint regions
  (focus state machine vs. the status pill/field). But "no conflict" hid a
  real trap: the rebase silently left two `Trip(status: …)` fixtures that
  #339 *added* after #338 branched — #338's field-removal diff couldn't have
  known about them — and only `flutter analyze` caught it (a clean rebase is
  not a correct one). Lessons: (1) hold the one-lane-per-hub rule at wave
  planning, not just hope the diffs miss each other; (2) when two lanes do
  overlap a hub, the integrator must run the analyzer/tests after the rebase
  even when git reports no conflicts — the dangerous case is the clean-but-
  wrong merge, where one lane's *new* code uses a symbol the other lane
  *removed*. No product impact; recorded so the next wave schedules
  `trip_detail_screen.dart` lanes serially.

- **[app] Friction → fixed (accordion city focus, supersedes the 08-11
  two-way rules):** the 08-11 city-focus feel didn't hold up in use —
  expanding one city didn't close the previously focused one; collapsing a
  non-focused group did nothing to the map while re-expanding it re-fired
  the camera; collapsing the focused group reset to All. All three were the
  documented "multi-expansion, focus = last expanded, non-focused collapse
  inert" design — the incoherence was the contract, not a bug. New
  contract, one sentence: **the open group IS the selection** — expanding a
  header (or tapping its chip) focuses its leg and closes the previous
  group; collapsing the open group, or tapping All, deselects both ways
  (map to overview, list all collapsed); Add place and Today/health
  day-links select the target leg so list and map can never disagree; a map
  pin tap stays reveal-only (camera must not refit under the zoom-to-pin);
  `<2` legs still never focus. Implementation follows docs/zen.md: the
  hand-synced `_expandedCities` set (6 writers, the drift source) is GONE —
  the open group is **derived** from the focused leg at read time via
  `TripDerivation.groupKeyForLeg` (lenses only merge runs, so leg → group
  is a function), with one narrow reveal-only field (`_unfocusedOpenLegKey`)
  for pin-tap/seed/single-leg, and one writer (`_setCityFocus`) asserting
  the two never coexist. Deriving through the group key also fixed two
  latent lens bugs for free: the desktop chip scroll targeted a leg key the
  header registry never held, and the Add-place reveal added leg keys to a
  group-keyed set — both silently inert under a places lens.

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
