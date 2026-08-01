---
name: lane
description: Bootstrap ONE parallel lane — worktree + port slot + LANE-BRIEF.md — and print the terminal one-liner to start a session in it (or spawn a background agent on request). The Mode B counterpart to /wave; rules in docs/parallel-dev.md.
---

# /lane — bootstrap a single lane

Usage: `/lane NAME [the lane's brief…]`. NAME becomes the branch, worktree
directory, and compose project (`gtt-<name>`). No NAME → ask.

## Steps

1. **Create the worktree**: `make wt-new NAME=<name>` (from the main
   checkout). It branches off origin/main, assigns the next port slot, copies
   and retargets `.env`, and prints the lane's gateway/postgres ports.

2. **Write `LANE-BRIEF.md`** at the worktree root (it is gitignored — never
   committed, never blocks ship or worktree removal), containing:
   - The brief: from the args; if none given, ask for one or a spec to point
     at (`specs/<feature>/` — include its `spec.md`/`plan.md`/task rows).
   - A conflict-manifest section: every EXISTING file the lane may edit,
     checked against the hub table (`docs/parallel-dev.md` §3); reserved
     migration number if the lane needs one.
   - The closing instruction verbatim: *"Run local checks, then `ship pr`.
     Report the PR URL. Do not merge. Do not touch files outside your
     manifest."*

3. **Hand off.** Print the one-liner for a new terminal:

   ```bash
   cd .claude/worktrees/<name> && claude "read LANE-BRIEF.md and execute it"
   ```

   If the user asked for background ("bg", "spawn it"): do NOT use worktree
   isolation — that would create a second worktree. Spawn a background Agent
   whose prompt says to work inside this existing worktree directory and
   execute its `LANE-BRIEF.md`; report the agent's task id.

4. Remind: `make docker-dev-bg` inside the lane brings up its own stack on
   the printed ports (only needed for hands-on testing); after the PR merges,
   `make wt-rm NAME=<name>` from the main checkout cleans everything up.
