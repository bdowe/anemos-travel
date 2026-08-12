import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/map_leg_chips.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/l10n_test_app.dart';

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Real coordinates so the trip detail screen mounts a live TripMap instead
/// of skipping it.
ItineraryItem _item(
  int pos,
  String name,
  String city,
  double lat,
  double lng,
  int day,
) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      latitude: lat,
      longitude: lng,
      category: 'attraction',
      day: day,
      city: city,
    );

void main() {
  // Paris (days 1-2, geocoded, stay-anchored Sep 1–3) → Rome (day 3,
  // geocoded) → Berlin (day 5, UNgeocoded, no stay) — Berlin exercises the
  // muted chip and the focused-leg empty state.
  final trip = Trip(
    id: 't1',
    title: 'Paris, Rome & Berlin',
    createdAt: '2026-06-01',
    updatedAt: '2026-06-01',
    startDate: '2026-09-01',
    endDate: '2026-09-05',
    items: [
      _item(0, 'Louvre', 'Paris', 48.8606, 2.3376, 1),
      _item(1, 'Orsay', 'Paris', 48.8600, 2.3266, 2),
      _item(2, 'Colosseum', 'Rome', 41.8902, 12.4922, 3),
      _item(3, 'Berlin Walk', 'Berlin', 0, 0, 5),
    ],
    accommodations: const [
      // Anchors Paris to Sep 1–3 (nights Sep 1 + Sep 2).
      Accommodation(
        id: 'a1',
        name: 'Paris Hotel',
        address: 'Rue X, Paris',
        latitude: 48.8630,
        longitude: 2.3364,
        checkIn: '2026-09-01',
        checkOut: '2026-09-03',
      ),
    ],
  );

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        ],
        child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Taps the chip labelled [label] inside the map's chip row (the itinerary
  /// list renders the same city names as group headers, so the find must be
  /// scoped to MapLegChips).
  Future<void> tapChip(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byType(MapLegChips),
      matching: find.text(label),
    ));
    // A chip tap kicks a post-frame camera re-fit AND (on the wide layout)
    // a 350ms page scroll to the focused city header — settle both before
    // asserting or tapping again.
    await tester.pumpAndSettle();
  }

  TripMap map(WidgetTester tester) =>
      tester.widget<TripMap>(find.byType(TripMap));

  testWidgets('renders All + one chip per city leg over the map',
      (WidgetTester tester) async {
    await pumpScreen(tester);

    final chips = find.byType(MapLegChips);
    expect(chips, findsOneWidget);
    for (final label in ['All', 'Paris', 'Rome', 'Berlin']) {
      expect(
        find.descendant(of: chips, matching: find.text(label)),
        findsOneWidget,
      );
    }
    // Day chips are gone from the map strip.
    expect(find.descendant(of: chips, matching: find.text('Day 1')),
        findsNothing);

    // All is the default: the map sees the whole trip.
    expect(map(tester).items, hasLength(4));
    expect(map(tester).accommodations, hasLength(1));
    expect(map(tester).fitSignature, isNull);
  });

  testWidgets('a city chip filters the map to that leg and its stays; '
      'All restores', (WidgetTester tester) async {
    await pumpScreen(tester);

    await tapChip(tester, 'Paris');

    expect(map(tester).items.map((i) => i.name), ['Louvre', 'Orsay']);
    expect(map(tester).accommodations.map((a) => a.name), ['Paris Hotel']);
    expect(map(tester).fitSignature, 'Paris');

    await tapChip(tester, 'Rome');

    expect(map(tester).items.map((i) => i.name), ['Colosseum']);
    // Rome's range holds no night the Paris stay covers.
    expect(map(tester).accommodations, isEmpty);
    expect(map(tester).fitSignature, 'Rome');

    await tapChip(tester, 'All');

    expect(map(tester).fitSignature, isNull);
    expect(map(tester).items, hasLength(4));
    expect(map(tester).accommodations, hasLength(1));
  });

  testWidgets('a leg with nothing mappable shows the on-map empty state '
      'with an Add place CTA while the chips stay',
      (WidgetTester tester) async {
    await pumpScreen(tester);

    await tapChip(tester, 'Berlin');

    // The leg's item is ungeocoded — passed through but unmappable.
    expect(map(tester).items.map((i) => i.name), ['Berlin Walk']);
    expect(map(tester).accommodations, isEmpty);
    expect(find.text('No places pinned in Berlin'), findsOneWidget);
    // The editable screen gets the CTA on the map itself (the itinerary
    // header has its own same-label button outside the map).
    expect(
      find.descendant(
        of: find.byType(TripMap),
        matching: find.text('Add place'),
      ),
      findsOneWidget,
    );
    // The chip row survives the empty selection and can navigate back out.
    expect(find.byType(MapLegChips), findsOneWidget);

    await tapChip(tester, 'All');
    expect(find.text('No places pinned in Berlin'), findsNothing);
    expect(map(tester).items, hasLength(4));
  });

  testWidgets('the empty-leg CTA opens Add place with its day preselected',
      (WidgetTester tester) async {
    await pumpScreen(tester);
    await tapChip(tester, 'Berlin');

    await tester.tap(find.descendant(
      of: find.byType(TripMap),
      matching: find.text('Add place'),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    // Berlin's sole item is tagged day 5, so the focused-leg add preselects
    // it. Asserted via the form field's value — the dropdown renders every
    // item's text offstage, so a text find would pass vacuously.
    final dayField = tester.state<FormFieldState<int?>>(
        find.byType(DropdownButtonFormField<int?>));
    expect(dayField.value, 5);
  });

  testWidgets('chips for legs with nothing mappable render muted but stay '
      'tappable', (WidgetTester tester) async {
    await pumpScreen(tester);

    ChoiceChip chipFor(String label) => tester.widget<ChoiceChip>(
          find.ancestor(
            of: find.descendant(
              of: find.byType(MapLegChips),
              matching: find.text(label),
            ),
            matching: find.byType(ChoiceChip),
          ),
        );

    // Berlin has no geocoded item and no covering stay; the rest plot.
    expect(chipFor('Berlin').labelStyle?.color, Colors.white60);
    expect(chipFor('Paris').labelStyle?.color, Colors.white);
    expect(chipFor('Rome').labelStyle?.color, Colors.white);
    expect(chipFor('All').labelStyle?.color, Colors.white);

    // Selecting the muted chip restores the full treatment (the ring says
    // "you are here"; the map's empty state says empty).
    await tapChip(tester, 'Berlin');
    expect(chipFor('Berlin').labelStyle?.color, Colors.white);
    expect(chipFor('Berlin').selected, isTrue);
  });
}
