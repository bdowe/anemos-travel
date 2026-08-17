import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/booking_todo_card.dart';

import 'support/l10n_test_app.dart';

/// Mobile declutter: at body width < 800 the item rows keep only the
/// time glyph + kebab (viewers: glyph + maps button), booking rows use short
/// open-labels, and drag handles disappear (kebab Move up/down remains).
/// Desktop (>= 800) keeps the pre-declutter affordances — pinned by the
/// threshold test at the bottom.
class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

ItineraryItem _item(int pos, String name, String category,
        {int? day, String? city, String? timeOfDay, String? address}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: address,
      // Zero coords: the map stays unmounted, keeping these tests about rows.
      latitude: 0,
      longitude: 0,
      category: category,
      day: day,
      city: city,
      timeOfDay: timeOfDay,
    );

Trip _trip({String? access}) => Trip(
      id: 't1',
      title: 'Sevilla week',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: '2026-09-01',
      endDate: '2026-09-03',
      access: access,
      items: [
        _item(0, 'Real Alcázar', 'attraction',
            day: 1,
            city: 'Sevilla',
            timeOfDay: 'morning',
            address: 'Patio de Banderas, Sevilla'),
        _item(1, 'Bodega Santa Cruz', 'restaurant',
            day: 1,
            city: 'Sevilla',
            timeOfDay: 'evening',
            address: 'C. Rodrigo Caro 1, Sevilla'),
      ],
      bookingTodos: access == null
          ? [
              BookingTodo(
                id: 'stay:sevilla',
                kind: 'stay',
                todoKey: 'stay:sevilla',
                title: 'Stay in Sevilla',
                auto: true,
                provider: 'airbnb',
              ),
            ]
          : null, // the server withholds todos from viewers
    );

Future<void> _pump(WidgetTester tester, Trip trip,
    {required Size surface}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: const TripDetailScreen(tripId: 't1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Finders scoped INSIDE item tiles: the app bar, booking rows, and section
/// headers also carry popups/icons, so bare byIcon finders over-match.
Finder _inTiles(Finder inner) =>
    find.descendant(of: find.byType(ListTile), matching: inner);

void main() {
  const phone = Size(390, 844);

  testWidgets('narrow editor rows: glyph + kebab only; kebab reaches Maps',
      (tester) async {
    await _pump(tester, _trip(), surface: phone);

    // No standalone maps button, no drag handle inside the tiles.
    expect(_inTiles(find.byIcon(Icons.map_outlined)), findsNothing);
    expect(_inTiles(find.byIcon(Icons.drag_indicator)), findsNothing);
    // Kebab present per row.
    expect(_inTiles(find.byIcon(Icons.more_vert)), findsNWidgets(2));
    // Icon-only time glyphs: icons render, labels don't.
    expect(_inTiles(find.byIcon(Icons.wb_twilight)), findsOneWidget);
    expect(_inTiles(find.byIcon(Icons.nightlight_outlined)), findsOneWidget);
    expect(find.text('Morning'), findsNothing);
    expect(find.text('Evening'), findsNothing);
    // The glyph tooltip carries the label.
    expect(
      _inTiles(find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'Morning')),
      findsOneWidget,
    );

    // The kebab menu contains the Maps entry.
    await tester.tap(_inTiles(find.byIcon(Icons.more_vert)).first);
    await tester.pumpAndSettle();
    expect(find.text('Open in Google Maps'), findsOneWidget);
    expect(find.text('Move down'), findsOneWidget); // reorder path survives
    await tester.tapAt(const Offset(5, 5)); // dismiss
    await tester.pumpAndSettle();
  });

  testWidgets('narrow viewer rows: maps button stays, no kebab, no sparkle',
      (tester) async {
    await _pump(tester, _trip(access: 'viewer'), surface: phone);

    expect(_inTiles(find.byIcon(Icons.map_outlined)), findsNWidgets(2));
    expect(_inTiles(find.byIcon(Icons.more_vert)), findsNothing);
    expect(find.byIcon(Icons.auto_awesome), findsNothing);
    expect(find.text('Refine with AI'), findsNothing);
  });

  testWidgets('narrow booking row: short label, checkbox stays last',
      (tester) async {
    await _pump(tester, _trip(), surface: phone);

    final row = find.byType(BookingTodoRow);
    expect(row, findsOneWidget);
    // Short brand label, not the full "Open in Airbnb".
    expect(find.descendant(of: row, matching: find.text('Airbnb')),
        findsOneWidget);
    expect(find.textContaining('Open in'), findsNothing);
    // Checkbox is the rightmost element of the row.
    final checkboxRight = tester
        .getTopRight(find.descendant(of: row, matching: find.byType(Checkbox)))
        .dx;
    final rowRight = tester.getTopRight(row).dx;
    expect(rowRight - checkboxRight, lessThan(24));
  });

  testWidgets('overflow floor: long content at 360px renders without errors',
      (tester) async {
    final trip = Trip(
      id: 't1',
      title: 'A very long trip title that will need to ellipsize somewhere',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: '2026-09-01',
      endDate: '2026-09-03',
      items: [
        _item(0,
            'Basílica de la Sagrada Família and its towers with a very long name',
            'attraction',
            day: 1,
            city: 'Barcelona',
            timeOfDay: 'afternoon',
            address:
                'Carrer de Mallorca, 401, L\'Eixample, 08013 Barcelona, Spain'),
      ],
      bookingTodos: [
        BookingTodo(
          id: 'stay:barcelona',
          kind: 'stay',
          todoKey: 'stay:barcelona',
          title: 'Stay in Barcelona for the whole long weekend period',
          auto: true,
          provider: 'booking',
        ),
      ],
    );
    await _pump(tester, trip, surface: const Size(360, 690));
    // Widget tests rethrow RenderFlex overflows at test end automatically —
    // reaching this line with a clean settle IS the assertion.
    expect(tester.takeException(), isNull);
  });

  testWidgets('threshold: 800 keeps desktop affordances, 799 flips to narrow',
      (tester) async {
    // The app bar's own tell used to be the refine sparkle: absent at 800,
    // present at 799. Refine no longer holds an icon at any width — it moved
    // into the `⋮` so the trip's name could have those ~48px — so the tell is
    // now share, which keeps its icon at 800 and folds below it.
    final shareIcon = find.byIcon(Icons.share_outlined);

    await _pump(tester, _trip(), surface: const Size(800, 900));
    // Desktop: maps button + full chip labels + header Refine + share icon.
    expect(_inTiles(find.byIcon(Icons.map_outlined)), findsNWidgets(2));
    expect(find.text('Morning'), findsOneWidget);
    expect(find.text('Refine with AI'), findsOneWidget);
    expect(shareIcon, findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(799, 900));
    await tester.pumpAndSettle();
    expect(_inTiles(find.byIcon(Icons.map_outlined)), findsNothing);
    expect(find.text('Morning'), findsNothing);
    expect(find.text('Refine with AI'), findsNothing);
    expect(shareIcon, findsNothing);
    // Refine has no icon on either side of the threshold now, so this says
    // "it did not sneak back", not "it flipped".
    expect(find.byTooltip('Refine with AI'), findsNothing);
  });
}
