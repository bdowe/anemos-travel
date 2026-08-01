#!/usr/bin/env bash
#
# tmux-dev.sh — spin up a tmux session for the travel-route-planner project.
#
# Windows:
#   1. docker   — runs the development Docker stack (make docker-dev)
#   2. monitor  — btop (cpu/mem) | macmon (GPU/ANE/power) | live service health
#   3. editor   — split into two panes: vim on the left, claude on the right
#
# Usage: ./scripts/tmux-dev.sh   (or attach to an existing session of the same name)

set -euo pipefail

# Project root = the directory containing this script's parent.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Parallel-lane worktrees (scripts/worktree.sh) carry a .wt.env with their own
# gateway port — adopt it, and give the lane its own tmux session name.
# Parse, don't source-with-export: exported GTT_* would seed the tmux SERVER's
# global environment and leak the lane's project/ports into every later
# session, including the main checkout's.
GTT_SLOT="" GTT_PROJECT="" GTT_GATEWAY_PORT=""
if [ -f "$PROJECT_DIR/.wt.env" ]; then
  GTT_SLOT=$(sed -n 's/^GTT_SLOT=//p' "$PROJECT_DIR/.wt.env")
  GTT_PROJECT=$(sed -n 's/^GTT_PROJECT=//p' "$PROJECT_DIR/.wt.env")
  GTT_GATEWAY_PORT=$(sed -n 's/^GTT_GATEWAY_PORT=//p' "$PROJECT_DIR/.wt.env")
fi
SESSION="travel-route-planner${GTT_SLOT:+-${GTT_PROJECT:-}}"

# Gateway port the dev stack exposes (health checks hit this).
PORT="${TRP_PORT:-${GTT_GATEWAY_PORT:-3000}}"

# Pick the best available system monitor.
if command -v btop >/dev/null 2>&1; then SYSMON="btop"; else SYSMON="htop"; fi

# If the session already exists, just attach (or switch, if already inside tmux).
if tmux has-session -t "=$SESSION" 2>/dev/null; then
  echo "Session '$SESSION' already exists — attaching."
  if [ -n "${TMUX:-}" ]; then
    exec tmux switch-client -t "=$SESSION"
  else
    exec tmux attach-session -t "=$SESSION"
  fi
fi

# Window 1: docker compose up (via the project's make target).
tmux new-session -d -s "$SESSION" -n docker -c "$PROJECT_DIR"
tmux send-keys -t "=$SESSION:docker" "make docker-dev" C-m

# Window 2: monitor — system monitor | GPU/power | live service health.
tmux new-window -t "=$SESSION" -n monitor -c "$PROJECT_DIR"

# left pane: cpu/mem
tmux send-keys -t "=$SESSION:monitor" "$SYSMON" C-m

# right pane: Apple Silicon GPU/ANE/power (macmon needs no sudo)
tmux split-window -h -t "=$SESSION:monitor" -c "$PROJECT_DIR"
if command -v macmon >/dev/null 2>&1; then
  tmux send-keys -t "=$SESSION:monitor" 'macmon' C-m
else
  tmux send-keys -t "=$SESSION:monitor" \
    "echo 'macmon not found:  brew install macmon'" C-m
fi

# bottom-right pane: live health of the gateway + API (no 'watch' on mac)
tmux split-window -v -t "=$SESSION:monitor" -c "$PROJECT_DIR"
tmux send-keys -t "=$SESSION:monitor" \
  "BASE_URL=http://localhost:$PORT '$PROJECT_DIR/scripts/healthcheck.sh'" C-m

tmux select-layout -t "=$SESSION:monitor" main-vertical

# Window 3: editor — vim (left pane) + claude (right pane).
tmux new-window -t "=$SESSION" -n editor -c "$PROJECT_DIR"
tmux send-keys -t "=$SESSION:editor" "vim ." C-m
tmux split-window -h -t "=$SESSION:editor" -c "$PROJECT_DIR"
tmux send-keys -t "=$SESSION:editor" "claude" C-m

# Start on the editor window.
tmux select-window -t "=$SESSION:editor"

# Attach (or switch, if already inside tmux).
if [ -n "${TMUX:-}" ]; then
  exec tmux switch-client -t "=$SESSION"
else
  exec tmux attach-session -t "=$SESSION"
fi
