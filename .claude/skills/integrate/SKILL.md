---
name: integrate
description: Serially merge a wave of open lane PRs in PR-open order — check for conflicts, merge straight away if there are none, resolve first if there are. Deploys run in the background and never block the next merge. Use after a parallel wave's lane agents have stopped at PR-open.
---

# Integrate a wave of lane PRs

Preconditions: you are the ONLY session merging; the main checkout is clean and
on `main`; `gh pr list` shows the wave's PRs. Rationale for every rule here:
`docs/parallel-dev.md` §3–6.

**The shape of this loop:** most lane PRs do not conflict with `main` — that is
what the hub table's partitioning rules are FOR. So a PR pays only for what it
actually needs: a conflict check, then either a merge (seconds, never leaving
the main checkout) or the resolve tail. Nothing is rebased and nothing is
force-pushed.

## 0. Build the queue — PR-open order

```bash
git fetch origin --prune
gh pr list --state open \
  --json number,title,createdAt,headRefName,baseRefName,isDraft \
  --jq 'sort_by(.createdAt)[] | "\(.number)\t\(.createdAt)\t\(.baseRefName)\t\(.headRefName)"'
```

Oldest `createdAt` first. Exactly **two** exceptions, both cheaper to obey than
to repair:

- **A stacked PR waits for its base.** If `baseRefName` is another open lane
  branch, skip it; when the base merges, retarget it
  (`gh pr edit <n> --base main`) and it re-enters at its own slot. This is the
  migration-00058 outage class (`docs/parallel-dev.md` §4a): PR #350 was merged
  into a branch that had already merged to main, so GitHub says MERGED while its
  migration never reached main. Confirm with
  `git merge-base --is-ancestor <merge-commit> origin/main`, never the badge.
- **Migration-carrying PRs merge in ascending migration number** among
  themselves, whatever order they were opened in. Numbers are reserved at wave
  planning in ascending order; landing a lower number after a higher one is
  refused by CI's out-of-order guard and forces a renumber plus a full CI
  re-run — pure overhead, avoided by ordering.

The `specs/<feature>/tasks.md` dependency edges are now **advisory**: read them
as a sanity check on the two exceptions above, not as the sequencer.

## 1. Conflict check — one command, no checkout

```bash
git fetch origin
git merge-tree --write-tree --name-only origin/main origin/<headRefName>
```

Exit `0` = clean → step 2a. Exit `1` = conflicts, and the output names the
conflicted paths → step 2b.

Use this rather than `gh pr view --json mergeable`: GitHub computes mergeability
asynchronously and answers `UNKNOWN` for a while after the base moves.

## 2a. Clean → merge

1. **Checks green on the PR's own head**: `gh pr checks <n>`. Pending means
   wait. Red means it is the lane's problem — hand it back (see step 4) and take
   the next PR.

2. **Migration floor** — only if the PR adds `src/packages/api/migrations/*.sql`:

   ```bash
   gh pr diff <n> --name-only | grep '^src/packages/api/migrations/'
   git ls-tree --name-only origin/main -- src/packages/api/migrations/ | tail -1
   ```

   Every added number must be **strictly greater** than main's highest.

   This is the one check that must survive skipping the rebase, and it is the
   only place this loop spends effort on a clean PR. Both CI migration guards
   read live `origin/main` (the out-of-order guard) or the PR merge ref (the
   duplicate guard) **at run time** — so they are only as fresh as the PR's last
   run. A competing migration that merged since then is invisible behind a green
   badge, produces no textual conflict (different filenames — a gap-fill
   "collides with nothing", §4a), and lands as `goose` refusing at boot:
   `log.Fatalf` before the port binds, a crash-loop outage that only goes red
   ~5 minutes later. Failing this check means renumber, which drops the PR into
   step 2b.

3. **Merge**, from the main checkout:
   `gh pr merge <n> --merge --delete-branch`.

   No rebase, no force-push, no worktree, no CI re-run. (`deleteBranchOnMerge`
   is `false` on this repo so the flag stays. The *local* branch delete may warn
   because the branch is checked out in the lane's worktree — harmless,
   `make wt-rm` finishes the job in step 6.)

## 2b. Conflicts → merge main in, resolve once, then merge

The lane's branch is checked out in its worktree, so `git checkout <branch>` in
the main checkout will refuse. Work there:

```bash
cd .claude/worktrees/<lane>
git fetch origin && git merge origin/main
```

(Only if the worktree is already gone: `git checkout <branch>` in the main
checkout.) The rest of this step runs in that same directory — its `.wt.env`
keeps the make targets pointed at the lane's own stack.

