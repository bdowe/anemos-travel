# Friction log

Running log of what broke, what dragged, and what kept coming up — feeds the
build queue. Priority when picking work: **breakage > friction in features
actually used > ideas that recur across ≥2 sessions**. Tag entries `[app]`
(dogfooding the product) or `[dev]` (workflow/tooling). Newest first.

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
