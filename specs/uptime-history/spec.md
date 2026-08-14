# Spec: Uptime History

## Context

The admin Health panel reports only what the *current* API process remembers: request
counters, memory, goroutines, and an "Uptime" figure that is time-since-last-restart.
Production recreates the API container on every push to main — 6–12 times a day — so that
memory is a few hours deep at best, and the degraded/recovered verdict the self-check
computes every five minutes is thrown away the moment it stops changing. There is no way to
answer "has this thing been healthy this month?", and no external monitor is wired up
anywhere. This feature keeps a durable record of what the self-check observes and renders it
as a status-page-style 90-day strip — one colored bar per day, per component — so an operator
can see the shape of the service's health over time instead of over the last few hours.

## User Stories

- As an **admin**, I want to see 90 days of availability at a glance so that I can tell
  whether today's problem is new or chronic.
- As an **admin**, I want each dependency (database, AI provider, backups) to have its own
  history so that a stale backup never looks like an outage of the app.
- As an **admin**, I want to inspect a single day so that I can see how much of it was
  unhealthy and why.
- As an **admin**, I want the panel to tell me plainly what this measurement can and cannot
  see, so that I don't mistake a green bar for proof the site was reachable.

## Acceptance Criteria

- [ ] The Health panel shows an **Uptime** section above the process tiles with one bar strip
      per component: API, Database, AI provider, Backups.
- [ ] Each strip renders exactly 90 day-bars, oldest at the left, today at the right, with a
      caption reading "90 days ago … *N* % uptime … Today".
- [ ] A day with no recorded observations renders in a recessive grey that cannot be mistaken
      for an outage, and contributes to no percentage.
- [ ] Before any history exists, the section renders 90 grey bars and says when monitoring
      began (or that it hasn't yet) — it never displays an invented 0 % or 100 %.
- [ ] Tapping or scrubbing a strip selects a day; the caption switches to that day's date,
      its uptime percentage, and the reason(s) recorded — and switches back when cleared.
- [ ] A day when the database was unreachable shows as unhealthy on **both** the API and
      Database strips.
- [ ] A day when backups were stale shows as unhealthy on the Backups strip **only**; the API
      strip still reads 100 %.
- [ ] A day when the AI provider was failing shows as unhealthy on the AI provider strip
      only.
- [ ] A normal deploy (the process restarting on a new release) does not reduce any
      component's uptime percentage.
- [ ] An unexplained restart — the process disappearing and returning on the same release —
      counts as downtime on the API strip.
- [ ] The section states, on screen, that this is a self-check that cannot observe gateway or
      edge outages.
- [ ] The history survives API restarts and deploys.
- [ ] The section is available to admins only, and is fully localized in English and Spanish.

## API Surface

### `GET /api/v1/admin/ops/uptime`
- **Purpose:** the per-day availability history the Health panel renders.
- **Request:** `days` (optional, default and maximum 90) — the size of the window, counted
  back from today inclusive, in whole UTC days.
- **Response:** the window (`days`, its first day), the instant monitoring first began (null
  when nothing has ever been recorded), and one entry per component. Each component carries a
  stable key, its current state, its uptime percentage across the window (null when nothing
  was observed), the number of days that carry any observation, and a **dense** list of
  exactly `days` entries — one per calendar day, oldest first. Each day entry carries its
  date, its state (`up`, `degraded`, `down`, or `no_data`), its uptime percentage (null when
  nothing was observed — which is a different value from zero), the seconds attributed to
  healthy, unhealthy, and unobserved, and the stable reason codes recorded that day.
- **Errors:** requires an authenticated admin (401 unauthenticated, 403 non-admin); 503 when
  the database is unavailable, since the history lives there.

## Data Model

- **Health sample** — one observation interval. It states the span it accounts for (from
  when, until when) rather than only the instant it was taken, so the record never depends on
  knowing the sampler's cadence. Two kinds exist:
  - a **tick**, carrying what the self-check saw for each signal it evaluates (database
    reachable, AI provider healthy, backups fresh), which is taken to hold for the interval
    it closes;
  - a **gap**, written when the process starts and finds that time has passed since the last
    recorded observation, carrying whether that absence is explained by a new release
    (a deploy) or unexplained (a crash, a reboot, a host outage).

  Samples are what *this process* observed about itself. An observation made from outside
  the process is a different kind of fact and is not stored here.

- **Component** — a named row in the graph, derived from the samples, never stored: API
  (the process was running and the database was reachable), Database, AI provider, Backups.

- **Day bucket** — a component's seconds for one UTC day, split three ways: healthy,
  unhealthy, and unobserved. Unobserved seconds belong to neither side of the percentage.

## UI Behavior

- **Screen / surface:** the Health tab of the admin Metrics screen, as a new section above
  the existing process tiles.
- **Happy path:** the admin opens the tab, sees four labeled strips with a status pill each,
  reads the window percentage in the caption, and scrubs across a strip to inspect any day.
- **States:**
  - *Loading* — a placeholder of the section's final height, so nothing below it moves when
    the data lands.
  - *No history* — 90 grey bars and a caption naming when monitoring began, or saying it has
    not yet.
  - *Success* — colored bars; the selected day's detail replaces the summary in the caption.
  - *Error* — a compact message with a retry action; the rest of the Health panel still
    renders.

## Edge Cases & Error States

- The database is unreachable when an observation is taken: the observation is held and
  written once the database is back, keeping its original time — so the outage appears as a
  recorded fact rather than as missing data. Held observations are bounded; the oldest are
  dropped once the bound is reached, and a crash while holding them loses them (that time
  then reads as unobserved).
- An observation interval crossing UTC midnight is split across both days.
- The sampler stalls (a paused or wedged host): only the interval it can vouch for is
  credited; the remainder is recorded as unexplained absence.
- The sampling cadence is changed: history stays readable, because every record states its
  own span.
- Days before monitoring began are `no_data`, never 0 %.
- Today is partial: only elapsed time is accounted for.
- History older than the window is pruned in the background.

## Out of Scope

- Any observation made from outside the API process — an external prober or a third-party
  monitor. The API strip is therefore blind to gateway, tunnel, and edge outages, and says so
  on screen.
- Graceful shutdown on SIGTERM (it would shrink the unobserved window around each deploy).
- A public status page; a separate incidents list; deploy markers on the strip; alerting
  changes of any kind.

## Open Questions

None outstanding. Resolved before implementation: the API strip is self-observed and labeled
as such; four component rows; per-day inspection via the caption rather than a separate
incident list.
