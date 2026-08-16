#!/usr/bin/env bash
# verify-edge-parity.sh — assert the CDN hands a browser exactly the bytes the
# origin serves, for every file this build publishes under a stable URL.
#
# WHY THIS EXISTS
#   `flutter build web` does not content-hash asset filenames, so /app/assets/**
#   URLs are stable while their bytes change on every deploy — notably
#   MaterialIcons-Regular.otf, which --release re-tree-shakes to exactly the
#   codepoints the code references, so ANY icon swap rewrites it. nginx
#   therefore serves that whole tree `no-cache`
#   (dockerize/deployment/nginx/snippets/app-locations.conf).
#
#   If anything re-pins it — a header regression here, a Cloudflare cache rule
#   there — the edge keeps answering with bytes from before the change and
#   nothing notices. The deploy is green, /app/version.json reports the new
#   release, main.dart.js is current, and only a few glyphs are missing.
#
#   Cost of not having this check, 2026-08-14..16: /app/assets/ was served
#   `max-age=31536000, immutable`; Cloudflare stored the icon font under a
#   one-year freshness lifetime; #426 corrected the header but a stored object
#   never revalidates, so the edge never learned. Three icons rendered blank in
#   production for two days and ~15 deploys, under a fix that had already
#   shipped. The deploy's own "Verify deployed release" step could not see it:
#   it appends `?deploy=<tag>` (ci.yml), so it only ever asks for URLs the edge
#   is not answering.
#
# WHAT IT ASSERTS
#   For every URL in the DEPLOYED service worker's RESOURCES map — already the
#   authoritative list of every file served under a stable name — the bytes the
#   edge returns equal the bytes the origin returns. A query string is always a
#   cache miss at the edge, so `?cb=<stamp>` reaches the origin.
#
#   The comparison is edge-vs-origin, NOT edge-vs-manifest-hash. The manifest is
#   knowingly not a byte oracle: tool/strip_katex_fonts.dart deletes 16 KaTeX
#   font files without rewriting RESOURCES, so those entries 404 — equally at
#   both ends, which is a pass, and correctly so. The invariant worth defending
#   is "a visitor receives what this build shipped", not "the manifest is tidy".
#
# WHEN IT GOES RED
#   The repair is a Cloudflare purge — runbook in dockerize/production/README.md.
#   Correcting the header alone does NOT fix it: an object already stored at the
#   edge keeps the freshness lifetime it was stored with and will never
#   revalidate. Purge first; only then ship any service-worker manifest bump,
#   or the bump refills every client's cache from the stale edge.
#
# Usage
#   scripts/verify-edge-parity.sh [base-url]     # default https://anemos.travel
#   scripts/verify-edge-parity.sh --self-test    # prove the gate can go red
#
# Environment
#   EDGE_PARITY_JOBS   parallel fetches (default 8)
#   NO_COLOR           disable ANSI

set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
EMPTY_MD5="d41d8cd98f00b204e9800998ecf8427e"

md5_stdin() {
  if command -v md5sum >/dev/null 2>&1; then md5sum | awk '{print $1}'; else md5; fi
}

# --- worker mode --------------------------------------------------------------
# Re-invoked by xargs, one path per call, so the fan-out needs no exported
# functions. Always exits 0: a mismatch is DATA on stdout, not a failed process.
if [ "${1:-}" = "--check-one" ]; then
  p="$2"
  edge=$(curl -sS -m 25 "$EP_BASE/app/$p" 2>/dev/null | md5_stdin)
  orig=$(curl -sS -m 25 "$EP_BASE/app/$p?cb=$EP_STAMP" 2>/dev/null | md5_stdin)
  # Deliberate corruption for --self-test, so the red path is exercised for real
  # rather than asserted in a comment.
  [ "${EP_FORCE_MISMATCH:-}" = "$p" ] && orig="0000000000000000forced0000000000"
  if [ "$edge" = "$EMPTY_MD5" ] && [ "$orig" = "$EMPTY_MD5" ]; then
    # Equal, but equally empty — both legs failed to fetch. Never call that a
    # pass: it is the one way this check could go vacuously green.
    printf 'UNREACHABLE\t%s\t-\t-\n' "$p"
  elif [ "$edge" != "$orig" ]; then
    printf 'MISMATCH\t%s\t%s\t%s\n' "$p" "$edge" "$orig"
  fi
  exit 0
