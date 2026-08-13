import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip_finding.dart';
import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/services/trip_review_api_service.dart';
import 'package:travel_route_planner/services/accommodations_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/providers/trip_review_provider.dart';
import 'package:travel_route_planner/providers/accommodations_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/theme/app_colors.dart';
import 'package:travel_route_planner/widgets/empty_state.dart';
import 'package:travel_route_planner/widgets/trip_review_section.dart';

import 'support/l10n_test_app.dart';

/// The app-bar Trip health icon + calm attention badge (warn/critical count,
/// info-only dot) and the bottom-sheet modal it opens (showTripHealthSheet) —
/// the surface that replaced the trailing-cluster row (friction-log
/// 2026-08-12; calmed 2026-08-13).

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Review fake: serves [findings] until [resolved], then [resolvedFindings]
/// (default all-clear — tests that fix one finding among several set the
/// residual list instead); [error] makes every fetch throw (the viewer-404
/// analog — provider has no value); [hoursError] fails only the checkHours
/// variant (flaky hours backend).
class _FakeReviewApiService extends TripReviewApiService {
  final List<TripFinding> findings;
  bool resolved = false;
  List<TripFinding> resolvedFindings = const [];
  bool error = false;
  bool hoursError = false;

  _FakeReviewApiService(this.findings)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<TripReview> getReview(String tripId,
      {bool checkHours = false}) async {
    if (error) throw Exception('403');
    if (checkHours && hoursError) throw Exception('hours backend down');
    return TripReview(findings: List.of(resolved ? resolvedFindings : findings));
  }
}

/// First fetch fails transiently (503); later fetches serve the findings.
/// The provider's one-shot 30s invalidateSelf must restore the hidden icon
/// with no user action — the manual retry lives behind the icon itself.
class _TransientThenOkReviewApi extends _FakeReviewApiService {
  int calls = 0;
  _TransientThenOkReviewApi(super.findings);

  @override
  Future<TripReview> getReview(String tripId,
      {bool checkHours = false}) {
    calls++;
    if (calls == 1) {
      return Future.error(ApiException(
          statusCode: 503, message: 'shed', endpoint: 'review'));
    }
    return super.getReview(tripId, checkHours: checkHours);
  }
}

class _FakeAccommodationsApiService extends AccommodationsApiService {
  final List<Map<String, dynamic>> patches = [];
  bool failUpdate = false;
  _FakeAccommodationsApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Accommodation> update(
      String tripId, String accId, Map<String, dynamic> body) async {
    if (failUpdate) throw Exception('500');
    patches.add({'id': accId, ...body});
    return Accommodation(id: accId, name: 'Stay');
  }
}

Trip _trip() => Trip(
      id: 't1',
      title: 'Greece',
      startDate: '2026-08-01',
      endDate: '2026-08-05',
      createdAt: '2026-07-01',
      updatedAt: '2026-07-01',
      items: [
        ItineraryItem(
          id: 'i0',
          position: 0,
          name: 'Acropolis',
          address: 'Athens, Greece',
          latitude: 0,
          longitude: 0,
          category: 'attraction',
          day: 1,
        ),
      ],
    );

TripFinding _finding(String severity, String message, {int? day}) =>
    TripFinding(
      severity: severity,
      category: 'dates',
      message: message,
      tripId: 't1',
      day: day,
    );

