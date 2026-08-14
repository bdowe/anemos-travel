# Re-home runbook — move prod to a new box in ~90 minutes

How to stand production up on a **fresh VM at any provider**, from any laptop,
with zero DNS changes. Proven for real on 2026-08-01 (Vultr account suspension
→ DigitalOcean), ~90 min of active work, zero data loss.

Why this works: the origin box is disposable by design. Everything durable
lives elsewhere —

| Asset | Where | Notes |
|---|---|---|
| Database | R2 bucket `goldentempo-backups` | nightly `pg_dump` via `backup.sh` (04:10 UTC) |
| Images | GHCR (`goldentempo-api` / `-gateway`, public) | tagged `latest` + full git SHA |
| Ingress | Cloudflare Tunnel | routes + Access live on the tunnel, not the box |
| Stack config | this directory | rsynced to `/opt/goldentempo/` |
| Secrets | dashboards + dev `.env` + 1Password | see Phase 0 |

Related docs: [`README.md`](README.md) (host provisioning details),
[`restore.md`](restore.md) (restore onto a box that already has data — NOT
needed for a fresh box), [`systemd/README.md`](systemd/README.md) (backups).

---

## Phase 0 — Dashboard checklist (~20 min, needs a human)

1. **New VM**: Ubuntu LTS x64, ≥2 vCPU / 4 GB, region near users (NYC),
   add your SSH public key at creation. (2026 reference: DO Basic 2/4GB ≈ $24/mo.)
2. **Rotate the tunnel token**: Cloudflare Zero Trust → Networks → Tunnels →
   the tunnel → rotate, copy the new `eyJ…` token. **Rotate, don't just copy**:
   rotation bricks the token on the old box so it can never reconnect as a
   second origin and split-brain the tunnel. (If rotate is unfindable in the
   UI, copying works — but then you MUST destroy the old box before it can
   ever boot again.)
3. **R2 credentials** — only if the old box is unreachable (the rclone token
   lives only on the box): R2 → Manage API tokens → create, Object Read &
   Write, scoped to `goldentempo-backups`. Copy Access Key ID / Secret / the
   `https://<account-id>.r2.cloudflarestorage.com` endpoint (shown once).
4. **Gather remaining `.env` values**: most provider keys live in the dev
   `.env` (`src/packages/api/.env`); `SENTRY_DSN` from sentry.io → project →
   Client Keys. `EXPORT_SIGNING_SECRET`: reuse if saved, else regenerate and
   accept that outstanding export/share/unsubscribe links die.

## Phase 1 — Bootstrap the box (`ssh root@<NEW_IP>`)

Per [`README.md`](README.md): Docker CE + compose plugin (docker.com apt
repo), `jq`, `rsync`, **rclone from rclone.org** (distro rclone is old and
noisy against R2), `deploy` user in the `docker` group,
`mkdir -p /opt/goldentempo/backups`.

From the laptop:

```bash
rsync -rtvz dockerize/production/ root@<NEW_IP>:/opt/goldentempo/
```

**⚠️ Ownership matters:** the CI deploy job rsyncs and writes `.image_tag` as
`deploy`. A root-owned tree fails the deploy with `mkstemp … Permission
denied (exit 23)`. After all root-side file writes are done:

```bash
chown -R deploy:deploy /opt/goldentempo
chown root:root /opt/goldentempo/backups && chmod 700 /opt/goldentempo/backups  # backup.sh runs as root
```

Write `/root/.config/rclone/rclone.conf` (chmod 600):

```ini
[r2]
type = s3
provider = Cloudflare
access_key_id = <R2 key id>
secret_access_key = <R2 secret>
endpoint = https://<account-id>.r2.cloudflarestorage.com
no_check_bucket = true          # REQUIRED with bucket-scoped tokens
```

## Phase 2 — `.env` + image tag

Build `/opt/goldentempo/.env` (chmod 600) from [`.env.sample`](.env.sample).
Rules learned the hard way:

- `POSTGRES_PASSWORD`: **alphanumeric only** (`openssl rand -hex 32`) —
  `@:/#%` break the composed DSN.
- `IMAGE_TAG`: the **full 40-char git SHA** of the last green main build
  (`git rev-parse origin/main`; confirm its CI `build-push` job succeeded).
  Put it in **both** `.image_tag` (CI convention) **and** `.env` — the `.env`
  copy is what saves you when someone recreates a service without sourcing
  `.image_tag` (the silent-`:latest`-rollback gotcha).
- `TUNNEL_TOKEN`: the rotated token from Phase 0.
- `SMTP_FROM`: bare address, no `Name <addr>` display form (breaks the
  envelope with 501).

## Phase 3 — Restore the database ⚠️ BEFORE anything else touches backups

**Hazard:** running `backup.sh` before the restore is verified would dump the
EMPTY database and, if run on the same UTC date as the newest good dump,
overwrite it in R2. Restore first. Always.

