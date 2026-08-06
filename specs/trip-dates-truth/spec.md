# Spec: Trip Dates — Single Source of Truth (umbrella)

> Umbrella for a staged re-architecture. The three feature specs execute it:
> [`specs/server-leg-dates/`](../server-leg-dates/spec.md) (waves 1–3),
> [`specs/server-booking-todos/`](../server-booking-todos/spec.md) (waves 4–5),
> [`specs/itinerary-item-dates/`](../itinerary-item-dates/spec.md) (waves 3–6).

## Context

The August 2026 leg-dates arc (PRs #284–#295, five dogfooding rounds on one
trip) kept producing the same bug shape: a date edit "succeeds" while the page
shows something else. An audit found why: the dates a trip displays are a
DERIVED view — per-city legs computed from positional item day numbers whose
semantics (a city's last item day is its departure) exist only by convention —
and that derivation exists in **five grouping rules and ~eight independent
day→date computations** across two languages, with a third copy of the dates
in the booking checklist that goes stale between screen loads, and write paths
that never see what the reader will render. Each round patched one mismatch;
this program removes the category: **one derivation, computed server-side,
consumed everywhere; real calendar dates as storage truth; derived rows
maintained by the writer, not the viewer.**

## End state

1. One Go function computes every city leg's rendered date span; the trip
   payload carries it; client, chat tools, print, calendar, health checks and
   the shared view all consume it. The client computes no dates.
2. `itinerary_items` stores a real calendar date; the day number remains as a
   derived mirror (wire format, dateless drafts, UI grouping). Authority is a
   pure function of whether the trip has a start date.
3. Auto booking-todos (and legacy auto drafts) are derived server-side on
   every relevant write. A trip edited only via chat renders correctly with a
   fresh checklist on first open.

## Rollout (A → C → B, six waves; see feature specs for lane tables)

Parity-prove the server derivation against the frozen client semantics first
(retained client fallback + a ≥1-week live parity soak gate), close the
checklist staleness channel second, flip storage last when it is a provable
no-op (dual-write + backfill + pre-flip audit query). Compat: old cached
bundles keep working forever (day-number inputs converted at the boundary;
todo syncs become no-op echoes that return server truth).

## The category is dead when

- [ ] Exactly one function computes leg date ranges; trip payload, shared
      payload, get_trip, section-rewrite results, print, and calendar spans
      all consume it (one definition, N call sites).
- [ ] Zero client-side date derivation code remains (grep list in tasks).
- [ ] Every dated item carries a stored calendar date; the stored day number
      is written only by the conversion boundary (or dropped); date-change
      tools move dates.
- [ ] A trip edited ONLY via chat renders correct leg dates and a fresh
      checklist on first screen load.
- [ ] An old cached bundle can still read the trip, edit items by day number,
      and call the legacy sync endpoints without corrupting server truth.
- [ ] All transition scaffolding (parity logger, twin fixtures, client
      fallback) is deleted.

## Out of Scope

- Day chips / Today mode / day-grouping mechanics (stay day-number-based).
- Print/shared visual redesigns beyond consuming the shared computation.
- Section-rewrite stay-coherence (backlog; visible via rendered-leg echoes).
