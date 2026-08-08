import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/airport.dart';
import 'package:travel_route_planner/models/flight_leg.dart';
import 'package:travel_route_planner/models/flight_offer.dart';
import 'package:travel_route_planner/models/flight_search_request.dart';
import 'package:travel_route_planner/models/flight_search_response.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/flights_provider.dart';
import 'package:travel_route_planner/screens/flight_search_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/flights_api_service.dart';
import 'package:travel_route_planner/widgets/airport_field.dart';
import 'package:travel_route_planner/widgets/flight_offer_card.dart';

import 'support/l10n_test_app.dart';

// ---------------------------------------------------------------------------
// Fakes (provider-fake pattern from flight_round_trip_test.dart)
// ---------------------------------------------------------------------------

class _FakeAuthNotifier extends StateNotifier<AuthState>
    implements AuthNotifier {
  _FakeAuthNotifier(UserModel? user)
      : super(AuthState(user: user, initialized: true));

  @override
  void clearError() => state = state.copyWith(clearError: true);

  @override
  Future<bool> login(String email, String password) async => false;
  @override
  Future<bool> register(String email, String password,
          {String? displayName}) async =>
      false;
  @override
  Future<void> completeOnboarding() async {}
  @override
  Future<void> logout() async {}
  @override
  Future<void> signOutLocally() async {}
  @override
  void setUser(UserModel user) {}
  @override
  Future<void> adoptSession(String token, UserModel user) async {}
}

/// Captures every search; fails while [failuresRemaining] > 0, then answers
/// with one offer. Airport lookups return two fixed suggestions so the inline
/// dropdown has rows to open.
class _FakeFlightsApiService extends FlightsApiService {
  final List<FlightSearchRequest> requests = [];
  int failuresRemaining;
  _FakeFlightsApiService({this.failuresRemaining = 0})
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<FlightSearchResponse> searchFlights(
      FlightSearchRequest request) async {
    requests.add(request);
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw Exception('boom');
    }
    final offer = _roundTripOffer();
    return FlightSearchResponse(
      offers: [offer],
      bestOfferId: offer.id,
      optimizeFor: request.optimizeFor,
      count: 1,
      status: 'success',
    );
  }

  @override
  Future<List<Airport>> searchAirports(String query) async => const [
        Airport(
            iataCode: 'CDG',
            name: 'Charles de Gaulle',
            city: 'Paris',
            country: 'France',
            subType: 'airport'),
        Airport(
            iataCode: 'ORY',
            name: 'Orly',
            city: 'Paris',
            country: 'France',
            subType: 'airport'),
      ];
}

const _outboundLegA = FlightLeg(
  from: 'JFK',
  to: 'LIS',
  carrier: 'TAP Air Portugal',
  flightNumber: 'TP204',
  departTime: '2026-09-01T18:00:00',
  arriveTime: '2026-09-02T05:30:00',
);

const _outboundLegB = FlightLeg(
  from: 'LIS',
  to: 'CDG',
  carrier: 'TAP Air Portugal',
  flightNumber: 'TP440',
  departTime: '2026-09-02T08:00:00',
  arriveTime: '2026-09-02T11:30:00',
);

const _returnLegA = FlightLeg(
  from: 'CDG',
  to: 'MAD',
  carrier: 'Iberia',
  flightNumber: 'IB3403',
  departTime: '2026-09-10T09:00:00',
  arriveTime: '2026-09-10T11:05:00',
);

const _returnLegB = FlightLeg(
  from: 'MAD',
  to: 'LIS',
  carrier: 'Iberia',
  flightNumber: 'IB3106',
  departTime: '2026-09-10T13:00:00',
  arriveTime: '2026-09-10T14:10:00',
);

const _returnLegC = FlightLeg(
  from: 'LIS',
  to: 'JFK',
  carrier: 'TAP Air Portugal',
  flightNumber: 'TP203',
  departTime: '2026-09-10T16:30:00',
  arriveTime: '2026-09-10T19:45:00',
);

/// A worst-case-width round trip: "12h 30m + 14h 5m" durations and split
/// Spanish stops ("1 escala / 2 escalas").
FlightOffer _roundTripOffer() => const FlightOffer(
      id: 'off_rt',
      price: 842,
      currency: 'USD',
      stops: 1,
      durationMinutes: 750,
      airlines: ['TAP Air Portugal'],
      departTime: '2026-09-01T18:00:00',
      arriveTime: '2026-09-02T11:30:00',
      segments: [_outboundLegA, _outboundLegB],
      returnSegments: [_returnLegA, _returnLegB, _returnLegC],
      returnDurationMinutes: 845,
      bookingUrl: 'https://example.com/book',
    );

