#!/usr/bin/env bash
# smoke.sh — end-to-end smoke test for the travel-route-planner stack.
#
# Drives the real HTTP surface through the nginx gateway (same host a browser
# hits) and asserts each step, colored PASS/FAIL, non-zero exit on any failure.
# Built to run TWICE against the same code: as a rehearsal against the local dev
# stack, and as the go/no-go sanity check against production the moment DNS flips
# to https://goldentempotravel.com. Pure bash + curl + jq, cloning the api_call idiom
# from scripts/seed_local_content.sh.
#
# It registers a THROWAWAY user (unique email), exercises the traveler journey
# end to end, then deletes the account in teardown — so it leaves no residue and
# is safe to run repeatedly, including against production.
#
# Environment:
#   BASE_URL              target gateway (default http://localhost:3000)
#   SMOKE_SEED_MODE       how to obtain a trip to exercise:
#                           sql      (default) INSERT a trip row via docker+psql
#                                    — local only, needs $SMOKE_DB_CONTAINER
#                           plan     POST /plan (SSE) and read the trip the agent
#                                    creates — costs Anthropic spend
#                           existing use $SMOKE_TRIP_ID directly (see note below)
#   SMOKE_TRIP_ID         trip id for existing mode
#   SMOKE_TOKEN           optional bearer for existing mode: when the target trip
#                          belongs to a real user, pass their token so the owner
#                          reads/writes (items/share/export) work. Without it,
#                          existing mode still verifies the public shared read but
#                          skips the owner-only mutations.
#   SMOKE_SIGNING_SECRET  dev-only: the server's UNSUBSCRIBE/EXPORT signing secret.
#                          When set, step 9 forges a one-click unsubscribe token
#                          and asserts the public endpoint honors it. Skipped when
#                          unset (production never exposes its secret — see the
#                          MANUAL CHECKS block for the real inbox round-trip).
#   SMOKE_DB_CONTAINER    postgres container for sql mode (default development-postgres-1)
#   SMOKE_TIMEOUT         per-request curl --max-time seconds (default 30; plan uses 180)
#
# Exit status: 0 if every non-skipped step passed, 1 otherwise.

set -u

BASE_URL="${BASE_URL:-http://localhost:3000}"
API="$BASE_URL/api/v1"
SMOKE_SEED_MODE="${SMOKE_SEED_MODE:-sql}"
SMOKE_TRIP_ID="${SMOKE_TRIP_ID:-}"
SMOKE_TOKEN="${SMOKE_TOKEN:-}"
SMOKE_SIGNING_SECRET="${SMOKE_SIGNING_SECRET:-}"
SMOKE_DB_CONTAINER="${SMOKE_DB_CONTAINER:-development-postgres-1}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-30}"

# --- output helpers -----------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

PASSED=0
FAILED=0
SKIPPED=0

pass() { PASSED=$((PASSED + 1)); printf '  %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$1"; [ -n "${2:-}" ] && printf '       %s%s%s\n' "$C_DIM" "$2" "$C_RESET"; return 0; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  %sSKIP%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
step() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }
note() { printf '       %s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }
die()  { printf '%sfatal:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; summary; exit 1; }

# check "description" EXPECTED ACTUAL [detail]
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]${4:+ — $4}"; fi
}

for dep in curl jq; do
  command -v "$dep" >/dev/null 2>&1 || die "missing dependency: $dep"
done

