# Spec: Itinerary Items Store Calendar Dates

> Stage B of [`specs/trip-dates-truth/`](../trip-dates-truth/spec.md).
> Migration numbers reserved: **00054** (add + backfill), **00055** (drop
> stored day, optional/deferred). Re-verify numbers at execution.

## Context

Item scheduling is stored as positional day integers anchored to the trip's
start date, with departure-day semantics that exist only by convention — the
root enabler of the leg-dates bug class (a writer can "correctly" write day
numbers that mean the wrong dates). This feature makes the calendar date the
stored truth on dated trips, with the day number maintained as a derived
mirror for wire compatibility, dateless drafts, and UI grouping.

## User Stories

- As a **traveler**, I want calendar/print/screen dates to be the same fact
  read three ways, not three computations that can disagree.
- As a **developer/agent**, I want date edits to be edits of dates, with the
  day number derived — never the reverse guessed.

## Acceptance Criteria

- [ ] Every dated trip's items carry a stored calendar date; backfill equals
      start_date + day − 1; currently-inconsistent trips backfill verbatim
      (the leg computation renders them exactly as today).
- [ ] Dateless trips keep day-number authority (item dates uniformly absent);
      the undated→dated transition materializes dates atomically; authority
      is decidable from the trip row alone.
- [ ] One conversion boundary writes BOTH fields on every write path; a
      lone-field write is impossible by construction. Day-number inputs
      (tool schemas, old bundles) keep working forever, converted at the
      boundary with the existing validation.
- [ ] Whole-trip and per-leg date tools shift/write item dates (day mirror
      maintained); the trip-PATCH date change gains the same semantics
      (unify with set_trip_dates: shift stays/segments and re-derive the
      checklist) inside a proper transaction.
- [ ] Calendar exports, print day sections, day sub-headers, and per-day
      weather read the stored date — making sub-headers agree with squeezed
      city headers (fixing the audited live inconsistency).
- [ ] The leg computation flips its item-day inputs to stored dates only
      after a prod audit query shows zero divergence (provable no-op).
- [ ] Binary rollback is safe (day mirror stays correct); one documented
      idempotent repair statement re-syncs dates on roll-forward.

## Out of Scope

- Removing day numbers from any wire format or UI grouping mechanism.
- Monotonicity/clamp-to-span enforcement beyond today's permissiveness (the
  leg computation absorbs disorder; trip health flags it).
