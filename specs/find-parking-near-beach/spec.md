# Spec: Find free/cheap parking near beaches

> **WHAT & WHY only.** No tech choices, file names, libraries, or code. If a
> sentence names a file or a package, it belongs in `plan.md`, not here.

## Context

Beach days on driving trips routinely cost travelers 30+ minutes and surprise
fees hunting for parking. The planning agent already knows when a traveler is
driving and which beaches are on the plan, so it should surface nearby parking
options with an honest free/cheap signal — letting the traveler budget time and
money before arriving instead of circling on the day.

## User Stories

- As a **traveler planning a road trip with beach stops**, I want the agent to
  show me parking options near a beach, flagged when they appear free, so I can
  budget time and money.
- As a **traveler**, I want the free/cheap flag presented as "listed as free —
  verify locally," so I'm never promised something the data can't guarantee.
- As a **signed-in traveler**, I want to add a parking spot to my trip like any
  other place.

## Acceptance Criteria

- [ ] Asking about beach parking on a driving trip (e.g. "we're driving — where
      can we park near Barceloneta Beach?") makes the agent look up parking
      near that beach and reply with concrete options.
- [ ] While the lookup runs, the chat shows a localized "Finding parking…"
      activity chip.
- [ ] Results appear as a horizontal photo-card rail in the chat (same style as
      places/local picks), at most 8 cards, with free-flagged options ranked
      ahead of paid-looking ones and closer options first.
- [ ] Cards that appear free show a visible "Free (listed)" marker; the agent's
      text presents the flag as heuristic ("listed as free — verify locally"),
      never as guaranteed.
- [ ] Tapping a card opens Google Maps for that spot; signed-in travelers can
      add a spot to their trip.
- [ ] If the beach can't be located or no parking is found nearby, the agent
      says so conversationally; the chat shows no empty rail and no error
      banner.
- [ ] The whole flow works in Spanish (activity chip, rail label, free marker).
- [ ] The agent does not proactively push parking on flight/train-only trips.

## API Surface

No new endpoint. This is a new capability of the existing planning stream: a
"parking results" side event carrying the beach label and up to 8 spot cards
(name, address, coordinates, optional photo, free-flag) alongside the agent's
conversational reply.

## Data Model

Nothing persisted. **Parking spot** — a place near the named beach whose
listing suggests it is for parking; carries a heuristic `free` flag derived
from the listing name, an optional photo, and distance-based ordering. Spots
added to a trip become ordinary itinerary items.

## UI Behavior

- **Surface:** the plan chat only.
- **Happy path:** traveler mentions driving + a beach → agent looks up parking
  → "Finding parking…" chip while running → photo-card rail + conversational
  summary with the verify-locally caveat.
- **States:** loading = activity chip; success = rail (max 8 cards); empty =
  conversational "nothing found" with no rail; upstream error = agent
  apologizes conversationally, no error banner.
- Rail persists until the next message is sent (same lifecycle as other result
  rails).

## Edge Cases & Error States

- Missing beach name → agent asks which beach is meant.
- Unknown/ambiguous beach → agent asks the traveler to confirm name and city.
- Coordinates provided but implausible → treated as absent; beach is looked up
  by name instead.
- Places outage mid-flow → agent apologizes conversationally; no crash, no
  broken rail.
- Zero parking results within ~2 km → conversational answer (side streets,
  arrive early), no rail.
- Duplicate results across the free-focused and general lookups → deduplicated.

## Out of Scope

- A public REST endpoint or trip-detail UI for parking.
- Real pricing data / paid parking APIs (Parkopedia, SpotHero).
- Parking availability, hours, or reservations.
- Non-beach parking guidance (the capability works anywhere but is only
  prompted for beach contexts).

## Open Questions

None — radius (~2 km) and honesty phrasing ("listed as free — verify locally")
resolved during planning.
