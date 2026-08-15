# Spec: Per-Trip Departure & Return Airports

## Context

A traveler asked the trip chat: *"Let's also update the flight to amsterdam to
be from ALB in the trip. Ensure it updates on the map as well."* The assistant
replied that the `EWR → Amsterdam` transport row is "auto-tracked and not
editable", **added a duplicate manual to-do** for the ALB flight, left the wrong
EWR row in place, and told the traveler to ignore it. The map was not addressed.

It was not wrong about its options. A trip's origin could only be set at
creation (and the in-app assistant could not set it even then), the derived
legs are auto rows the checklist tools refuse, and the only remaining tool adds
a *new* item. Meanwhile the airport the legs actually used came from the saved
home airport — a standing fact about the traveler, not about this trip.

Underneath sat a worse problem: a derived leg was **identified by its endpoint
labels**, so changing an airport deleted the row and silently took the booked
flag, the per-leg travel mode and the linked budget expense with it. That fired
whenever anyone corrected their home airport in Settings, on every trip they
owned, and whenever a collaborator opened a shared trip.

Intended outcome: "make this trip leave from ALB and come home into EWR" moves
the real rows — no duplicates, nothing lost — and moves the map pins, while the
saved home airport stays exactly as it was.

## User Stories

- As a **traveler**, I want to tell the assistant which airport *this* trip
  leaves from, so my checklist and map show my actual flight rather than a
  guess based on where I usually fly from.
- As a **traveler flying out of one airport and home into another**, I want both
  ends recorded separately, so neither leg contradicts my booking.
- As a **traveler**, I want a leg I have already booked to stay booked when I
  correct its airport, so I don't lose track of what I've paid for.
- As the **assistant**, I want a tool for this, so I never have to leave a wrong
  row on the checklist and ask the traveler to ignore it.

## Acceptance Criteria

- [ ] Asking the assistant to change where a saved trip departs from renames the
      existing departure leg. No duplicate row appears, and the leg keeps its
      booked state, its per-leg travel mode, its position, and any linked
      expense.
- [ ] A trip can depart from one airport and return into another; changing one
      leaves the other untouched.
- [ ] Stating one airport and nothing about the return means the trip returns to
      the same airport, and the tool says so.
- [ ] The trip map pins the trip's own airports — two pins when they differ,
      one when they match — and one pin still renders when the other airport
      cannot be resolved.
- [ ] The saved home airport is never changed as a side effect; a traveler who
      says they have *moved* is the only reason to touch it.
- [ ] An airport is refused as the origin of a stated ground trip, naming the
      free-text alternative instead of writing a leg that starts at a terminal.
- [ ] An airport code that resolves to no real airport is refused, and nothing
      is written.
- [ ] Stating the origin before a trip is saved carries it onto the trip when
      the itinerary is created, and survives later version saves.
- [ ] The assistant can see a trip's current endpoints, and can tell "explicitly
      set" apart from "falling back to the saved home airport".
- [ ] Correcting the saved home airport no longer destroys booked flags, per-leg
      modes, or linked expenses on any trip — and reaches an open trip page
      without an app restart.
- [ ] A checklist row the traveler has booked, given a mode, or spent against is
      never deleted by the itinerary sync; it becomes an ordinary row they can
      edit or remove.

## Data Model

- **Trip origin** (existing) — where the traveler set out from *in their own
  words* ("Lake George, NY"). Free text: it titles the booking legs verbatim and
  resolves to no coordinates, so it draws no map pin.
- **Trip departure airport / return airport** (new) — the airports this trip
  actually flies out of and home into, as codes. They may differ. They are
  recorded together or not at all: absent means this trip states no airport (and
  the legs fall back to the stated origin, then to the saved home airport), and
  never "same as the other direction".
- **Derived leg identity** (changed) — a derived departure or return leg is
  identified by *which end of the journey it is*, not by the airport's name, so
  the airport is ordinary content that can change without the row being
  replaced. Its endpoint labels are recorded alongside it.

## UI Behavior

- **Surface:** the trip chat only. There is no new control on the trip page this
  wave; the page reflects the result.
- **Happy path:** the traveler says where the trip departs from (and, if it
  differs, where it returns into). The checklist's departure and return rows
  re-title themselves, the map's pins move, and the assistant reports both
  endpoints and exactly which rows changed.
- **States:** a trip with no itinerary yet records the endpoints and says
  plainly that no leg was renamed; an unresolvable airport changes nothing and
  says so.

## Out of Scope

- Any trip-page control for editing the endpoints (chat only, this wave).
- Changing the endpoints through the public trip PATCH surface.
- Teaching the connector's trip-create tool about airports (it still takes only
  the free-text origin).
- Re-pricing or re-searching flights when an endpoint changes.

## Open Questions

None outstanding.
