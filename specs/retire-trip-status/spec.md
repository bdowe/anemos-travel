# Spec: Retire trip Draft/Planned status

## Context

Every trip carried a manual two-value lifecycle label — **draft** (the default
on all creation paths) and **planned** — changeable only through a small
dropdown in the trip header. The label was specified as display-only
(specs/trip-model), but three behaviors quietly grew on top of it: departure
reminder emails fired only for `planned` trips, the weekly re-engagement nudge
used "has a draft trip" as its unfinished-work signal, and Trip Health skipped
the missing-lodging check for accommodation-less drafts. Because nothing ever
promoted a trip automatically and the dropdown never explained what flipping
it did, essentially every trip stayed `draft` forever — departure reminders
were dead code, and the nudge signal carried no information (and kept nudging
users whose only trips were long past). This is the anti-pattern docs/zen.md
exists to prevent: meaning living in a convention someone must remember.

The status concept is retired outright — column, API field, and UI — and each
consumer derives its signal from state that already means something.

## Decision Record

- **Remove, don't automate.** Auto-promoting draft→planned on dates-set was
  rejected: the pill would merely echo the date chip beside it, and stored
  derived state invites drift. A future completed/archived state, if ever
  wanted, is better modeled as an `archived_at` timestamp (the free-cap spec
  already anticipates archived lineages leaving the count).
- **D1 — Departure reminders: dated is enough.** A trip with a departure date
  in the reminder window gets the reminder; no content guard. Every creation
  path creates trips with items, so an empty dated shell is a rare
  hand-emptied edge and "your trip starts in 3 days" is still true for it.
- **D2 — Weekly nudge "unfinished work" is derived**: an undated trip (latest
  version of its lineage), OR an upcoming trip (departing today or later,
  latest version) with at least one unbooked booking todo, OR a resumable plan
  chat (unchanged). This deliberately narrows the audience: users whose only
  trips are in the past stop being nudged weekly forever.
- **D3 — Lodging health check**: gated by dates alone. An undated trip is
  skipped; a dated trip without lodging is exactly what the check flags.
- **D4 — The shared status pill widget** survives only as its explicit-label
  variant (Live, Past-trips count, Today, packing/review counts, alerts…);
  the draft/planned rendering is gone.
- **D5 — Stale clients: accepted, no shim.** The API neither accepts nor
  emits `status`. A PATCH body that still sends it is tolerated (unknown JSON
  keys are ignored) and pinned by a test; old cached web bundles requiring
  the field in trip responses error on trips screens until reload. Serving a
  vestigial `"status":"draft"` was rejected — it would render a wrong pill on
  every formerly-planned trip.

## Acceptance Criteria

- [ ] The trip header shows no status pill or status menu; the trips list and
      home recent-trip tile show no status label.
- [ ] `PATCH /api/v1/trips/{id}` with `{"status": ...}` still succeeds (the
      key is ignored) and no trip response contains a `status` field.
- [ ] A dated trip with no stays yields the missing-lodging Trip Health
      finding regardless of any former status.
- [ ] A dated trip departing in 3 days / today produces the trip_soon /
      trip_today reminder for its owner, without any manual step.
- [ ] An idle user with an undated trip, or an upcoming trip with unbooked
      booking todos, or a resumable chat, qualifies for the weekly nudge; an
      idle user whose only trips are past does not.

## Rollout Notes

- The reminder gate flip cannot burst: the query matches departure dates
  exactly (today / today+3), the reminder ledger (user, lineage, kind) dedups
  before send, and each tick is capped. A trip departing 1–2 days after
  deploy silently misses trip_soon (window already passed) and still gets
  trip_today.
- Weekly-nudge volume in admin metrics drops — intended narrowing.
- The down-migration restores only the column shape; all rows return as
  `'draft'` (the labels were cosmetic and are unrecoverable).
- MCP `list_trips` output loses its `status` field (tolerated by connector
  clients, which re-fetch tool schemas per session).