# --- request helper -----------------------------------------------------------
# req METHOD PATH [BODY] [HEADER...] — hits $API$PATH, sets LAST_STATUS/RESP_BODY
# in the current shell (never $(...)) so both survive. Content-Type is JSON when
# a body is given. Extra positional args after BODY are passed as -H headers.
LAST_STATUS=""
RESP_BODY=""
req() {
  local method="$1" path="$2" body="${3:-}" tmp dh status attempt retry
  shift $(( $# >= 3 ? 3 : $# ))
  local -a hdr=()
  local h
  for h in "$@"; do hdr+=(-H "$h"); done
  tmp="$(mktemp)"; dh="$(mktemp)"
  # The strict auth/alerts endpoints share a 5/min-per-IP bucket; honor a 429's
  # Retry-After once so back-to-back runs (or a polluted bucket) don't spuriously
  # fail. Capped so a hostile Retry-After can't hang the run.
  for attempt in 1 2; do
    # ${hdr[@]+...} guards the empty-array expansion under `set -u` on bash 3.2.
    if [ -n "$body" ]; then
      status="$(curl -sS -o "$tmp" -D "$dh" -w '%{http_code}' --max-time "$SMOKE_TIMEOUT" \
        -X "$method" "$API$path" -H 'Content-Type: application/json' \
        ${hdr[@]+"${hdr[@]}"} -d "$body")" || status="000"
    else
      status="$(curl -sS -o "$tmp" -D "$dh" -w '%{http_code}' --max-time "$SMOKE_TIMEOUT" \
        -X "$method" "$API$path" ${hdr[@]+"${hdr[@]}"})" || status="000"
    fi
    if [ "$status" = "429" ] && [ "$attempt" = 1 ]; then
      retry="$(grep -i '^retry-after:' "$dh" | tr -dc '0-9')"
      [ -n "$retry" ] || retry=60
      [ "$retry" -le 65 ] 2>/dev/null || retry=65
      note "rate limited on $method $path — waiting ${retry}s (Retry-After) then retrying once"
      sleep "$retry"
      continue
    fi
    break
  done
  LAST_STATUS="$status"
  RESP_BODY="$(cat "$tmp")"
  rm -f "$tmp" "$dh"
}

err_of() { printf '%s' "$1" | jq -r '.error // .message // empty' 2>/dev/null || true; }

# url-safe base64, no padding — matches Go's base64.RawURLEncoding.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

summary() {
  printf '\n%s------------------------------------------%s\n' "$C_DIM" "$C_RESET"
  printf '%sSMOKE SUMMARY%s  %s%d passed%s / %s%d failed%s / %s%d skipped%s   (%s, seed=%s)\n' \
    "$C_BOLD" "$C_RESET" \
    "$C_GREEN" "$PASSED" "$C_RESET" \
    "$C_RED" "$FAILED" "$C_RESET" \
    "$C_YELLOW" "$SKIPPED" "$C_RESET" \
    "$BASE_URL" "$SMOKE_SEED_MODE"
}

# --- teardown safety net ------------------------------------------------------
# Best-effort account cleanup if we bail after registering (so a mid-run failure
# against a shared/prod env doesn't strand a throwaway user).
TOKEN=""
USER_ID=""
PASSWORD=""
ACCOUNT_DELETED=0
cleanup() {
  if [ -n "$TOKEN" ] && [ "$ACCOUNT_DELETED" = 0 ]; then
    # Via req so a 429 gets one Retry-After retry: a die() mid-run lands here
    # with the strict per-IP bucket still hot, which used to strand the user.
    req DELETE /auth/account "$(jq -n --arg p "$PASSWORD" '{password:$p}')" \
      "Authorization: Bearer $TOKEN" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

printf '%s%s smoke test%s  ->  %s  (seed mode: %s)\n' \
  "$C_BOLD" "goldentempo" "$C_RESET" "$BASE_URL" "$SMOKE_SEED_MODE"

# ===== 1. Health =============================================================
step "1. Health"
gw_health="$(curl -sS --max-time "$SMOKE_TIMEOUT" "$BASE_URL/health" 2>/dev/null || true)"
if printf '%s' "$gw_health" | grep -q 'healthy'; then
  pass "gateway GET /health returns healthy"
else
  fail "gateway GET /health returns healthy" "got: ${gw_health:-<no response — gateway down?>}"
  die "gateway is unreachable at $BASE_URL — is the stack up?"
fi
req GET /health
db_status="$(printf '%s' "$RESP_BODY" | jq -r '.database // empty' 2>/dev/null || true)"
check "API GET /api/v1/health has .database==ok" "ok" "$db_status" "status=$LAST_STATUS"

# ===== 2. Register + auth =====================================================
step "2. Register + authenticate"
TS="$(date +%s)"
EMAIL="smoke+${TS}$$@example.com"
PASSWORD="smoke-pw-${TS}-ok"
# A unique X-Forwarded-For dodges the strict 5/min per-IP register limiter so
# repeated runs from one machine don't trip it.
XFF="10.55.$(( RANDOM % 250 + 1 )).$(( RANDOM % 250 + 1 ))"
req POST /auth/register \
  "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e, password:$p}')" \
  "X-Forwarded-For: $XFF"
if [ "$LAST_STATUS" = "201" ] || [ "$LAST_STATUS" = "200" ]; then
  pass "POST /auth/register ($EMAIL)"
else
  fail "POST /auth/register" "status=$LAST_STATUS: $(err_of "$RESP_BODY")"
  die "cannot register a user — aborting"
fi
TOKEN="$(printf '%s' "$RESP_BODY" | jq -r '.token // empty')"
USER_ID="$(printf '%s' "$RESP_BODY" | jq -r '.user.id // empty')"
if [ -n "$TOKEN" ]; then pass "register returned a token"; else fail "register returned a token"; die "no token"; fi
if [ -n "$USER_ID" ]; then pass "register returned a user id ($USER_ID)"; else fail "register returned a user id"; fi

req GET /auth/me "" "Authorization: Bearer $TOKEN"
me_email="$(printf '%s' "$RESP_BODY" | jq -r '.email // empty' 2>/dev/null || true)"
check "GET /auth/me confirms the user" "$EMAIL" "$me_email" "status=$LAST_STATUS"

# For the owner-scoped steps we use the freshly-registered user's token by
# default. existing mode may override it with SMOKE_TOKEN.
OWNER_TOKEN="$TOKEN"
OWNER_CAN_MUTATE=1

# ===== 3. Seed a trip =========================================================
step "3. Seed a trip (mode: $SMOKE_SEED_MODE)"
TRIP_ID=""
case "$SMOKE_SEED_MODE" in
  sql)
    if ! command -v docker >/dev/null 2>&1; then
      fail "sql seed mode needs docker" "docker not found on PATH — use SMOKE_SEED_MODE=plan or existing for remote targets"
      die "cannot seed via sql without docker"
    fi
    if ! docker exec "$SMOKE_DB_CONTAINER" true >/dev/null 2>&1; then
      fail "sql seed mode needs container $SMOKE_DB_CONTAINER" \
        "container not reachable — sql mode is local-only; use plan/existing against remote"
      die "postgres container $SMOKE_DB_CONTAINER unreachable"
    fi
    chat_id="smoke-chat-${TS}-$$"
    # psql prints the RETURNING row AND an "INSERT 0 1" command tag; grep the UUID.
    TRIP_ID="$(docker exec "$SMOKE_DB_CONTAINER" psql -U travel -d travel_planner -tAX \
      -c "INSERT INTO trips (user_id, title, status, chat_id) VALUES ('$USER_ID', 'Smoke Test Trip', 'active', '$chat_id') RETURNING id;" \
      2>/dev/null | grep -Eiom1 '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')"
    if [ -n "$TRIP_ID" ]; then
      pass "INSERT trip row via psql ($TRIP_ID)"
    else
      fail "INSERT trip row via psql"
      die "could not insert trip row"
    fi
    # Prove the API can read the row the way the owner would.
    req GET "/trips/$TRIP_ID" "" "Authorization: Bearer $OWNER_TOKEN"
    check "GET /trips/{id} owned by the new user" "200" "$LAST_STATUS" "$(err_of "$RESP_BODY")"
    ;;

  plan)
    note "plan mode streams POST /plan through Claude — this costs Anthropic spend."
    plan_body="$(jq -n '{chat_id:("smoke-chat-"+(now|tostring)), messages:[{role:"user", content:"Plan me a simple one-day trip to Athens, Greece. Keep it to 2 or 3 well-known spots. Finalize the itinerary."}]}')"
    plan_out="$(curl -sS --max-time 180 -N -X POST "$API/plan" \
      -H 'Content-Type: application/json' -H "Authorization: Bearer $OWNER_TOKEN" \
      -d "$plan_body" 2>/dev/null || true)"
    # The `done` SSE event carries the persisted trip_id (see plan_handler.go).
    TRIP_ID="$(printf '%s' "$plan_out" \
      | sed -n 's/^data: //p' \
      | jq -r 'select(.type=="done") | .data.trip_id // empty' 2>/dev/null \
      | grep -v '^$' | head -n1)"
    if [ -n "$TRIP_ID" ]; then
      pass "POST /plan created a trip (done event trip_id=$TRIP_ID)"
    else
      # Loose fallback: maybe the agent asked a clarifying question and created
      # nothing this turn — check whether ANY trip now exists for the user.
      req GET /trips "" "Authorization: Bearer $OWNER_TOKEN"
      TRIP_ID="$(printf '%s' "$RESP_BODY" | jq -r '(if type=="array" then . else (.trips // []) end)[0].id // empty' 2>/dev/null || true)"
      if [ -n "$TRIP_ID" ]; then
        pass "POST /plan resulted in a trip (via GET /trips fallback: $TRIP_ID)"
      else
        fail "POST /plan created a trip" "no done/trip_id in stream and GET /trips is empty"
        die "plan mode produced no trip"
      fi
    fi
    ;;

  existing)
    [ -n "$SMOKE_TRIP_ID" ] || die "existing mode requires SMOKE_TRIP_ID"
    TRIP_ID="$SMOKE_TRIP_ID"
    if [ -n "$SMOKE_TOKEN" ]; then
      OWNER_TOKEN="$SMOKE_TOKEN"
      req GET "/trips/$TRIP_ID" "" "Authorization: Bearer $OWNER_TOKEN"
      check "GET /trips/{id} owned via SMOKE_TOKEN" "200" "$LAST_STATUS" "$(err_of "$RESP_BODY")"
    else
      # No owner token: we can't mutate (add items etc.), and we can't resolve the
      # trip without its share token, so we downgrade the owner-only steps to SKIP.
      OWNER_CAN_MUTATE=0
      note "existing mode without SMOKE_TOKEN: owner-only steps (items/share/export) will be skipped."
      note "pass SMOKE_TOKEN=<owner bearer> to exercise them."
      pass "using existing trip id $TRIP_ID"
    fi
    ;;

  *)
    die "unknown SMOKE_SEED_MODE '$SMOKE_SEED_MODE' (expected sql|plan|existing)"
    ;;
