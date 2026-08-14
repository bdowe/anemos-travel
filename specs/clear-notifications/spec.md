# Spec: Clear Notifications

> **WHAT & WHY only.** No tech choices, file names, libraries, or code. If a
> sentence names a file or a package, it belongs in `plan.md`, not here.

## Context

Notifications accumulate forever: the product can list them, mark them read,
and count unread — but nothing can ever remove one. For an admin the feed is
dominated by repeated "System degraded" alerts (one per monitored state change
*and* per deploy restart), so the center becomes a wall of stale rows that
crowds out real notifications and cannot be reset. This feature adds the
missing removal half of the notification lifecycle: an explicit, user-initiated
"Clear all", plus a server-side retention policy so read history eventually
expires on its own.

## User Stories

- As a **signed-in user**, I want to **clear all my notifications at once** so
  that a backlog of stale rows doesn't bury new, relevant ones.
- As an **admin**, I want the **wall of repeated ops alerts to be dismissible
  and self-expiring** so that the notification center stays useful as a feed
  rather than a permanent log.
- As a **user**, I want **unread notifications to never disappear on their
  own** so that I can trust nothing was removed before I saw it.

## Acceptance Criteria

- [ ] With at least one notification in the feed, the notification center
      offers a "Clear all" action; it is not shown while the feed is loading,
      failed to load, or is already empty.
- [ ] Choosing "Clear all" asks for confirmation before anything is deleted;
      cancelling leaves the feed untouched.
- [ ] Confirming removes every notification belonging to the signed-in user:
      the feed shows its empty state, the unread badge is 0, and a reload/
      re-login shows the feed still empty (deletion is server-side, not
      cosmetic).
- [ ] Clearing one user's notifications never affects another user's.
- [ ] Clearing an already-empty feed (e.g. two devices racing) succeeds
      quietly rather than erroring.
- [ ] If the clear fails (offline, server error), the user sees an error
      message and the feed still shows its rows — never a false empty state.
- [ ] Notifications the user has already read are removed automatically about
      45 days after they were read. Unread notifications are never removed
      automatically, no matter how old.
- [ ] The action and dialog are fully localized (English and Spanish).

## API Surface

### `DELETE /api/v1/notifications`
- **Purpose:** delete every notification belonging to the authenticated
  caller ("Clear all").
- **Request:** no body, no parameters. The affected user is always the
  session's user — the caller cannot name a different scope.
- **Response:** `204 No Content`, including when the feed was already empty
  (idempotent, mirroring the mark-all-read sibling). Post-state is observed by
  re-fetching the list (empty array) and the unread count (0).
- **Errors:** `401` when unauthenticated; `503` when the database is
  unavailable (degraded mode); `500` with a generic message on database
  failure.

**Retention policy (server-side, no endpoint):** an hourly background prune
deletes notifications that were read more than 45 days ago. The clock starts
at the moment the notification was read, not when it was created, so the
guarantee is expressible to a user: "anything you've seen sticks around about
six more weeks; anything you haven't seen stays until you see it or clear it."

## Data Model

- No new entities and no schema change. **Retention becomes an explicit
  policy** on the existing notification record: rows are hard-deleted (a
  notification is an ephemeral signal, not a record of account activity),
  either wholesale by their owner or individually by age-after-read.

## UI Behavior

- **Screen / surface:** the notification center (account menu → Notifications).
- **Happy path:** open the center → overflow (⋮) menu in the app bar →
  "Clear all" (styled as destructive) → confirmation dialog ("Clear all
  notifications?" / cancel · delete) → feed switches to its empty state; the
  ⋮ menu disappears with it.
- **States:** loading/error/empty — no ⋮ menu (nothing clearable). Non-empty —
  ⋮ menu present. Clear failure — snackbar with the reason; rows remain.

## Edge Cases & Error States

- Opening the center already marks everything read; clearing is independent of
  read state and also removes rows that arrived (still unread) mid-session —
  the dialog copy says so explicitly.
- A notification created between the delete and the refetch appears in the
  refreshed feed: correct — it was never cleared.
- Admin ops alerts regenerate on the next monitored state change or deploy.
  Clearing empties history; it does not mute the monitor. (Muting is out of
  scope.)
- Clearing removes the row the collaborator-edit throttle checks for, so a
  collaborator's next edit inside the 6-hour window may re-notify. Accepted:
  after an explicit clear, a fresh notification beats silence.
- The first prune after this ships will remove read rows older than 45 days
  from the historical backlog (including migrated price-drop history). That is
  the policy applying retroactively, not data loss.

## Out of Scope

- Per-notification dismissal (swipe or ✕) — clear-all only, by decision.
- Undo after clearing.
- Soft delete / archive / trash.
- Muting, deduplicating, or rate-limiting the ops-alert stream itself.
- Any change to when notifications are *written*.

## Open Questions

None — scope (clear-all only + 45-day read-row retention, hard delete) was
decided with the product owner on 2026-08-13.
