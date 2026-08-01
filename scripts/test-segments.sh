#!/usr/bin/env bash
#
# test-segments.sh — end-to-end assertions for the flights-transport feature.
#
# Exercises the transport-links endpoint (no auth) and the full trip-segment
# lifecycle (auth + owner-scoped add/list/delete), checking HTTP status codes
# and response bodies. Prints a PASS/FAIL summary and exits non-zero on failure.
#
# Trips have no create endpoint (they're created by the agent's save_trip tool),
# so the script registers a real user via the API for a valid token, then seeds
# a trip row straight into Postgres for that user. Seeded rows are cleaned up at
# the end.
#
# Usage:
#   scripts/test-segments.sh
#   BASE_URL=http://localhost:8080 scripts/test-segments.sh   # bare api-run
#   PG_CONTAINER=my-pg scripts/test-segments.sh               # different container
#
# Requires: curl, jq, docker (for the psql seed/cleanup).

set -u

# Lane-aware defaults: a parallel worktree's .wt.env (scripts/worktree.sh)
# points this checkout at its own gateway/postgres; env vars still override.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/.wt.env" ]; then
  : "${GTT_GATEWAY_PORT:=$(sed -n 's/^GTT_GATEWAY_PORT=//p' "$ROOT/.wt.env")}"
  : "${GTT_PROJECT:=$(sed -n 's/^GTT_PROJECT=//p' "$ROOT/.wt.env")}"
fi

BASE_URL="${BASE_URL:-http://localhost:${GTT_GATEWAY_PORT:-3000}}"
API="$BASE_URL/api/v1"
PG_CONTAINER="${PG_CONTAINER:-${GTT_PROJECT:-development}-postgres-1}"
PG_USER="${PG_USER:-travel}"
PG_DB="${PG_DB:-travel_planner}"

pass=0
fail=0
ok()  { echo "  ✅ $1"; pass=$((pass + 1)); }
no()  { echo "  ❌ $1"; fail=$((fail + 1)); }
# assert_eq <expected> <actual> <label>
assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else no "$3 — expected '$1', got '$2'"; fi
}

# psql_q <sql> — run a query in the Postgres container, tuples-only.
psql_q() { docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc "$1"; }

# http METHOD PATH [DATA] [TOKEN] — emits the response body then a final line
# with the HTTP status code. Split with status_of / body_of.
http() {
  local method="$1" path="$2" data="${3:-}" token="${4:-}"
  local -a a=(-s -w $'\n%{http_code}' -X "$method" "$API$path")
  [ -n "$data" ]  && a+=(-H 'Content-Type: application/json' -d "$data")
  [ -n "$token" ] && a+=(-H "Authorization: Bearer $token")
  curl "${a[@]}"
}
status_of() { printf '%s' "$1" | tail -n1; }
body_of()   { printf '%s' "$1" | sed '$d'; }

# ---- preflight ----------------------------------------------------------------
for bin in curl jq docker; do
  command -v "$bin" >/dev/null 2>&1 || { echo "✋ missing dependency: $bin"; exit 2; }
done
if [ "$(status_of "$(http GET /health)")" != "200" ]; then
  echo "✋ API not reachable at $API/health — is the stack running? (make docker-dev)"
  exit 2
fi
if ! psql_q "select 1;" >/dev/null 2>&1; then
  echo "✋ cannot reach Postgres via 'docker exec $PG_CONTAINER psql -U $PG_USER -d $PG_DB'"
  exit 2
fi

echo "🚀 Testing flights-transport against $API"
echo "================================================"

# ---- 1. transport-links (no auth) ---------------------------------------------
echo "1️⃣  transport-links"

r=$(http GET "/transport-links?mode=flight&origin=Boston&destination=Lisbon&depart_date=2026-07-01&return_date=2026-07-10&passengers=2")
assert_eq 200 "$(status_of "$r")" "flight links → 200"
providers=$(body_of "$r" | jq -r '[.[].provider] | sort | join(",")')
assert_eq "google_flights,kayak" "$providers" "flight links → google_flights + kayak"
kayak_url=$(body_of "$r" | jq -r '.[] | select(.provider=="kayak") | .url')
case "$kayak_url" in
  *Boston-Lisbon*adults=2*) ok "kayak url carries route + passengers" ;;
  *) no "kayak url malformed: $kayak_url" ;;