esac

# ===== 4. Add an itinerary item ==============================================
step "4. Add an itinerary item"
if [ "$OWNER_CAN_MUTATE" = 1 ]; then
  req POST "/trips/$TRIP_ID/items" \
    "$(jq -n '{name:"Acropolis of Athens", category:"attraction", time_of_day:"morning", day:1}')" \
    "Authorization: Bearer $OWNER_TOKEN"
  if [ "$LAST_STATUS" = "201" ] || [ "$LAST_STATUS" = "200" ]; then
    pass "POST /trips/{id}/items added an item"
  else
    fail "POST /trips/{id}/items" "status=$LAST_STATUS: $(err_of "$RESP_BODY")"
  fi
else
  skip "add item — no owner token in existing mode"
fi

# ===== 5. Share + bot-UA OG preview ==========================================
step "5. Share link + OG preview"
SHARE_TOKEN=""
if [ "$OWNER_CAN_MUTATE" = 1 ]; then
  req POST "/trips/$TRIP_ID/share" '{"role":"viewer"}' "Authorization: Bearer $OWNER_TOKEN"
  if [ "$LAST_STATUS" = "201" ] || [ "$LAST_STATUS" = "200" ]; then
    SHARE_TOKEN="$(printf '%s' "$RESP_BODY" | jq -r '.token // empty')"
    if [ -n "$SHARE_TOKEN" ]; then
      pass "POST /trips/{id}/share returned a token"
    else
      fail "POST /trips/{id}/share returned a token"
    fi
  else
    fail "POST /trips/{id}/share" "status=$LAST_STATUS: $(err_of "$RESP_BODY")"
  fi