1. **Resolve** hand-written hubs by hand, per the hub table
   (`docs/parallel-dev.md` §3): `main.go` / `.env.sample` / `CLAUDE.md` = take
   both; `.arb`s = take both key sets; `plan_tool_registry.go` = main's order +
   tail append, never reorder; migrations = the lane's reserved number.

2. **Conflicted generated files: take main's side unread.** Under
   `git merge origin/main` on the lane branch, main is **`--theirs`**:

   ```bash
   git checkout --theirs -- src/packages/api/store \
     src/packages/flutter-app/lib/l10n/app_localizations*.dart \
     'src/packages/flutter-app/lib/models/*.g.dart'
   ```

   ⚠️ This is the **inverse** of the rebase spelling (`--ours`), which is what
   this loop used to run and what §4 of the doc still explains for historical
   reference. Getting it backwards silently ships main's *stale* generated code
   into the lane. Verified empirically, both directions.

3. `git add -A && git commit` to conclude the merge, then **regen LAST** —
   sources settled first:
   `make api-sqlc` · `make flutter-gen-l10n` · `make flutter-build-models`.
   Commit the regen output.

4. **Check locally**: `make api-fmt && make api-vet && make flutter-analyze`,
   plus `make api-test-go` / `make flutter-test` for the sides the lane touched.
   Verify any migration still carries its reserved number.

5. **Push**: `git push`. Plain — a merge commit is a fast-forward on the lane
   branch, so nothing needs forcing. There is no longer any sanctioned
   force-push in this repo.

6. **Wait green**: `gh pr checks <n> --watch`. This re-run is also what re-arms
   both migration guards against everything merged since the lane's last run.

7. **Merge** as in 2a.3.

## 3. Deploys — start them, never queue behind them

Every main merge triggers build-push → a self-verifying prod deploy. Go straight
to the next PR — **do not wait for "Verify deployed release"**. Brian's standing
instruction: a multi-PR wave otherwise spends most of its wall-clock idling on
`gh run watch`, and the deploy is self-verifying with its result still visible
afterward.

**The safety valve stays — it is just moved, not removed.** Check the deploys
you already started between merges (a non-blocking
`gh run list --branch main --limit 5` is enough), and the moment one **fails**:
stop the queue, fix forward on main (or revert), resume only when prod is green.
A broken deploy under a stacked queue is un-bisectable, so not-blocking is a bet
that deploys usually pass — never a licence to leave a failure unnoticed.

**`cancelled` on a main run is normal here — do NOT treat it as a failure.**
Merging back-to-back is exactly what this loop encourages, so main deploy runs
queue up, and GitHub keeps only the newest *pending* run in the concurrency
group (`ci-${{ github.ref }}`, `cancel-in-progress` is false for main — see
`.github/workflows/ci.yml`). The superseded ones are cancelled **before running
a single job**, so nothing was interrupted mid-deploy and nothing is lost: the
surviving run builds the newest main, which already contains every commit the
cancelled ones would have shipped. Tell the two apart by the jobs list, not the
badge — `gh run view <id> --json jobs --jq '.jobs|length'` returns `0` for a
superseded run and non-zero for one that actually ran and broke.

**A run that was never created is a THIRD state, and the jobs check cannot see
it** — there is no run to inspect. Observed 2026-08-19: three merges 5–6 seconds
apart produced runs for only the first two; main's tip had **zero** check-runs.
It is not the superseded case — main's concurrency keeps the newest *pending*
run, so a run for the tip would have cancelled its predecessor; instead the
predecessor survived and ran. Merging back-to-back is what this loop encourages,
so this window is one the loop actively creates. Step 6.1 is the check for it.

The consequence: **a wave is only verified when its LAST deploy succeeds.**
Intermediate `cancelled` runs prove nothing either way, so step 6's accounting
is load-bearing rather than a formality.

## 4. When something is red, classify before touching anything

- *Integration-caused* — hub resolution, cross-lane Go↔Dart contract parity,
  codegen drift, l10n coverage, fmt/vet: **fix inline**, you created it.
