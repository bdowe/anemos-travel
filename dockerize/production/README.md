# Production stack — anemos.travel

> **Box died / provider fired us?** [`REHOME.md`](REHOME.md) is the
> start-to-finish runbook for standing prod up on a fresh VM in ~90 minutes
> (proven 2026-08-01, Vultr → DigitalOcean).

Runs the prebuilt GHCR images (amd64) on a cloud VPS (**DigitalOcean**,
Ubuntu LTS — previously Vultr, originally a home Raspberry Pi) reached exclusively through
a **Cloudflare Tunnel**: the `cloudflared` service dials out to the
Cloudflare edge, so the host publishes no ports and exposes nothing
directly — even with a public IP, ingress stays tunnel-only. TLS
terminates at the edge; nginx restores the real client IP from
`CF-Connecting-IP` so the API's per-IP rate limiter sees end users, not
the tunnel connector.

## Host provisioning

Any amd64 VM with **≥ 4 GB RAM** works (the `chrome` service alone asks
for a 2 GB `shm_size`, plus postgres/api/nginx/cloudflared). From a fresh
Ubuntu LTS image:

1. Install Docker CE + the compose plugin, `rclone` (off-site backups),
   and `jq`.
2. Create a `deploy` user in the `docker` group; put the CI deploy
   public key (pair of the `DEPLOY_SSH_KEY` secret) in its
   `authorized_keys`.
3. Recreate the layout below under `/opt/goldentempo/` (rsync this
   directory; `mkdir backups`), fill `.env` from `.env.sample`.
4. Firewall: `ufw allow from 172.28.0.0/16 to any port 22` (tunnel →
   sshd for CI deploys), default-deny inbound otherwise. No inbound
   80/443 ever; close public 22 once the tunnel SSH path is verified.
5. Install the backup timer units from [`systemd/`](systemd/README.md).
6. Regenerate the `DEPLOY_KNOWN_HOSTS` GitHub secret from the new host's
   keys (one-liner in the deploy section below).

## Server layout

```
/opt/goldentempo/
├── docker-compose.yml        # this directory's compose file
├── .env                      # secrets incl. TUNNEL_TOKEN — copy .env.sample, fill in (chmod 600)
├── .image_tag                # IMAGE_TAG=<sha> of the live deploy (written by CI)
├── backup.sh                 # nightly pg_dump + prune + optional rclone off-site copy
├── nginx/
│   ├── prod.conf             # :80 server blocks (mounted over conf.d/default.conf)
│   └── cloudflare-realip.conf# compose-subnet trust + real_ip_header (mounted into conf.d/)
└── backups/                  # backup.sh output (gzipped pg_dump custom format)
```

## Cloudflare Tunnel

One tunnel (Zero Trust → Networks → Tunnels), token in `.env` as
`TUNNEL_TOKEN`, with five public hostnames:

| Hostname | Service | Purpose |
|----------|---------|---------|
| `anemos.travel` | `http://gateway:80` | the site |
| `www.anemos.travel` | `http://gateway:80` | nginx 301s it to the apex |
| `goldentempotravel.com` | `http://gateway:80` | legacy domain — nginx 308s to anemos.travel (pre-cutover email/share/unsubscribe links never die; unsubscribe is served in place) |
| `www.goldentempotravel.com` | `http://gateway:80` | legacy www — same 308 |
| `ssh.goldentempotravel.com` | `ssh://172.28.0.1:22` | CI deploys (host sshd via the pinned bridge gateway IP; deliberately stays on the legacy domain — tunnel-internal, keeps the `DEPLOY_*`/Access secrets stable) |

The SSH hostname sits behind a Cloudflare **Access** application with a
**service token**; CI authenticates with it (`CF_ACCESS_*` secrets) and
then does normal SSH-key auth on top. The host firewall needs
`ufw allow from 172.28.0.0/16 to any port 22` (tunnel→sshd) and no
inbound 80/443 rules at all. Enable **Always Use HTTPS** at the edge —
the origin serves plain :80 and never sees an http URL a user typed.

**The `cloudflared` image is version-pinned** in `docker-compose.yml` —
never `:latest`. Deploys ride the tunnel, and recreating the cloudflared
container severs the deploy's own SSH session; with `:latest`, any
upstream release turned the next routine deploy into that recreate and
left the stack half-down with no way back in (the 2026-07-23 Pi outage).
To upgrade cloudflared: bump the pin in its own commit and deploy
normally — CI runs `compose up` detached on the host, so the recreate
completes and the tunnel returns after a seconds-long blip (the deploy's
Verify step still confirms the site came back). If a bump ever goes
wrong, the DO web console is the tunnel-free way in.

