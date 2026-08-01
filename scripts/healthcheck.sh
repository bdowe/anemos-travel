#!/usr/bin/env bash
#
# Continuously probe the gateway and API through the nginx gateway on :3000.
#
# Usage:
#   scripts/healthcheck.sh           # poll every 2s (default)
#   scripts/healthcheck.sh 5         # poll every 5s
#   BASE_URL=http://host:3000 scripts/healthcheck.sh
#
# Notes:
#   - The gateway's /health endpoint returns plain text ("healthy"), so it is
#     NOT piped through jq. The API's /api/v1/health returns JSON.

set -u

# Lane-aware default: a parallel worktree's .wt.env (scripts/worktree.sh)
# points this checkout at its own gateway; BASE_URL still overrides.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${GTT_GATEWAY_PORT:-}" ] && [ -f "$ROOT/.wt.env" ]; then
  GTT_GATEWAY_PORT=$(sed -n 's/^GTT_GATEWAY_PORT=//p' "$ROOT/.wt.env")
fi

BASE_URL="${BASE_URL:-http://localhost:${GTT_GATEWAY_PORT:-3000}}"
INTERVAL="${1:-2}"

while true; do
  clear
  echo "== gateway ($BASE_URL/health) =="
  curl -sf "$BASE_URL/health" && echo || echo 'gateway down'

  echo
  echo "== api ($BASE_URL/api/v1/health) =="
  curl -s "$BASE_URL/api/v1/health" | jq . 2>/dev/null || echo 'api down'

  sleep "$INTERVAL"
done
