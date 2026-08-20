-- Seeded corpus for the scope-'trip' guard audit (specs: trip-scope-guard ticket 2).
--
-- WHY THIS FILE EXISTS: the audit's whole point is to check the guard against
-- real itineraries before it starts rejecting writes, and the local dev database
-- was destroyed and recreated on 2026-08-19 — it holds zero trips. Production is
-- on DO and is Brian's to run. So the numbers this lane can produce come from a
-- SEEDED corpus, and this file is it, written down so the numbers are
-- reproducible and so a reader can see exactly which shapes were and were not
-- covered.
--
-- A run over this corpus is NOT a substitute for a production run. It proves the
-- predicate's behaviour on the shapes we know how to name; it cannot prove
-- anything about shapes real travelers produced that nobody thought of.
--
-- Usage (against a migrated, otherwise-empty database):
--   psql "$DATABASE_URL" -f testdata/guard_audit_corpus.sql
--   go run . repair-sections
--
-- Trip titles are prefixed LEGIT- or CORRUPT- so the audit's output can be read
-- against the intent without cross-referencing ids.

BEGIN;

INSERT INTO users (id, email)
VALUES ('00000000-0000-0000-0000-0000000000aa', 'guard-audit@example.test')
ON CONFLICT (email) DO NOTHING;

