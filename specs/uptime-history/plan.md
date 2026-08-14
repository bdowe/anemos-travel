# Plan: Uptime History

## Technical Approach

The health monitor (`ops_monitor.go`) already ticks every `HEALTH_TICK_MINUTES` and already
computes the exact verdict we want to plot (`computeHealthState` over DB ping, backup
freshness, AI-provider health). It just throws the verdict away unless it changed. So: persist
each tick, roll the stream up per UTC day in one pure function, and render it.

Three decisions carry the design:

1. **Every stored row is an interval with a state** (`covers_from` → `observed_at`), not a
   bare timestamp. The alternative — count samples per day and divide by an expected count —
   makes `HEALTH_TICK_MINUTES` retroactive schema: change it and every prior day is silently
   re-scored. Storing the span each row vouches for means history is permanently
   self-describing (`docs/zen.md`: conventions get promoted to storage).
2. **Absence is written down, not inferred.** The sampler cannot observe its own downtime, so
   at boot the process compares the newest stored row against now and writes an explicit `gap`
   row for the span in between, with a cause: the release changed (`deploy`) or it didn't
   (`unknown` — crash, OOM, host reboot). The rollup then performs zero inference; "a missing
   row means downtime" never becomes a rule someone has to remember. This is also what keeps
   6–12 deploys/day from inventing ~4 %/day of phantom downtime: deploy gaps are *unobserved*,
   counted in neither half of the ratio, while an unexplained gap is the one thing that paints
   a bar red.
3. **The three signals stay three booleans.** Never a joined reasons string. That is what
   makes it structurally impossible for a stale backup to tint the availability bar.

Deliberately **not** in scope: graceful shutdown. `startServer` ends in
`log.Fatal(ListenAndServe)`, so a SIGTERM handler would be a deploy-path behavior change; it
would only shrink the unobserved band around each deploy, which already costs nothing in the
percentage.

## Go API Changes

`src/packages/api/`:

- **Migration** `migrations/00059_health_samples.sql` — 00059 because
  `00058_expense_booking_link.sql` was reserved by the `budget-v2` lane (that lane never
  reached main and 00058 is now permanently burned — `docs/parallel-dev.md` §4a). Table
  `health_samples`: `observed_at` PK, `covers_from`, `kind` (`tick`|`gap`), `release`,
  `gap_cause`, and the three nullable booleans, with CHECK constraints binding the columns to
  the kind so a malformed row cannot exist.
- **Queries** `query/ops_uptime.sql` → `make api-sqlc`:
  - `InsertHealthSample :exec` (`ON CONFLICT (observed_at) DO NOTHING` — a buffered flush can
    collide with a live tick).
  - `HealthSamplesSince :many` — the window plus **one anchor row from before it**, ascending;
    without the anchor, day 0 reads as no-data until its first tick.
  - `LastHealthSample :one` (`observed_at`, `release`) — drives the boot gap.
  - `EarliestHealthSample :one` — `monitoring_since`.
  - `DeleteOldHealthSamples :exec` — 100-day retention (window + slack so the oldest bar keeps
    its anchor).
- **Sampler** `ops_monitor.go` — additions only, alerting untouched: an `insertSample` seam
  (its own, separate from the alerting seams), `lastSampleAt`, `release`, a mutex-guarded
  bounded retry buffer, `bootstrapSamples` (writes the boot gap), and a `writeSample` call in
  `runOnce` **before** the transition dedup returns, so a sample is written every tick.
- **Rollup + handler** `ops_uptime.go` (new) — `rollupUptime(...)` is pure and is the only
  place any of this is derived; `opsUptimeHandler` wraps it. Response types
  `UptimeResponse` / `UptimeComponent` / `UptimeDay`.
- **Route** `main.go` — `api.Handle("/admin/ops/uptime", admin(opsUptimeHandler)).Methods("GET")`
  beside the other two `/admin/ops/*` registrations, plus a startup log line. Unlike its
  siblings it 503s when `dbPool == nil`, like `/admin/metrics/*`, because it is DB-backed.
- **Prune** `janitor.go` — `DeleteOldHealthSamples` in `janitorTick`, same shape as the two
  existing prunes.

Attribution rules (the whole of the derivation, stated once here and once in the rollup's doc
comment):

| row | api | database | ai_provider | backups |
|---|---|---|---|---|
| `tick`, `db_ok` | up | up | `ai_ok` ? up : down | `backups_ok` ? up : down |
| `tick`, `!db_ok` | **down** | down | `ai_ok` ? up : down | `backups_ok` ? up : down |
| `gap`, `deploy` | unknown | unknown | unknown | unknown |
| `gap`, `unknown` | **down** | unknown | unknown | unknown |

`api` contains `database` on purpose (the app is unusable without persistence) — one verdict
with a documented containment, not two competing ones. A gap says nothing about Anthropic or
about backups, so charging our own restart to their uptime would be a lie.

