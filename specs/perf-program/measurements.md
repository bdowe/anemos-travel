# Perf program — measurements log

Plan: `~/.claude/plans/the-app-feels-pretty-sorted-crescent.md`. This file is
seeded from the Wave 0 baseline and updated after each wave's deploy; it is
committed to `specs/perf-program/measurements.md` by the integrator.

## Wave 0 baseline — 2026-08-07 (pre-Wave-1)

Prod release: `e2ddd2e2aed566fbd40f119979a91f2a76c2352e` (= main e2ddd2e).

### Prod asset payload (unauthenticated curls, Claude)

| Resource | Identity bytes | Notes |
|---|---:|---|
| `/app/main.dart.js` | 5,553,814 | browser leg `content-encoding: br` (Cloudflare); `cf-cache-status: REVALIDATED`; **`cache-control: max-age=14400` at the edge — NOT the origin's no-cache** (observation: CF default TTL overrides shell no-cache for js; helps perf, delays deploy pickup ≤4 h for warm browsers) |
| mdi `materialdesignicons-webfont.ttf` | 1,034,252 | confirmed shipped (Lane 1C removes) |
| `Inter-Regular.ttf` / `Inter-Bold.ttf` | 411,640 / 420,428 | ×4 weights ≈ 1.67 MB (Lane 1C subsets) |
| `KaTeX_Main-Regular.ttf` | 68,376 | ×16 files ≈ 597 KB (Wave 3B strips) |
| `JetBrainsMono-Regular.ttf` | 273,900 | code blocks only |
| CanvasKit | — | **loads from gstatic CDN** (`flutter_bootstrap.js` → `https://www.gstatic.com/flutter-canvaskit`) → brotli + edge-cached; D6 resolved: NOT an origin problem. Local `/app/canvaskit/canvaskit.wasm` exists (7,052,864 B) but unused. |
| `flutter_service_worker.js` | 12,040 | `max-age=14400`, `cf-cache-status: MISS`; D2 (SW cache inert?) still needs the in-browser Application-tab check (BRIAN) |
| `/app/` index.html | — | `no-cache`, `DYNAMIC`, br ✓ |

### Prod API TTFB (unauthenticated)

`GET /api/v1/health` ×5: 0.356, 0.200, 0.182, 0.349, 0.213 s → **median ≈ 0.213 s**.
(Network+edge+tunnel+Go floor, no session tax. Authed comparisons below.)

### Pending baseline pieces

- [ ] **BRIAN (Zen browser)**: hard-reload Network waterfall of `/app/`
  (Disable cache ON): total bytes + first-frame timing (3-run median via
  `flutter-first-frame` listener); then normal reload — which resources
  re-download vs 304 vs SW (screenshot Application → Cache Storage = D2
  verification). One `about:profiling` boot capture. Trip-open waterfall +
  interaction profile (open → row tap → city expand → filter → back → reopen).
- [ ] **Authed TTFB medians** (needs a session token): ×10
  `GET /api/v1/trips/{id}`, `GET /api/v1/chats`, cold `GET /trips/{id}/review`;
  `GET /api/v1/admin/ops/metrics` snapshot.
### Local harness (docker-deploy, main @ e2ddd2e) — DONE 2026-08-07

- `main.dart.js` with `Accept-Encoding: gzip, br`: **NO Content-Encoding**
  (5,553,814 raw bytes) — confirms zero origin compression (Lane 1A's
  before/after). `Cache-Control: no-cache` at origin — confirms prod's
  `max-age=14400` is Cloudflare's edge default TTL overriding the origin
  header, not an origin change.
- mdi font served locally: 1,034,252 B (Lane 1C before/after).
- `GET /api/v1/health` TTFB ×5 local: ~0.001 s → prod's ~0.213 s median is
  network+edge+tunnel, not Go. Authed-endpoint deltas are where the
  session-DELETE fix will show.
- [ ] Local trip-open waterfall (browser, optional — prod waterfall is the
  primary artifact).

## Wave 1 — post-deploy 2026-08-10 (prod a1b3ce2)

Merged + deploy-verified in order: #308 (what-to-wear, pre-wave backlog) →
#309 (1B api-hot-path-tax, migration 00054) → #311 (1A nginx-gateway) →
#310 (1C flutter-quick-wins).

| Metric | Before (08-07) | After (08-10) |
|---|---:|---:|
| mdi icon font | 1,034,252 B | **404 — gone** |
| Inter ×4 weights | 1,669,112 B | **298,892 B** (73,840/74,724/75,284/75,044) |
| main.dart.js | 5,553,814 B | 5,558,739 B (unchanged as expected; KaTeX strip is Wave 3B) |
| FontManifest | mdi + KaTeX + Inter + … | mdi **removed**; KaTeX remains (Wave 3B) |
| `/plan` priming | n/a (buffered) | `: stream-open` at TTFB ≈ network floor, HTTP 200 pre-parse ✓ |

**Boot font payload cut: ~2.40 MB → ~0.30 MB (−2.1 MB per cold boot), plus
origin gzip now on for the tunnel leg + local stacks.**

**TTFB caveat (important for future comparisons):** 08-10 `/health` reads
~0.37–0.55 s vs 08-07's ~0.21 s median, but static `version.json` (pure
nginx, unchanged code path) shows the SAME elevation, and connect+TLS alone
is ~0.29 s today — the delta is the network path on the day, not the wave.
Cross-day absolute TTFBs are unreliable; measure relative (static vs API,
authed vs unauth) within one session. The session-DELETE win must be read as
(authed − unauth) delta once a token is available.

Remaining follow-ups:
- [ ] BRIAN: Zen-browser before/after feel check + the pending baseline
  captures (boot waterfall, about:profiling, trip-open profile) — these are
  now "after Wave 1" reference points for Waves 2–4.
- [ ] Authed TTFB medians (needs session token) — meaningful for Wave 2's
  before/after more than Wave 1's.
- [ ] 429-count observation window (rate-limit retune evidence).
