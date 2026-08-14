# Restore runbook — anemos.travel Postgres

Restores a `backup.sh` dump (`pg_dump -Fc | gzip`) into a **fresh volume
first**, verifies it there, and only then swaps it under the live stack.
The old volume's data is preserved until you delete it, so every step is
reversible.

Assumptions: stack at `/opt/goldentempo` (compose project `goldentempo`,
data volume `goldentempo_postgres_data`), dumps in
`/opt/goldentempo/backups/`. Confirm the volume name first:

```bash
docker volume ls | grep postgres_data
```

## 0. Pick the dump and sanity-check it

```bash
cd /opt/goldentempo
DUMP=backups/travel_planner-2026-07-06.dump.gz   # <-- pick the one you want

gunzip -t "$DUMP"                                # gzip integrity
gunzip -c "$DUMP" | pg_restore --list | head -30 # table of contents (host psql tools,
                                                 # or pipe through the container as below)
```

## 1. Stop writers (leave postgres up for now)

```bash
docker compose stop api
```

The gateway will serve 502s for `/api/` while the api is down; the static
app keeps loading. Keep this window short.

## 2. Restore into a fresh scratch volume

```bash
source .env   # for POSTGRES_PASSWORD

docker volume create goldentempo_postgres_restore

docker run -d --name pg-restore \
  -v goldentempo_postgres_restore:/var/lib/postgresql/data \
  -e POSTGRES_USER=travel \
  -e POSTGRES_DB=travel_planner \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  postgres:16-alpine

# Wait for it to accept connections — and stay up. A single pg_isready check
# races the image's first-boot init, which starts a TEMPORARY server, then
# stops and restarts it: the restore then fails with "the database system is
# shutting down" (hit for real in the 2026-07-21 drill). Require several
# consecutive successes instead.
ok=0
until [ "$ok" -ge 3 ]; do
  if docker exec pg-restore pg_isready -U travel -d travel_planner >/dev/null 2>&1; then
    ok=$((ok+1))
  else
    ok=0
  fi
  sleep 2
done

gunzip -c "$DUMP" | docker exec -i pg-restore \
  pg_restore -U travel -d travel_planner --no-owner --exit-on-error
```

## 3. Verify the scratch restore

```bash
docker exec pg-restore psql -U travel -d travel_planner -c '\dt'      # tables present
docker exec pg-restore psql -U travel -d travel_planner \
  -c 'SELECT count(*) FROM users; SELECT count(*) FROM trips;'        # plausible counts
docker exec pg-restore psql -U travel -d travel_planner \
  -c 'SELECT version_id, tstamp FROM goose_db_version ORDER BY id DESC LIMIT 1;'
```

Do **not** proceed past this point until the scratch data looks right.

```bash
docker stop pg-restore && docker rm pg-restore
```

## 4. Swap the restored data under the live stack

```bash
docker compose stop postgres

# Copy scratch volume over the live data volume. The live volume is only
# overwritten here — if anything above failed, you haven't touched it.
docker run --rm \
  -v goldentempo_postgres_restore:/src:ro \
  -v goldentempo_postgres_data:/dst \
  alpine sh -c 'rm -rf /dst/* && cp -a /src/. /dst/'

docker compose up -d postgres
docker compose up -d api      # api boot re-applies any missing migrations
```

## 5. Verify end to end

```bash
docker compose ps                                        # postgres healthy, api healthy
docker compose logs --tail 50 api                        # migrations applied, no errors
curl -fsS https://anemos.travel/api/v1/health           # "database":"ok"
```

Then a real user check: log in at <https://anemos.travel/app/> and open a
trip.

## 6. Clean up

```bash
docker volume rm goldentempo_postgres_restore
```

## Rollback

If the swapped data is wrong, the pre-swap state is gone from the live
volume (step 4 overwrote it) — restore an earlier dump by repeating from
step 0. If you want a zero-risk swap instead, run `backup.sh` once more
immediately before step 4 so "current state" is itself a restorable dump.