- *In-lane failure* — reproduces on the lane branch before integration, or the
  fix would rewrite lane logic: **hand back** to the owning agent (SendMessage
  in Mode A; the lane's terminal in Mode B) and integrate an independent PR
  meanwhile.

## 5. A red `main` after a clean merge — the trade this loop accepts

Skipping the rebase means skipping a CI run against the current main, and
skipping the local checks means cross-lane **semantic** drift is no longer
caught before the merge. Lane A renames a Go field, lane B adds a Dart call
site: no textual conflict, both PRs green, main goes red. (`docs/friction-log.md`
— *"a clean rebase is not a correct one"* — is the recorded instance of this
class. It was never a git-conflict problem, so the rebase was not what caught it
either; the local analyzer run was.)

What is deliberately kept vs traded:

| Was caught by | Now caught by |
|---|---|
| Rebase CI re-run: duplicate / out-of-order migration | Step 2a.2 migration floor — local, seconds, because the failure is an outage not a red check |
| Integrator local checks: cross-lane contract drift, codegen drift | `main`'s own CI/deploy → stops the queue → fix forward |
| Force-push + rebase: tidy lane history | Nothing. No policy required it — `main` has no branch protection and already carries merge bubbles |

Procedure when main goes red: **stop the queue and fix forward on main.** The
merge is already in, so reverting is the wrong default unless the fix is not
obvious. Resume when green.

Escalation valve: if a PR looks stale *and* touches a risky surface,
`gh run rerun <pr-run-id>` re-arms both migration guards against the current
main without touching the branch. Safe on a **PR** run — never on a **main**
run, which would redeploy an old SHA.

## 6. Next PR, then close out

When the queue is empty: `git checkout main && git pull`, then
`make wt-rm NAME=<lane>` for each merged lane (from the main checkout — it
deletes the lane's worktree and branch). Then the deploy accounting below, which
is what step 3's per-merge watch was traded for and is the one deploy check that
must not be skipped.

### 6.1 Assert a run EXISTS for main's tip — before watching anything

**Never assume the newest run corresponds to the tip.** Resolve the tip's SHA
and ask for *its* runs by SHA, not by recency:

```bash
git fetch origin -q
SHA=$(git rev-parse origin/main)
gh api "repos/golden-tempo/anemos-travel/commits/$SHA/check-runs" --jq .total_count
```

`0` means no workflow was ever created for that push. Poll for a minute before
concluding it (run creation is not instant), then treat it as a **stop**, not a
formality: this is the state step 3 describes, and no amount of inspecting the
newest run will reveal it — that run is green and belongs to a different commit.

Why the distinction is load-bearing rather than pedantic: `build-push` tags
images `ghcr.io/...:${{ github.sha }}` and `deploy` uses
`IMAGE_TAG: ${{ github.event_name == 'workflow_dispatch' && inputs.image_tag || github.sha }}`.
**A run ships its OWN commit, not main's tip.** So a missing run for the tip
means the last merged PR is on main and not in production, with every check
green and nothing to notice.

**`workflow_dispatch` cannot repair it.** Its `image_tag` input requires the SHA
of *a previously green main build*, and `build-push` is gated
`if: github.event_name == 'push'`, so dispatch never builds. No image exists for
the tip. The remedy is a push event that never happened:

```bash
git commit --allow-empty -m "chore(ci): trigger the deploy main's tip never got"
git push origin main
```

Do it **after** any in-flight deploy completes, so deploy order stays clean, and
only once that one is green — a failure still stops the queue. Then re-run the
check above and confirm the count is non-zero before moving on.

### 6.2 Watch that run to a green finish — but do not trust the exit code

`gh run watch <id> --exit-status` is the natural spelling and has misreported
twice in one day: piped (`| tail`) it returns the **pipe's** exit code, and
unpiped it returned `1` on a run that concluded `success` (a transient
`api.github.com` timeout during the watch, not a red deploy). Read the verdict
from the run itself:

```bash
until [ "$(gh run view <id> --json status --jq .status)" = completed ]; do sleep 25; done
gh run view <id> --json conclusion --jq .conclusion      # this is the answer
gh run view <id> --json jobs --jq '.jobs[] | "\(.name): \(.conclusion)"'
```

Superseded `cancelled` runs are expected and need no action; a `failure` does.

### 6.3 Confirm production actually serves the tip

`/health` `release` or `/app/version.json` must equal `git rev-parse HEAD`.
This is the only step that speaks for what is really running, and it is what
catches 6.1's failure mode even if every other check was skipped.

Then report the wave summary: PRs merged, the path each took, and the deploy
that shipped them.

## Notes

- Lane agents never merge, rebase, or integrate; if a lane branch moved after
  its agent stopped, assume the integrator (you) moved it.
- If two queued PRs turn out to collide semantically (not textually — e.g. both
  changed the same behavior), pause and surface it to Brian rather than picking
  a winner silently.
