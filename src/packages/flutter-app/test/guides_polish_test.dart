import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'package:travel_route_planner/models/event.dart';
import 'package:travel_route_planner/models/local_guide.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/local_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/guides_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/add_to_trip_sheet.dart';
import 'package:travel_route_planner/widgets/event_card.dart';
import 'package:travel_route_planner/widgets/section_header.dart';

import 'support/l10n_test_app.dart';

const _guide = LocalGuide(
  id: 'g1',
  title: 'Ana\'s Alfama',
  city: 'Lisbon',
  sourceName: 'Ana',
);

/// Serves a fixed trip list/detail so the sheet can open without a network.
class _FakeTripsApiService extends TripsApiService {
  final List<Trip> trips;
  final Trip detail;

  _FakeTripsApiService({required this.trips, required this.detail})
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() async => trips;

  @override
  Future<Trip> getTrip(String id) async => detail;
}

Trip _trip() => Trip(
      id: 't1',
      title: 'Lisbon Trip',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: const [],
    );

void main() {
  testWidgets(
      'guides error branch shows the localized message and Retry refetches',
      (WidgetTester tester) async {
    var calls = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allGuidesProvider.overrideWith((ref) async {
            calls++;
            if (calls == 1) throw Exception('DioException [connection error]');
            return const [_guide];
          }),
        ],
        child: localizedTestApp(
          home: const GuidesScreen(),
          locale: const Locale('es'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Localized fixed copy — never the raw exception.
    expect(find.text('No se pudieron cargar las guías'), findsOneWidget);
    expect(find.text('Comprueba tu conexión e inténtalo de nuevo.'),
        findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
    expect(find.textContaining('DioException'), findsNothing);

    // Retry refetches: the second load succeeds and the list renders,
    // with the city group as a SectionHeader.
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('Ana\'s Alfama'), findsOneWidget);
    expect(find.widgetWithText(SectionHeader, 'Lisbon'), findsOneWidget);
  });

  testWidgets('guides list survives a narrow Spanish viewport',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 690));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const longGuide = LocalGuide(
      id: 'g2',
      title:
          'Una caminata larguísima por los miradores escondidos de la ciudad vieja',
      city: 'San Cristóbal de las Casas',
      neighborhood: 'Barrio de Guadalupe y alrededores',
      sourceName: 'María de los Ángeles Fernández',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allGuidesProvider.overrideWith((ref) async => const [longGuide]),
        ],
        child: localizedTestApp(
          home: const GuidesScreen(),
          locale: const Locale('es'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('caminata larguísima'), findsOneWidget);
  });

  testWidgets('EventCard renders Spanish month/weekday under es locale',
      (WidgetTester tester) async {
    // The locale provider does this in the real app; widget tests set the
    // intl default explicitly (same pattern as locale_provider_test.dart).
    await initializeDateFormatting('es');
    Intl.defaultLocale = 'es';
    addTearDown(() => Intl.defaultLocale = null);

    const event = Event(
      id: 'e1',
      name: 'Fado Night',
      venue: 'Casa do Fado',
      startDate: '2026-08-12', // a Wednesday
      startTime: '20:00',
      url: 'https://tickets.example/e1',
    );
    await tester.pumpWidget(localizedTestApp(
      home: const Scaffold(body: EventCard(event: event)),
      locale: const Locale('es'),
    ));
    await tester.pumpAndSettle();

    // Spanish abbreviations ("mié" / "ago"), not the old hardcoded English.
    expect(find.textContaining('ago'), findsOneWidget);
    expect(find.textContaining('mié'), findsOneWidget);
    expect(find.textContaining('Aug'), findsNothing);
    expect(find.textContaining('Wed'), findsNothing);
    expect(find.textContaining('20:00'), findsOneWidget);
  });

  testWidgets('EventCard keeps the English label shape by default',
      (WidgetTester tester) async {
    const event = Event(
      id: 'e2',
      name: 'Jazz Evening',
      startDate: '2026-08-12',
      startTime: '19:30',
    );
    await tester.pumpWidget(localizedTestApp(
      home: const Scaffold(body: EventCard(event: event)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Wed, Aug 12 · 19:30'), findsOneWidget);
  });

  testWidgets('add-to-trip sheet is width-capped on desktop',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = _FakeTripsApiService(trips: [_trip()], detail: _trip());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tripsApiServiceProvider.overrideWithValue(service)],
        child: localizedTestApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showAddToTripSheet(
                  context,
                  const AddToTripPayload(name: 'Tasca da Ana', source: 'event'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The sheet content is capped at 560, not the 1400px viewport. The
    // submit button stretches to the sheet's inner width, so its size is
    // the observable cap (BottomSheet applies `constraints` to its child).
    final buttonWidth = tester.getSize(find.byType(FilledButton)).width;
    expect(buttonWidth, lessThanOrEqualTo(560));
    expect(buttonWidth, greaterThan(400)); // sanity: still a wide sheet
  });
}