String _fmt(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Future<void> _setSurface(WidgetTester tester, Size s) async {
  await tester.binding.setSurfaceSize(s);
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Future<_FakeFlightsApiService> _pumpScreen(
  WidgetTester tester, {
  Locale? locale,
  bool prefill = false,
  int failuresRemaining = 0,
}) async {
  final flights = _FakeFlightsApiService(failuresRemaining: failuresRemaining);
  final depart = _fmt(DateTime.now().add(const Duration(days: 30)));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      flightsApiServiceProvider.overrideWithValue(flights),
      // Anonymous: keeps the signed-in-only "Watch this route" row out of
      // these layout/state tests.
      authProvider.overrideWith((ref) => _FakeAuthNotifier(null)),
    ],
    child: localizedTestApp(
      locale: locale,
      home: prefill
          ? FlightSearchScreen(
              prefillOrigin: 'JFK',
              prefillDestination: 'CDG',
              prefillDepartDate: depart,
            )
          : const FlightSearchScreen(),
    ),
  ));
  await tester.pumpAndSettle();
  return flights;
}

void main() {
  testWidgets(
      'overflow floor: 360x690 es, form expanded, children row and open '
      'airport suggestions — no exception', (tester) async {
    await _setSurface(tester, const Size(360, 690));
    await _pumpScreen(tester, locale: const Locale('es'));

    // Form starts expanded (no search yet).
    expect(find.byType(AirportField), findsNWidgets(2));

    // Add a child so the per-child age picker row renders.
    await tester.tap(find.byTooltip('Añadir niño'));
    await tester.pumpAndSettle();
    expect(find.text('Niño 1'), findsOneWidget);

    // Open the origin autocomplete's inline suggestion list.
    await tester.enterText(
      find.descendant(
          of: find.byType(AirportField).first,
          matching: find.byType(TextField)),
      'par',
    );
    // The field debounces the provider-feeding query by 350 ms.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('Paris (CDG)'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'successful search collapses the form to a summary with the first '
      'offer on screen; expanding restores the fields', (tester) async {
    await _setSurface(tester, const Size(800, 1400));
    await _pumpScreen(tester, prefill: true);

    // Auto-collapsed after the prefill auto-search: summary row + results,
    // no form fields.
    expect(find.text('Edit search'), findsOneWidget);
    expect(find.textContaining('JFK → CDG'), findsOneWidget);
    expect(find.byType(AirportField), findsNothing);
    expect(find.byType(FlightOfferCard), findsOneWidget);
    // The first offer really is on screen, not just built.
    expect(tester.getRect(find.byType(FlightOfferCard)).top, lessThan(1400));

    // Expand back to edit.
    await tester.tap(find.text('Edit search'));
    await tester.pumpAndSettle();
    expect(find.byType(AirportField), findsNWidgets(2));
    expect(find.text('Search Flights'), findsOneWidget);
  });

  testWidgets(
      'failed search shows EmptyState with Retry that re-runs the '
      'last request', (tester) async {
    await _setSurface(tester, const Size(800, 1800));
    final flights =
        await _pumpScreen(tester, prefill: true, failuresRemaining: 1);

    // Error state: shared EmptyState, form kept open for fixing inputs.
    expect(flights.requests, hasLength(1));
    expect(find.text('Could not load flights'), findsOneWidget);
    expect(find.byType(AirportField), findsNWidgets(2));

    await tester.ensureVisible(find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    // Retry re-sent the same request, and this time results rendered.
    expect(flights.requests, hasLength(2));
    expect(flights.requests.last.origin, 'JFK');
    expect(flights.requests.last.destination, 'CDG');
    expect(find.byType(FlightOfferCard), findsOneWidget);
    expect(find.text('Edit search'), findsOneWidget);
  });

  testWidgets('offer card stats row survives 360px with a long es round trip',
      (tester) async {
    await _setSurface(tester, const Size(360, 690));
    await tester.pumpWidget(localizedTestApp(
      locale: const Locale('es'),
      home: Scaffold(
        body: FlightOfferCard(
          offer: _roundTripOffer(),
          isBest: true,
          savingsLabel: 'Ahorras US\$23 frente a la siguiente opción',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('12h 30m + 14h 5m'), findsOneWidget);
    expect(find.text('MEJOR OPCIÓN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop 1200px: results column stays capped and centered',
      (tester) async {
    await _setSurface(tester, const Size(1200, 900));
    await _pumpScreen(tester, prefill: true);

    final card = find.byType(FlightOfferCard);
    expect(card, findsOneWidget);
    expect(tester.getSize(card).width, lessThanOrEqualTo(700));
    final left = tester.getTopLeft(card).dx;
    final right = 1200 - tester.getTopRight(card).dx;
    expect((left - right).abs(), lessThan(2));
  });
}
