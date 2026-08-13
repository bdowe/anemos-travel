import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip_finding.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/providers/trip_review_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/services/trip_review_api_service.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/l10n_test_app.dart';

// Screen-level tests for the Next Step CTA (specs/next-step-cta): the card
// renders the review payload's step, planning steps seed the trip chat with
// the server-built prompt, mechanical steps act directly, and the card
// advances when the review re-fetches after a chat mutation.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Serves [initial] until [resolved] flips (or forever), counting fetches —
/// the counter is the "chat mutations re-read the review" regression pin.
class _FakeReviewApiService extends TripReviewApiService {
  TripReview initial;
  TripReview? resolved;
  int calls = 0;
  _FakeReviewApiService(this.initial, {this.resolved})
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<TripReview> getReview(String tripId,
      {bool checkHours = false}) async {
    calls++;
    return (calls > 1 ? resolved : null) ?? initial;
  }
}

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
    // Let the refine panel mount and register its tripUpdateCount listener
    // before events arrive — real SSE is never frame-synchronous.
    // pumpAndSettle advances this timer.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    for (final e in events) {
      yield e;
    }
  }
}

ItineraryItem _item(int pos, String name, {int? day, String? city}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$city, Greece',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

Trip _trip({List<ItineraryItem>? items, String? access}) => Trip(
      id: 't1',
      title: 'Greece',
      startDate: '2026-09-01',
      endDate: '2026-09-05',
      createdAt: '2026-07-01',
      updatedAt: '2026-07-01',
      access: access,
      items: items ??
          [
            _item(0, 'Acropolis', day: 1, city: 'Athens'),
            _item(1, 'Plaka walk', day: 2, city: 'Athens'),
          ],
    );

const _lodgingSeed =
    'I want to refine my saved trip "Greece" (2026-09-01 to 2026-09-05).\n\n'
    'I still need a place to stay in Athens for 2026-09-01 to 2026-09-03. '
    'Suggest a few good lodging options (call suggest_stays)…';

TripReview _lodgingReview() => const TripReview(
      findings: [
        TripFinding(
          severity: 'warn',
          category: 'lodging',
          message: 'No lodging booked for the nights of Sep 1 – Sep 2.',
          tripId: 't1',
          day: 1,
        ),
      ],
      nextStep: NextStep(
        kind: 'add_lodging',
        title: 'Book a place to stay',
        detail: 'No lodging booked for the nights of Sep 1 – Sep 2.',
        day: 1,
        seedPrompt: _lodgingSeed,
      ),
      planProgress: PlanProgress(done: 2, total: 7),
    );

const _allSetReview = TripReview(
  findings: [],
  nextStep: NextStep(kind: 'all_set', title: "You're all set"),
  planProgress: PlanProgress(done: 7, total: 7),
);

void _useViewport(WidgetTester tester, {double width = 1400}) {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pump(
  WidgetTester tester, {
  required Trip trip,
  required _FakeReviewApiService review,
  List<PlanEvent> planEvents = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        tripReviewApiServiceProvider.overrideWithValue(review),
        tripRefineProvider.overrideWith((ref, tripId) => PlanNotifier(
            _ScriptedPlanService(planEvents), ApiClient(),
            tripId: tripId)),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

PlanState _refineState(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(TripDetailScreen)))
        .read(tripRefineProvider('t1'));

void main() {
  testWidgets('card renders the review step with progress and detail',
      (tester) async {
    _useViewport(tester);
    await _pump(tester, trip: _trip(), review: _FakeReviewApiService(_lodgingReview()));

    expect(find.byKey(const ValueKey('next-step-card')), findsOneWidget);
    expect(find.text('NEXT STEP · 3 of 7'), findsOneWidget);
    expect(find.text('Book a place to stay'), findsOneWidget);
    expect(find.text('Find lodging'), findsOneWidget);
  });

  testWidgets('planning step seeds the trip chat with the server prompt',
      (tester) async {
    _useViewport(tester);
    await _pump(tester, trip: _trip(), review: _FakeReviewApiService(_lodgingReview()));

    await tester.tap(find.byKey(const ValueKey('next-step-primary')));
    await tester.pumpAndSettle();

    final messages = _refineState(tester).messages;
    expect(messages, hasLength(1));
    // Verbatim server seed (canonical English), shown as the localized title.
    expect(messages.single.content, _lodgingSeed);
    expect(messages.single.displayLabel, 'Book a place to stay');
  });

  testWidgets('zero-items trip: FAB hidden but the card still opens chat',
      (tester) async {
    _useViewport(tester);
    const review = TripReview(
      findings: [],
      nextStep: NextStep(
        kind: 'plan_itinerary',
        title: 'Plan your days',
        detail: 'No places saved yet — plan your days in chat.',
        seedPrompt: 'I want to plan my saved trip "Greece". It has no places '
            'yet. Help me build the itinerary from scratch…',
      ),
      planProgress: PlanProgress(done: 1, total: 7),
    );
    await _pump(tester,
        trip: _trip(items: const []),
        review: _FakeReviewApiService(review));

    // The chat FAB is items-gated, but the card must not be.
    expect(find.byType(FloatingActionButton), findsNothing);
    await tester.tap(find.byKey(const ValueKey('next-step-primary')));
    await tester.pumpAndSettle();

    // No "add places first" snack; the seed went out.
    expect(find.text('Add some places before refining with AI.'), findsNothing);
    expect(_refineState(tester).messages, hasLength(1));
    expect(
        _refineState(tester).messages.single.content, contains('no places'));
  });

  testWidgets('set_dates step opens the date picker, not chat',
      (tester) async {
    _useViewport(tester);
    const review = TripReview(
      findings: [],
      nextStep: NextStep(
        kind: 'set_dates',
        title: 'Set your travel dates',
        fix: FindingFix(action: 'set_dates', label: 'Set dates'),
        seedPrompt: 'My saved trip "Greece" has no dates yet…',
      ),
      planProgress: PlanProgress(done: 0, total: 7),
    );
    await _pump(tester, trip: _trip(), review: _FakeReviewApiService(review));

    await tester.tap(find.byKey(const ValueKey('next-step-primary')));
    await tester.pumpAndSettle();

    expect(find.byType(DateRangePickerDialog), findsOneWidget);
    expect(_refineState(tester).messages, isEmpty);
  });

  testWidgets('book_trip step switches to the unbooked bookings lens',
      (tester) async {
    _useViewport(tester);
    const review = TripReview(
      findings: [],
      nextStep: NextStep(
        kind: 'book_trip',
        title: 'Book everything',
        detail: '3 bookings still to confirm.',
        count: 3,
      ),
      planProgress: PlanProgress(done: 5, total: 7),
    );
    await _pump(tester, trip: _trip(), review: _FakeReviewApiService(review));

    await tester.tap(find.byKey(const ValueKey('next-step-primary')));
    await tester.pumpAndSettle();

    // The unbooked lens shows its scope chip selected; no chat was seeded.
    expect(find.text('Not booked yet'), findsWidgets);
    expect(_refineState(tester).messages, isEmpty);
  });

  testWidgets(
      'chat trip_updated re-reads the review and advances the card to all set',
      (tester) async {
    _useViewport(tester); // wide: panel docks, card stays visible behind it
    final review =
        _FakeReviewApiService(_lodgingReview(), resolved: _allSetReview);
    await _pump(
      tester,
      trip: _trip(),
      review: review,
      planEvents: const [
        PlanEvent(type: 'trip_updated', data: {}),
        PlanEvent(type: 'text_delta', data: {'text': 'Lodging added.'}),
      ],
    );
    expect(review.calls, 1);

    await tester.tap(find.byKey(const ValueKey('next-step-primary')));
    await tester.pumpAndSettle();

    // trip_updated → onTripUpdated → _refresh → _invalidateReview (the
    // regression this test pins) → the resolved payload's all_set celebration
    // renders because this session saw the lodging step first.
    expect(review.calls, greaterThan(1));
    expect(find.byKey(const ValueKey('next-step-all-set')), findsOneWidget);

    // Session dismissal hides it.
    await tester.tap(find.byKey(const ValueKey('next-step-dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('next-step-all-set')), findsNothing);
  });

  testWidgets('a trip opened already-complete shows no card at all',
      (tester) async {
    _useViewport(tester);
    await _pump(tester,
        trip: _trip(), review: _FakeReviewApiService(_allSetReview));

    expect(find.byKey(const ValueKey('next-step-card')), findsNothing);
    expect(find.byKey(const ValueKey('next-step-all-set')), findsNothing);
  });

  testWidgets('viewers never see the card', (tester) async {
    _useViewport(tester);
    await _pump(tester,
        trip: _trip(access: 'viewer'),
        review: _FakeReviewApiService(_lodgingReview()));

    expect(find.byKey(const ValueKey('next-step-card')), findsNothing);
  });

  testWidgets('narrow layout renders the compact card', (tester) async {
    _useViewport(tester, width: 500);
    await _pump(tester, trip: _trip(), review: _FakeReviewApiService(_lodgingReview()));

    expect(find.byKey(const ValueKey('next-step-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('next-step-view-all')), findsNothing);
    expect(find.textContaining('No lodging booked'), findsNothing);
  });

  testWidgets('"View all" opens the health sheet', (tester) async {
    _useViewport(tester);
    await _pump(tester, trip: _trip(), review: _FakeReviewApiService(_lodgingReview()));

    await tester.tap(find.byKey(const ValueKey('next-step-view-all')));
    await tester.pumpAndSettle();

    expect(find.text('Trip health'), findsWidgets);
  });
}
