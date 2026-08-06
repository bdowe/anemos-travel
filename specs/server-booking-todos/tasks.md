# Tasks: Server-Derived Booking Checklist

Lane briefs are written at wave-4 execution time against then-current code.

## Wave 4 (one lane, two PRs — deploy + dogfood soak between them)

| Lane | Branch | Contents |
|---|---|---|
| 3a-shadow | `server-todos-shadow` | Go `rederiveBookingTodos` port over computeTripLegs (owner home airport, ferry/ground rules); on client sync, log client-vs-server diff; no behavior change |
| 3a-flip | same lane, PR 2 | derive-on-write triggers everywhere + sync endpoints become no-op echoes (SAME deploy); replaces set_trip_dates' todo SQL-shift with full re-derive |

## Wave 5 (hub lane)

| Lane | Branch | Contents |
|---|---|---|
| 3b | `delete-client-todos` | delete `_deriveTodos`/`_syncBookingTodos`/home-ferry-ground builders; flight/ferry prefill rebuilt from todo rows |

Hard rule: 3b merges no earlier than one full wave after 3a-flip deploys
(rollback asymmetry — reverting the flip after 3b would freeze todos).
plan.md for this spec is written with the wave-4 lane briefs.
