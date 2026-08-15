import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/airport.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/ferry_option.dart';
import 'package:travel_route_planner/models/flight_search_request.dart';
import 'package:travel_route_planner/models/flight_search_response.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip_finding.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/ferries_provider.dart';
import 'package:travel_route_planner/providers/flights_provider.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/providers/trip_review_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/ferry_api_service.dart';
import 'package:travel_route_planner/services/flights_api_service.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/services/trip_review_api_service.dart';
import 'package:travel_route_planner/screens/flight_search_screen.dart';
import 'package:travel_route_planner/widgets/booking_todo_card.dart';
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
  Future<TripReview> getReview(String tripId, {bool checkHours = false}) async {
    calls++;
    return (calls > 1 ? resolved : null) ?? initial;
  }
}

/// Airport resolution and flight search both answer empty — the transport
/// handoff test only needs FlightSearchScreen to mount, never real offers.
class _FakeFlightsApiService extends FlightsApiService {
  _FakeFlightsApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<FlightSearchResponse> searchFlights(
          FlightSearchRequest request) async =>
      const FlightSearchResponse(
          offers: [], optimizeFor: 'balanced', count: 0, status: 'success');

  @override
  Future<List<Airport>> searchAirports(String query) async => [];

  @override
  Future<List<Airport>> nearestAirports(double lat, double lng) async => [];
}

/// Accepts the booked flip so the card's advance signal can be observed; the
/// derived sync fails (offline test env) exactly as it does in the other
/// trip-detail suites, leaving the fixture's own todos in place.
class _FakeBookingTodosApiService extends BookingTodosApiService {
  final List<(String, bool)> bookedCalls = [];
  _FakeBookingTodosApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
          String tripId, List<Map<String, dynamic>> derived) async =>
      throw Exception('offline test env');

  @override
  Future<BookingTodo> setBooked(
      String tripId, String todoId, bool booked) async {
    bookedCalls.add((todoId, booked));
    return BookingTodo(
        id: todoId,
        kind: 'transport',
        todoKey: 'transport:paris>>lyon',
        title: 'Paris → Lyon',
        booked: booked);
  }
}

/// Empty ferry results: the ferry handoff degrades to the search-failed
/// snack, which is the observable "took the ferry path" signal.
class _FakeFerryApiService extends FerryApiService {
  _FakeFerryApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<FerryOption>> searchFerries(String origin, String destination,
          {String? date, int? passengers}) async =>
      [];
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

Trip _trip({
  List<ItineraryItem>? items,
  String? access,
  List<BookingTodo>? bookingTodos,
}) =>
    Trip(
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
      bookingTodos: bookingTodos,
    );

/// Two hubs so [_deriveTodos] produces the Paris→Lyon inter-city leg (and
/// registers it in the screen's flight/ferry leg maps). Item names are real
/// places, never city filler (#280).
List<ItineraryItem> _twoCityItems() => [
      _item(0, 'Louvre', day: 1, city: 'Paris'),
      _item(1, 'Old Town', day: 3, city: 'Lyon'),
    ];

const _lodgingSeed =
    'I want to refine my saved trip "Greece" (2026-09-01 to 2026-09-05).\n\n'
    'I still need a place to stay in Athens for 2026-09-01 to 2026-09-03. '
    'Call search_hotels with those dates and show me a few real options…';

/// The ladder the server ships alongside every step — what the eyebrow's
/// "3 of 6" counter expands into (specs/next-step-cta).
const _ladder = [
  PlanPhase(id: 'dates', label: 'Set your travel dates'),
  PlanPhase(id: 'itinerary', label: 'Plan your days'),
  PlanPhase(id: 'bookings', label: 'Book travel & stays'),
  PlanPhase(id: 'schedule', label: 'Tidy up your schedule'),
  PlanPhase(id: 'confirm', label: 'Book everything'),
  PlanPhase(id: 'packing', label: 'Start your packing list'),
];

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
      planProgress: PlanProgress(done: 2, total: 6, phases: _ladder),
    );

