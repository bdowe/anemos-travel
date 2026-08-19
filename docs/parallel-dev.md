# Parallel Development — lanes, worktrees, and the merge queue

How feature waves run with several coding agents working at once. The tooling
half lives in `scripts/worktree.sh` + the `wt-*` Makefile targets; this doc is
the process half.

## 1. The model

One feature wave = N **lanes**. One lane = one branch = one git worktree = one
coding agent = one PR (or a short PR chain). Lane agents **stop at PR-open** —
they never merge. One **integrator** session merges serially, in the order the
PRs were opened: check for conflicts → merge if there are none → otherwise
merge `main` in, resolve hub files, regenerate generated code, green CI → merge
→ next. Nothing is rebased and nothing is force-pushed (§4, §6). The prod
deploy each merge triggers runs in the background and **never blocks the next
merge** (§6); it is checked as it lands, and a red one stops the queue. Brian
approves the lane plan and steers; agents code.

Roles:

- **Lane agent** — implements exactly its lane's tasks from
  `specs/<feature>/tasks.md`, runs local checks, ships with `ship pr`
  (stop-at-PR-open mode), reports the PR URL, stops. Never merges, never
  rebases, never touches files outside its conflict manifest.
- **Integrator** — owns `main`. Runs the `/integrate` loop
  (`.claude/skills/integrate`). Only the integrator merges, and only the
  integrator pushes to a lane branch (to carry a conflict resolution). It
  tracks deploys without serializing the queue behind them, and accounts for
  every one in the wave summary.
- **Brian** — wave-planning approval, lane steering, anything requiring
  product judgment.

## 2. Two modes — and when to use which

### Mode A — orchestrator fan-out (one session)

Brian's session spawns one background coding agent per lane (Agent tool,
`isolation: "worktree"`), monitors via TaskList/TaskOutput, steers via
SendMessage, then runs `/integrate` in the same session.

Use when: lanes are well-specified or mechanical (string extraction, endpoint
+ model + provider wiring), the wave fits one sitting, and no lane needs
hands-on browser testing.

### Mode B — multi-session (N terminals)

`make wt-new NAME=<lane-branch>` per lane → one Claude Code session per
worktree → paste the lane brief → each session implements against its own dev
stack and ships to PR-open. One session (or Brian in the main checkout) runs
`/integrate`.

Use when: lanes need interactive steering or manual end-to-end testing against
a live stack, lanes span days, or Brian wants to pair on one lane while others
run.

Rule of thumb: **Mode A for width** (3–4 mechanical lanes), **Mode B for
depth** (2–3 lanes with a human in the loop). A wave can mix them.

### Lane mechanics (either mode)

```bash
make wt-new NAME=feature-x        # worktree + branch + port slot + .env copy
cd .claude/worktrees/feature-x
make docker-dev-bg                # own stack: gateway 3000+N, postgres 5432+N
make test-db                      # per-lane integration-test DB
make wt-list                      # who has which slot / what's running
make wt-rm NAME=feature-x         # after merge: stack down -v, worktree+branch gone
```

Harness-created worktrees (Mode A) self-provision with `make wt-init`.
`make` reads `.wt.env` automatically; for bare `docker`/`go` commands run
`set -a; . ./.wt.env; set +a` first — an unsourced bare command falls back to
the main stack's ports/project.

**Write `./.wt.env`, with the `./`.** In zsh — this repo's shell — `.` on a
bare relative name searches `$PATH`, not the working directory, so
`. .wt.env` fails with *"no such file or directory: .wt.env"* while the file
is sitting right there. It is one line of stderr in the middle of a compound
command, and the command then **runs anyway, against the DEFAULT project**.
That is how a lane's `docker compose … down -v` deleted the main checkout's
`development_postgres_data` instead of its own. Prefer `make`, which sources
the file itself; when you must go bare, pass `-p "$GTT_PROJECT"` explicitly
so the target is named in the command rather than inherited from an
environment that may not have loaded.

**Booting the stack breaks the host analyzer — `flutter pub get` fixes it.**
The Flutter dev container runs its own `flutter pub get` against the *mounted*
source tree, and the file it writes,
`src/packages/flutter-app/.dart_tool/package_config.json`, holds absolute
paths to the SDK. It comes back pointing at the container's
(`file:///flutter/packages/flutter`) instead of the host's
(`file:///opt/homebrew/share/flutter/...`), so every host tool that reads it
sees no Flutter at all:

