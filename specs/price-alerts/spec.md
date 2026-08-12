# Spec: Price Alerts

> **STATUS: REMOVED 2026-08.** Feature deleted (never watched a real fare on
> prod: paused under the SerpApi swap, test-mode Duffel before that, never
> used). Code resurrectable from git @ 8ca59c5. The notification center it
> spawned (v2) lives on with other writers.

> Watch a flight route; get told when the fare drops.

## Context

Flight prices move constantly, and travelers who aren't ready to book today
have no reason to come back tomorrow — unless the product watches the fare for
them. Price alerts are the named "power traveler" anchor feature in the
business model (`docs/business-model.md` §4): they create a recurring reason
to return, an owned notification channel (email), and a future paid-tier gate.
They ship free and uncapped-by-payment now; only a per-user sanity cap bounds
cost.

## User Stories

- As a **traveler who searched a route**, I want to **watch it with one tap**
  so that **I don't have to re-search every day to catch a deal**.
- As a **budget traveler**, I want to **set a target price** so that **I'm
  only pinged when the fare is actually worth acting on**.
- As a **flexible traveler**, I want **"tell me on any real drop"** so that
  **I can decide myself when it's cheap enough**.
- As an **alert owner**, I want to **see, pause, resume, and delete my
  alerts** so that **I stay in control of what emails me**.

## Acceptance Criteria

- [ ] A signed-in user who has just searched flights can create an alert for
      that route/date without re-entering anything.
- [ ] An alert is either **target mode** (notify at or below a price) or
      **any-drop mode** (notify on a meaningful drop — at least 5% *and* $5
      below the last known price).
- [ ] The system checks active alerts periodically (roughly every 6 hours per
      alert) and emails the owner when the trigger condition is met, with the
      route, dates, current best price, and a link back to the app.
- [ ] The same price never produces two emails; after notifying, only a
      further drop re-notifies.
- [ ] Alerts whose departure date has passed stop being checked and show as
      expired.
- [ ] The user can list their alerts with current state (watching / price
      dropped / paused / expired, last checked price and time), pause/resume,
      and delete them.
- [ ] A user can hold at most 10 active alerts (11th is rejected with a clear
      message) and cannot create an exact duplicate of an active alert.
- [ ] Anonymous users cannot create alerts (flight search itself stays open).
- [ ] With email delivery unconfigured, triggered notifications appear in the
      server log instead (same degraded convention as verification email).
- [ ] Alert creation and every triggered notification are recorded as
      analytics events; the admin metrics endpoint reports both counts.

## API Surface

### `POST /api/v1/alerts` (auth, strict rate tier)
- **Purpose:** create an alert.
- **Request:** `origin`/`destination` (IATA codes), `depart_date`
  (YYYY-MM-DD, today or later), optional `return_date`, optional
  `cabin_class` (default economy), optional `adults` (default 1), optional
  `target_price` (absent = any-drop mode), optional `current_price` +
  `currency` (the search result the user is looking at — becomes the initial
  baseline), optional `trip_id`.
- **Response:** the created alert (all fields below).
- **Errors:** 422 invalid fields or 11th active alert; 409 duplicate active
  alert; 401 unauthenticated; 503 database unavailable.

### `GET /api/v1/alerts` (auth)
- **Purpose:** list the caller's alerts, newest first.
- **Response:** array of alerts: route, dates, cabin, adults, mode
  (target price or any-drop), currency, last checked price/time, last
  notified price/time, status (`active`/`paused`/`expired`), created time.

### `PATCH /api/v1/alerts/{id}` (auth)
- **Purpose:** pause/resume (`status`) and/or change `target_price`.
- **Errors:** 404 not the caller's alert; 400 invalid status/target.

### `DELETE /api/v1/alerts/{id}` (auth)
- **Purpose:** remove the alert. 204 on success, 404 if not the caller's.

## Data Model

**Price alert** — who watches what, and the watch state: owner; optional trip
link; route (origin/destination); depart and optional return date; cabin
class and adult count; optional target price; currency (set from the first
observed offer); last checked price/time; last notified price/time (the
idempotency anchor — never re-notify at or above it); status
(active/paused/expired). Deleting the owner deletes their alerts.

## Out of Scope (v1)

- Child passengers on the watched search (adults only).
- Date *ranges* / flexible-date watching (single depart date).
- In-app/push notification channels (email + in-app list state only).
- Per-notification read/unread tracking.
- Paid-tier gating (the 10-alert cap is a cost bound, not a paywall).
- Multi-instance coordination of the checker (single process assumed).

## Risks / Notes

- **Fares are ephemeral quotes.** Each check is a fresh search; the cheapest
  offer naturally jitters between runs. The 5%+$5 any-drop threshold, the
  target mode as primary UX, and email copy ("prices change frequently")
  absorb this. Offer IDs expire in minutes and are deliberately not tracked.
- **Every check is a billable provider search.** Bounded by the 6h per-alert
  cadence, a per-cycle batch cap, per-cycle route dedupe (N users watching
  the same route cost one search), and the 10-alert user cap.
- Test-mode flight credentials return synthetic prices; alerts "work" in
  staging but the numbers are fake.
