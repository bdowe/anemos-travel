# Production stack — goldentempotravel.com

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
`TUNNEL_TOKEN`, with three public hostnames:

| Hostname | Service | Purpose |
|----------|---------|---------|
| `goldentempotravel.com` | `http://gateway:80` | the site |
| `www.goldentempotravel.com` | `http://gateway:80` | nginx 301s it to the apex |
| `ssh.goldentempotravel.com` | `ssh://172.28.0.1:22` | CI deploys (host sshd via the pinned bridge gateway IP) |

The SSH hostname sits behind a Cloudflare **Access** application with a
**service token**; CI authenticates with it (`CF_ACCESS_*` secrets) and
then does normal SSH-key auth on top. The host firewall needs
`ufw allow from 172.28.0.0/16 to any port 22` (tunnel→sshd) and no
inbound 80/443 rules at all. Enable **Always Use HTTPS** at the edge —
the origin serves plain :80 and never sees an http URL a user typed.

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
`/opt/goldentempo/.image_tag` so manual restarts don't fall back to
`:latest`. CI reaches the host through the tunnel's SSH hostname via
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

# Restart whatever is currently deployed (reads .image_tag written by CI)
set -a; . ./.image_tag; set +a
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
curl -fsS https://goldentempotravel.com/health              # gateway
curl -fsS https://goldentempotravel.com/api/v1/health       # API through the proxy
curl -sI  http://goldentempotravel.com/                     # 301 → https apex
curl -sI  https://www.goldentempotravel.com/                # 301 → apex
```

For the full end-to-end journey (register → trip → item → share/OG → export →
alerts → notifications → teardown), run the smoke harness against the live host.
It registers a throwaway user and deletes it in teardown, so it is safe to run
against production:

```bash
# sql seed mode is local-only (needs the postgres container); against prod use
# plan mode (the AI planner builds a real trip — costs a little Anthropic spend)
# or existing mode with a trip you own (SMOKE_TRIP_ID + SMOKE_TOKEN=<bearer>).
make smoke BASE_URL=https://goldentempotravel.com SMOKE_SEED_MODE=plan
```

Green means the traveler journey works end to end; the run also prints a
**MANUAL CHECKS REMAINING** block for the things a script can't assert on its own
(real Cloudflare real-IP rate limiting, Slack/Facebook link-preview unfurl, SMTP
inbox round-trips, legal-page DRAFT-banner sign-off).