```
error - Target of URI doesn't exist: 'package:flutter/material.dart'
error - Undefined class 'State'.  (…~32k more)
```

Nothing is wrong with the branch. Run `flutter pub get` on the **host**, from
`src/packages/flutter-app`, and it is over — the file is gitignored and
per-worktree, so this affects no one else and nothing needs committing.

What makes it cost time is that **it does not look like a tooling problem**:
the gates stay green, because `flutter analyze` and `flutter test` each run an
implicit `pub get` and silently repair the file before doing anything. Only
the tools that don't — your editor's analysis server, and bare `dart analyze`
— report the wall of errors. So the failure shows up as "my IDE says the
branch is broken while every check passes", which reads like a bad merge.
Expect it again after any `docker-dev` restart.

## 3. Lane partitioning rules (the hub table)

Measured over 144 merged PRs (2026-06-15 → 07-31). Wave planning must check
these **before** fan-out; they are the four constraints in the tasks.md Lanes
template.

| Surface | Hit rate | Planning rule | On conflict (integrator) |
|---|---|---|---|
| `lib/screens/trip_detail_screen.dart` | 31% of PRs | **≤ 1 lane per wave.** This 5,900-line god-screen is the throughput governor: beyond 3–4 lanes you usually can't find work that avoids it. | Should never conflict (single writer). |
| `api/main.go` (buildRouter) | 30% | No constraint — any lane may add routes. | Trivial adjacent-line conflicts; take both, keep the route grouping. |
| `app_en.arb` + `app_es.arb` | 45% of recent PRs | Each lane declares a unique key prefix (e.g. `tripBudget*`) in its manifest. | Take both key sets on the `.arb`s; **never** hand-edit `app_localizations*.dart` — regen LAST. |
| `api/migrations/` | 15% | Numbers **reserved at wave planning** (`ls src/packages/api/migrations \| tail -1` → next free). ≤ 1 migration per lane. A new number must be **strictly greater than main's highest** — never fill a gap (see §4a). CI guards duplicates and out-of-order numbers. | Renumber per reservation; never merge two files onto one number. |
| `api/plan_tool_registry.go` | low freq, **high severity** | **≤ 1 tool-adding lane in flight.** Registry order = the Anthropic prompt-cache prefix; append-at-tail only. A reorder-merge silently destroys prompt caching — no test fails. Tool *implementations* in separate `plan_tools_*.go` files are parallel-safe. | Keep main's order byte-stable; re-append the new entry at the tail. |
| `store/` (sqlc) | 19% | Never a planning constraint. | Regen, don't merge (§4). |
| `lib/models/*.g.dart`, `lib/l10n/app_localizations*.dart` | — | Same. | Regen, don't merge (§4). |
| `.env.sample`, `CLAUDE.md` | 15% / 9% | Append-only; no constraint. | Take both. |

## 4a. Migration numbers only ever go up — 00058 is burned

A migration number below the highest number **already deployed** can never be
merged, no matter how long the gap has sat empty. `db.go` calls `goose.Up`
without `WithAllowMissing`, so goose refuses any unapplied version below the
database's current max (`found N missing migrations before current version M`),
and `main.go` turns that into `log.Fatalf` — the API exits before binding its
port and crash-loops with the previous container already replaced. It is a full
outage, and the deploy only goes red ~5 minutes later.

Nothing upstream catches it: the "Migrations apply from zero" CI job starts
from an empty database, where any ordering is trivially valid, and the
duplicate guard sees no collision because a gap-fill collides with nothing.
That is why the **out-of-order guard** now runs in the same CI job — it is the
only check that can see this class.

**00058 is permanently burned.** Production applied 00057 → 00059 → 00060, so
58 is forever below the floor. It is not a free slot; it is a hole. Do not
"tidy up" the sequence by filling it, and do not enable `WithAllowMissing` to
make it merge — that would trade one loud, zero-damage crash for silent
order-dependent schema state across the whole repo.

How the hole appeared, so it isn't repeated: PR #350 was stacked on PR #349's
branch and merged **into that branch 47 minutes after the branch itself had
already merged to main**. GitHub reports #350 as MERGED, but its commits —
including `00058_expense_booking_link.sql` — only ever reached
`origin/budget-v2`. **When a stacked PR's base merges first, retarget the child
to `main` before merging it**, and check `git merge-base --is-ancestor
<merge-commit> origin/main` rather than trusting the MERGED badge.