else
  skip "create share link — no owner token in existing mode"
fi

if [ -n "$SHARE_TOKEN" ]; then
  req GET "/shared/$SHARE_TOKEN"
  if [ "$LAST_STATUS" = "200" ] && printf '%s' "$RESP_BODY" | jq -e '.trip' >/dev/null 2>&1; then
    pass "GET /shared/{token} returns the trip JSON"
  else
    fail "GET /shared/{token} returns the trip JSON" "status=$LAST_STATUS"
  fi

  # Bot-UA OG: a crawler UA on /app/share/{token} should be rewritten by nginx to
  # the share-preview HTML. The rewrite lives in the DEPLOYMENT/PRODUCTION gateway
  # (app-locations snippet + $share_prerender map); the lean dev gateway does NOT
  # carry it, so treat a non-OG dev response as a SKIP (the real check is against
  # production — and is also in the MANUAL CHECKS block). Either way we hard-assert
  # the underlying preview endpoint, which is what the rewrite targets.
  og_html="$(curl -sS --max-time "$SMOKE_TIMEOUT" -A 'facebookexternalhit/1.1' \
    "$BASE_URL/app/share/$SHARE_TOKEN" 2>/dev/null || true)"
  if printf '%s' "$og_html" | grep -q 'og:'; then
    pass "bot-UA /app/share/{token} serves OG preview HTML (nginx rewrite live)"
  else
    skip "bot-UA /app/share/{token} rewrite — gateway has no bot rewrite (expected on dev; verify on prod)"
  fi

  # Hard assertion on the preview endpoint the rewrite points at.
  preview="$(curl -sS --max-time "$SMOKE_TIMEOUT" "$API/share-preview/$SHARE_TOKEN" 2>/dev/null || true)"
  if printf '%s' "$preview" | grep -q 'og:'; then
    pass "GET /api/v1/share-preview/{token} renders OG meta"
  else
    fail "GET /api/v1/share-preview/{token} renders OG meta"
  fi
