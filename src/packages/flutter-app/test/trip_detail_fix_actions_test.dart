import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip_finding.dart';
import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/trip_segment.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/services/trip_review_api_service.dart';
import 'package:travel_route_planner/services/accommodations_api_service.dart';
import 'package:travel_route_planner/services/transport_api_service.dart';
import 'package:travel_route_planner/services/checklist_api_service.dart';
import 'package:travel_route_planner/models/checklist_item.dart';
import 'package:travel_route_planner/services/budget_api_service.dart';
import 'package:travel_route_planner/models/budget.dart';
import 'package:travel_route_planner/models/expense.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/providers/trip_review_provider.dart';
import 'package:travel_route_planner/providers/accommodations_provider.dart';
import 'package:travel_route_planner/providers/transport_provider.dart';
import 'package:travel_route_planner/providers/checklist_provider.dart';
import 'package:travel_route_planner/providers/budget_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/booking_sheets.dart';

import 'support/l10n_test_app.dart';

/// Serves a fixed trip and records itinerary-item PATCHes for the move_item fix.
class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  final List<Map<String, dynamic>> itemPatches = [];
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;

  @override
  Future<ItineraryItem> updateItineraryItem(
      String tripId, String itemId, Map<String, dynamic> body) async {
    itemPatches.add({'id': itemId, ...body});
    return _item(0, 'x', 'y', 'attraction', day: body['day'] as int?);
  }
}

/// Stateful review fake: returns [findings] until a fix resolves them, then
/// empty on the next fetch — so a successful fix both re-fetches (call count
/// grows) and drops the finding from the list.
class _FakeReviewApiService extends TripReviewApiService {
  final List<TripFinding> findings;
  int calls = 0;
  bool resolved = false;

  _FakeReviewApiService(this.findings)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<TripFinding>> getReview(String tripId,
      {bool checkHours = false}) async {
    calls++;
    return resolved ? const [] : List.of(findings);
  }
}

class _FakeAccommodationsApiService extends AccommodationsApiService {
  final List<Map<String, dynamic>> patches = [];
  _FakeAccommodationsApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Accommodation> update(
      String tripId, String accId, Map<String, dynamic> body) async {
    patches.add({'id': accId, ...body});
    return Accommodation(id: accId, name: 'Stay');
  }
}

class _FakeTransportApiService extends TransportApiService {
  final List<Map<String, dynamic>> patches = [];
  final List<Map<String, dynamic>> added = [];
  _FakeTransportApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<TripSegment> updateSegment(
      String tripId, String segmentId, Map<String, dynamic> body) async {
    patches.add({'id': segmentId, ...body});
    return TripSegment(id: segmentId, mode: 'ferry');
  }

  @override
  Future<TripSegment> addSegment(
      String tripId, Map<String, dynamic> body) async {
    added.add(body);
    return TripSegment(id: 'seg-new', mode: body['mode'] as String? ?? 'other');
  }
}

class _FakeChecklistApiService extends ChecklistApiService {
  int addCount = 0;
  String? lastTitle;
  String? lastCategory;
  _FakeChecklistApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<ChecklistItem>> list(String tripId) async => const [];

  @override
  Future<ChecklistItem> add(
      String tripId, String title, String category) async {
    addCount++;
    lastTitle = title;
    lastCategory = category;
    return ChecklistItem(id: 'c1', category: category, title: title);
  }
}

/// Loaded-but-empty budget: enough for the collapsed Budget row to render
/// ("Not tracked yet") without a target or expenses.
class _FakeBudgetApiService extends BudgetApiService {
  _FakeBudgetApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Budget> getBudget(String tripId) async => const Budget();

  @override
  Future<List<Expense>> listExpenses(String tripId) async => const [];
}

ItineraryItem _item(int pos, String name, String address, String category,
        {int? day}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: address,
      latitude: 0,
      longitude: 0,
      category: category,
      day: day,
    );

