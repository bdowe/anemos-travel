# Docker setup

Docker orchestration lives here instead of in individual app packages. A single **nginx gateway** exposes one port so the browser talks to one origin (no CORS issues between UI and API).

## Layout

```
dockerize/
├── development/     # Flutter dev server (hot reload) + Go API + nginx
├── deployment/      # Static Flutter build + Go API + nginx
└── production/      # anemos.travel: prebuilt GHCR images behind a Cloudflare Tunnel (see its README)
```

## Quick start

From the repository root:

```bash
# Development: hot reload, http://localhost:3000
make docker-dev

# Deployment: static build, http://localhost:3000/app/
make docker-deploy
```

## URLs

| Path | Target |
|------|--------|
| `http://localhost:3000/` | Flutter UI (dev server or redirect to `/app/`) |
| `http://localhost:3000/app/` | Flutter UI (deployment static files) |
| `http://localhost:3000/api/v1/...` | Go API (proxied) |
| `http://localhost:3000/health` | Gateway health check |

The Flutter app is built with `API_BASE_URL=/api/v1` so API calls are same-origin relative paths.

## API configuration

Set `GOOGLE_PLACES_API_KEY` in `src/packages/api/.env` (see `.env.sample`). Both compose files load it via `env_file`.

## Development stack

- **api** — Go server on internal port 8080
- **flutter** — `flutter run -d web-server` with source mounted from `src/packages/flutter-app`
- **gateway** — nginx on host port 3000

First start can take 1–2 minutes (Flutter SDK download + dev server compile). The gateway returns **502** if you open the app before the Flutter container is ready — wait until `flutter` logs show `lib/main.dart on Web Server`, then refresh.

After `docker compose restart flutter`, expect ~30–90s of 502s while the dev server restarts (no full `build_runner` run unless `RUN_BUILD_RUNNER=1`).

## Deployment stack

- **api** — Go server (internal only)
- **gateway** — multi-stage image: builds Flutter web, serves static files, proxies `/api/` to api

## Local development without Docker

```bash
make api-run          # API on http://localhost:8080
make flutter-run      # Pass API URL if needed:
# flutter run --dart-define=API_BASE_URL=http://localhost:8080/api/v1
```
