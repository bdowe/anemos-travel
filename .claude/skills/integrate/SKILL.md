---
name: integrate
description: Serially merge a wave of open lane PRs — rebase, resolve hub files, regenerate generated code, wait for green CI, merge, repeat. Deploys run in the background and never block the next merge. Use after a parallel wave's lane agents have stopped at PR-open.
---

# Integrate a wave of lane PRs

Preconditions: you are the ONLY session merging; working tree clean; on
`main`; `gh pr list` shows the wave's PRs; the merge order is the Lanes
section of the feature's `specs/<feature>/tasks.md`. Rationale for every rule
here: `docs/parallel-dev.md` §3–6.

## The loop — repeat per PR, in dependency order

1. **Pick** the next PR whose dependency edges are all merged. Never merge
   around an edge; if the next PR is blocked, an *independent* PR may go
   first.

2. **Rebase** its branch onto `origin/main`. While the lane's worktree exists,
   its branch is checked out THERE — `git checkout <branch>` in the main
   checkout will refuse. Work inside the lane's worktree instead:
   `git fetch origin && cd .claude/worktrees/<lane> && git rebase origin/main`.
   (Only if the worktree is already gone: `git checkout <branch>` in the main
   checkout.) Steps 3–5 run in that same directory — its `.wt.env` keeps the
   make targets pointed at the lane's own stack.

3. **Resolve** conflicts per the hub table (`docs/parallel-dev.md` §3):
   hand-written hubs by hand (`main.go` / `.env.sample` / `CLAUDE.md` = take
   both; `.arb`s = take both key sets; `plan_tool_registry.go` = main's order
   + tail append, never reorder; migrations = the lane's reserved number).
   Conflicted **generated** files: take main's side unread
   (`git checkout --ours -- src/packages/api/store src/packages/flutter-app/lib/l10n/app_localizations*.dart 'src/packages/flutter-app/lib/models/*.g.dart'`),
   then after the whole rebase completes, regen LAST:
   `make api-sqlc` · `make flutter-gen-l10n` · `make flutter-build-models`,
   and commit the regen output.

4. **Check locally**: `make api-fmt && make api-vet && make flutter-analyze`,
   plus `make api-test-go` / `make flutter-test` for the sides the lane
   touched. Verify any migration still carries its reserved number.

5. **Push**: `git push --force-with-lease`. This is the ONE sanctioned
   force-push in this repo: the integrator, after a rebase, on a lane branch
   whose agent has stopped.

6. **Wait green**: `gh pr checks <number> --watch`. (This rerun is also what
   arms the duplicate-migration guard against anything merged since the
   lane's last CI run.)

7. **If red, classify before touching anything**:
   - *Integration-caused* — hub resolution, cross-lane Go↔Dart contract
     parity, codegen drift, l10n coverage, fmt/vet: **fix inline**, you
     created it.
   - *In-lane failure* — reproduces on the lane branch before the rebase, or
     the fix would rewrite lane logic: **hand back** to the owning agent
     (SendMessage in Mode A; the lane's terminal in Mode B) and integrate an
     independent PR meanwhile.

8. **Merge**: `gh pr merge <number> --merge --delete-branch`.

9. **Start the deploy, but do NOT block the queue on it**: every main merge
   triggers build-push → a self-verifying prod deploy. Go straight to
   rebasing the next PR — **do not wait for "Verify deployed release"**.
   Brian's standing instruction: a multi-PR wave otherwise spends most of its
   wall-clock idling on `gh run watch`, and the deploy is self-verifying with
   its result still visible afterward.

   **The safety valve stays — it is just moved, not removed.** Check the
   deploys you already started between merges (a non-blocking
   `gh run list --branch main --limit 3` is enough), and the moment one goes
   red: **stop the queue**, fix forward on main (or revert), resume only when
   prod is green. A broken deploy under a stacked queue is un-bisectable, so
   not-blocking is a bet that deploys usually pass — never a licence to leave
   a failure unnoticed. Every deploy must be accounted for by step 10.

10. **Next PR.** When the queue is empty: return to the main checkout,
    `git checkout main && git pull`, then `make wt-rm NAME=<lane>` for each
    merged lane (from the main checkout — it deletes the lane's worktree and
    branch), and report the wave summary — PRs merged, **the outcome of every
    deploy the wave started** (confirm each one actually landed before
    declaring the wave done; this is where the step-9 watch was traded for),
    final prod SHA.

## Notes

- Lane agents never rebase or merge; if a lane branch moved after its agent
  stopped, assume the integrator (you) moved it.
- If two queued PRs turn out to collide semantically (not textually — e.g.
  both changed the same behavior), pause and surface it to Brian rather than
  picking a winner silently.
