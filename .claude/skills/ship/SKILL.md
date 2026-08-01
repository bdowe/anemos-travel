---
name: ship
description: Commit the current changes, push a branch, open a PR, and merge it. Use when the user asks to "ship" the current work or to commit/push/PR/merge in one go. `ship pr` stops at PR-open — required for parallel-wave lane agents (the integrator merges).
---

# Ship the current changes

Take the working-tree changes through commit → push → PR → merge.

## Modes

- `ship` (default) — the full pipeline through merge. Solo, single-lane work.
- `ship pr` — stop after step 5 (`gh pr create`). Report the PR URL and STOP:
  do not merge, do not switch back to `main` (the integrator will rebase this
  branch). Required for lane agents in a parallel wave (`docs/parallel-dev.md`).
- **Auto-detection**: if running inside a linked worktree
  (`git rev-parse --git-dir` differs from `git rev-parse --git-common-dir`),
  behave as `ship pr` even if no argument was given — worktree agents are wave
  lanes and never merge.

## Steps

1. **Inspect the tree**: run `git status --short` and `git diff --stat`. If the tree contains changes unrelated to the work just done, stop and ask which files to include rather than committing everything blindly. If the tree is clean, say so and stop.

2. **Branch**: if currently on `main`, create a descriptive kebab-case branch named after the change (e.g. `trip-detail-title`). If already on a feature branch, stay on it.

3. **Commit**: stage only the relevant files (explicit paths, not `git add -A` unless everything belongs). Write a conventional-commit message (`feat:`, `fix:`, `test:`, …) with a short body explaining the why. End the message with:

   ```
   Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
   ```

4. **Push**: `git push -u origin <branch>`.

5. **Open the PR**: `gh pr create` with a `## Summary` bullet list and a `## Testing` section describing what was run (analyzer, tests, manual verification). End the body with:

   ```
   🤖 Generated with [Claude Code](https://claude.com/claude-code)
   ```

6. **Merge** *(default mode only — skipped in `pr` mode)*: `gh pr merge <number> --merge --delete-branch`. This also switches local back to `main` and fast-forwards it.

7. **Report**: give the user the PR URL; in default mode confirm the merge landed on `main`, in `pr` mode state that the PR awaits the integrator.

## Notes

- Never force-push or amend commits that are already pushed. (Exception owned elsewhere: the integrator may `--force-with-lease` a lane branch after its agent has stopped — see `.claude/skills/integrate`.)
- If the merge is blocked (required checks, review requirements), report the blocker and stop — don't bypass with admin flags.
