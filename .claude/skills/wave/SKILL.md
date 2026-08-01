---
name: wave
description: Run plans/specs as parallel coding lanes end to end — cross-plan conflict check, lane table (pauses once for approval), fan out worktree agents, auto-/integrate when every lane reaches PR-open. `/wave status` shows lanes/agents/PRs; `/wave abort` is the kill switch. Rules live in docs/parallel-dev.md.
---

# /wave — orchestrate a parallel lane wave

Args decide the mode: `status` → snapshot; `abort` → kill switch; anything else
(spec names, plan-file paths, or free-text feature descriptions) → orchestrate.
No args in orchestrate intent → ask what to run.

## Orchestrate

1. **Resolve inputs.** Accept any mix of: `specs/<name>/` directories,
   `~/.claude/plans/*.md` files, or ad-hoc descriptions. Read every plan fully
   before partitioning.

2. **Cross-plan conflict check.** Build a per-lane conflict manifest (every
   EXISTING file the lane will edit — new files are free) against the hub
   table in `docs/parallel-dev.md` §3. Enforce the four constraints:
   ≤1 lane touches `trip_detail_screen.dart`; ≤1 lane appends to
   `plan_tool_registry.go`; ARB key prefixes unique across the wave;
   ≤1 migration per lane with numbers reserved NOW
   (`ls src/packages/api/migrations | tail -1` → next free, assigned in merge
   order). 2–4 lanes total. If a constraint cannot be satisfied, propose a
   re-split or a serialization edge and say so in the table.

3. **Write the Lanes section** into each spec's `tasks.md` (template:
   `specs/_template/tasks.md`). For plan-file or ad-hoc inputs, put the lane
   table in a wave note instead.

4. **PAUSE — the one human gate.** Present the lane table (lanes, branches,
   manifests, reserved migration numbers, merge order) with AskUserQuestion:
   approve / edit / cancel. State explicitly: *after approval the wave runs
   unattended through fan-out, PR-open, serial merge, and prod deploys.*

5. **Preflight.** Main CI green, no deploy in flight, `git status` clean in
   the main checkout, `make wt-list` shows no conflicting lanes.

6. **Fan out.** One background Agent per lane, `isolation: "worktree"`. The
   lane brief must contain: the spec/plan paths; the lane's task rows and
   conflict manifest verbatim; its reserved migration number (if any); a
   `make wt-init` note if the lane needs a live dev stack; and the closing
   instruction verbatim: *"Run local checks, then `ship pr`. Report the PR
   URL. Do not merge. Do not touch files outside your manifest."*

7. **Monitor.** Track lanes via TaskList/TaskOutput; steer or hand red-CI
   failures back with SendMessage (who-fixes-what rule:
   `docs/parallel-dev.md` §6). Collect PR URLs from completion reports.

8. **Auto-integrate.** When EVERY lane has reported PR-open, run the
   `integrate` skill with the lane table's merge order. No second approval —
   the step-4 gate covered this.

9. **Close.** `make wt-rm NAME=<lane>` per merged lane (from the main
   checkout), then report the wave summary: PRs merged, deploys verified,
   final prod SHA, anything handed back or left open.

## /wave status

One combined snapshot, no changes: `make wt-list` (lanes/slots/ports),
TaskList (running lane agents), `gh pr list` (open lane PRs), and
`docker compose ls` filtered to `gtt-*`/`development`. Flag anomalies
(a lane worktree with no agent and no PR; an agent whose lane is gone).

## /wave abort

The kill switch. Stop every running lane agent (TaskStop). Then ASK before
touching worktrees — `make wt-rm` destroys uncommitted lane work; default is
to leave worktrees in place. Report per lane: agent stopped / already done /
worktree kept or removed, and any PRs already open (they stay open for a
later `/integrate` or manual close).
