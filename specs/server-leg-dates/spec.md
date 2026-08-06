# Spec: Server-Computed City-Leg Dates

> Stage A of [`specs/trip-dates-truth/`](../trip-dates-truth/spec.md).

## Context

Every surface that shows "Paris — Sep 20 – Sep 24" derives that range itself,
in two hand-mirrored implementations (client + server) plus several one-off
computations, with documented and undocumented divergences between them. This
feature makes the server compute the legs ONCE and ship them in the trip
payload; the client renders what it's told, keeping a temporary local fallback
only for legless payloads (offline caches, rollback).

## User Stories

- As a **traveler**, I want every view of my trip — headers, stay rows,
  flights, map pins, chat answers, print — to show the SAME dates for a city.
- As the **trip assistant**, I want to read the exact ranges the traveler
  sees, so I never narrate dates the page contradicts.

## Acceptance Criteria

- [ ] The trip detail and shared-trip payloads carry a `legs` array: one entry
      per contiguous city run (revisits distinct, hubless runs labeled), with
      the rendered start/end dates, the date source (stay / items / auto /
      none), a zero-night flag, item-position bounds, and a representative
      coordinate. Old clients ignore it.
- [ ] The trip screen's city headers, stay/flight checklist inputs, map pins,
      and weather/events windows render the payload legs when present, and
      fall back to the local derivation only when absent.
- [ ] get_trip and section-rewrite tool results echo the same computation.
- [ ] A debug-mode parity monitor compares payload legs to the local
      derivation on every trip load and reports mismatches; one week of daily
      dogfooding with zero mismatches gates the client repoint.
- [ ] Reconciled-rule behavior deltas are enumerated, decided, and pinned by
      tests (address-then-name stay matching; chain skip over spanless legs;
      first-spanned-leg anchor; no address-parse grouping).

## Out of Scope

- Schema changes (stage B) and server-derived todos (stage C).
- The trips LIST endpoint (its `cities` summary is not a date consumer).