else
  skip "shared reads + OG preview — no share token"
fi

# ===== 6. Export (print + calendar) ==========================================
step "6. Export tokens (print.html + calendar.ics)"
if [ "$OWNER_CAN_MUTATE" = 1 ]; then
  req POST "/trips/$TRIP_ID/export-token" "" "Authorization: Bearer $OWNER_TOKEN"
  EXPORT_TOKEN="$(printf '%s' "$RESP_BODY" | jq -r '.token // empty')"
  if [ -n "$EXPORT_TOKEN" ]; then
    pass "POST /trips/{id}/export-token returned a token"

    p_status="$(curl -sS -o /dev/null -w '%{http_code}::%{content_type}' --max-time "$SMOKE_TIMEOUT" \
      "$API/export/$EXPORT_TOKEN/print.html" 2>/dev/null || echo "000::")"
    if [ "${p_status%%::*}" = "200" ] && printf '%s' "${p_status##*::}" | grep -q 'text/html'; then
      pass "GET /export/{token}/print.html -> 200 text/html"
    else
      fail "GET /export/{token}/print.html -> 200 text/html" "got $p_status"
    fi

    ics_code="$(curl -sS -o /dev/null -w '%{http_code}::%{content_type}' --max-time "$SMOKE_TIMEOUT" \
      "$API/export/$EXPORT_TOKEN/calendar.ics" 2>/dev/null || echo "000::")"
    ics_body="$(curl -sS --max-time "$SMOKE_TIMEOUT" "$API/export/$EXPORT_TOKEN/calendar.ics" 2>/dev/null || true)"
    if [ "${ics_code%%::*}" = "200" ] && printf '%s' "${ics_code##*::}" | grep -q 'text/calendar' \
       && printf '%s' "$ics_body" | grep -q 'BEGIN:VCALENDAR'; then
      pass "GET /export/{token}/calendar.ics -> 200 text/calendar with BEGIN:VCALENDAR"
    else
      fail "GET /export/{token}/calendar.ics -> 200 text/calendar with BEGIN:VCALENDAR" "got $ics_code"
    fi
  else
    fail "POST /trips/{id}/export-token returned a token" "status=$LAST_STATUS: $(err_of "$RESP_BODY")"
  fi
else
  skip "export tokens — no owner token in existing mode"
fi

