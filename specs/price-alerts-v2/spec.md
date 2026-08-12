# Spec: Price Alerts v2 — Notification Center & Flexible Dates

> **STATUS: PARTIALLY REMOVED 2026-08.** The alert/flex-dates surface was
> deleted with v1 (resurrectable from git @ 8ca59c5). The generalized
> notification center this spec introduced SURVIVES — trip reminders, collab
> activity and ops rows still write to it, and it moved to a first-class
> "Notifications" account-menu item.

> Every price drop becomes a durable in-app notification, and an alert can
> watch a small window of dates instead of exactly one.

## Context

Price alerts v1 (specs/price-alerts) notifies by email only. The only
persisted trace of a drop is a scalar pair on the alert (last notified
price/time), so the app itself has no memory of what happened: a user who
misses or deletes the email has nothing to return to, there is no badge
pulling them back into the product, and two drops on the same alert
overwrite each other. This wave gives every triggered notification a durable
per-event record with read/unread state, surfaces it in an in-app
notification center, and adds the most-requested watch upgrade: flexible
departure dates (± up to 3 days), so travelers who can shift a day or two
stop creating near-duplicate alerts by hand.

Shipped in three parts: the event model + read API (PR 1), the Flutter
notification center (PR 2), flexible dates (PR 3).

## User Stories

- As an **alert owner**, I want **every price drop kept in the app**, so
  that **I can review past drops even if I missed the email**.
- As a **returning user**, I want **a badge showing how many drops I haven't
  seen**, so that **I know something happened since my last visit**.
- As a **notification reader**, I want **each entry to show the route, dates,
  new price, and what it dropped from**, so that **I can judge the deal
  without opening anything else**.
- As a **flexible traveler**, I want **one alert to watch my departure date
  ± a few days**, so that **I catch the cheap day without managing seven
  alerts**.

## Acceptance Criteria

### Alert events (PR 1)

- [ ] When an alert triggers (the same moment v1 sends the email), a
      notification event is recorded with the observed price, its currency,
      and the reference price the drop was judged against.
- [ ] The email and the event never disagree: one trigger produces exactly
      one email and one event with the same numbers; a check that does not
      trigger produces neither; re-checking an unchanged price produces
      neither (v1 idempotency applies to events too).
- [ ] A failure to record the event never blocks or delays checking or the
      email (best-effort, logged).
- [ ] The owner can list their events newest-first; each entry carries the
      alert's route, departure/return dates, target price (if any), and the
      alert's current status, with no follow-up request needed.
- [ ] The owner can see an unread count and mark **all** their events read
      in one action; the count then reads zero and listed events show when
      they were read.
- [ ] Events are private to their owner: another signed-in user sees none of
      them and cannot affect their read state.
- [ ] Deleting an alert removes its events; deleting the account removes all
      of the user's events.
- [ ] Alerts expose the price the watch started from (the baseline), so a
      client can render "was X, now Y" deltas.

### Notification center (PR 2)

- [ ] A bell (or equivalent) surface in the app shows the unread count badge
      and opens the notification list.
- [ ] Opening the list marks all events read (mark-all is the v1 read model
      — see Decisions).
- [ ] Each row shows route, dates, new price, previous/reference price, and
      how long ago the drop happened; tapping a row lands on the alert (or
      its flight search).
- [ ] Empty state explains that drops on watched routes will appear here.

### Flexible dates (PR 3)

- [ ] When creating an alert, the user can choose date flexibility of 0–3
      days around the departure date (0 = exact, the default; existing
      alerts behave as 0).
- [ ] A flexible alert triggers when the trigger condition is met on **any**
      date in the window, and the notification (email and event) says which
      departure date the price was found for.
- [ ] Flexibility is capped at ±3 days; larger values are rejected with a
      clear message.
- [ ] Provider cost stays bounded: a flexible alert may not multiply search
      volume past the existing per-cycle caps (a wider window means the
      alert consumes more of the per-cycle budget, not a bigger budget).

## API Surface

### `GET /api/v1/alerts/events?limit=` (auth)
- **Purpose:** the notification feed, newest first.
- **Request:** optional `limit` (default 50, capped at 200).
- **Response:** array of events: id, alert id, price, currency, optional
  previous (reference) price, occurred time, optional read time, and the
  joined alert context — origin, destination, depart date, optional return
  date, optional target price, alert status.
- **Errors:** 401 unauthenticated; 503 database unavailable.

### `POST /api/v1/alerts/events/read` (auth)
- **Purpose:** mark all of the caller's events read. Returns 204.
- **Errors:** 401 unauthenticated; 503 database unavailable.

### `GET /api/v1/alerts/events/unread-count` (auth)
- **Purpose:** the badge number. Returns `{"count": N}`.
- **Errors:** 401 unauthenticated; 503 database unavailable.

### Changed: alert responses
- Alert objects now also expose `baseline_price` — the watch's starting
  reference price (null until seeded by creation or first check).

### Changed (PR 3): `POST /api/v1/alerts`
- Accepts optional `flex_days` (0–3, default 0); alert responses echo it.

## Data Model

- **Alert event** — one triggered notification: which alert and owner (the
  owner is recorded directly on the event so feed reads are cheap — and the
  event dies with either); the observed price and currency; the optional
  reference price the drop was judged against (absent when a target-mode
  alert triggers on its very first observation); when it occurred; when it
  was read (unset = unread).
- **Price alert (PR 3)** — gains a flexibility-in-days field (0–3).

## UI Behavior (PR 2)

- **Surface:** a bell icon with an unread badge in the app shell, visible to
  signed-in users; opens the notification center list.
- **Happy path:** drop happens → badge increments (unread-count polled on
  app resume/navigation) → user opens list → rows render newest-first with
  route, dates, price and delta → open marks all read → badge clears.
- **States:** loading spinner; empty state ("price drops on routes you watch
  will show up here"); error state with retry; read rows visually muted.

## Edge Cases & Error States

- Event insert fails (constraint, outage): logged, email still sends, check
  loop continues — the feed misses one entry rather than the user missing
  the notification entirely.
- Alert deleted after events were written: its events disappear from the
  feed (cascade). Acceptable: the feed is a notification surface, not an
  audit log.
- Two drops in quick succession on one alert: two events, both listed;
  ordering ties broken deterministically.
- `limit` absent, zero, negative, or non-numeric → default 50; above the cap
  → capped at 200.
- Mark-all-read with nothing unread: still 204 (idempotent).
- Degraded mode (no database): all three endpoints answer 503, matching the
  rest of the alerts surface.

## Decisions

- **Mark-all-read, not per-event.** Opening the center is the read action —
  one call, no row bookkeeping, matches how the badge is actually used. A
  per-event variant can be added later without changing the model
  (`read_at` is already per-row).
- **Denormalized owner on the event**, mirroring the analytics-events
  convention: per-user feed and badge queries stay single-table.
- **No new notification channels.** Events power the in-app center; email
  remains the push channel.

## Out of Scope

- Push/web-push notifications.
- Per-event read toggling, deleting or muting individual events.
- Event types other than price drops (this is the spine such types could
  later share, but only `alert triggered` is written).
- Flexible **return** dates and flexibility > ±3 days.
- Retention/pruning of old events (revisit if feeds grow past usefulness).

## Open Questions

- None. (Resolved during spec: read model = mark-all; flex cap = ±3 days;
  events cascade with their alert rather than being orphan-preserved.)