fi

# --- output helpers -----------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

die() { printf '%sfatal:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 2; }

# --- args ---------------------------------------------------------------------

SELF_TEST=0
if [ "${1:-}" = "--self-test" ]; then SELF_TEST=1; shift; fi

BASE="${1:-${EDGE_PARITY_BASE_URL:-https://anemos.travel}}"
BASE="${BASE%/}"
JOBS="${EDGE_PARITY_JOBS:-8}"
STAMP="parity-$$-$(date +%s)"

printf '%sedge/origin byte parity%s  %s\n' "$C_BOLD" "$C_RESET" "$BASE"

# --- the file list, from the deployed service worker --------------------------

sw=$(curl -sS -m 25 "$BASE/app/flutter_service_worker.js?cb=$STAMP" 2>/dev/null) \
  || die "could not fetch $BASE/app/flutter_service_worker.js"

paths=$(printf '%s' "$sw" \
  | grep -oE '"[^"]+":[[:space:]]*"[0-9a-f]{32}"' \
  | sed 's/":.*//; s/^"//')

count=$(printf '%s\n' "$paths" | grep -c . || true)

# A gate that cannot fail is not a gate: if Flutter ever changes the RESOURCES
# shape, the grep above yields nothing and every check below passes vacuously.
# Refuse to report success on a list this short.
[ "$count" -ge 20 ] || die "parsed only $count resources from the service worker \
(expected 20+) — the RESOURCES parse is broken, not the cache"

if [ "$SELF_TEST" = "1" ]; then
  EP_FORCE_MISMATCH="$(printf '%s\n' "$paths" | head -1)"
  export EP_FORCE_MISMATCH
  printf '  %sself-test: forcing a mismatch on %s%s\n' \
    "$C_DIM" "$EP_FORCE_MISMATCH" "$C_RESET"
fi

printf '  %s%s resources, %s parallel fetches%s\n' "$C_DIM" "$count" "$JOBS" "$C_RESET"

# --- compare ------------------------------------------------------------------

export EP_BASE="$BASE" EP_STAMP="$STAMP"
results=$(printf '%s\n' "$paths" | xargs -P "$JOBS" -I{} "$SELF" --check-one "{}")

bad=$(printf '%s\n' "$results" | grep -c . || true)

if [ "$bad" = "0" ]; then
  printf '  %sPASS%s every resource: edge bytes == origin bytes\n' "$C_GREEN" "$C_RESET"
  if [ "$SELF_TEST" = "1" ]; then
    printf '  %sFAIL%s self-test: a forced mismatch was NOT reported\n' "$C_RED" "$C_RESET"
    exit 1
  fi
  exit 0
fi

printf '\n  %sFAIL%s %s resource(s) differ between the edge and the origin:\n' \
  "$C_RED" "$C_RESET" "$bad"
printf '%s\n' "$results" | while IFS=$'\t' read -r kind p edge orig; do
  if [ "$kind" = "UNREACHABLE" ]; then
    printf '       %s  %s(both legs returned nothing)%s\n' "$p" "$C_DIM" "$C_RESET"
  else
    printf '       %s\n         %sedge   %s%s\n         %sorigin %s%s\n' \
      "$p" "$C_DIM" "$edge" "$C_RESET" "$C_DIM" "$orig" "$C_RESET"
  fi
done

if [ "$SELF_TEST" = "1" ]; then
  printf '\n  %sPASS%s self-test: the forced mismatch was reported\n' "$C_GREEN" "$C_RESET"
  exit 0
fi

printf '\n  %sThe edge is serving bytes this build did not produce.%s\n' "$C_BOLD" "$C_RESET"
printf '  Repair: purge the Cloudflare cache, then re-run this script.\n'
printf '  Correcting a cache header does NOT evict an object already stored.\n'
printf '  Runbook: dockerize/production/README.md ("Edge cache").\n'
[ -n "${GITHUB_ACTIONS:-}" ] && \
  printf '::error::edge/origin byte parity failed for %s resource(s) — purge the Cloudflare cache (see dockerize/production/README.md)\n' "$bad"
exit 1
