import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/trip_leg_dto.dart';

void main() {
  test('TripLegDto parses the server legs payload shape', () {
    final trip = Trip.fromJson({
      'id': 't1',
      'title': 'Fixture',
      'status': 'planned',
      'created_at': '2026-08-01',
      'updated_at': '2026-08-01',
      'legs': [
        {
          'key': 'Panama City',
          'label': 'Panama City',
          'hub': 'Panama City',
          'start_date': '2026-09-15',
          'end_date': '2026-09-20',
          'date_source': 'stay',
          'first_position': 0,
          'last_position': 5,
          'lat': 8.98,
          'lng': -79.52,
        },
        {
          'key': 'Other places',
          'label': 'Other places',
          'first_position': 6,
          'last_position': 6,
        },
      ],
    });

    final legs = trip.legs!;
    expect(legs, hasLength(2));
    expect(legs[0].key, 'Panama City');
    expect(legs[0].startDate, '2026-09-15');
    expect(legs[0].endDate, '2026-09-20');
    expect(legs[0].dateSource, 'stay');
    expect(legs[0].zeroNight, isNull);
    expect(legs[1].hub, isNull);
    expect(legs[1].startDate, isNull);
    expect(legs[1].firstPosition, 6);
  });

  test('a payload without legs parses to null (fallback path)', () {
    final trip = Trip.fromJson({
      'id': 't1',
      'title': 'Fixture',
      'status': 'planned',
      'created_at': '2026-08-01',
      'updated_at': '2026-08-01',
    });
    expect(trip.legs, isNull);
  });

  test('TripLegDto round-trips through toJson', () {
    const leg = TripLegDto(
      key: 'Athens#2',
      label: 'Athens',
      hub: 'Athens',
      startDate: '2026-06-05',
      endDate: '2026-06-06',
      dateSource: 'items',
      zeroNight: true,
      firstPosition: 4,
      lastPosition: 6,
    );
    final back = TripLegDto.fromJson(leg.toJson());
    expect(back.key, 'Athens#2');
    expect(back.zeroNight, isTrue);
    expect(back.lat, isNull);
  });
}