const _allSetReview = TripReview(
  findings: [],
  nextStep: NextStep(kind: 'all_set', title: "You're all set"),
  planProgress: PlanProgress(done: 6, total: 6),
);

// A walk-derived transport step (itinerary-order walk): the fix carries the
// leg's cased endpoints + date + mode, so the screen can hand off to the
// matching synced booking todo instead of chat.
const _transportSeed =
    'I want to refine my saved trip "Greece" (2026-09-01 to 2026-09-05).\n\n'
    'I still need transport from Paris to Lyon around 2026-09-03. '
    'Help me compare options (call search_flights)…';

TripReview _transportReview({required String mode}) => TripReview(
      findings: const [],
      nextStep: NextStep(
        kind: 'add_transport',
        title: mode == 'ferry'
            ? 'Book your ferry to Lyon'
            : 'Book your flight to Lyon',
        detail: 'Paris → Lyon on Sep 3.',
        fix: FindingFix(
          action: 'add_transport',
          label: mode == 'ferry' ? 'Find ferries' : 'Find flights',
          origin: 'Paris',
          destination: 'Lyon',
          date: '2026-09-03',
          mode: mode,
        ),
        seedPrompt: _transportSeed,
      ),
      planProgress: const PlanProgress(done: 2, total: 6),
    );

