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

**Amended 2026-08-22 — per-notification dismissal is now in scope.** The
original decision was clear-all only. In use that made the feed all-or-nothing:
the only way to remove one stale row was to destroy every other row with it,
including unread ones the traveler had not acted on yet. Wholesale deletion is
the wrong price for tidying, so each row now carries its own ✕. Clear-all keeps
its confirmation dialog and stays the way to empty the feed.

## User Stories

- As a **signed-in user**, I want to **clear all my notifications at once** so
  that a backlog of stale rows doesn't bury new, relevant ones.
- As an **admin**, I want the **wall of repeated ops alerts to be dismissible
  and self-expiring** so that the notification center stays useful as a feed
  rather than a permanent log.
- As a **user**, I want **unread notifications to never disappear on their
  own** so that I can trust nothing was removed before I saw it.
- As a **signed-in user**, I want to **remove one notification I'm done with**
  so that tidying the feed doesn't cost me every other notification in it.

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

Per-notification dismissal (amended):

- [ ] Every row in the feed offers a dismiss control, in both the popover and
      the full-page presentation, visible without hovering.
- [ ] Dismissing asks for no confirmation, and removes only that row —
      server-side, so a reload still shows it gone.
- [ ] Dismissing an unread row lowers the unread badge by one.
- [ ] A notification that is not the caller's cannot be dismissed, and the
      refusal is indistinguishable from one for an id that does not exist, so
      the response cannot be used to discover other users' notification ids.
- [ ] Dismissing the same row twice reports that there was nothing to dismiss
      the second time — unlike clear-all, this names a resource.
- [ ] If a dismiss fails (offline, server error), the row stays in the feed
      and the user sees why — never a row that looks dismissed but was not.
- [ ] Dismissing the last row leaves the feed in its empty state, with the
      clear-all action gone.

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

### `DELETE /api/v1/notifications/{id}`
- **Purpose:** dismiss one notification (amended 2026-08-22).
- **Request:** the notification's id in the path; no body. Ownership is not a
  parameter — the row must belong to the session's user.
- **Response:** `204 No Content`.
- **Errors:** `404` when the id names nothing the caller owns — which covers a
  bad id, an already-dismissed row, and another user's row **with the same
  response**, so existence cannot be probed. `401` when unauthenticated;
  `503`/`500` as the sibling endpoints.
- **Deliberately not idempotent**, unlike clear-all: this call names a
  resource, so a repeat finds nothing to delete and says so.

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
- **Dismissing one (amended):** every row carries a trailing ✕ — always
  visible, not hover-revealed, because the same row renders in the popover and
  on the narrow page where hover does not exist. Tapping it removes that row
  with no dialog; the control shows progress while the server is asked, and on
  failure the row stays put under a snackbar saying why.

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

- Swipe-to-dismiss. The ✕ serves both presentations; swipe would be a second
  idiom for the same act and only on one of them.
- Undo, after clearing or after dismissing one.
- Soft delete / archive / trash.
- Muting, deduplicating, or rate-limiting the ops-alert stream itself.
- Any change to when notifications are *written*.

## Open Questions

None. Original scope (clear-all only + 45-day read-row retention, hard delete)
was decided with the product owner on 2026-08-13; per-notification dismissal
was added at their request on 2026-08-22, superseding that one exclusion.
