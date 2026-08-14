#!/usr/bin/env bash
# Nightly Postgres backup for the anemos.travel production stack.
#
# Dumps the database from the running postgres container (pg_dump custom
# format, gzipped), prunes local dumps older than RETENTION_DAYS, and — if
# rclone is installed with the configured remote — copies the new dump
# off-site. Designed for cron:
#
#   10 4 * * * /opt/goldentempo/backup.sh >> /var/log/goldentempo-backup.log 2>&1
#
# Exit status: non-zero if the dump itself fails (cron mails/logs it);
# a missing/unconfigured rclone only warns and exits 0 (off-site copy is
# best-effort, the local dump already succeeded).
#
# Every path/name is overridable via env so the script can be dry-run
# against another stack (e.g. the dev compose) without touching this file:
#
#   COMPOSE_FILE      compose file of the stack to back up
#                     (default /opt/goldentempo/docker-compose.yml)
#   COMPOSE_PROJECT   compose project name; empty => derived by compose
#                     from the compose-file directory (default empty)
#   BACKUP_DIR        where dumps land (default /opt/goldentempo/backups)
#   PG_SERVICE        compose service name of postgres (default postgres)
#   PG_USER / PG_DB   database credentials (default travel / travel_planner)
#   RETENTION_COUNT   how many dumps to keep, locally AND on the remote
#                     (default 10; count-based so a stalled backup job can
#                     never age-out every existing copy)
#   RCLONE_REMOTE     rclone destination (default r2:goldentempo-backups)
#   BACKUP_HEARTBEAT_FILE  freshness marker written on a good local dump
#                     (default $BACKUP_DIR/.last_success); the API's
#                     /admin/ops/health reads it to detect stale backups
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-/opt/goldentempo/docker-compose.yml}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-}"
BACKUP_DIR="${BACKUP_DIR:-/opt/goldentempo/backups}"
PG_SERVICE="${PG_SERVICE:-postgres}"
PG_USER="${PG_USER:-travel}"
PG_DB="${PG_DB:-travel_planner}"
RETENTION_COUNT="${RETENTION_COUNT:-10}"
RCLONE_REMOTE="${RCLONE_REMOTE:-r2:goldentempo-backups}"
BACKUP_HEARTBEAT_FILE="${BACKUP_HEARTBEAT_FILE:-$BACKUP_DIR/.last_success}"

compose() {
    if [ -n "$COMPOSE_PROJECT" ]; then
        docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" "$@"
    else
        docker compose -f "$COMPOSE_FILE" "$@"
    fi
}

# install -d, not mkdir -p: the mode must be explicit AND applied even when
# the directory already exists. This job runs as root, and root's umask once
# created the directory 0700 — the api container (uid 1001, read-only mount)
# couldn't traverse it, so /admin/ops/health reported "backups stale" forever
# despite fresh nightly dumps. 0755 is required for the heartbeat to be
# readable through the compose bind mount; self-heals on every run.
install -d -m 755 "$BACKUP_DIR"

out="$BACKUP_DIR/${PG_DB}-$(date +%F).dump.gz"
tmp="$out.tmp"
trap 'rm -f "$tmp"' EXIT

echo "[backup] $(date -u +%FT%TZ) dumping $PG_DB from service '$PG_SERVICE' to $out"

# pipefail makes a pg_dump failure fail the whole pipeline; the tmp+mv dance
# means a failed run never leaves a truncated file behind as "the backup".
compose exec -T "$PG_SERVICE" pg_dump -Fc -U "$PG_USER" "$PG_DB" | gzip >"$tmp"
mv "$tmp" "$out"

echo "[backup] wrote $(du -h "$out" | cut -f1) $out"

# Prune local dumps beyond the newest RETENTION_COUNT. Dump names embed the
# date (YYYY-MM-DD), so a reverse lexical sort is newest-first; count-based
# (not age-based) so if backups ever silently stop, the last N copies survive
# instead of aging out to nothing.
find "$BACKUP_DIR" -maxdepth 1 -name "${PG_DB}-*.dump.gz" -type f |
    sort -r | tail -n +$((RETENTION_COUNT + 1)) |
    while IFS= read -r f; do rm -f "$f" && echo "[backup] pruned $f"; done

# Freshness heartbeat: a good local dump exists. Written BEFORE the best-effort
# off-site copy so an unconfigured/failed rclone (which exits 0) never withholds
# the "backups are current" signal — the API's /admin/ops/health only asks
# whether a recent dump succeeded, not whether it was mirrored off-site.
date -u +%FT%TZ >"$BACKUP_HEARTBEAT_FILE"
echo "[backup] heartbeat $(cat "$BACKUP_HEARTBEAT_FILE") -> $BACKUP_HEARTBEAT_FILE"

# Off-site copy (best-effort): requires rclone AND the remote to exist.
remote_name="${RCLONE_REMOTE%%:*}"
if ! command -v rclone >/dev/null 2>&1; then
    echo "[backup] WARNING: rclone not installed — skipping off-site copy of $out" >&2
    exit 0
fi
if ! rclone listremotes | grep -qx "${remote_name}:"; then
    echo "[backup] WARNING: rclone remote '${remote_name}:' not configured — skipping off-site copy of $out" >&2
    exit 0
fi
rclone copy "$out" "$RCLONE_REMOTE/"
echo "[backup] copied $out to $RCLONE_REMOTE/"

# Prune the remote to the same newest-RETENTION_COUNT window. Best-effort like
# the copy itself: a prune hiccup must not fail a backup that already succeeded
# locally and uploaded. awk (not grep) filters so an empty match set doesn't
# trip pipefail.
rclone lsf "$RCLONE_REMOTE/" --files-only |
    awk "/^${PG_DB}-.*\.dump\.gz$/" | sort -r | tail -n +$((RETENTION_COUNT + 1)) |
    while IFS= read -r f; do
        rclone deletefile "$RCLONE_REMOTE/$f" &&
            echo "[backup] pruned remote $f" ||
            echo "[backup] WARNING: failed to prune remote $f" >&2
    done