Trip _trip({List<ItineraryItem>? items}) => Trip(
      id: 't1',
      title: 'Greece',
      startDate: '2026-08-01',
      endDate: '2026-08-05',
      createdAt: '2026-07-01',
      updatedAt: '2026-07-01',
      items: items ??
          [_item(0, 'Acropolis', 'Athens, Greece', 'attraction', day: 1)],
    );

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Pumps the trip detail screen; [openSheet] then taps the app-bar health
/// icon so the finding rows (and their fix buttons) are on screen.
Future<void> _pumpScreen(
  WidgetTester tester, {
  required Trip trip,
  required _FakeReviewApiService review,
  _FakeTripsApiService? trips,
  _FakeAccommodationsApiService? accommodations,
  _FakeTransportApiService? transport,
  _FakeChecklistApiService? checklist,
  _FakeBudgetApiService? budget,
  bool openSheet = true,
}) async {
  _useTallViewport(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider
            .overrideWithValue(trips ?? _FakeTripsApiService(trip)),
        tripReviewApiServiceProvider.overrideWithValue(review),
        if (accommodations != null)
          accommodationsApiServiceProvider.overrideWithValue(accommodations),
        if (transport != null)
          transportApiServiceProvider.overrideWithValue(transport),
        if (checklist != null)
          checklistApiServiceProvider.overrideWithValue(checklist),
        if (budget != null)
          budgetApiServiceProvider.overrideWithValue(budget),
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
  if (!openSheet) return;
  await tester.tap(find.byTooltip('Trip health'));
  await tester.pumpAndSettle();
}

TripFinding _finding(String category, String message, FindingFix fix) =>
    TripFinding(
      severity: 'warn',
      category: category,
      message: message,
      tripId: 't1',
      fix: fix,
    );

void main() {
  testWidgets('mark_booked (accommodation) PATCHes booked + re-reads review',
      (tester) async {
    final review = _FakeReviewApiService([
      _finding('bookings', 'Stay not booked',
          const FindingFix(
              action: 'mark_booked',
              label: 'Mark booked',
              itemId: 'acc-1',
              entityType: 'accommodation')),
    ]);
    final accommodations = _FakeAccommodationsApiService();
    await _pumpScreen(tester,
        trip: _trip(), review: review, accommodations: accommodations);

    final callsBefore = review.calls;
    review.resolved = true; // server now considers it booked
    await tester.tap(find.widgetWithText(FilledButton, 'Mark booked'));
    await tester.pumpAndSettle();

    expect(accommodations.patches, hasLength(1));
    expect(accommodations.patches.single['id'], 'acc-1');
    expect(accommodations.patches.single['booked'], true);
    // Review re-read (invalidated) — and the resolved finding is gone.
    expect(review.calls, greaterThan(callsBefore));
    expect(find.widgetWithText(FilledButton, 'Mark booked'), findsNothing);
  });

  testWidgets('mark_booked (segment) PATCHes the transport segment',
      (tester) async {
    final review = _FakeReviewApiService([
      _finding('transit', 'Ferry not booked',
          const FindingFix(
              action: 'mark_booked',
              label: 'Mark booked',
              itemId: 'seg-1',
              entityType: 'segment')),
    ]);
    final transport = _FakeTransportApiService();
    await _pumpScreen(tester,
        trip: _trip(), review: review, transport: transport);

    await tester.tap(find.widgetWithText(FilledButton, 'Mark booked'));
    await tester.pumpAndSettle();

    expect(transport.patches, hasLength(1));
    expect(transport.patches.single['id'], 'seg-1');
    expect(transport.patches.single['booked'], true);
  });

  testWidgets('move_item PATCHes the item day + re-reads review',
      (tester) async {
    final trips = _FakeTripsApiService(_trip());
    final review = _FakeReviewApiService([
      _finding('unscheduled', 'Item stranded on the wrong day',
          const FindingFix(
              action: 'move_item',
              label: 'Move to Day 2',
              itemId: 'i0',
              targetDay: 2)),
    ]);
    await _pumpScreen(tester, trip: trips.trip, review: review, trips: trips);

    final callsBefore = review.calls;
    review.resolved = true;
    await tester.tap(find.widgetWithText(FilledButton, 'Move to Day 2'));
    await tester.pumpAndSettle();

    expect(trips.itemPatches, hasLength(1));
    expect(trips.itemPatches.single['id'], 'i0');
    expect(trips.itemPatches.single['day'], 2);
    expect(review.calls, greaterThan(callsBefore));
  });

  testWidgets('add_packing adds a checklist item + re-reads review',
      (tester) async {
    final review = _FakeReviewApiService([
      _finding('packing', 'No umbrella for rainy Athens',
          const FindingFix(
              action: 'add_packing',
              label: 'Add to list',
              packingItem: 'Umbrella',
              packingCategory: 'general')),
    ]);
    final checklist = _FakeChecklistApiService();
    await _pumpScreen(tester,
        trip: _trip(), review: review, checklist: checklist);

    final callsBefore = review.calls;
    review.resolved = true;
    await tester.tap(find.widgetWithText(FilledButton, 'Add to list'));
    await tester.pumpAndSettle();

    expect(checklist.addCount, 1);
    expect(checklist.lastTitle, 'Umbrella');
    expect(checklist.lastCategory, 'general');
    expect(review.calls, greaterThan(callsBefore));
  });

  testWidgets('add_lodging opens the stay sheet prefilled with dates',
      (tester) async {
    final review = _FakeReviewApiService([
      _finding('lodging', 'No stay in Naxos',
          const FindingFix(
              action: 'add_lodging',
              label: 'Add a stay',
              city: 'Naxos',
              checkIn: '2026-08-03',
              checkOut: '2026-08-04')),
    ]);
    await _pumpScreen(tester, trip: _trip(), review: review);

    await tester.tap(find.widgetWithText(FilledButton, 'Add a stay'));
    await tester.pumpAndSettle();

    // The stay sheet is open, prefilled with a city name hint and the dates.
    expect(find.byType(AddStaySheet), findsOneWidget);
    expect(find.text('Stay in Naxos'), findsOneWidget);
    expect(find.text('2026-08-03 → 2026-08-04'), findsOneWidget);
  });

  testWidgets('add_transport opens the transport sheet prefilled',
      (tester) async {
    final review = _FakeReviewApiService([
      _finding('transit', 'No transport Athens → Naxos',
          const FindingFix(
              action: 'add_transport',
              label: 'Add transport',
              origin: 'Athens',
              destination: 'Naxos',
              mode: 'ferry',
              date: '2026-08-03')),
    ]);
    await _pumpScreen(tester, trip: _trip(), review: review);

    await tester.tap(find.widgetWithText(FilledButton, 'Add transport'));
    await tester.pumpAndSettle();

    expect(find.byType(AddSegmentSheet), findsOneWidget);
    Finder inSheet(String text) => find.descendant(
        of: find.byType(AddSegmentSheet), matching: find.text(text));
    expect(inSheet('Athens'), findsOneWidget);
    expect(inSheet('Naxos'), findsOneWidget);
    // Prefilled departure date shows on the date button.
    expect(inSheet('2026-08-03'), findsOneWidget);
  });

  testWidgets(
      'health and packing live in the app bar; Budget is a header tab',
      (tester) async {
    // Layout contract (friction-log 2026-08-13, evolving 2026-08-04): Trip
    // health left the trailing cluster for the always-visible app-bar icon
    // (its count badge is the glanceable state), Budget left it for the
    // third header tab, and What to wear & pack — the cluster's last row —
    // left for the app-bar luggage icon, retiring the cluster entirely.
    final review = _FakeReviewApiService([
      _finding('packing', 'No umbrella for rainy Athens',
          const FindingFix(
              action: 'add_packing',
              label: 'Add to list',
              packingItem: 'Umbrella',
              packingCategory: 'general')),
    ]);
    await _pumpScreen(tester,
        trip: _trip(),
        review: review,
        checklist: _FakeChecklistApiService(),
        budget: _FakeBudgetApiService(),
        openSheet: false);

    // Both contextual entries are app-bar icons; neither renders a body row.
    expect(find.byTooltip('Trip health'), findsOneWidget);
    expect(find.text('Trip health'), findsNothing);
    expect(find.byTooltip('What to wear & pack'), findsOneWidget);
    expect(find.text('What to wear & pack'), findsNothing);

    // Budget renders exactly once — as the tab.
    final budgetTab = find.text('Budget');
    expect(budgetTab, findsOneWidget);

    // Tapping it swaps the body for the budget view; the app-bar icons are
    // not view-gated and stay put.
    await tester.tap(budgetTab);
    await tester.pumpAndSettle();
    expect(find.text('No budget yet'), findsOneWidget);
    expect(find.byTooltip('What to wear & pack'), findsOneWidget);
  });
}