# ===== 7. Price alerts ========================================================
step "7. Price alerts"
depart="$(date -u -v+30d '+%Y-%m-%d' 2>/dev/null || date -u -d '+30 days' '+%Y-%m-%d' 2>/dev/null)"
req POST /alerts \
  "$(jq -n --arg d "$depart" '{origin:"JFK", destination:"CDG", depart_date:$d}')" \
  "Authorization: Bearer $TOKEN"
if [ "$LAST_STATUS" = "201" ]; then
  pass "POST /alerts created an alert (JFK->CDG $depart)"
else
  fail "POST /alerts" "status=$LAST_STATUS: $(err_of "$RESP_BODY")"
fi
req GET /alerts "" "Authorization: Bearer $TOKEN"
# /alerts returns a bare JSON array; be tolerant of a {alerts:[...]} wrapper too.
alert_count="$(printf '%s' "$RESP_BODY" | jq -r 'if type=="array" then length else (.alerts | length) end' 2>/dev/null || echo 0)"
if [ "$LAST_STATUS" = "200" ] && [ "${alert_count:-0}" -ge 1 ] 2>/dev/null; then
  pass "GET /alerts lists the alert ($alert_count total)"
else
  fail "GET /alerts lists the alert" "status=$LAST_STATUS count=$alert_count"
fi

# ===== 8. Notifications =======================================================
step "8. Notifications"
req GET /notifications "" "Authorization: Bearer $TOKEN"
check "GET /notifications" "200" "$LAST_STATUS" "$(err_of "$RESP_BODY")"
req GET /notifications/unread-count "" "Authorization: Bearer $TOKEN"
check "GET /notifications/unread-count" "200" "$LAST_STATUS" "$(err_of "$RESP_BODY")"
req POST /notifications/read '{}' "Authorization: Bearer $TOKEN"
if [ "$LAST_STATUS" = "200" ] || [ "$LAST_STATUS" = "204" ]; then
  pass "POST /notifications/read"
else
  fail "POST /notifications/read" "status=$LAST_STATUS: $(err_of "$RESP_BODY")"
fi

# ===== 9. One-click unsubscribe (dev-only, forged token) ======================
step "9. One-click unsubscribe (dev-only)"
if [ -n "$SMOKE_SIGNING_SECRET" ]; then
  payload="${USER_ID}|all"
  sig_b64="$(printf '%s' "$payload" \
    | openssl dgst -sha256 -mac HMAC -macopt "key:$SMOKE_SIGNING_SECRET" -binary \
    | b64url)"
  payload_b64="$(printf '%s' "$payload" | b64url)"
  unsub_token="${payload_b64}.${sig_b64}"
  req GET "/unsubscribe/$unsub_token"
  if [ "$LAST_STATUS" = "200" ]; then
    pass "GET /unsubscribe/{token} honored the forged one-click token"
  else
    fail "GET /unsubscribe/{token}" "status=$LAST_STATUS — does SMOKE_SIGNING_SECRET match the server's UNSUBSCRIBE/EXPORT secret?"
  fi
else
  skip "unsubscribe — SMOKE_SIGNING_SECRET unset (server dev secret is random/unknowable; real check is the inbox round-trip below)"
fi

# ===== 10. Legal pages (launch-ready) ========================================
step "10. Legal pages"
for page in terms privacy; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$SMOKE_TIMEOUT" "$BASE_URL/$page" 2>/dev/null || echo 000)"
  html="$(curl -sS --max-time "$SMOKE_TIMEOUT" "$BASE_URL/$page" 2>/dev/null || true)"
  if [ "$code" != "200" ]; then
    fail "GET /$page -> 200" "status=$code"
  elif printf '%s' "$html" | grep -qiE 'draft-banner|noindex|TODO: set launch date'; then
    fail "/$page is finalized (no draft-banner/noindex/TODO)" "an un-finalized marker is still present"
  else
    pass "GET /$page -> 200, finalized (no draft-banner/noindex/TODO)"
  fi
done

# ===== 11. SEO plumbing + version marker =====================================
step "11. SEO plumbing + version marker"
for path in /robots.txt /sitemap.xml; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$SMOKE_TIMEOUT" "$BASE_URL$path" 2>/dev/null || echo 000)"
  check "GET $path -> 200" "200" "$code"
