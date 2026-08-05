# Friction log

Running log of what broke, what dragged, and what kept coming up — feeds the
build queue. Priority when picking work: **breakage > friction in features
actually used > ideas that recur across ≥2 sessions**. Tag entries `[app]`
(dogfooding the product) or `[dev]` (workflow/tooling). Newest first.

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