## 4. Regen-not-merge doctrine

`store/` (sqlc), `lib/l10n/app_localizations*.dart` (gen-l10n), and
`lib/models/*.g.dart` (build_runner) are committed and CI-drift-checked. When a
PR conflicts with `main` in generated files you **never hand-merge them**:

1. In the lane's worktree (the branch is checked out there):
   `git fetch origin && git merge origin/main`
2. Hand-resolve ONLY hand-written sources — once, not once per commit:
   `query/*.sql`, `migrations/*.sql`, the `.arb`s (take both key sets),
   `lib/models/*.dart`, `main.go`, `.env.sample`, `plan_tool_registry.go`
   (main's order + your tail append).
3. For conflicted **generated** files take main's side without reading the
   diff — in a merge, main is the side coming IN, so it is `--theirs`:
   ```bash
   git checkout --theirs -- src/packages/api/store \
     src/packages/flutter-app/lib/l10n/app_localizations*.dart \
     'src/packages/flutter-app/lib/models/*.g.dart'
   git add -A && git commit
   ```
   ⚠️ This inverts if you ever rebase instead: **during a rebase `--ours` is
   the branch you are rebasing ONTO**, i.e. main. Both spellings mean "take
   main"; getting one backwards silently ships main's *stale* generated code
   into the lane, and no conflict marker is left to notice.
4. **After** the merge is committed — sources settled — regenerate everything:
   `make api-sqlc` · `make flutter-gen-l10n` · `make flutter-build-models`.
   The three are independent of each other, but all run after ALL hand
   resolution is done ("regen LAST").
5. Commit the regen output, run
   `make api-fmt && make api-vet && make flutter-analyze` + targeted tests,
   then `git push` — plain, no force. A merge commit fast-forwards the lane
   branch, so there is nothing to force.

## 5. Wave sizing — 2–4 lanes, usually 3

- `trip_detail_screen.dart` is in ~1 of 3 PRs: in a wave of k typical lanes,
  expected god-screen touchers ≈ 0.31k. Past 3–4 lanes you can't fill a wave
  that avoids it. (Splitting that screen is the single biggest future unlock.)
- Integration is serial, but only a *conflicting* PR is expensive: a clean one
  is a conflict check plus `gh pr merge` (seconds, without leaving the main
  checkout), while merge + regen + CI wait + merge is the ~10–20 min tail a
  conflicting one pays (§6). The prod deploy each merge triggers is queued and
  self-verifying, but sits **off** the critical path (§6), so it never adds to
  the per-PR cost — it only stops the queue if it goes red. The integrator tail
  now scales with how many lanes actually collided, not with how many lanes
  there were.
- The ≤1-migration-per-lane and single-registry-lane rules cap schema- or
  agent-tool-heavy waves regardless.
- Each Mode-B lane also runs a full 4-container stack (~1–2 GB peak during the
  Flutter compile) — ~3 concurrent stacks is a realistic laptop ceiling.

## 6. The integrator merge queue

Summary (the operational skill is `.claude/skills/integrate` — run
`/integrate`): one PR at a time, **in the order the PRs were opened**
(`gh pr list --json createdAt`, ascending). Check for conflicts first —
`git merge-tree --write-tree --name-only origin/main origin/<branch>`, exit 0 =
clean. **Clean → merge it** (`gh pr merge --merge --delete-branch`): no rebase,
no force-push, no worktree, no CI re-run. **Conflicts → merge `origin/main`
into the lane branch** inside its worktree, resolve per §3–4, regen, local
checks, plain `git push`, wait green, merge. Either way: **start the next PR
immediately; do NOT wait for the deploy**.

Two exceptions to PR-open order, both cheaper to obey than to repair: a
**stacked PR waits for its base** and is retargeted to `main` first (§4a — this
is how 00058 was burned), and **migration-carrying PRs go in ascending
migration number** among themselves, since a lower number landing after a
higher one is refused by CI and forces a renumber. The `tasks.md` dependency
edges are advisory now — a sanity check on those two cases, not the sequencer.

What skipping the rebase costs, and what is kept: both CI migration guards read
the PR **merge ref** / live `origin/main` **at run time**, so they never needed
a rebase — only a fresh *run*. A green badge is therefore only as fresh as the
PR's last run. That matters for exactly one class: a competing migration merged
since then produces no textual conflict (different filenames) and lands as a
boot-time crash-loop (§4a), so `/integrate` keeps a local migration-floor check
on every PR that adds one. Everything else a stale run could hide — cross-lane
Go↔Dart contract drift, codegen drift — is a red check, and is now caught by
`main`'s own CI instead of the integrator's local run: the queue stops and the
fix goes forward on main.

The prod deploy each merge triggers is self-verifying and runs off the
critical path. Check the ones already in flight between merges, and **the
moment one FAILS, stop the queue** — fix forward on main (or revert) and
resume only when prod is green, because a broken deploy under a stacked queue
is un-bisectable.

**A `cancelled` main run is not a failure.** Back-to-back merges queue their
deploys, and GitHub keeps only the newest *pending* run in the concurrency
group (`cancel-in-progress` is false for main, so nothing is ever killed
mid-deploy). Superseded runs are cancelled before executing a single job —
check `gh run view <id> --json jobs`: `0` jobs means superseded, not broken.
The surviving run builds a main that already contains the cancelled runs'
commits.

**A run that was never created is a third state, and the jobs check cannot see
it.** On 2026-08-19 three merges 5-6 seconds apart produced runs for only the
first two; main's tip had zero check-runs. It is not the superseded case — the
concurrency group keeps the newest *pending* run, so a run for the tip would
have cancelled its predecessor, and instead the predecessor survived and ran.
This matters because `build-push` tags images with `github.sha` and `deploy`
defaults `IMAGE_TAG` to the same: **a run ships its own commit, not main's
tip**, so a missing run leaves the last merged PR on main and out of
production with every check green. `workflow_dispatch` cannot repair it (its
`image_tag` needs an already-built image and `build-push` is push-only); the
remedy is an empty commit to recreate the push event.

So the wave is verified by its **last** deploy, not by each one — and "last"
means *the run whose head SHA equals main's tip*, asserted by SHA rather than
by recency (`gh api repos/<owner>/<repo>/commits/$(git rev-parse origin/main)/check-runs`),
never by picking the newest run off the list. Watch it to green, read the
verdict from `gh run view --json conclusion` rather than `gh run watch
--exit-status` (which has misreported in both directions), and confirm prod
serves the new SHA before calling the wave done. Not blocking is a bet that
deploys usually pass, never a reason to skip that final check.

Who fixes a red check: **the integrator fixes anything integration created**
(hub resolution, cross-lane contract parity, codegen drift, fmt);
**lane agents fix anything already wrong inside their lane** (hand back via
SendMessage in Mode A, the lane's terminal in Mode B). Tie-breaker: if the
failure reproduces on the lane branch *before* integration, it's the lane's.

## 7. Wave runbook

> Shortcuts: `/wave <plans…>` automates Mode A end to end (steps 1–6 with one
> approval pause at the lane table, then auto-`/integrate`); `/lane NAME`
> bootstraps a Mode B worktree with a `LANE-BRIEF.md`. The steps below remain
> the underlying reference.

1. **Plan** — planning agents (read-only, parallel — this part already works)
   draft the Lanes section of `specs/<feature>/tasks.md`: per-lane branch,
   tasks, conflict manifest, reserved migration numbers, dependency edges.
   Check the four constraints (§3). Brian approves the lane table.
2. **Preflight** — main green in CI, no deploy in flight, `make wt-list`
   clean, `git status` clean.
3. **Fan out** — Mode A: one background agent per lane with worktree
   isolation; Mode B: `make wt-new` + one terminal per lane. The lane brief =
   paths to `spec.md`/`plan.md`, the lane's task rows + conflict manifest
   verbatim, the reserved migration number, and the closing instruction:
   *"Run local checks, then `ship pr`. Report the PR URL. Do not merge. Do
   not touch files outside your manifest."*
4. **Monitor** — TaskList / TaskOutput / SendMessage (Mode A) or the
   terminals (Mode B). Collect PR URLs.
5. **Integrate** — `/integrate`, in PR-open order (§6).
6. **Close** — `make wt-rm` per merged lane, confirm prod SHA + health, check
   off the spec's acceptance criteria.

## 8. Fragment-file pattern (many-agent mechanical work)

For >2 lanes that would contend on the ARBs (or any single hub file), use the
pattern proven by the i18n-spanish extraction: each agent writes disjoint
fragment files (`lib/l10n/_frag_<lane>.json`), and one fold-in lane merges
them into the real file and regenerates. Contention on the hub drops to one
writer; the mechanical lanes become fully parallel.
