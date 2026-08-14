# Plan: Clear Notifications

> **HOW.** Translates `spec.md` into a file-level technical approach. Every
> decision should trace back to an acceptance criterion. See `../../CLAUDE.md`
> for repo conventions referenced below — don't restate them, point to them.

## Technical Approach

Hard delete, no migration: the `notifications` table already carries everything
retention needs (`read_at`, `created_at`), so the feature is two new sqlc
queries, one handler, one route, one janitor line, and a screen-level UI. The
delete model mirrors the existing read model — `MarkNotificationsRead` is
mark-*all*, so `DeleteNotificationsByUser` is clear-*all* — and the retention
prune joins the janitor's existing prune list as its fourth entry.

**Decision record (a) — 204 on zero rows.** `deleteChatSessionHandler` 404s on
zero rows because the caller named a specific resource that must exist and be
theirs. Clear-all names no resource: ownership is structural (`WHERE user_id =
$1` can only touch the caller's rows) and an empty feed is a valid pre-state,
so the handler returns idempotent `204` exactly like mark-all-read. This
diverges from the zen "a mutating result echoes post-state" preference with
rationale: the response is a fixed 204 and the client *observes* post-state by
refetching list + unread-count via provider invalidation — the same contract
the sibling mark-read endpoint already has.

**Decision record (b) — prune predicate and no index.** The prune deletes
`read_at IS NOT NULL AND read_at < now() - interval '45 days'` — the clock
starts when the row was *seen*, so "unread never expires" is structural
(`IS NOT NULL`), not conventional. Neither existing index
(`(user_id, created_at DESC)`; partial unread) covers a `read_at` range scan,
and a supporting partial index would need a migration this feature
deliberately avoids. The hourly seq scan is fine at current scale (per-user
feeds capped at 200, small tenancy); precedent is `DeleteOldHealthSamples`,
also an unindexed interval scan. Revisit only if the table reaches millions of
rows.

## Go API Changes

`src/packages/api/`:

- **Queries** (`query/notifications.sql`): append `DeleteNotificationsByUser`
  (`:execrows`, `WHERE user_id = $1`) and `DeleteOldReadNotifications`
  (`:exec`, the retention predicate above), each with a rationale comment.
  Regenerate `store/` via `make api-sqlc` — never hand-edit.
- **Handler** (`notifications_handler.go`): `clearNotificationsHandler`, exact
  shape of `markNotificationsReadHandler` (nil-pool → 503 "database
  unavailable"; `userFromContext`; store call; error → 500 "could not clear
  notifications"; else 204). Header comment updated — the file now reads,
  marks, and clears.
- **Route** (`main.go`): `DELETE /notifications` behind `authMiddleware`,
  registered beside its three siblings; comment block extended. No dedicated
  rate bucket — a dialog-confirmed user action sits fine behind the global
  `generalLimiter`, same as the siblings.
- **Janitor** (`janitor.go`): fourth prune in `janitorTick`, identical
  warn/debug shape to `DeleteOldHealthSamples`; fix the stale "runs both
  prunes" doc comment.
- **Types:** none — 204/empty body; errors use the existing `Response` shape
  via `writeJSONError`.

## Flutter Changes

`src/packages/flutter-app/lib/`:

- **Models:** none (no new payloads).
- **Service** (`services/notifications_api_service.dart`): `clearAll()` —
  `DELETE /notifications` via `apiClient.httpClient.delete` + `jsonHeaders()`,
  expect 204 else throw `_errorMessage(...)` (mirror of
  `chats_api_service.dart` `dismissChat`).
- **Provider** (`providers/notifications_provider.dart`): unchanged — the
  screen calls the service and invalidates `notificationsProvider` +
  `notificationsUnreadCountProvider`, the same pair `_markRead` invalidates.
- **Screen** (`screens/notification_center_screen.dart`):
  - App-bar ⋮ `PopupMenuButton` (structure from `trip_detail_screen.dart`'s
    overflow menu — the destructive-actions-live-behind-⋮ convention) with one
    error-colored "Clear all" item. **Visibility rule:** rendered iff
    `notifs.valueOrNull?.isNotEmpty ?? false` — hidden on loading/error/empty.
  - `_clearAll()`: confirm dialog (`AlertDialog`, cancel `TextButton` +
    error-colored `FilledButton`, clone of the trip-delete dialog); on
    confirm, `clearAll()`; on failure `showSnack` with
    `notifClearAllFailed(friendlyError(...))` and **no invalidation** (the
    feed must not show a false empty state); on success invalidate both
    providers.
- **l10n** (`l10n/app_en.arb` + `app_es.arb`, then `make flutter-gen-l10n`):
  `notifMoreActions`, `notifClearAll`, `notifClearAllTitle`,
  `notifClearAllBody`, `notifClearAllFailed` (placeholder `error`; EN carries
  the `@`-metadata, ES stays flat). `notifMoreActions` is deliberately not a
  reuse of `tripMoreActions` — no cross-domain key dependency.

## Contract Parity  ← anti-drift gate

No new JSON payloads cross the boundary (204/empty body both ways). Parity is
route ↔ caller ↔ status handling:

| Surface | Server | Client | ✓ |
|---------|--------|--------|---|
| Route | `DELETE /api/v1/notifications` (auth) | `clearAll()` → `DELETE $base/notifications` | ☐ |
| Success | `204 No Content`, incl. empty feed | `!= 204` throws; post-state via refetch | ☐ |
| Error body | `{"message": …}` (`writeJSONError`) | `_errorMessage` reads `message` | ☐ |
| Post-state | list `[]`, unread-count `0` | invalidate feed + badge providers | ☐ |

## Cross-cutting

- **Env vars:** none.
- **Gateway:** `/api/v1/notifications` already proxies; DELETE needs no extra
  nginx config.
- **Migrations:** none — deliberately (00058 was contested at the time and has
  since been permanently burned; see `docs/parallel-dev.md` §4a).

## Verification

(Mirror into `tasks.md` as the final tasks.)

- `make api-fmt && make api-vet` — clean; `make api-sqlc` diff confined to
  `store/notifications.sql.go`.
- `make test-db` then `make api-test-go` — `TestNotificationsClearAll` and
  `TestJanitorPrunesOldReadNotifications` run (not skipped) and pass.
- `make flutter-gen-l10n` — regen committed; EN/ES key parity (CI-enforced).
- `make flutter-analyze` — no NEW findings (3 pre-existing infos in
  `models/route_response.dart` are known-red vs CI; do not fix).
- `make flutter-test` — new notification-center tests + existing suite green.
- Manual e2e on this lane's stack (`make docker-dev-bg`, gateway :3007): seed
  a notification, walk every acceptance criterion in `spec.md`.
- `curl -X DELETE http://localhost:3007/api/v1/notifications -H "Authorization: Bearer <token>"`
  → 204; repeat → 204; `GET /api/v1/notifications` → `[]`.