```bash
# 1. preserve the last old-box dump under a distinct name
rclone copyto r2:goldentempo-backups/travel_planner-<DATE>.dump.gz \
              r2:goldentempo-backups/travel_planner-<DATE>-oldbox.dump.gz

# 2. fetch + integrity-check
mkdir -p /root/restore && rclone copy r2:goldentempo-backups/travel_planner-<DATE>.dump.gz /root/restore/
gunzip -t /root/restore/travel_planner-<DATE>.dump.gz

# 3. postgres alone
cd /opt/goldentempo && set -a; . ./.image_tag; set +a && docker compose up -d postgres

# 4. THREE consecutive pg_isready checks — a single check races the image's
#    first-boot init restart ("the database system is shutting down")
ok=0; until [ "$ok" -ge 3 ]; do
  docker compose exec -T postgres pg_isready -U travel -d travel_planner >/dev/null 2>&1 \
    && ok=$((ok+1)) || ok=0
  sleep 2
done

# 5. fresh empty volume → restore straight in (no restore.md volume-swap dance)
gunzip -c /root/restore/travel_planner-<DATE>.dump.gz | \
  docker compose exec -T postgres pg_restore -U travel -d travel_planner --no-owner --exit-on-error

# 6. sanity
docker compose exec -T postgres psql -U travel -d travel_planner -Atc \
  "SELECT count(*) FROM users; SELECT count(*) FROM trips; SELECT max(version_id) FROM goose_db_version;"
```

The api applies any migrations newer than the dump at boot — expect
`goose: successfully migrated database to version: N` in its log. (Session
rows hashed after the dump was taken get re-hashed → those users sign in
again. Fine.)

## Phase 4 — Stack up + public cutover

```bash
docker compose pull && docker compose up -d
docker compose ps                      # all healthy
docker compose logs cloudflared | tail # connector registered
```

From the laptop (no DNS changes — the tunnel route follows the connector):

```bash
curl -s https://anemos.travel/api/v1/health | jq '{database, release}'   # ok + your SHA
curl -s "https://anemos.travel/app/version.json?d=1" | jq -r .release    # same SHA
```

Log into a real account in a browser: proves restored password hashes and
sessions end-to-end.

## Phase 5 — SSH + firewall

Keep a **temporary** public-22 allow until the tunnel SSH path is proven —
the proof is a green CI deploy (Phase 7), which connects through the tunnel
with the Access service token.

```bash
ufw default deny incoming; ufw default allow outgoing
ufw allow from 172.28.0.0/16 to any port 22 proto tcp   # tunnel path (compose bridge gateway)
ufw allow 22/tcp comment "TEMPORARY - remove after tunnel verified"
ufw --force enable
```

Check for provider-image pre-seeded ufw rules and delete strays. Never open
80/443 — tunnel-only ingress is what makes `cloudflare-realip.conf`'s trust
of the compose subnet unspoofable. **After Phase 7 is green:**
`ufw delete allow 22/tcp` (run twice: v4+v6), then verify from outside:
`nc -z -w5 <NEW_IP> 22` must fail.

## Phase 6 — Backups live again (only after Phase 3 verified)

Per [`systemd/README.md`](systemd/README.md): copy the two units to
`/etc/systemd/system/`, `daemon-reload`, `enable --now
goldentempo-backup.timer` (do **not** also add the legacy cron line). Then one
manual `/opt/goldentempo/backup.sh` run: check the local dump, the
`.last_success` heartbeat, and `rclone lsf r2:goldentempo-backups` shows the
upload.

## Phase 7 — Re-point CI deploys

The old CI keypair's public half lives only on the dead box — mint fresh:

```bash
ssh-keygen -t ed25519 -f /tmp/dk -N '' -C gh-actions-deploy
gh secret set DEPLOY_SSH_KEY < /tmp/dk && rm /tmp/dk
# install /tmp/dk.pub as /home/deploy/.ssh/authorized_keys (deploy:deploy, 600)

# new host keys → known_hosts secret (run on the box):
for f in /etc/ssh/ssh_host_*_key.pub; do awk '{print "ssh.goldentempotravel.com", $1, $2}' "$f"; done
#   → gh secret set DEPLOY_KNOWN_HOSTS

# DEPLOY_HOST and CF_ACCESS_CLIENT_ID/SECRET are origin-independent: unchanged.

gh workflow run CI -f image_tag=<same full SHA>   # deploy-only redeploy proof
```

Green deploy = tunnel SSH proven → finish Phase 5's public-22 removal.

## Verification checklist (definition of done)

- [ ] `docker compose ps`: 4 services healthy, restart `unless-stopped`
- [ ] Public health + `version.json` both report the pinned SHA; `database: ok`
- [ ] Real-account browser login; trips visible
- [ ] `make smoke BASE_URL=https://anemos.travel SMOKE_SEED_MODE=plan SMOKE_MCP_EXPECT=on` → 0 failed
      (`on` catches the re-home footgun: a `.env` rebuilt from `.env.sample`
      comes up `MCP_ENABLED=false` and silently disables the live connector)
- [ ] Backup timer scheduled + manual run uploaded to R2
- [ ] CI redeploy green including the release-verify step
- [ ] Public 22 refused from outside; ufw shows only the 172.28.0.0/16 rule
- [ ] UptimeRobot monitors green; Sentry shows the api "sentry enabled" boot line

## Old-box afterlife

Token rotation already bricked its tunnel access. When/if the old box is
reachable again: pull `/opt/goldentempo/.env` (old signing secrets) and
`docker compose logs api` (forensics) if wanted, then destroy the instance
and kill the billing. Update `~/.ssh/config`'s emergency-fallback comment and
the provider name in [`README.md`](README.md) + `.github/workflows/ci.yml`.