esac

r=$(http GET "/transport-links?mode=ground&origin=Lisbon&destination=Porto")
assert_eq 200 "$(status_of "$r")" "ground links → 200"
assert_eq "rome2rio" "$(body_of "$r" | jq -r '.[].provider')" "ground links → rome2rio"

r=$(http GET "/transport-links?mode=flight&origin=Boston")
assert_eq 400 "$(status_of "$r")" "missing destination → 400"

# ---- 2. setup: register a user, seed a trip -----------------------------------
echo "2️⃣  setup (register user + seed trip)"

email="seg-test-$(date +%s)-$RANDOM@example.com"
r=$(http POST /auth/register "{\"email\":\"$email\",\"password\":\"password123\"}")
assert_eq 201 "$(status_of "$r")" "register → 201"
token=$(body_of "$r" | jq -r '.token // empty')
user_id=$(body_of "$r" | jq -r '.user.id // empty')
[ -n "$token" ] && ok "got session token" || no "no token in register response"

trip_id=$(psql_q "INSERT INTO trips (user_id, title, status) VALUES ('$user_id', 'Segment Test Trip', 'draft') RETURNING id;" | head -n1 | tr -d '[:space:]')
case "$trip_id" in
  ????????-????-????-????-????????????) ok "seeded trip $trip_id" ;;
  *) no "failed to seed trip (got '$trip_id')"; echo "  Summary: $pass passed, $((fail)) failed"; exit 1 ;;
esac

# ---- 3. add / list / delete a segment -----------------------------------------
echo "3️⃣  segment lifecycle"

r=$(http POST "/trips/$trip_id/segments" \
  '{"mode":"flight","origin":"Boston","destination":"Lisbon","depart_date":"2026-07-01","provider":"TAP"}' "$token")
assert_eq 201 "$(status_of "$r")" "add valid segment → 201"
seg_id=$(body_of "$r" | jq -r '.id // empty')
assert_eq "flight" "$(body_of "$r" | jq -r '.mode')" "response echoes mode=flight"

r=$(http GET "/trips/$trip_id" "" "$token")
assert_eq 200 "$(status_of "$r")" "get trip → 200"
assert_eq "1" "$(body_of "$r" | jq '.segments | length')" "trip shows 1 segment"
assert_eq "$seg_id" "$(body_of "$r" | jq -r '.segments[0].id')" "segment id matches"

# ---- 4. validation & authorization --------------------------------------------
echo "4️⃣  validation & authorization"

r=$(http POST "/trips/$trip_id/segments" \
  '{"mode":"flight","depart_date":"2026-07-10","arrive_date":"2026-07-01"}' "$token")
assert_eq 400 "$(status_of "$r")" "arrive before depart → 400"

r=$(http POST "/trips/$trip_id/segments" '{"mode":"plane"}' "$token")
assert_eq 400 "$(status_of "$r")" "invalid mode → 400"

random_trip="11111111-1111-1111-1111-111111111111"
r=$(http POST "/trips/$random_trip/segments" '{"mode":"flight"}' "$token")
assert_eq 404 "$(status_of "$r")" "add to non-owned trip → 404"

r=$(http POST "/trips/$trip_id/segments" '{"mode":"flight"}')
assert_eq 401 "$(status_of "$r")" "add without token → 401"

# ---- 5. delete ----------------------------------------------------------------
echo "5️⃣  delete"

assert_eq 204 "$(status_of "$(http DELETE "/trips/$trip_id/segments/$seg_id" "" "$token")")" "delete segment → 204"
r=$(http GET "/trips/$trip_id" "" "$token")
assert_eq "0" "$(body_of "$r" | jq '.segments | length')" "trip shows 0 segments after delete"
assert_eq 404 "$(status_of "$(http DELETE "/trips/$trip_id/segments/$seg_id" "" "$token")")" "delete again → 404"

# ---- cleanup (best effort) ----------------------------------------------------
psql_q "DELETE FROM trips WHERE id = '$trip_id';" >/dev/null 2>&1
psql_q "DELETE FROM users WHERE id = '$user_id';" >/dev/null 2>&1

# ---- summary ------------------------------------------------------------------
echo "================================================"
echo "📊 $pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "✅ all checks passed" || echo "❌ failures detected"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
