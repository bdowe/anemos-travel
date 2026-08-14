# Tasks: Uptime History

> Dependency-ordered, split into the two PRs of one lane (`uptime-history`).
> `[P]` = parallelizable with its siblings.

## PR A — server

- [ ] `migrations/00059_health_samples.sql` (up + down, CHECK constraints binding columns to `kind`)
- [ ] `query/ops_uptime.sql`: insert, windowed read with anchor, last, earliest, prune
- [ ] `make api-sqlc`, commit `store/`
- [ ] `ops_monitor.go`: `insertSample` seam, `lastSampleAt`, `release`, bounded retry buffer
- [ ] `ops_monitor.go`: `bootstrapSamples` writes the boot gap (`deploy` vs `unknown`)
- [ ] `ops_monitor.go`: `runOnce` writes a tick sample every tick, with the stall cap
- [ ] `ops_uptime.go`: response types + pure `rollupUptime`
- [ ] `ops_uptime.go`: `opsUptimeHandler` (admin, 503 without DB, `days` cap 90)
- [ ] `main.go`: route registration + startup log line
- [ ] `janitor.go`: `DeleteOldHealthSamples` in `janitorTick`
- [ ] `integration_test.go`: `health_samples` in the `resetDB` TRUNCATE list
- [ ] `ops_uptime_test.go` (pure): green day · db outage · deploy gap · unexplained gap ·
      midnight split · sampler stall · backups isolation · empty table · partial today ·
      cadence change mid-window
- [ ] `ops_monitor_test.go`: boot gap cause, retry buffer flush keeps original timestamp,
      buffer cap drops oldest, sample writes don't perturb transition alerts
- [ ] `admin_integration_test.go` (or sibling): `TestOpsUptimeEndpoint` — 401 / 403 / 200 + shape
- [ ] `CLAUDE.md` Key Constraints bullet + endpoint table row
- [ ] `make api-fmt`, `make api-vet`, `go test ./...` green → `ship pr`

## PR B — Flutter

- [ ] `models/ops_uptime.dart` + `make flutter-build-models`
- [ ] Complete the Contract Parity table in `plan.md` (every row ✓)
- [ ] [P] `services/ops_admin_api_service.dart`: `getOpsUptime`
- [ ] [P] `providers/ops_admin_provider.dart`: `opsUptimeProvider` (off the 10 s timer)
- [ ] [P] `theme/app_colors.dart`: `upMark` / `degradedMark` / `downMark`
- [ ] `widgets/uptime_strip.dart`: painter, scrub + keyboard + semantics, caption trio
- [ ] `widgets/health_pane.dart`: `_UptimeSection` first, four component rows, self-check
      disclosure, `healthUptime` → `healthProcessUptime`, uptime off the 10 s refresh
- [ ] `l10n/app_en.arb` + `l10n/app_es.arb` keys, then `make flutter-gen-l10n` (regen LAST)
- [ ] `test/health_pane_test.dart`: provider override in `_wrap`, fix the ambiguous
      `find.text('Uptime')`
- [ ] `test/health_uptime_test.dart`: happy path · no-history · outage day tap · keyboard ·
      loading · error isolates · dark theme · 360 px + `es` · not on the 10 s timer
- [ ] `test/ops_uptime_model_test.dart`: dense expansion, `no_data` vs `0 %`, JSON parity
- [ ] `make flutter-analyze`, `make flutter-test` green

## Verification

- [ ] Restart the API container twice → exactly one `gap` row per restart, correct cause
- [ ] Backfill 90 synthetic days locally → strip fills; flipping `db_ok` for a few hours moves
      only the API + Database strips, only on those days
- [ ] Backups-stale day leaves the API strip at 100 %
- [ ] Browser pass: Health tab at desktop + 360 px, light + dark, scrub updates the caption,
      no horizontal overflow, "Process uptime" vs "Uptime" unambiguous
- [ ] `ship pr` for PR B
