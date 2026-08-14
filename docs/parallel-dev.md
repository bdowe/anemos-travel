# Parallel Development — lanes, worktrees, and the merge queue

How feature waves run with several coding agents working at once. The tooling
half lives in `scripts/worktree.sh` + the `wt-*` Makefile targets; this doc is
the process half.

## 1. The model

One feature wave = N **lanes**. One lane = one branch = one git worktree = one
coding agent = one PR (or a short PR chain). Lane agents **stop at PR-open** —
they never merge. One **integrator** session merges serially: rebase → resolve
hub files → regenerate generated code → green CI → merge → watch the deploy →
next. Brian approves the lane plan and steers; agents code.

Roles:

- **Lane agent** — implements exactly its lane's tasks from
  `specs/<feature>/tasks.md`, runs local checks, ships with `ship pr`
  (stop-at-PR-open mode), reports the PR URL, stops. Never merges, never
  rebases, never touches files outside its conflict manifest.
- **Integrator** — owns `main`. Runs the `/integrate` loop
  (`.claude/skills/integrate`). Only the integrator rebases, force-pushes
  (`--force-with-lease`), merges, and watches deploys.
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
`set -a; . .wt.env; set +a` first — an unsourced bare command falls back to
the main stack's ports/project.

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
`lib/models/*.g.dart` (build_runner) are committed and CI-drift-checked. On a
rebase that conflicts in generated files you **never hand-merge them**:

1. `git fetch origin && git rebase origin/main`
2. In each conflicted commit, hand-resolve ONLY hand-written sources:
   `query/*.sql`, `migrations/*.sql`, the `.arb`s (take both key sets),
   `lib/models/*.dart`, `main.go`, `.env.sample`, `plan_tool_registry.go`
   (main's order + your tail append).
3. For conflicted **generated** files take main's side without reading the
   diff — during a rebase `--ours` is the branch you're rebasing ONTO:
   ```bash
   git checkout --ours -- src/packages/api/store \
     src/packages/flutter-app/lib/l10n/app_localizations*.dart \
     'src/packages/flutter-app/lib/models/*.g.dart'
   git add -A && git rebase --continue
   ```
4. **After** the rebase completes — sources settled — regenerate everything:
   `make api-sqlc` · `make flutter-gen-l10n` · `make flutter-build-models`.
   The three are independent of each other, but all run after ALL hand
   resolution is done ("regen LAST").
5. Commit the regen output, run
   `make api-fmt && make api-vet && make flutter-analyze` + targeted tests,
   then `git push --force-with-lease`.

## 5. Wave sizing — 2–4 lanes, usually 3

- `trip_detail_screen.dart` is in ~1 of 3 PRs: in a wave of k typical lanes,
  expected god-screen touchers ≈ 0.31k. Past 3–4 lanes you can't fill a wave
  that avoids it. (Splitting that screen is the single biggest future unlock.)
- Integration is serial: rebase + regen + CI wait + merge + deploy watch is
  ~15–25 min per PR, and every merge to main is a queued, self-verifying prod
  deploy. Four lanes ≈ a 1.5 h integrator tail; beyond that the parallel
  coding gain is eaten by the tail.
- The ≤1-migration-per-lane and single-registry-lane rules cap schema- or
  agent-tool-heavy waves regardless.
- Each Mode-B lane also runs a full 4-container stack (~1–2 GB peak during the
  Flutter compile) — ~3 concurrent stacks is a realistic laptop ceiling.

## 6. The integrator merge queue

Summary (the operational skill is `.claude/skills/integrate` — run
`/integrate`): merge in dependency order; one PR at a time; rebase (inside the
lane's worktree — the branch is checked out there) → resolve per §3–4 →
local checks → `--force-with-lease` → wait green (the rebase rerun
is also what makes the duplicate-migration CI guard bite) → merge → **watch
the deploy until prod serves the new SHA before starting the next merge** — a
broken deploy under a stacked queue is un-bisectable.

Who fixes a red check: **the integrator fixes anything integration created**
(hub resolution, cross-lane contract parity, codegen drift, fmt);
**lane agents fix anything already wrong inside their lane** (hand back via
SendMessage in Mode A, the lane's terminal in Mode B). Tie-breaker: if the
failure reproduces on the lane branch *before* the rebase, it's the lane's.

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
5. **Integrate** — `/integrate`, in the tasks.md merge order.
6. **Close** — `make wt-rm` per merged lane, confirm prod SHA + health, check
   off the spec's acceptance criteria.

## 8. Fragment-file pattern (many-agent mechanical work)

For >2 lanes that would contend on the ARBs (or any single hub file), use the
pattern proven by the i18n-spanish extraction: each agent writes disjoint
fragment files (`lib/l10n/_frag_<lane>.json`), and one fold-in lane merges
them into the real file and regenerates. Contention on the hub drops to one
writer; the mechanical lanes become fully parallel.