/// The client-synced row the walk-derived step's fix points at (todo_key is
/// the documented lowercase convention; the title is what the server splits
/// back into the fix's cased endpoints).
BookingTodo _parisLyonLeg({String? mode}) => BookingTodo(
      id: 'bt1',
      kind: 'transport',
      todoKey: 'transport:paris>>lyon',
      title: 'Paris → Lyon',
      provider: mode == 'ferry' ? 'ferry' : 'google_flights',
      departDate: '2026-09-03',
      mode: mode,
      position: 2,
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
        // The transport handoff paths reach these two: Find Flights resolves
        // airports on mount, the ferry path fetches the booking link on tap.
        flightsApiServiceProvider.overrideWithValue(_FakeFlightsApiService()),
        ferryApiServiceProvider.overrideWithValue(_FakeFerryApiService()),
        bookingTodosApiServiceProvider
            .overrideWithValue(_FakeBookingTodosApiService()),
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
    await _pump(tester,
        trip: _trip(), review: _FakeReviewApiService(_lodgingReview()));

    expect(find.byKey(const ValueKey('next-step-card')), findsOneWidget);
    expect(find.text('NEXT STEP · 3 of 6'), findsOneWidget);
    expect(find.text('Book a place to stay'), findsOneWidget);
    expect(find.text('Find lodging'), findsOneWidget);
  });

  testWidgets('planning step seeds the trip chat with the server prompt',
      (tester) async {
    _useViewport(tester);
    await _pump(tester,
        trip: _trip(), review: _FakeReviewApiService(_lodgingReview()));

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
      planProgress: PlanProgress(done: 1, total: 6),
    );
    await _pump(tester,
        trip: _trip(items: const []), review: _FakeReviewApiService(review));

    // The chat FAB is items-gated, but the card must not be.
    expect(find.byType(FloatingActionButton), findsNothing);
    await tester.tap(find.byKey(const ValueKey('next-step-primary')));
    await tester.pumpAndSettle();

    // No snack; the seed went out. Asserted as "no SnackBar at all" because
    // the copy it used to check for no longer exists — its only caller was the
    // guard this change removed.
    expect(find.byType(SnackBar), findsNothing);
    expect(_refineState(tester).messages, hasLength(1));
    expect(_refineState(tester).messages.single.content, contains('no places'));
  });

  // specs/shape-before-schedule. "Refine with AI" on a trip with no items was a
  // visible, enabled button whose only outcome was the snack below — it named a
  // door and the callee refused to open it. The Next Step card had already
  // routed around that guard; this makes the header chip do the same, which
  // fixes both entry points (chip and narrow app-bar icon) at once.
  testWidgets('zero-items trip: Refine with AI opens chat, not a snack',
      (tester) async {
    _useViewport(tester);
    await _pump(tester,
        trip: _trip(items: const []),
        review: _FakeReviewApiService(const TripReview(
            findings: [], planProgress: PlanProgress(done: 1, total: 6))));

    await tester.tap(find.text('Refine with AI'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
    final seed = _refineState(tester).messages.single.content;
    // And the seed tells the truth about the trip it describes: no places yet,
    // shape first. It used to say "The full itinerary:" followed by nothing.
    expect(seed, contains('no places yet'));
    expect(seed, contains('SHAPE'));
    expect(seed, isNot(contains('exactly as listed above')));
  });

  // A SEPARATE test, not a second pumpWidget: two pumpWidget calls in one test
  // reuse the same State, so the second would silently inspect the first
  // case's screen.
  testWidgets('zero-items trip: the empty state offers the same door',
      (tester) async {
    _useViewport(tester);
    await _pump(tester,
        trip: _trip(items: const []),
        review: _FakeReviewApiService(const TripReview(
            findings: [], planProgress: PlanProgress(done: 1, total: 6))));

    await tester.tap(find.byKey(const ValueKey('empty-trip-plan')));
    await tester.pumpAndSettle();

    expect(_refineState(tester).messages.single.content, contains('no places'));
  });

  testWidgets('set_dates step opens the date picker, not chat', (tester) async {
    _useViewport(tester);
    const review = TripReview(
      findings: [],
      nextStep: NextStep(
        kind: 'set_dates',
        title: 'Set your travel dates',
        fix: FindingFix(action: 'set_dates', label: 'Set dates'),
        seedPrompt: 'My saved trip "Greece" has no dates yet…',
      ),
      planProgress: PlanProgress(done: 0, total: 6),
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
      planProgress: PlanProgress(done: 4, total: 6),
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
    await _pump(tester,
        trip: _trip(), review: _FakeReviewApiService(_lodgingReview()));

    expect(find.byKey(const ValueKey('next-step-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('next-step-view-all')), findsNothing);
    expect(find.textContaining('No lodging booked'), findsNothing);
    // The health entry goes, the counter's explanation stays — the counter
    // itself renders at every width.
    expect(find.byKey(const ValueKey('next-step-progress')), findsOneWidget);
  });

  testWidgets('the health entry opens the health sheet', (tester) async {
    _useViewport(tester);
    await _pump(tester,
        trip: _trip(), review: _FakeReviewApiService(_lodgingReview()));

    await tester.tap(find.byKey(const ValueKey('next-step-view-all')));
    await tester.pumpAndSettle();

    expect(find.text('Trip health'), findsWidgets);
  });

  // The counter is no longer a dead end: it opens the ladder it counts
  // (specs/next-step-cta), with the card's own step on the current rung.
  testWidgets('the progress counter opens the plan-progress sheet',
      (tester) async {
    _useViewport(tester);
    await _pump(tester,
        trip: _trip(), review: _FakeReviewApiService(_lodgingReview()));

    expect(find.text('NEXT STEP · 3 of 6'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('next-step-progress')));
    await tester.pumpAndSettle();

    expect(find.text('Plan progress'), findsOneWidget);
    for (final p in _ladder) {
      expect(find.byKey(ValueKey('plan-phase-${p.id}')), findsOneWidget);
    }
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('plan-phase-bookings')),
            matching: find.text('Book a place to stay')),
        findsOneWidget);
  });

  // Walk-derived transport steps (itinerary-order walk, specs/next-step-cta):
  // the fix's endpoints locate the synced booking todo and the card hands off
  // exactly like the checklist row — Find Flights / Ferryhopper — with the
  // seeded chat only as the no-matching-todo fallback. Mechanics: the trip
  // fixture seeds _bookingTodos before the (failing, swallowed) network sync,
  // and _deriveTodos runs synchronously as syncTodos's argument, so the
  // screen's flight/ferry leg maps populate; items at lat/lng 0 skip the
  // travel-time computation.
  testWidgets('transport step with a synced flight leg opens Find Flights',
      (tester) async {
    _useViewport(tester);
    await _pump(tester,
        trip: _trip(items: _twoCityItems(), bookingTodos: [_parisLyonLeg()]),
        review: _FakeReviewApiService(_transportReview(mode: 'flight')));

    // The mode-aware action label, matching the checklist row's override
    // (which renders the same text on its own row — scope to the card).
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('next-step-primary')),
            matching: find.text('Find flights')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('next-step-primary')));
    await tester.pumpAndSettle();

    // The checklist row's in-app handoff, prefilled — and no chat seed.
    expect(find.byType(FlightSearchScreen), findsOneWidget);
    final container = ProviderScope.containerOf(
        tester.element(find.byType(TripDetailScreen, skipOffstage: false)));
    expect(container.read(tripRefineProvider('t1')).messages, isEmpty);
  });

  testWidgets('transport step with a ferry-mode leg runs the ferry handoff',
      (tester) async {
    _useViewport(tester);
    await _pump(tester,
        trip: _trip(
            items: _twoCityItems(),
            bookingTodos: [_parisLyonLeg(mode: 'ferry')]),
        review: _FakeReviewApiService(_transportReview(mode: 'ferry')));

    expect(
        find.descendant(
            of: find.byKey(const ValueKey('next-step-primary')),
            matching: find.text('Find ferries')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('next-step-primary')));
    await tester.pumpAndSettle();

    // The ferry path fetched (empty fake) and degraded to its failure snack —
    // proof the tap took the checklist row's ferry handoff, not Find Flights
    // and not chat.
    expect(find.text('Could not open ferry search'), findsOneWidget);
    expect(find.byType(FlightSearchScreen), findsNothing);
    expect(_refineState(tester).messages, isEmpty);
  });

  testWidgets('transport step without a matching todo falls back to chat',
      (tester) async {
    _useViewport(tester);
    // No bookingTodos on the trip: the review's step outruns the client sync.
    await _pump(tester,
        trip: _trip(items: _twoCityItems()),
        review: _FakeReviewApiService(_transportReview(mode: 'flight')));

    await tester.tap(find.byKey(const ValueKey('next-step-primary')));
    await tester.pumpAndSettle();

    expect(find.byType(FlightSearchScreen), findsNothing);
    final messages = _refineState(tester).messages;
    expect(messages, hasLength(1));
    // Verbatim server seed (canonical English), shown as the localized title.
    expect(messages.single.content, _transportSeed);
    expect(messages.single.displayLabel, 'Book your flight to Lyon');
  });

  // Ticking a slot's checkbox IS the card's advance signal: phase 3 walks the
  // booked flags, so the flip must re-read the review. Without the
  // invalidation the card keeps recommending the leg the traveler just booked.
  testWidgets('checking off a booking row advances the card', (tester) async {
    _useViewport(tester);
    final review = _FakeReviewApiService(
      _transportReview(mode: 'flight'),
      resolved: _lodgingReview(),
    );
    await _pump(tester,
        trip: _trip(items: _twoCityItems(), bookingTodos: [_parisLyonLeg()]),
        review: review);

    expect(find.text('Book your flight to Lyon'), findsOneWidget);
    final callsBefore = review.calls;

    final row = find.widgetWithText(BookingTodoRow, 'Paris → Lyon');
    await tester.tap(find.descendant(of: row, matching: find.byType(Checkbox)));
    await tester.pumpAndSettle();

    expect(review.calls, greaterThan(callsBefore));
    expect(find.text('Book a place to stay'), findsOneWidget);
  });
}
