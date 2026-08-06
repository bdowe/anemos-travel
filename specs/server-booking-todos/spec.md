# Spec: Server-Derived Booking Checklist

> Stage C of [`specs/trip-dates-truth/`](../trip-dates-truth/spec.md).
> Executes after the server-leg-dates client repoint (wave 4–5).

## Context

The auto "Stay in X" / "A → B" checklist rows are derived on the traveler's
device only when the trip screen loads, then synced up — so a trip edited via
chat serves stale checklist dates to the AI (get_trip), the print packet, and
collaborators until someone opens the page. Deriving them server-side on
every relevant write makes the checklist a maintained view, not a cache.

## User Stories

- As a **traveler**, when I change dates in chat, my checklist (and its
  printed copy) is already correct the next time anyone sees it.
- As the **trip assistant**, I want get_trip's checklist dates to be trustworthy
  without requiring a screen load in between.

## Acceptance Criteria

- [ ] Auto stay/transport/home-leg/ferry checklist rows are re-derived
      server-side (from the shared leg computation, using the trip OWNER's
      home airport) after every write that can change them: itinerary edits,
      date tools, stay/segment CRUD, travel-mode and home-airport changes.
- [ ] Manual and agent-added rows, booked flags, and dismissals survive
      re-derivation untouched.
- [ ] Rollout is shadow-first: a comparison window logs client-posted vs
      server-derived rows on real trips before the flip.
- [ ] At the flip, the legacy client sync endpoints become no-op echoes that
      return server truth (old cached bundles then display it); the client
      derivation code is deleted one wave later.
- [ ] Legacy auto draft stays/segments follow the same server derivation (no
      second client-owned derivation remains).
- [ ] "Stay in Other places" rows are no longer produced (hubless legs get no
      stay todo) — a flagged, deliberate improvement.

## Out of Scope

- Localized subtitles (server keeps writing English date-range subtitles for
  old bundles; the updated client formats from the date fields).
- Any change to manual todo editing or the booked/dismiss flows.
