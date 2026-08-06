# Tasks: Itinerary Items Store Calendar Dates

Lane briefs are written at execution time (waves 3–6) against then-current
code; plan.md accompanies the wave-3 brief. Migration lane rule: one
migration lane per wave.

| Wave | Lane | Branch | Contents |
|---|---|---|---|
| 3 | 4a | `item-date-column` | migration 00054 (add `item_date` + backfill), `itemSchedule` conversion boundary, writer sweep dual-write, POST/PATCH dual-accept |
| 5 | 5a | `item-date-anchor-flip` | leg computation + calendar + print + review + sub-headers onto `item_date`; pre-flip prod audit query = 0 |
| 5 | 5b | `date-tools-native` | set_trip_dates shifts item dates + materializes on undated→dated; set_leg_dates writes dates natively; trip-PATCH unification (tx + shifts + re-derive) |
| 6 | 6a | `kill-client-fallback` | offline-cache version bump; delete `leg_ranges.dart`, parity logger, transition tests (hub lane) |
| 6 | 6b | `drop-stored-day` | migration 00055: derive day in reads, drop the column (or defer with boundary-only writes as the acceptance bar) |
