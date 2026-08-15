import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/theme/app_theme.dart';
import 'package:travel_route_planner/widgets/live_trip_card.dart';
import 'package:travel_route_planner/widgets/up_next_trip_card.dart';

import 'support/l10n_test_app.dart';

/// The shared promoted-trip card (widgets/trip_hero_card.dart) seen through
/// its two wrappers. The screen-level placement and dedupe live in
/// trips_list_live_test / trips_list_up_next_test; what's pinned here is the
/// policy that differs between the two heroes.
String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _rel(int days) => _iso(DateTime.now().add(Duration(days: days)));

Trip _trip({String? start, String? end, String? nextTransportDepart}) => Trip(
      id: 't1',
      title: 'Athens Trip',
      startDate: start,
      endDate: end,
      nextTransportDepart: nextTransportDepart,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

Future<void> _pump(WidgetTester tester, Widget card,
        {Locale? locale, ThemeData? theme}) =>
    tester.pumpWidget(
      ProviderScope(
        // TripMapBand reads the cache and collapses on the miss.
        overrides: [tripCacheProvider.overrideWithValue(TripCache('u1'))],
        child: localizedTestApp(
          home: Scaffold(body: card),
          locale: locale,
          theme: theme,
        ),
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the up-next hero raises the booking nudge',
      (WidgetTester tester) async {
    await _pump(
      tester,
      UpNextTripCard(
        trip: _trip(
            start: _rel(10), end: _rel(13), nextTransportDepart: _rel(5)),
        onTap: () {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('UP NEXT'), findsOneWidget);
    expect(find.textContaining('Book transport'), findsOneWidget);
  });

  testWidgets('a started trip never nudges — the copy is pre-departure',
      (WidgetTester tester) async {
    // Same window the up-next case passes on (a departure 2 days out), but
    // the traveler is on day 2: bookingNudgeDate gates only on the departure
    // being unbooked and near, so an unbooked RETURN leg reaches it — and
    // "first leg departs …" is then simply false.
    await _pump(
      tester,
      LiveTripCard(
        trip:
            _trip(start: _rel(-1), end: _rel(3), nextTransportDepart: _rel(2)),
        onTap: () {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('HAPPENING NOW'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.textContaining('Book transport'), findsNothing);
  });

  testWidgets('every fact at once survives a 360px phone in Spanish, dark',
      (WidgetTester tester) async {
    // The hero took on the plain card's whole fact set, so its meta row can
    // now run to nine labels. This is the density guard: a Wrap run that
    // overflowed would fail the pump outright, and es is the long-string
    // locale. Dark mode rides along — the pills are alpha-white on the
    // gradient either way, and this catches a theme-dependent regression.
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pump(
      tester,
      LiveTripCard(
        trip: Trip(
          id: 't1',
          title: 'Gran Aventura de Verano',
          summary: 'Tres días de ruinas, café y mercados.',
          startDate: _rel(-1),
          endDate: _rel(3),
          cities: const ['Atenas', 'El Pireo', 'Salónica'],
          itemCount: 63,
          bookingTotal: 18,
          bookingBooked: 5,
          stayTotal: 4,
          packingTotal: 20,
          packingDone: 12,
          budgetTarget: 800,
          budgetSpent: 540,
          budgetCurrency: 'EUR',
          shared: true,
          createdAt: '2026-06-01',
          updatedAt: '2026-06-01',
        ),
        onTap: () {},
      ),
      locale: const Locale('es'),
      theme: AppTheme.dark,
    );
    await tester.pumpAndSettle();

    expect(find.text('SUCEDIENDO AHORA'), findsOneWidget);
    expect(find.text('En curso'), findsOneWidget);
    expect(find.text('5/18 reservados'), findsOneWidget);
    expect(find.text('12/20 en la maleta'), findsOneWidget);
    expect(find.text('63 lugares'), findsOneWidget);
    expect(find.text('Compartido'), findsOneWidget);
  });
}
