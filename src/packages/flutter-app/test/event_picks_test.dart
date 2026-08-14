import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/event.dart';
import 'package:travel_route_planner/utils/event_picks.dart';

Event _e(String date, String time, {String? name}) => Event(
      id: '$date-$time',
      name: name ?? '$date $time',
      startDate: date,
      startTime: time,
    );

/// The shape the API actually returns: `sort=date,asc`, so the input to
/// [spreadEventsByDay] is already chronological.
List<Event> _chrono(List<Event> events) => events;

void main() {
  group('spreadEventsByDay', () {
    test('covers every day of a busy stay instead of filling up on day one',
        () {
      // Berlin Sep 1-4 as the live API returns it: 2 / 3 / 2 / 7 per day.
      final events = _chrono([
        _e('2026-09-01', '19:00'), _e('2026-09-01', '20:30'),
        _e('2026-09-02', '19:30'), _e('2026-09-02', '20:00'),
        _e('2026-09-02', '20:15'),
        _e('2026-09-03', '18:30'), _e('2026-09-03', '20:00'),
        _e('2026-09-04', '16:00'), _e('2026-09-04', '18:00'),
        _e('2026-09-04', '19:30'), _e('2026-09-04', '19:35'),
        _e('2026-09-04', '20:00'), _e('2026-09-04', '20:05'),
        _e('2026-09-04', '20:30'),
      ]);

      final picks = spreadEventsByDay(events, limit: 8);

      expect(picks.length, 8);
      // Two per day, every day — not "all eight from Sep 1 and Sep 2".
      final perDay = <String, int>{};
      for (final e in picks) {
        perDay[e.startDate] = (perDay[e.startDate] ?? 0) + 1;
      }
      expect(perDay,
          {'2026-09-01': 2, '2026-09-02': 2, '2026-09-03': 2, '2026-09-04': 2});
      // What the old `events.take(5)` would have shown on this same data:
      // the whole back half of the stay, invisible.
      expect(
          events.take(5).map((e) => e.startDate).toSet(),
          {'2026-09-01', '2026-09-02'});
    });

    test('picks the earliest of each day first', () {
      final events = _chrono([
        _e('2026-09-01', '10:00'), _e('2026-09-01', '22:00'),
        _e('2026-09-02', '11:00'), _e('2026-09-02', '23:00'),
      ]);

      expect(spreadEventsByDay(events, limit: 2).map((e) => e.startTime),
          ['10:00', '11:00']);
    });

    test('returns picks in chronological order, not round-robin order', () {
      final events = _chrono([
        _e('2026-09-01', '10:00'), _e('2026-09-01', '11:00'),
        _e('2026-09-02', '10:00'), _e('2026-09-02', '11:00'),
      ]);

      // Round-robin visits 09-01@10, 09-02@10, 09-01@11, 09-02@11.
      expect(
          spreadEventsByDay(events, limit: 4).map((e) => e.name),
          ['2026-09-01 10:00', '2026-09-01 11:00', '2026-09-02 10:00',
            '2026-09-02 11:00']);
    });

    test('fills remaining slots from the busy days once thin days run dry', () {
      final events = _chrono([
        for (var i = 0; i < 10; i++)
          _e('2026-09-01', '1${i.toString().padLeft(1, '0')}:00'),
        _e('2026-09-03', '20:00'),
      ]);

      final picks = spreadEventsByDay(events, limit: 4);

      expect(picks.length, 4);
      expect(picks.where((e) => e.startDate == '2026-09-03').length, 1);
      expect(picks.where((e) => e.startDate == '2026-09-01').length, 3);
    });

    test('a single-day window still fills the rail', () {
      // The reported Berlin case once the window collapsed to the last day.
      final events = _chrono([
        for (var i = 0; i < 8; i++) _e('2026-09-04', '1$i:00'),
      ]);

      final picks = spreadEventsByDay(events, limit: 8);

      expect(picks.length, 8);
      expect(picks.every((e) => e.startDate == '2026-09-04'), isTrue);
    });

    test('returns everything, chronologically, when under the limit', () {
      final events = _chrono([
        _e('2026-09-01', '19:00'),
        _e('2026-09-03', '20:00'),
      ]);

      expect(spreadEventsByDay(events, limit: 8).map((e) => e.startDate),
          ['2026-09-01', '2026-09-03']);
    });

    test('never filters: a blank start_date keeps its slot, sorted last', () {
      final events = [
        _e('', '', name: 'malformed'),
        _e('2026-09-01', '19:00'),
      ];

      final picks = spreadEventsByDay(events, limit: 8);

      expect(picks.length, 2);
      expect(picks.last.name, 'malformed');
    });

    test('degenerate inputs', () {
      expect(spreadEventsByDay(const [], limit: 8), isEmpty);
      expect(spreadEventsByDay([_e('2026-09-01', '19:00')], limit: 0), isEmpty);
      expect(
          spreadEventsByDay([_e('2026-09-01', '19:00')], limit: -1), isEmpty);
    });

    test('is deterministic when date and time both tie', () {
      final events = [
        _e('2026-09-01', '19:30', name: 'first'),
        _e('2026-09-01', '19:30', name: 'second'),
      ];

      expect(spreadEventsByDay(events, limit: 2).map((e) => e.name),
          ['first', 'second']);
    });
  });

  test('kEventsServerCap mirrors maxEvents in events_service.go', () {
    // Pinned on the Go side by TestEventsServerCapIsThirty. If one moves and
    // the other does not, one of these two tests fails instead of the UI
    // quietly claiming "30 events" when there were more.
    expect(kEventsServerCap, 30);
  });
}