## Flutter Changes

`src/packages/flutter-app/lib/`:

- **Model** `models/ops_uptime.dart` (+ `.g.dart` via `make flutter-build-models`) —
  `OpsUptime` / `UptimeComponent` / `UptimeDay`, snake-case field rename, all-defaulted const
  constructors like the rest of the `ops_*` family. `state` and `reasonCodes` stay `String`s
  so a value added server-side later renders as unknown instead of throwing. `uptimePct` is
  `double?`; the client never recomputes a percentage.
- **Service** `services/ops_admin_api_service.dart` — `getOpsUptime({int days = 90})`.
- **Provider** `providers/ops_admin_provider.dart` — `opsUptimeProvider`, deliberately **not**
  on the pane's 10-second refresh timer (the data changes at most every 5 minutes); it
  refreshes on pull-to-refresh and on app resume.
- **Widget** `widgets/uptime_strip.dart` (new) — a sibling `CustomPainter` to
  `daily_count_chart.dart`, not an extension of it: that widget is single-hue by written
  doctrine and built around a value axis; this one encodes a category per day and has no
  scale. Its slot math is copied verbatim (proven at 90 bars on a phone). Fixed 48 px canvas
  so a bad day landing on refresh cannot reflow the pane; severity raises the mark height so
  the encoding survives grayscale and color blindness.
- **Theme** `theme/app_colors.dart` — brightness-aware `upMark` / `degradedMark` / `downMark`.
  The existing `successContainer` / `warningContainer` are 15–20 % alpha (invisible at 3 px)
  with `shade800/900` foregrounds (the known dark-mode weak spot). `no_data` takes
  `colorScheme.outlineVariant` — the recessive role, so absence is not a fourth severity.
- **Pane** `widgets/health_pane.dart` — `_UptimeSection` first in the `ListView`; the existing
  process tile is renamed `healthUptime` → `healthProcessUptime` ("Process uptime") so the
  word "Uptime" means exactly one thing on the screen.
- **l10n** — new `health*` keys in `app_en.arb` **and** `app_es.arb` (CI fails on any
  untranslated key), then `make flutter-gen-l10n`, regenerated **last**.

## Contract Parity

| JSON key | Go type | Dart type | Nullable? | ✓ |
|---|---|---|---|---|
| `days` | `int` | `int` | no | ☐ |
| `start_day` | `string` (`YYYY-MM-DD`) | `String` | no | ☐ |
| `monitoring_since` | `*string` (RFC3339) | `DateTime?` | yes | ☐ |
| `components` | `[]UptimeComponent` | `List<UptimeComponent>` | no | ☐ |
| `components[].key` | `string` | `String` | no | ☐ |
| `components[].status` | `string` | `String` | no | ☐ |
| `components[].uptime_pct` | `*float64` | `double?` | yes | ☐ |
| `components[].observed_days` | `int` | `int` | no | ☐ |
| `components[].days` | `[]UptimeDay` | `List<UptimeDay>` | no | ☐ |
| `components[].days[].day` | `string` (`YYYY-MM-DD`) | `DateTime` | no | ☐ |
| `components[].days[].state` | `string` | `String` | no | ☐ |
| `components[].days[].uptime_pct` | `*float64` | `double?` | yes | ☐ |
| `components[].days[].up_s` | `int64` | `int` | no | ☐ |
| `components[].days[].down_s` | `int64` | `int` | no | ☐ |
| `components[].days[].unknown_s` | `int64` | `int` | no | ☐ |
| `components[].days[].reason_codes` | `[]string` (non-nil) | `List<String>` | no | ☐ |

`uptime_pct` is null **iff** the state is `no_data`; `0.0` and `null` are different values and
the UI must not conflate them. `reason_codes` are stable enum codes
(`db_unreachable` / `process_down` / `ai_failing` / `backups_stale`), localized client-side —
the wire never carries English prose for this.

## Cross-cutting

- **Env vars:** none new. `HEALTH_TICK_MINUTES` keeps its meaning; the stored history no
  longer depends on it.
- **Gateway:** the new path is under `/api/v1/`, so no proxy change.
- **Test harness:** `health_samples` must be added to `resetDB`'s TRUNCATE list.

## Verification

- `make api-fmt && make api-vet`; `go test ./...` with `TEST_DATABASE_URL` set.
- `make flutter-build-models`, `make flutter-gen-l10n`, `make flutter-analyze`,
  `make flutter-test` — all clean, generated files committed.
- Local stack (`make docker-dev`): restart the API container twice and confirm one `gap` row
  per restart with the expected cause; backfill 90 days of synthetic samples into the dev DB
  and confirm the strip fills, and that flipping a few hours of `db_ok` to false moves exactly
  the API and Database strips for exactly those days.
- Browser pass on the Health tab, desktop and 360 px, light and dark.
