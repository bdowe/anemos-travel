import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';

/// The `places` SSE event (chat photo cards): parsing, per-turn reset, and
/// the itinerary-turn suppression in BOTH event orders.

class _ScriptedPlanService extends PlanService {
  final List<PlanEvent> events;

  _ScriptedPlanService(this.events) : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    for (final e in events) {
      yield e;
    }
  }
}

const _placesEvent = PlanEvent(type: 'places', data: {
  'query': 'tapas in seville',
  'places': [
    {
      'name': 'Bar El Comercio',
      'place_id': 'p1',
      'address': 'Calle Lineros 9',
      'lat': 37.39,
      'lng': -5.99,
      'rating': 4.5,
      'price_level': 1,
      'category': 'restaurant',
      'photo_ref': 'REF-1',
      'photo_attribution': 'Jane D',
    },
    {
      'name': 'Setas de Sevilla',
      'place_id': 'p2',
      'address': 'Pl. de la Encarnación',
      'lat': 37.393,
      'lng': -5.991,
      'category': 'attraction',
    },
  ],
});

void main() {
  test('places event parses into state with query label', () async {
    final notifier =
        PlanNotifier(_ScriptedPlanService([_placesEvent]), ApiClient());
    await notifier.sendMessage('where to eat?');

    final places = notifier.state.places;
    expect(places, isNotNull);
    expect(places!.length, 2);
    expect(notifier.state.placesQuery, 'tapas in seville');

    final first = places.first;
    expect(first.name, 'Bar El Comercio');
    expect(first.placeId, 'p1');
    expect(first.address, 'Calle Lineros 9');
    expect(first.lat, 37.39);
    expect(first.lng, -5.99);
    expect(first.rating, 4.5);
    expect(first.priceLevel, 1);
    expect(first.category, 'restaurant');
    expect(first.photoRef, 'REF-1');
    expect(first.photoAttribution, 'Jane D');

    // Optional fields absent on the wire come back as safe defaults.
    final second = places[1];
    expect(second.photoRef, '');
    expect(second.rating, isNull);
  });

  test('a later places event in the same turn wins whole (replaced list)',
      () async {
    const second = PlanEvent(type: 'places', data: {
      'query': 'cafes',
      'places': [
        {'name': 'Cafe Uno', 'place_id': 'c1', 'lat': 1.0, 'lng': 2.0},
      ],
    });
    final notifier = PlanNotifier(
        _ScriptedPlanService([_placesEvent, second]), ApiClient());
    await notifier.sendMessage('food then coffee');

    expect(notifier.state.places!.single.name, 'Cafe Uno');
    expect(notifier.state.placesQuery, 'cafes');
  });

  test('next send clears the previous strip (per-turn slot)', () async {
    final service = _ScriptedPlanService([_placesEvent]);
    final notifier = PlanNotifier(service, ApiClient());
    await notifier.sendMessage('where to eat?');
    expect(notifier.state.places, isNotNull);

    service.events.clear();
    await notifier.sendMessage('thanks!');
    expect(notifier.state.places, isNull);
    expect(notifier.state.placesQuery, isNull);
  });

  test('places survives a non-itinerary turn after the stream closes',
      () async {
    final notifier =
        PlanNotifier(_ScriptedPlanService([_placesEvent]), ApiClient());
    await notifier.sendMessage('where to eat?');
    expect(notifier.state.isStreaming, isFalse);
    expect(notifier.state.places, isNotNull);
  });

  test('itinerary turn suppresses the strip: places then done', () async {
    final notifier = PlanNotifier(
        _ScriptedPlanService([
          _placesEvent,
          const PlanEvent(type: 'done', data: {'locations': [], 'summary': ''}),
        ]),
        ApiClient());
    await notifier.sendMessage('plan seville');
    expect(notifier.state.places, isNull);
    expect(notifier.state.placesQuery, isNull);
  });

  test('itinerary turn suppresses the strip: done then places', () async {
    final notifier = PlanNotifier(
        _ScriptedPlanService([
          const PlanEvent(type: 'done', data: {'locations': [], 'summary': ''}),
          _placesEvent,
        ]),
        ApiClient());
    await notifier.sendMessage('plan seville');
    expect(notifier.state.places, isNull);
  });

  test('itinerary turn suppresses the strip: places then trip_updated',
      () async {
    final notifier = PlanNotifier(
        _ScriptedPlanService([
          _placesEvent,
          const PlanEvent(type: 'trip_updated', data: {}),
        ]),
        ApiClient(),
        tripId: 't1');
    await notifier.sendMessage('add a tapas stop');
    expect(notifier.state.places, isNull);
  });

  test('local_recs photo fields ride along onto the model', () async {
    final notifier = PlanNotifier(
        _ScriptedPlanService([
          const PlanEvent(type: 'local_recs', data: {
            'city': 'Athens',
            'recommendations': [
              {
                'id': 'r1',
                'name': 'Ta Karamanlidika',
                'source_name': 'Eleni',
                'tags': <String>[],
                'photo_ref': 'REF-venue',
                'photo_attribution': 'Local Snapper',
              },
              {
                'id': 'r2',
                'name': 'No Photo Spot',
                'source_name': 'Eleni',
                'tags': <String>[],
              },
            ],
          }),
        ]),
        ApiClient());
    await notifier.sendMessage('local tips?');

    final recs = notifier.state.localRecs!;
    expect(recs.first.photoRef, 'REF-venue');
    expect(recs.first.photoAttribution, 'Local Snapper');
    expect(recs[1].photoRef, '');
  });
}
