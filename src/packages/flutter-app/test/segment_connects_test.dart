import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/trip_segment.dart';
import 'package:travel_route_planner/screens/trip_detail_derivation.dart';

/// Twin fixtures for the Go rule in trip_review.go / trip_next_step.go. The
/// tables below are the SAME cases as TestFuzzyMatchShortTokens and
/// TestSegmentConnectsBothEnds; if one side moves and the other doesn't, one of
/// these files is now lying about what the page shows.
void main() {
  BookingTodo leg(String key, String title) => BookingTodo(
        id: 'todo-$key',
        kind: 'transport',
        todoKey: key,
        title: title,
      );

  TripSegment seg(String? origin, String? destination) => TripSegment(
        id: 'seg-$origin-$destination',
        mode: 'flight',
        origin: origin,
        destination: destination,
      );

  group('fuzzyMatch', () {
    // A three-letter endpoint must not substring-claim a longer place name:
    // "alb" vs "Albufeira" would silently mark the flight out as booked. Short
    // city names must still work. The deliberate cost is the other direction —
    // a code no longer claims the spelled-out airport it stands for, because
    // nothing here knows IATA, and a missed claim is the safe failure.
    const cases = <(String, String, bool)>[
      ('albufeira', 'alb', false),
      ('alb', 'alb', true),
      ('albany international airport', 'alb', false),
      ('rio de janeiro', 'rio', true),
      ('new york, ny', 'ny', true),
      ('amsterdam', 'rome', false),
      ('amsterdam schiphol', 'amsterdam', true),
    ];
    for (final (a, b, want) in cases) {
      test('$a vs $b -> $want', () => expect(fuzzyMatch(a, b), want));
    }

    test('an empty side never matches', () {
      expect(fuzzyMatch('', 'alb'), isFalse);
      expect(fuzzyMatch('alb', ''), isFalse);
    });
  });

  group('legEndpoints', () {
    test('reads the endpoint-labelled wire key', () {
      expect(legEndpoints(leg('transport:ewr>>amsterdam', 'EWR → Amsterdam')),
          (from: 'ewr', to: 'amsterdam'));
    });

    test('falls back to the title when the key speaks another grammar', () {
      expect(legEndpoints(leg('custom:abc', 'Lake George, NY → Montreal')),
          (from: 'lake george, ny', to: 'montreal'));
    });

    test('a reserved @ token names no place a segment could connect', () {
      // The client is only ever sent display keys, so this is a guard rather
      // than a case — but a storage key leaking through must not be parsed as
      // a place called "@home".
      expect(legEndpoints(leg('transport:@home>>amsterdam', 'ALB → Amsterdam')),
          (from: 'alb', to: 'amsterdam'));
      expect(legEndpoints(leg('transport:@home>>amsterdam', 'no arrow here')),
          isNull);
    });
  });

  group('segmentConnectsLeg', () {
    final outbound = leg('transport:ewr>>amsterdam', 'EWR → Amsterdam');

    test('both ends match', () {
      expect(segmentConnectsLeg(seg('EWR', 'Amsterdam'), outbound), isTrue);
    });

    test('either direction counts', () {
      expect(segmentConnectsLeg(seg('Amsterdam', 'EWR'), outbound), isTrue);
    });

    // The reported bug: correcting the airport in the "Add details…" sheet
    // posted "ALB → Amsterdam" and the page nested it under "EWR → Amsterdam"
    // on the destination alone, reading as covered while Trip Health — which
    // has always required both ends — still counted the flight as a gap.
    test('a different origin does NOT cover the leg', () {
      expect(segmentConnectsLeg(seg('ALB', 'Amsterdam'), outbound), isFalse);
    });

    test('a different destination does NOT cover the leg', () {
      expect(segmentConnectsLeg(seg('EWR', 'Rome'), outbound), isFalse);
    });

    test('a half-empty segment covers nothing', () {
      expect(segmentConnectsLeg(seg(null, 'Amsterdam'), outbound), isFalse);
      expect(segmentConnectsLeg(seg('EWR', null), outbound), isFalse);
    });

    test('a leg that names no endpoints is covered by nothing', () {
      expect(segmentConnectsLeg(seg('EWR', 'Amsterdam'), leg('custom:x', 'Fly')),
          isFalse);
    });

    test('city names still match loosely across airport spellings', () {
      final interCity = leg('transport:amsterdam>>rome', 'Amsterdam → Rome');
      expect(
          segmentConnectsLeg(
              seg('Amsterdam Schiphol', 'Rome Fiumicino'), interCity),
          isTrue);
    });
  });
}