Future<void> _pumpScreen(
  WidgetTester tester, {
  required _FakeReviewApiService review,
  _FakeAccommodationsApiService? accommodations,
  Size surface = const Size(800, 1000),
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(_trip())),
        tripReviewApiServiceProvider.overrideWithValue(review),
        if (accommodations != null)
          accommodationsApiServiceProvider.overrideWithValue(accommodations),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _healthIcon() => find.byTooltip('Trip health');

void main() {
  testWidgets('badge counts only the attention tier, colored by its severity',
      (tester) async {
    final review = _FakeReviewApiService([
      _finding('warn', 'No transport booked from Athens to Naxos.'),
      _finding('warn', 'No lodging for the night of Aug 3.'),
      _finding('info', 'Day 2 has nothing scheduled.'),
    ]);
    await _pumpScreen(tester, review: review);

    expect(_healthIcon(), findsOneWidget);
    // 2 warns + 1 info → the badge reads 2, never the raw total.
    expect(
        find.descendant(of: find.byType(Badge), matching: find.text('2')),
        findsOneWidget);
    expect(
        find.descendant(of: find.byType(Badge), matching: find.text('3')),
        findsNothing);
    // Worst severity is warn → the solid amber on-gradient pair.
    expect(tester.widget<Badge>(find.byType(Badge)).backgroundColor,
        AppColors.warningSolid);
  });

  testWidgets('info-only findings show a neutral dot, not a number',
      (tester) async {
    final review = _FakeReviewApiService([
      _finding('info', 'Day 2 has nothing scheduled.'),
      _finding('info', 'Hotel Delfini not booked yet.'),
    ]);
    await _pumpScreen(tester, review: review);

    // No label → Material renders the small-dot variant.
    final badge = tester.widget<Badge>(find.byType(Badge));
    expect(badge.label, isNull);
    expect(badge.backgroundColor, AppColors.neutralSolid);
    expect(
        find.descendant(of: find.byType(Badge), matching: find.text('2')),
        findsNothing);
  });

  testWidgets('badge semantics announce the tier, not a bare number',
      (tester) async {
    final handle = tester.ensureSemantics();
    final review = _FakeReviewApiService([
      _finding('warn', 'No transport booked from Athens to Naxos.'),
      _finding('warn', 'No lodging for the night of Aug 3.'),
    ]);
    await _pumpScreen(tester, review: review);
    // RegExp: the button's tooltip semantics may merge with the label node.
    expect(find.bySemanticsLabel(RegExp('2 items need attention')),
        findsOneWidget);
    handle.dispose();
  });

  testWidgets('dot badge semantics announce the suggestion count',
      (tester) async {
    final handle = tester.ensureSemantics();
    final review = _FakeReviewApiService([
      _finding('info', 'Day 2 has nothing scheduled.'),
      _finding('info', 'Hotel Delfini not booked yet.'),
    ]);
    await _pumpScreen(tester, review: review);
    expect(find.bySemanticsLabel(RegExp('2 suggestions available')),
        findsOneWidget);
    handle.dispose();
  });

  testWidgets('a critical finding turns the badge red', (tester) async {
    final review = _FakeReviewApiService([
      _finding('warn', 'No transport booked from Athens to Naxos.'),
      _finding('critical', 'Trip dates are in the past.'),
    ]);
    await _pumpScreen(tester, review: review);

    final badge = tester.widget<Badge>(find.byType(Badge));
    final theme = Theme.of(tester.element(find.byType(Badge)));
    expect(badge.backgroundColor, theme.colorScheme.error);
  });

  testWidgets('zero findings: bare icon, sheet shows the all-clear',
      (tester) async {
    final review = _FakeReviewApiService(const []);
    await _pumpScreen(tester, review: review);

    expect(_healthIcon(), findsOneWidget);
    expect(find.byType(Badge), findsNothing);

    await tester.tap(_healthIcon());
    await tester.pumpAndSettle();
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('Looks good'), findsOneWidget);
  });

  testWidgets('icon hidden while the review has no value (error/viewer)',
      (tester) async {
    final review = _FakeReviewApiService(const [])..error = true;
    await _pumpScreen(tester, review: review);

    expect(_healthIcon(), findsNothing);
  });

  testWidgets('tapping the icon opens the sheet with header, pill and rows',
      (tester) async {
    final review = _FakeReviewApiService([
      _finding('warn', 'No transport booked from Athens to Naxos.'),
      _finding('warn', 'No lodging for the night of Aug 3.'),
      _finding('info', 'Day 2 has nothing scheduled.'),
    ]);
    await _pumpScreen(tester, review: review);

    await tester.tap(_healthIcon());
    await tester.pumpAndSettle();

    expect(find.byType(TripReviewSection), findsOneWidget);
    expect(find.text('Trip health'), findsOneWidget);
    expect(find.text('Mostly ready — 2 to fix'), findsOneWidget);
    expect(find.text('Needs attention'), findsOneWidget);
    expect(
        find.text('No transport booked from Athens to Naxos.'), findsOneWidget);
    // The info row starts collapsed behind the Suggestions header…
    expect(find.text('Day 2 has nothing scheduled.'), findsNothing);
    await tester.tap(find.text('Suggestions'));
    await tester.pumpAndSettle();
    // …and one tap reveals it.
    expect(find.text('Day 2 has nothing scheduled.'), findsOneWidget);
  });

  testWidgets('info-only sheet header reads as in-good-shape', (tester) async {
    final review = _FakeReviewApiService([
      _finding('info', 'Day 2 has nothing scheduled.'),
      _finding('info', 'Hotel Delfini not booked yet.'),
    ]);
    await _pumpScreen(tester, review: review);

    await tester.tap(_healthIcon());
    await tester.pumpAndSettle();

    expect(find.text('In good shape — 2 suggestions'), findsOneWidget);
    expect(find.text('Needs attention'), findsNothing);
  });

  testWidgets('tapping a day-anchored finding closes the sheet and scrolls',
      (tester) async {
    final review = _FakeReviewApiService([
      _finding('warn', 'Day 1 is overloaded.', day: 1),
    ]);
    await _pumpScreen(tester, review: review);

    await tester.tap(_healthIcon());
    await tester.pumpAndSettle();
    expect(find.byType(TripReviewSection), findsOneWidget);

    // The sheet pops first, then the screen beneath scrolls — no crash.
    await tester.tap(find.text('Day 1 is overloaded.'));
    await tester.pumpAndSettle();
    expect(find.byType(TripReviewSection), findsNothing);
  });

  testWidgets('an in-sheet fix live-updates the list and the badge behind it',
      (tester) async {
    final review = _FakeReviewApiService([
      TripFinding(
        severity: 'warn',
        category: 'bookings',
        message: 'Stay not booked',
        tripId: 't1',
        fix: const FindingFix(
            action: 'mark_booked',
            label: 'Mark booked',
            itemId: 'acc-1',
            entityType: 'accommodation'),
      ),
    ]);
    final accommodations = _FakeAccommodationsApiService();
    await _pumpScreen(tester, review: review, accommodations: accommodations);
    expect(find.byType(Badge), findsOneWidget);

    await tester.tap(_healthIcon());
    await tester.pumpAndSettle();

    review.resolved = true; // the server now considers it booked
    await tester.tap(find.widgetWithText(FilledButton, 'Mark booked'));
    await tester.pumpAndSettle();

    expect(accommodations.patches, hasLength(1));
    // Sheet stays open and re-renders empty; the badge behind it clears too.
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.byType(Badge), findsNothing);
  });

  testWidgets('fixing an info inside the expanded Suggestions live-updates',
      (tester) async {
    final review = _FakeReviewApiService([
      TripFinding(
        severity: 'info',
        category: 'bookings',
        message: 'Stay not booked',
        tripId: 't1',
        fix: const FindingFix(
            action: 'mark_booked',
            label: 'Mark booked',
            itemId: 'acc-1',
            entityType: 'accommodation'),
      ),
    ]);
    final accommodations = _FakeAccommodationsApiService();
    await _pumpScreen(tester, review: review, accommodations: accommodations);
    expect(tester.widget<Badge>(find.byType(Badge)).label, isNull);

    await tester.tap(_healthIcon());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suggestions'));
    await tester.pumpAndSettle();

    review.resolved = true; // the server now considers it booked
    await tester.tap(find.widgetWithText(FilledButton, 'Mark booked'));
    await tester.pumpAndSettle();

    expect(accommodations.patches, hasLength(1));
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.byType(Badge), findsNothing);
  });

  testWidgets('badge and framing flip to suggestions-only after the last warn',
      (tester) async {
    final info = _finding('info', 'Day 2 has nothing scheduled.');
    final review = _FakeReviewApiService([
      TripFinding(
        severity: 'warn',
        category: 'bookings',
        message: 'Stay not booked',
        tripId: 't1',
        fix: const FindingFix(
            action: 'mark_booked',
            label: 'Mark booked',
            itemId: 'acc-1',
            entityType: 'accommodation'),
      ),
      info,
    ])
      ..resolvedFindings = [info];
    final accommodations = _FakeAccommodationsApiService();
    await _pumpScreen(tester, review: review, accommodations: accommodations);
    expect(
        find.descendant(of: find.byType(Badge), matching: find.text('1')),
        findsOneWidget);

    await tester.tap(_healthIcon());
    await tester.pumpAndSettle();
    expect(find.text('Mostly ready — 1 to fix'), findsOneWidget);

    review.resolved = true;
    await tester.tap(find.widgetWithText(FilledButton, 'Mark booked'));
    await tester.pumpAndSettle();

    // The sheet reframes to the calm info-only reading and the badge behind
    // it becomes the dot.
    expect(find.text('In good shape — 1 suggestion'), findsOneWidget);
    expect(tester.widget<Badge>(find.byType(Badge)).label, isNull);
  });

  testWidgets('a failed fix closes the sheet so the error snackbar is seen',
      (tester) async {
    final review = _FakeReviewApiService([
      TripFinding(
        severity: 'warn',
        category: 'bookings',
        message: 'Stay not booked',
        tripId: 't1',
        fix: const FindingFix(
            action: 'mark_booked',
            label: 'Mark booked',
            itemId: 'acc-1',
            entityType: 'accommodation'),
      ),
    ]);
    final accommodations = _FakeAccommodationsApiService()..failUpdate = true;
    await _pumpScreen(tester, review: review, accommodations: accommodations);

    await tester.tap(_healthIcon());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Mark booked'));
    await tester.pumpAndSettle();

    // The sheet closed itself so the screen's error snackbar is visible —
    // never a silent no-op behind the barrier. The finding is unresolved,
    // so the badge still shows.
    expect(find.byType(TripReviewSection), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byType(Badge), findsOneWidget);
  });

  testWidgets('a failed hours check reverts to the list with an inline note',
      (tester) async {
    final review = _FakeReviewApiService([
      _finding('warn', 'No transport booked from Athens to Naxos.'),
    ])..hoursError = true;
    await _pumpScreen(tester, review: review);

    await tester.tap(_healthIcon());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Also check opening hours'));
    await tester.pumpAndSettle();

    // Reverted to the cached base list — never a blank sheet — with the
    // failure noted inline by the toggle (snackbars render behind sheets).
    expect(find.text('No transport booked from Athens to Naxos.'),
        findsOneWidget);
    expect(find.text("Couldn't check opening hours — try again."),
        findsOneWidget);
  });

  testWidgets('Escape dismisses the sheet', (tester) async {
    final review = _FakeReviewApiService([
      _finding('warn', 'No transport booked from Athens to Naxos.'),
    ]);
    await _pumpScreen(tester, review: review);

    await tester.tap(_healthIcon());
    await tester.pumpAndSettle();
    expect(find.byType(TripReviewSection), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TripReviewSection), findsNothing);
  });

  testWidgets('icon shows on phone and desktop widths (not narrow-gated)',
      (tester) async {
    final review = _FakeReviewApiService([
      _finding('warn', 'No transport booked from Athens to Naxos.'),
    ]);
    await _pumpScreen(tester,
        review: review, surface: const Size(390, 800));
    expect(_healthIcon(), findsOneWidget);

    await _pumpScreen(tester,
        review: review, surface: const Size(1200, 800));
    expect(_healthIcon(), findsOneWidget);
  });

  testWidgets('a transient review failure self-heals and restores the icon',
      (tester) async {
    final review = _TransientThenOkReviewApi([
      _finding('warn', 'No lodging for the night of Aug 3.'),
    ]);
    await _pumpScreen(tester, review: review);

    // The 503 hid the icon — previously for the whole session, since the
    // only retry path (the sheet) opens from the icon itself.
    expect(_healthIcon(), findsNothing);

    // The provider's one-shot 30s invalidateSelf fires on the fake clock and
    // the active app-bar watch refetches.
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();

    expect(review.calls, 2);
    expect(_healthIcon(), findsOneWidget);
    expect(find.byType(Badge), findsOneWidget);
  });
}