## Environment / secrets

All runtime configuration lives in one file: `/opt/goldentempo/.env`
(`cp .env.sample .env`, fill in, `chmod 600`). It is used two ways:

1. **Compose interpolation** — `POSTGRES_PASSWORD` (required, no default:
   `docker compose config` fails fast if it's missing) and `IMAGE_TAG`.
2. **`env_file` passthrough into the api** — provider keys, SMTP, Sentry,
   `PUBLIC_*`, tuning vars. See `.env.sample` for the annotated inventory
   of what's required vs degraded-mode-optional.

`DATABASE_URL` is **not** set in `.env` — the compose file composes it from
`POSTGRES_PASSWORD` (so api and postgres can never disagree) with
`sslmode=disable`, which is safe because 5432 is never published to the
host; it exists only on the private compose network.

## How config reaches the containers

**Mounted, never baked.** The gateway image (built by
`dockerize/deployment/Dockerfile`) bakes in:

- `/etc/nginx/snippets/app-locations.conf` — the shared location set
  (API proxy, SPA, share-preview rewrite, static caching, legal pages),
  used verbatim by both the deployment and production `:80` servers;
- `/etc/nginx/conf.d/share-prerender-map.conf` — the `$share_prerender`
  bot-UA `map` (must live at `http` scope);
- `/etc/nginx/conf.d/default.conf` — the local `:80` server shell.

The production compose then **mounts** `nginx/prod.conf` *over*
`conf.d/default.conf` (replacing the `:80 localhost` shell with the
apex + www→apex servers) and mounts `nginx/cloudflare-realip.conf` into
`conf.d/`. Editing a conf on the host therefore needs only a gateway
restart, not an image rebuild:

```bash
docker compose exec gateway nginx -t && docker compose exec gateway nginx -s reload
```

## Client-IP chain (rate limiting correctness)

1. The Cloudflare edge terminates TLS and hands the request to this host's
   `cloudflared` connector, which proxies it to nginx `:80` with
   `CF-Connecting-IP` set to the end user's IP.
2. `cloudflare-realip.conf`: the peer is the cloudflared container on the
   pinned compose subnet (`172.28.0.0/16`), so the realip module rewrites
   `$remote_addr` to the header's value. Unspoofable because the gateway
   publishes no host ports — that subnet is the only possible traffic
   source, and everything on it is ours.
3. The shared `/api/` proxy block sends
   `X-Forwarded-For: $remote_addr` — **replace, not append** — a single
   trusted value.
4. The Go rate limiter (`src/packages/api/ratelimit.go` `clientIP()`) takes
   the rightmost `X-Forwarded-For` entry → the real user IP.

## Deploy / rollback

**Normal path is hands-off:** every green push to `main` builds + pushes
both images to GHCR (`:latest` and `:<sha>`) and the CI `deploy` job
rsyncs this directory to `/opt/goldentempo/` and restarts the stack with
`IMAGE_TAG=<sha>`. It also writes the live tag to
`/opt/goldentempo/.image_tag` AND refreshes the `IMAGE_TAG=` pin inside
`/opt/goldentempo/.env`, so a bare `docker compose up -d` on the host
always runs the currently-deployed image — a stale `.env` pin once made a
manual recreate silently roll the stack back to an old image. CI reaches the host through the tunnel's SSH hostname via
`cloudflared access ssh` + an Access service token. (Until the
`DEPLOY_HOST` / `DEPLOY_SSH_KEY` / `DEPLOY_KNOWN_HOSTS` /
`CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET` secrets exist, the
deploy job self-skips with a notice. `DEPLOY_HOST` is the SSH hostname —
`ssh.goldentempotravel.com` — and `DEPLOY_KNOWN_HOSTS` entries must use
that same name: on the host,
`for f in /etc/ssh/ssh_host_*_key.pub; do awk '{print "ssh.goldentempotravel.com", $1, $2}' "$f"; done`.)

**Rollback** = re-deploy an older image: GitHub → Actions → CI →
*Run workflow* on `main` with `image_tag` set to the git SHA of a previous
green main build. Manual fallback on the server:

```bash
cd /opt/goldentempo

# Restart whatever is currently deployed. CI refreshes the IMAGE_TAG pin in
# .env on every deploy, so bare compose commands are safe; sourcing
# .image_tag first is equivalent belt-and-braces.
docker compose pull && docker compose up -d

# Deploy/rollback a specific build by hand
IMAGE_TAG=<sha> docker compose pull && IMAGE_TAG=<sha> docker compose up -d

# Config-only change (no new images)
docker compose up -d --force-recreate gateway

# Status / logs
docker compose ps
docker compose logs -f gateway api

# DB backup before risky deploys (same script cron runs nightly)
./backup.sh
```

## Backups & restore

`backup.sh` dumps the database (`pg_dump -Fc | gzip`) into `backups/`,
prunes dumps older than 14 days, and — when `rclone` is installed with an
`r2:goldentempo-backups` remote configured — copies the new dump off-site
(otherwise it warns and still exits 0). Nightly cron (as root):

```cron
10 4 * * * /opt/goldentempo/backup.sh >> /var/log/goldentempo-backup.log 2>&1
```

Paths/services are overridable via env (`COMPOSE_FILE`, `COMPOSE_PROJECT`,
`BACKUP_DIR`, …) — see the header of `backup.sh`.

To restore a dump, follow [`restore.md`](restore.md): verify the dump in a
fresh scratch volume first, then swap it under the live stack and confirm
`/api/v1/health` reports `database: ok`.

## Sanity checks after a deploy

```bash
curl -fsS https://anemos.travel/health              # gateway
curl -fsS https://anemos.travel/api/v1/health       # API through the proxy
curl -sI  http://anemos.travel/                     # 301 → https apex
curl -sI  https://www.anemos.travel/                # 301 → apex
curl -sI  https://goldentempotravel.com/            # 308 → anemos.travel (legacy)
```

For the full end-to-end journey (register → trip → item → share/OG → export →
notifications → teardown), run the smoke harness against the live host.
It registers a throwaway user and deletes it in teardown, so it is safe to run
against production:

```bash
# sql seed mode is local-only (needs the postgres container); against prod use
# plan mode (the AI planner builds a real trip — costs a little Anthropic spend)
# or existing mode with a trip you own (SMOKE_TRIP_ID + SMOKE_TOKEN=<bearer>).
# SMOKE_MCP_EXPECT=on hard-fails unless the MCP connector is live — use it
# whenever MCP_ENABLED=true on the host, so a botched flip can't read as green
# (auto would happily assert the disabled state); off is the post-rollback run.
make smoke BASE_URL=https://anemos.travel SMOKE_SEED_MODE=plan SMOKE_MCP_EXPECT=on
```

Green means the traveler journey works end to end; the run also prints a
**MANUAL CHECKS REMAINING** block for the things a script can't assert on its own
(real Cloudflare real-IP rate limiting, Slack/Facebook link-preview unfurl, SMTP
inbox round-trips, legal-page DRAFT-banner sign-off).

## Edge cache — when icons or assets go stale

Symptom: the app is on the current release (`/app/version.json` is right,
`main.dart.js` is current, the deploy was green) but a few Material icons render
blank, or an image looks two deploys old. That is the CDN, not the build.

Why it happens: `flutter build web` does not content-hash asset filenames, so
`/app/assets/**` URLs are stable while the bytes change on every deploy —
`--release` re-tree-shakes `MaterialIcons-Regular.otf` to exactly the codepoints
the code references, so any icon swap rewrites it. nginx serves that tree
`no-cache` for precisely this reason. But if an object was ever stored under a
long-lived header, **it keeps the freshness lifetime it was stored with**:
correcting the origin header does not evict it, and the edge will not revalidate
until the original TTL expires. On 2026-08-14 that TTL was a year.

Check — this also runs automatically in the deploy job:

```bash
scripts/verify-edge-parity.sh https://anemos.travel
```

Repair. **The order is the whole point:**

1. **Purge Cloudflare** → Caching → Configuration → **Purge Everything**.
   (Purge-by-prefix is Enterprise-only; per-URL works on any plan but leaves the
   siblings pinned.)
2. **Re-run `scripts/verify-edge-parity.sh` until it passes.** Do not proceed
   while it is red.
3. **Only then** bump the service-worker manifest suffix
   (`flutter-app-manifest-vN` in `dockerize/deployment/Dockerfile`) and deploy.
   That is the one-shot eviction for clients whose service worker already filed
   stale bytes under the correct hash — it fires **once per client and can never
   be re-fired**, so firing it while the edge is still stale refills every client
   *from* the stale edge and burns the lever. That is exactly what `v2` did on
   2026-08-15.

One already-broken browser (yours) is repaired out of band: DevTools →
Application → Storage → **Clear site data**, then reload. A hard reload alone
repaints correctly for a single load and then reverts, because it bypasses the
service worker without repairing its cache.