done
ver="$(curl -sS --max-time "$SMOKE_TIMEOUT" "$BASE_URL/app/version.json" 2>/dev/null || true)"
if printf '%s' "$ver" | jq -e '.release // .version // .build_number' >/dev/null 2>&1; then
  pass "GET /app/version.json exposes a release/version marker"
else
  skip "/app/version.json — served by the deployed gateway (dev proxies the live Flutter dev server); verify on prod"
fi

# ===== 12. Edge security headers =============================================
# Added to the deployment/production gateway (snippets/security-headers.conf).
# The lean dev gateway doesn't carry them, so treat their absence as a SKIP and
# hard-verify on prod — same posture as the bot-UA OG rewrite in step 5.
step "12. Edge security headers"
hdrs="$(curl -sS -I --max-time "$SMOKE_TIMEOUT" "$BASE_URL/app/" 2>/dev/null || true)"
if printf '%s' "$hdrs" | grep -qi '^strict-transport-security:'; then
  for h in Strict-Transport-Security X-Content-Type-Options X-Frame-Options Content-Security-Policy-Report-Only; do
    if printf '%s' "$hdrs" | grep -qi "^$h:"; then
      pass "/app/ sends $h"
    else
      fail "/app/ sends $h" "header missing"
    fi
  done
else
  skip "edge security headers — absent on this gateway (deployment/production only; verify on prod with curl -I)"
fi

# ===== 13. Localized share preview (es) ======================================
step "13. Localized share preview (es)"
if [ -n "$SHARE_TOKEN" ]; then
  es_prev="$(curl -sS --max-time "$SMOKE_TIMEOUT" "$API/share-preview/$SHARE_TOKEN?lang=es" 2>/dev/null || true)"
  if printf '%s' "$es_prev" | grep -qi '<html lang="es"' && printf '%s' "$es_prev" | grep -q 'og:'; then
    pass "GET /share-preview/{token}?lang=es renders the Spanish OG page (html lang=es)"
  else
    fail "GET /share-preview/{token}?lang=es renders the Spanish OG page" 'no <html lang="es"> + og: meta'
  fi
else
  skip "localized share preview — no share token from step 5"
fi

# ===== 14. Teardown ===========================================================
step "14. Teardown (delete throwaway account)"
req DELETE /auth/account "$(jq -n --arg p "$PASSWORD" '{password:$p}')" \
  "Authorization: Bearer $TOKEN"
if [ "$LAST_STATUS" = "204" ]; then
  ACCOUNT_DELETED=1
  pass "DELETE /auth/account -> 204"
else
  fail "DELETE /auth/account -> 204" "status=$LAST_STATUS: $(err_of "$RESP_BODY")"
fi
req GET /auth/me "" "Authorization: Bearer $TOKEN"
check "old token is rejected after deletion" "401" "$LAST_STATUS"

# ===== summary + manual checks ================================================
summary

cat <<EOF

${C_BOLD}MANUAL CHECKS REMAINING (need real DNS/SMTP/crawler)${C_RESET}
  These cannot be asserted from this script and must be verified by hand on the
  production host once DNS is live:
    - http->https redirect AND www->apex redirect both return 301 (curl -sI).
    - Real-IP rate limiting: the register/login limiter keys off CF-Connecting-IP
      behind Cloudflare (X-Forwarded-For is spoofable) — confirm a burst from one
      real client trips 429, and that this script's XFF trick does NOT bypass it.
    - Real Slack / Facebook / iMessage link-preview unfurl of a live share URL
      shows the OG title + image (proves the prod bot rewrite + crawler reach).
    - SMTP deliverability + full inbox round-trips: signup verification email,
      password-reset email, and the List-Unsubscribe one-click (RFC 8058) link
      all arrive and work end to end.
    - Legal review sign-off: step 10 auto-checks the draft-banner/noindex/TODO
      are gone, but a human still owns the "the copy is correct" sign-off.
    - Prod-only edge checks (skipped against the dev gateway): the security
      headers (step 12) and /app/version.json (step 11) must be re-run against
      the live https://goldentempotravel.com gateway with curl -I / curl.
EOF

[ "$FAILED" -eq 0 ]
