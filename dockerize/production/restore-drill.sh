#!/usr/bin/env bash
# Restore drill for the anemos.travel Postgres backups.
#
# Codifies the "verify a dump into a throwaway volume" half of restore.md
# (steps 0–3) as a repeatable, non-destructive check: it NEVER touches the live
# stack or its data volume. It restores the latest (or a named) dump into a
# scratch postgres container, runs a sanity SELECT count(*) on a core table,
# reports PASS/FAIL, and tears the scratch container down.
#
# Run it periodically (or from a systemd timer) so "we have backups" is proven,
# not assumed. Exit status is 0 on PASS, non-zero on FAIL.
#
# Every knob overrides via env so it can drill any stack's dumps:
#
#   BACKUP_DIR      where dumps live (default /opt/goldentempo/backups)
#   PG_DB           database name inside the dump (default travel_planner)
#   PG_USER         role to restore as (default travel)
#   DUMP            explicit dump path (default: newest ${PG_DB}-*.dump.gz)
#   CORE_TABLE      table the sanity count runs against (default users)
#   PG_IMAGE        scratch postgres image (default postgres:16-alpine)
#   SCRATCH_NAME    scratch container name (default pg-restore-drill)
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/opt/goldentempo/backups}"
PG_DB="${PG_DB:-travel_planner}"
PG_USER="${PG_USER:-travel}"
CORE_TABLE="${CORE_TABLE:-users}"
PG_IMAGE="${PG_IMAGE:-postgres:16-alpine}"
SCRATCH_NAME="${SCRATCH_NAME:-pg-restore-drill}"

fail() {
    echo "[restore-drill] FAIL: $*" >&2
    exit 1
}

# Pick the dump: an explicit DUMP wins, else the newest matching file.
DUMP="${DUMP:-}"
if [ -z "$DUMP" ]; then
    DUMP="$(find "$BACKUP_DIR" -maxdepth 1 -name "${PG_DB}-*.dump.gz" -type f \
        | sort | tail -n 1)"
fi
[ -n "$DUMP" ] && [ -f "$DUMP" ] || fail "no dump found in $BACKUP_DIR (${PG_DB}-*.dump.gz)"

echo "[restore-drill] $(date -u +%FT%TZ) drilling $DUMP"

# gzip integrity before we spend a container on it.
gunzip -t "$DUMP" || fail "gzip integrity check failed for $DUMP"

# Always tear the scratch container down, even on failure.
cleanup() {
    docker rm -f "$SCRATCH_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Fresh scratch postgres — no volume, purely ephemeral.
docker rm -f "$SCRATCH_NAME" >/dev/null 2>&1 || true
docker run -d --name "$SCRATCH_NAME" \
    -e POSTGRES_USER="$PG_USER" \
    -e POSTGRES_DB="$PG_DB" \
    -e POSTGRES_PASSWORD=drill \
    "$PG_IMAGE" >/dev/null

echo "[restore-drill] waiting for scratch postgres to accept connections"
for _ in $(seq 1 30); do
    if docker exec "$SCRATCH_NAME" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
docker exec "$SCRATCH_NAME" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1 \
    || fail "scratch postgres never became ready"

echo "[restore-drill] restoring dump"
gunzip -c "$DUMP" | docker exec -i "$SCRATCH_NAME" \
    pg_restore -U "$PG_USER" -d "$PG_DB" --no-owner --exit-on-error \
    || fail "pg_restore reported errors"

# Sanity: the core table exists and its row count is a non-negative integer.
count="$(docker exec "$SCRATCH_NAME" psql -U "$PG_USER" -d "$PG_DB" -tA \
    -c "SELECT count(*) FROM ${CORE_TABLE};" 2>/dev/null | tr -d '[:space:]')" \
    || fail "sanity SELECT on ${CORE_TABLE} failed"
case "$count" in
    ''|*[!0-9]*) fail "sanity count on ${CORE_TABLE} was not a number: '${count}'" ;;
esac

echo "[restore-drill] PASS: ${CORE_TABLE} restored with ${count} rows from $DUMP"
