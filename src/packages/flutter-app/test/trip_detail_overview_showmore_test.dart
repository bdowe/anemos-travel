import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/l10n_test_app.dart';

/// Header overview "Show more": the toggle must track what the collapsed
/// 2-line clamp actually clips at the laid-out width, not a character count.
/// Regression coverage for BOTH failure directions of the old `length > 140`
/// heuristic: a long summary that fits on a wide window got a dead toggle,
/// and a short newline-heavy one clipped with no toggle at all.
class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// 150 chars (> the old 140 gate), no newlines, longest word 9 chars — fits
/// the 2-line clamp at the wide surface under _shrinkText, clips on a phone.
const _fittingSummary =
    'Ten days across Andalusia with slow mornings, tapas crawls, palaces, '
    'patios, flamenco, day trips to Ronda and Cadiz, and one lazy beach day '
    'to finish.';

/// 56 chars (≪ 140) but three hard lines, each short enough (≤ 23 chars)
/// never to soft-wrap even at phone width — clips the 2-line clamp while the
/// old heuristic saw "short text" and hid the toggle.
const _newlineSummary = 'Pack light.\nBook the Alcazar early.\n'
    'Eat at Casa Morales.';

Trip _trip(String summary) => Trip(
      id: 't1',
      title: 'Sevilla week',
      summary: summary,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: '2026-09-01',
      endDate: '2026-09-03',
      items: [
        ItineraryItem(
          id: 'i0',
          position: 0,
          name: 'Real Alcázar',
          // Zero coords so the screen skips the map widget in the test env.
          latitude: 0,
          longitude: 0,
          category: 'attraction',
          day: 1,
          city: 'Sevilla',
        ),
      ],
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
      child: localizedTestApp(home: const TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

/// Halves text so a >140-char summary can FIT the wide 2-line clamp: at
/// scale 1.0 the header's 900px content cap holds only ~126 test-font chars
/// in two lines, so every >140-char string would clip and the no-toggle
/// assertion would be vacuous (old and new code agree). Also exercises the
/// textScaler-aware measurement path in _collapsedClips.
void _shrinkText(WidgetTester tester) {
  tester.platformDispatcher.textScaleFactorTestValue = 0.5;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  const phone = Size(390, 844);
  const wide = Size(1000, 800);

  testWidgets('no toggle when a >140-char summary fits the 2-line clamp',
      (WidgetTester tester) async {
    expect(_fittingSummary.length, greaterThan(140)); // old-code trigger
    _shrinkText(tester);
    await _pump(tester, _trip(_fittingSummary), surface: wide);

    expect(find.text(_fittingSummary), findsOneWidget); // anti-vacuity
    expect(find.text('Show more'), findsNothing);
    expect(find.text('Show less'), findsNothing);
  });

  testWidgets('same summary on a phone clips: toggle shows and expands',
      (WidgetTester tester) async {
    await _pump(tester, _trip(_fittingSummary), surface: phone);

    expect(find.text('Show more'), findsOneWidget);
    final collapsed = tester.getSize(find.text(_fittingSummary)).height;

    await tester.tap(find.text('Show more'));
    await tester.pumpAndSettle();
    expect(find.text('Show less'), findsOneWidget);
    // The expanded text really renders more lines — kills "toggle flips but
    // nothing changes".
    expect(tester.getSize(find.text(_fittingSummary)).height,
        greaterThan(collapsed));

    await tester.tap(find.text('Show less'));
    await tester.pumpAndSettle();
    expect(find.text('Show more'), findsOneWidget);
    expect(tester.getSize(find.text(_fittingSummary)).height, collapsed);
  });

  testWidgets('short newline-heavy summary (<140 chars) still gets a toggle',
      (WidgetTester tester) async {
    expect(_newlineSummary.length, lessThan(140)); // old code hid the toggle
    await _pump(tester, _trip(_newlineSummary), surface: phone);

    expect(find.text('Show more'), findsOneWidget);
    final collapsed = tester.getSize(find.text(_newlineSummary)).height;
    await tester.tap(find.text('Show more'));
    await tester.pumpAndSettle();
    expect(find.text('Show less'), findsOneWidget);
    expect(tester.getSize(find.text(_newlineSummary)).height,
        greaterThan(collapsed)); // 2 lines -> 3 lines
  });

  testWidgets('stale expanded state is harmless once the text fits',
      (WidgetTester tester) async {
    _shrinkText(tester);
    await _pump(tester, _trip(_fittingSummary), surface: phone);

    await tester.tap(find.text('Show more')); // clips at 390 even at 0.5
    await tester.pumpAndSettle();
    expect(find.text('Show less'), findsOneWidget);

    await tester.binding.setSurfaceSize(wide); // now fits the clamp
    await tester.pumpAndSettle();
    expect(find.text('Show less'), findsNothing);
    expect(find.text('Show more'), findsNothing);
    expect(find.text(_fittingSummary), findsOneWidget);
  });
}