-- Each trip gets a fixed uuid so re-running is idempotent and reports are stable.
INSERT INTO trips (id, user_id, title) VALUES
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'LEGIT-01 linear two cities'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'LEGIT-02 genuine revisit Paris-Rome-Paris'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000aa', 'LEGIT-03 shared transition day'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000aa', 'LEGIT-04 day trip from hub'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000aa', 'LEGIT-05 hubless item between two city runs'),
  ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000000aa', 'LEGIT-06 spine with empty middle days'),
  ('10000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000000aa', 'LEGIT-07 unscheduled tail'),
  ('10000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-0000000000aa', 'LEGIT-08 diacritic spelling variance'),
  ('10000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-0000000000aa', 'LEGIT-09 five-city trip with transitions and a day trip'),
  ('10000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000aa', 'LEGIT-10 single city'),
  ('10000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000aa', 'LEGIT-11 revisit repeating one place (known limitation)'),
  ('10000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-0000000000aa', 'LEGIT-12 island hop, every city once'),
  ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'CORRUPT-01 stale trailing run (2026-08-20 shape)'),
  ('20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'CORRUPT-02 stale leading run'),
  ('20000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000aa', 'CORRUPT-03 days run backwards, no repeated hub'),
  ('20000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000aa', 'CORRUPT-04 four cities fragmented (observed incident)')
ON CONFLICT (id) DO NOTHING;

-- position, name, city, day_trip_from, day. Coordinates are distinct per place:
-- itemIdentity keys on lat/lng, so reusing one coordinate everywhere would make
-- every place a content duplicate of every other and the corpus would flag for
-- the wrong reason.
INSERT INTO itinerary_items (trip_id, position, name, latitude, longitude, city, day_trip_from, day) VALUES
-- LEGIT-01: the ordinary case, and by far the commonest.
('10000000-0000-0000-0000-000000000001', 0, 'Louvre',        48.8606, 2.3376, 'Paris', NULL, 1),
('10000000-0000-0000-0000-000000000001', 1, 'Orsay',         48.8600, 2.3266, 'Paris', NULL, 2),
('10000000-0000-0000-0000-000000000001', 2, 'Eiffel Tower',  48.8584, 2.2945, 'Paris', NULL, 3),
('10000000-0000-0000-0000-000000000001', 3, 'Colosseum',     41.8902, 12.4922, 'Rome', NULL, 4),
('10000000-0000-0000-0000-000000000001', 4, 'Forum',         41.8925, 12.4853, 'Rome', NULL, 5),
('10000000-0000-0000-0000-000000000001', 5, 'Pantheon',      41.8986, 12.4769, 'Rome', NULL, 6),

-- LEGIT-02: two Paris runs, different places in each. computeTripLegs renders
-- this as three legs on purpose; the guard must leave it alone.
('10000000-0000-0000-0000-000000000002', 0, 'Louvre',        48.8606, 2.3376, 'Paris', NULL, 1),
('10000000-0000-0000-0000-000000000002', 1, 'Orsay',         48.8600, 2.3266, 'Paris', NULL, 2),
('10000000-0000-0000-0000-000000000002', 2, 'Colosseum',     41.8902, 12.4922, 'Rome', NULL, 3),
('10000000-0000-0000-0000-000000000002', 3, 'Forum',         41.8925, 12.4853, 'Rome', NULL, 4),
('10000000-0000-0000-0000-000000000002', 4, 'Sacre-Coeur',   48.8867, 2.3431, 'Paris', NULL, 5),
('10000000-0000-0000-0000-000000000002', 5, 'Montmartre',    48.8867, 2.3406, 'Paris', NULL, 6),

-- LEGIT-03: the move day carries the SAME day number in both cities.
('10000000-0000-0000-0000-000000000003', 0, 'Louvre',            48.8606, 2.3376, 'Paris', NULL, 1),
('10000000-0000-0000-0000-000000000003', 1, 'Orsay',             48.8600, 2.3266, 'Paris', NULL, 2),
('10000000-0000-0000-0000-000000000003', 2, 'Sainte-Chapelle',   48.8554, 2.3450, 'Paris', NULL, 3),
('10000000-0000-0000-0000-000000000003', 3, 'Trastevere dinner', 41.8890, 12.4700, 'Rome', NULL, 3),
('10000000-0000-0000-0000-000000000003', 4, 'Colosseum',         41.8902, 12.4922, 'Rome', NULL, 4),

-- LEGIT-04: Versailles sits inside the Paris run via day_trip_from.
('10000000-0000-0000-0000-000000000004', 0, 'Louvre',      48.8606, 2.3376, 'Paris', NULL, 1),
('10000000-0000-0000-0000-000000000004', 1, 'Versailles',  48.8049, 2.1204, 'Versailles', 'Paris', 2),
('10000000-0000-0000-0000-000000000004', 2, 'Orsay',       48.8600, 2.3266, 'Paris', NULL, 3),
('10000000-0000-0000-0000-000000000004', 3, 'Colosseum',   41.8902, 12.4922, 'Rome', NULL, 4),

-- LEGIT-05: a hubless place between two Paris runs; "Other places" in the UI.
('10000000-0000-0000-0000-000000000005', 0, 'Louvre',           48.8606, 2.3376, 'Paris', NULL, 1),
('10000000-0000-0000-0000-000000000005', 1, 'Roadside viewpoint', 48.7000, 2.2000, NULL, NULL, 2),
('10000000-0000-0000-0000-000000000005', 2, 'Orsay',            48.8600, 2.3266, 'Paris', NULL, 3),
('10000000-0000-0000-0000-000000000005', 3, 'Colosseum',        41.8902, 12.4922, 'Rome', NULL, 4),

-- LEGIT-06: a spine — first and last day of each city only, middles empty.
('10000000-0000-0000-0000-000000000006', 0, 'Arrive Paris', 48.8606, 2.3376, 'Paris', NULL, 1),
('10000000-0000-0000-0000-000000000006', 1, 'Leave Paris',  48.8600, 2.3266, 'Paris', NULL, 4),
('10000000-0000-0000-0000-000000000006', 2, 'Arrive Rome',  41.8902, 12.4922, 'Rome', NULL, 4),
('10000000-0000-0000-0000-000000000006', 3, 'Leave Rome',   41.8925, 12.4853, 'Rome', NULL, 8),

-- LEGIT-07: an undated "maybe" at the tail.
('10000000-0000-0000-0000-000000000007', 0, 'Louvre',         48.8606, 2.3376, 'Paris', NULL, 1),
('10000000-0000-0000-0000-000000000007', 1, 'Orsay',          48.8600, 2.3266, 'Paris', NULL, 2),
('10000000-0000-0000-0000-000000000007', 2, 'Maybe: Pompidou', 48.8607, 2.3522, 'Paris', NULL, NULL),

-- LEGIT-08: the model re-typing Kraków as Krakow must stay ONE run.
('10000000-0000-0000-0000-000000000008', 0, 'Wawel Castle',   50.0540, 19.9354, 'Kraków', NULL, 1),
('10000000-0000-0000-0000-000000000008', 1, 'Sukiennice',     50.0616, 19.9373, 'Krakow', NULL, 2),
('10000000-0000-0000-0000-000000000008', 2, 'Rynek Glowny',   50.0617, 19.9370, 'KRAKOW', NULL, 3),
('10000000-0000-0000-0000-000000000008', 3, 'Charles Bridge', 50.0865, 14.4114, 'Prague', NULL, 4),

-- LEGIT-09: a long realistic itinerary — five cities, shared transition days,
-- a day trip, an undated maybe. The shape most like a real saved trip.
('10000000-0000-0000-0000-000000000009', 0,  'Sagrada Familia', 41.4036, 2.1744, 'Barcelona', NULL, 1),
('10000000-0000-0000-0000-000000000009', 1,  'Park Guell',      41.4145, 2.1527, 'Barcelona', NULL, 2),
('10000000-0000-0000-0000-000000000009', 2,  'Montserrat',      41.5934, 1.8380, 'Montserrat', 'Barcelona', 3),
('10000000-0000-0000-0000-000000000009', 3,  'Boqueria',        41.3817, 2.1717, 'Barcelona', NULL, 4),
('10000000-0000-0000-0000-000000000009', 4,  'Alhambra',        37.1761, -3.5881, 'Granada', NULL, 4),
('10000000-0000-0000-0000-000000000009', 5,  'Albaicin',        37.1809, -3.5926, 'Granada', NULL, 5),
('10000000-0000-0000-0000-000000000009', 6,  'Mezquita',        37.8790, -4.7794, 'Cordoba', NULL, 6),
('10000000-0000-0000-0000-000000000009', 7,  'Alcazar',         37.3830, -5.9903, 'Seville', NULL, 7),
('10000000-0000-0000-0000-000000000009', 8,  'Plaza de Espana', 37.3772, -5.9869, 'Seville', NULL, 8),
('10000000-0000-0000-0000-000000000009', 9,  'Prado',           40.4138, -3.6921, 'Madrid', NULL, 9),
('10000000-0000-0000-0000-000000000009', 10, 'Retiro',          40.4153, -3.6844, 'Madrid', NULL, 10),
('10000000-0000-0000-0000-000000000009', 11, 'Maybe: Toledo',   39.8628, -4.0273, 'Toledo', 'Madrid', NULL),

-- LEGIT-10: one city, nothing to fragment.
('10000000-0000-0000-0000-00000000000a', 0, 'Louvre', 48.8606, 2.3376, 'Paris', NULL, 1),
('10000000-0000-0000-0000-00000000000a', 1, 'Orsay',  48.8600, 2.3266, 'Paris', NULL, 2),

-- LEGIT-11: a genuine revisit whose return run REPEATS a place from the first.
-- Days run forwards throughout; nothing here is corrupt. This is the shape the
-- conservative predicate is expected to flag anyway — see the lane report.
('10000000-0000-0000-0000-00000000000b', 0, 'Louvre',    48.8606, 2.3376, 'Paris', NULL, 1),
('10000000-0000-0000-0000-00000000000b', 1, 'Orsay',     48.8600, 2.3266, 'Paris', NULL, 2),
('10000000-0000-0000-0000-00000000000b', 2, 'Colosseum', 41.8902, 12.4922, 'Rome', NULL, 3),
('10000000-0000-0000-0000-00000000000b', 3, 'Forum',     41.8925, 12.4853, 'Rome', NULL, 4),
('10000000-0000-0000-0000-00000000000b', 4, 'Louvre',    48.8606, 2.3376, 'Paris', NULL, 5),

-- LEGIT-12: Greek island hop, every island once, shared transition days.
('10000000-0000-0000-0000-00000000000c', 0, 'Acropolis',      37.9715, 23.7257, 'Athens', NULL, 1),
('10000000-0000-0000-0000-00000000000c', 1, 'Plaka dinner',   37.9725, 23.7300, 'Athens', NULL, 2),
('10000000-0000-0000-0000-00000000000c', 2, 'Oia sunset',     36.4618, 25.3753, 'Santorini', NULL, 2),
('10000000-0000-0000-0000-00000000000c', 3, 'Red Beach',      36.3487, 25.3940, 'Santorini', NULL, 3),
('10000000-0000-0000-0000-00000000000c', 4, 'Little Venice',  37.4467, 25.3289, 'Mykonos', NULL, 4),
('10000000-0000-0000-0000-00000000000c', 5, 'Delos',          37.3936, 25.2686, 'Delos', 'Mykonos', 5),

-- CORRUPT-01: the 2026-08-20 shape. Krakow twice — the fresh copy on days 1-2,
-- the stale copy still carrying its pre-swap days 3-4.
('20000000-0000-0000-0000-000000000001', 0, 'Wawel Castle',    50.0540, 19.9354, 'Krakow', NULL, 1),
('20000000-0000-0000-0000-000000000001', 1, 'Rynek Glowny',    50.0617, 19.9370, 'Krakow', NULL, 2),
('20000000-0000-0000-0000-000000000001', 2, 'Charles Bridge',  50.0865, 14.4114, 'Prague', NULL, 3),
('20000000-0000-0000-0000-000000000001', 3, 'Old Town Square', 50.0870, 14.4207, 'Prague', NULL, 4),
('20000000-0000-0000-0000-000000000001', 4, 'Wawel Castle',    50.0540, 19.9354, 'Krakow', NULL, 3),
('20000000-0000-0000-0000-000000000001', 5, 'Rynek Glowny',    50.0617, 19.9370, 'Krakow', NULL, 4),

-- CORRUPT-02: the mirror, from the same user action targeting the other city.
('20000000-0000-0000-0000-000000000002', 0, 'Charles Bridge',  50.0865, 14.4114, 'Prague', NULL, 1),
('20000000-0000-0000-0000-000000000002', 1, 'Old Town Square', 50.0870, 14.4207, 'Prague', NULL, 2),
('20000000-0000-0000-0000-000000000002', 2, 'Wawel Castle',    50.0540, 19.9354, 'Krakow', NULL, 1),
('20000000-0000-0000-0000-000000000002', 3, 'Rynek Glowny',    50.0617, 19.9370, 'Krakow', NULL, 2),
('20000000-0000-0000-0000-000000000002', 4, 'Charles Bridge',  50.0865, 14.4114, 'Prague', NULL, 3),
('20000000-0000-0000-0000-000000000002', 5, 'Old Town Square', 50.0870, 14.4207, 'Prague', NULL, 4),

-- CORRUPT-03: a hand-reordered list whose days zig-zag. No hub repeats at all,
-- so candidateTripsSQL never sees it — only the day-monotonicity check does.
('20000000-0000-0000-0000-000000000003', 0, 'Colosseum',   41.8902, 12.4922, 'Rome', NULL, 4),
('20000000-0000-0000-0000-000000000003', 1, 'Forum',       41.8925, 12.4853, 'Rome', NULL, 5),
('20000000-0000-0000-0000-000000000003', 2, 'Louvre',      48.8606, 2.3376, 'Paris', NULL, 1),
('20000000-0000-0000-0000-000000000003', 3, 'Orsay',       48.8600, 2.3266, 'Paris', NULL, 2),
('20000000-0000-0000-0000-000000000003', 4, 'Duomo',       45.4642, 9.1900, 'Milan', NULL, 6),

-- CORRUPT-04: the observed incident — Prague and Kraków appearing twice, Rome
-- and Sorrento split, two legs carrying wrong dates.
('20000000-0000-0000-0000-000000000004', 0,  'Charles Bridge',  50.0865, 14.4114, 'Prague', NULL, 1),
('20000000-0000-0000-0000-000000000004', 1,  'Old Town Square', 50.0870, 14.4207, 'Prague', NULL, 2),
('20000000-0000-0000-0000-000000000004', 2,  'Wawel Castle',    50.0540, 19.9354, 'Kraków', NULL, 3),
('20000000-0000-0000-0000-000000000004', 3,  'Rynek Glowny',    50.0617, 19.9370, 'Kraków', NULL, 4),
('20000000-0000-0000-0000-000000000004', 4,  'Colosseum',       41.8902, 12.4922, 'Rome', NULL, 5),
('20000000-0000-0000-0000-000000000004', 5,  'Marina Grande',   40.6263, 14.3757, 'Sorrento', NULL, 7),
('20000000-0000-0000-0000-000000000004', 6,  'Charles Bridge',  50.0865, 14.4114, 'Prague', NULL, 5),
('20000000-0000-0000-0000-000000000004', 7,  'Old Town Square', 50.0870, 14.4207, 'Prague', NULL, 6),
('20000000-0000-0000-0000-000000000004', 8,  'Wawel Castle',    50.0540, 19.9354, 'Krakow', NULL, 7),
('20000000-0000-0000-0000-000000000004', 9,  'Rynek Glowny',    50.0617, 19.9370, 'Krakow', NULL, 8),
('20000000-0000-0000-0000-000000000004', 10, 'Forum',           41.8925, 12.4853, 'Rome', NULL, 9),
('20000000-0000-0000-0000-000000000004', 11, 'Marina Grande',   40.6263, 14.3757, 'Sorrento', NULL, 10);

COMMIT;
