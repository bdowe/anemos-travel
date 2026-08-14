# Tasks: Clear Notifications

> Dependency-ordered. `[P]` = can run in parallel with its siblings (no shared
> files / no ordering dependency). Work top to bottom; verification is last.

## API (Go)

- [ ] Append `DeleteNotificationsByUser` (`:execrows`) and
      `DeleteOldReadNotifications` (`:exec`) to `query/notifications.sql`
      with rationale comments
- [ ] `make api-sqlc` — regenerate `store/` (commit the regen)
- [ ] `clearNotificationsHandler` in `notifications_handler.go` (+ header
      comment update)
- [ ] Register `DELETE /notifications` in `main.go` (+ comment block update)
- [ ] Fourth prune in `janitorTick` (+ fix stale "both prunes" comment)
- [ ] Integration tests: `readNotificationAgo` helper,
      `TestNotificationsClearAll` (isolation, idempotency, 401),
      `TestJanitorPrunesOldReadNotifications` (calls `janitorTick` directly;
      unread-never-expires pinned)

## Models & codegen (Flutter)

- [ ] No new models — confirm Contract Parity table in `plan.md` (every row ✓)

## UI (Flutter)

- [ ] [P] `clearAll()` in `services/notifications_api_service.dart`
- [ ] [P] Five l10n keys in `app_en.arb` + `app_es.arb`; `make flutter-gen-l10n`
- [ ] App-bar ⋮ menu (visibility: loaded ∧ non-empty) + confirm dialog +
      `_clearAll()` in `notification_center_screen.dart`
- [ ] Widget tests: ⋮ hidden on empty / present with rows; menu → dialog;
      cancel = no call, rows survive; confirm = cleared + empty state + ⋮
      gone; failure = snackbar, rows intact

## Verification

- [ ] `make api-fmt && make api-vet` clean
- [ ] `make test-db` + `make api-test-go` — new tests run (not skipped), pass
- [ ] `make flutter-analyze` — no NEW findings
- [ ] `make flutter-test` pass
- [ ] Manual end-to-end via this lane's gateway (`make docker-dev-bg` →
      `http://localhost:3007`): every acceptance criterion in `spec.md`
      checked off
- [ ] `ship pr` — stop at PR-open (integrator merges)
