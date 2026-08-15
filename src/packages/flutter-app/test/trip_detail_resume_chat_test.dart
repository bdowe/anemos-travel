import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/chat_session.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/trip_refine_chat.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';

import 'support/l10n_test_app.dart';

/// Coming back to a trip's conversation after a reload
/// (specs/trip-refine-memory): the page says one is waiting, opening it
/// restores the transcript, and every failure is answered where the traveler
/// asked — in the panel — never as a snackbar over the itinerary.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  final TripRefineChatDetail? detail;
  final Object? failWith;

  /// Gates the fetch so a test can inspect the loading state.
  final Completer<void>? gate;

  int getChatCalls = 0;
  int deleteCalls = 0;

  _FakeTripsApiService(this.trip, {this.detail, this.failWith, this.gate})
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;

  @override
  Future<TripRefineChatDetail> getTripRefineChat(String tripId) async {
    getChatCalls++;
    if (gate != null) await gate!.future;
    final e = failWith;
    if (e != null) throw e;
    return detail!;
  }

  @override
  Future<void> deleteTripRefineChat(String tripId) async {
    deleteCalls++;
  }
}

class _SilentPlanService extends PlanService {
  _SilentPlanService() : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {}
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

Trip _trip({TripRefineChat? chat, bool withItems = true}) => Trip(
      id: 't1',
      title: 'Greek Islands',
      startDate: '2026-08-01',
      endDate: '2026-08-05',
      createdAt: '2026-07-01',
      updatedAt: '2026-07-01',
      refineChat: chat,
      items: withItems
          ? [
              _item(0, 'Acropolis', day: 1, city: 'Athens'),
              _item(1, 'Portara', day: 2, city: 'Naxos'),
            ]
          : const [],
    );

TripRefineChat _summary({int count = 4}) => TripRefineChat(
      messageCount: count,
      preview: 'Naxos then Paros.',
      updatedAt: '2026-07-30T10:00:00Z',
    );

TripRefineChatDetail _detail() => const TripRefineChatDetail(
      tripId: 't1',
      summary: '',
      messages: [
        ChatSessionMessage(
            role: 'user',
            content: 'I want to refine my saved trip … latitude 37.9 …',
            displayLabel: 'Refining Day 2 — Athens'),
        ChatSessionMessage(role: 'assistant', content: 'Naxos then Paros.'),
      ],
      messageCount: 2,
      updatedAt: '2026-07-30T10:00:00Z',
    );

Widget _app(_FakeTripsApiService api) => ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(api),
        tripRefineProvider.overrideWith((ref, tripId) =>
            PlanNotifier(_SilentPlanService(), ApiClient(), tripId: tripId)),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: const TripDetailScreen(tripId: 't1'),
      ),
    );

PlanState _refineState(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(TripDetailScreen)))
        .read(tripRefineProvider('t1'));

void main() {
  testWidgets('a trip with a saved conversation says so on the page',
      (WidgetTester tester) async {
    await tester.pumpWidget(
        _app(_FakeTripsApiService(_trip(chat: _summary()), detail: _detail())));
    await tester.pumpAndSettle();

    expect(find.text('Continue chat'), findsOneWidget);
    expect(find.text('Naxos then Paros.'), findsOneWidget);
  });

  testWidgets('no saved conversation, no row', (WidgetTester tester) async {
    await tester.pumpWidget(_app(_FakeTripsApiService(_trip())));
    await tester.pumpAndSettle();

    expect(find.text('Continue chat'), findsNothing);
  });

  testWidgets('the chat is reachable on a trip with no places yet',
      (WidgetTester tester) async {
    // The zero-item plan_itinerary Next Step seeds a chat on an empty trip, so
    // gating the FAB on items would strand the saved conversation on exactly
    // the trips that most need it.
    await tester.pumpWidget(_app(_FakeTripsApiService(
        _trip(chat: _summary(), withItems: false),
        detail: _detail())));
    await tester.pumpAndSettle();

    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.text('Continue chat'), findsOneWidget);
  });

  testWidgets('restoring shows the placeholder, then the transcript',
      (WidgetTester tester) async {
    final gate = Completer<void>();
    final api = _FakeTripsApiService(_trip(chat: _summary()),
        detail: _detail(), gate: gate);
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue chat'));
    await tester.pump();

    expect(find.text('Restoring your conversation…'), findsOneWidget);
    // No composer until the history is back: sending onto an empty panel would
    // overwrite the stored conversation.
    expect(find.byType(ChatPanel), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.byType(ChatPanel), findsOneWidget);
    expect(_refineState(tester).messages, hasLength(2));
    // The seed renders as its chip, not as a wall of coordinates.
    expect(find.text('Refining Day 2 — Athens'), findsWidgets);
    expect(find.textContaining('latitude 37.9'), findsNothing);
  });

  testWidgets('an expired conversation is reported in the panel, with no retry',
      (WidgetTester tester) async {
    final api = _FakeTripsApiService(
      _trip(chat: _summary()),
      failWith: const ApiException(
          statusCode: 404, message: 'gone', endpoint: '/trips/t1/refine-chat'),
    );
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue chat'));
    await tester.pumpAndSettle();

    expect(find.text('This conversation has expired.'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('New chat'), findsOneWidget);
    // Nothing was sent into the empty panel.
    expect(_refineState(tester).messages, isEmpty);
  });

  testWidgets('a failed restore offers a retry that actually refetches',
      (WidgetTester tester) async {
    final api = _FakeTripsApiService(
      _trip(chat: _summary()),
      failWith: const ApiException(
          statusCode: 500, message: 'boom', endpoint: '/trips/t1/refine-chat'),
    );
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue chat'));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't reopen this conversation."), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(api.getChatCalls, 1);

    // The failure block scrolls inside the narrow sheet (it is taller than the
    // 0.45 opening height), so bring the action into view like a traveler
    // dragging the sheet would.
    await tester.ensureVisible(find.text('Retry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(api.getChatCalls, 2);
  });

  testWidgets('a failed restore blocks the ✨ from sending onto an empty panel',
      (WidgetTester tester) async {
    // The load-bearing guard. The transcript is upserted wholesale every turn,
    // so seeding a panel that failed to restore would overwrite a long stored
    // conversation with two messages.
    final api = _FakeTripsApiService(
      _trip(chat: _summary()),
      failWith: const ApiException(
          statusCode: 500, message: 'boom', endpoint: '/trips/t1/refine-chat'),
    );
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue chat'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't reopen this conversation."), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refine with AI'));
    await tester.pumpAndSettle();

    expect(_refineState(tester).messages, isEmpty,
        reason: 'nothing may be sent until the stored transcript is back');
  });

  testWidgets('an in-memory conversation reopens without a fetch',
      (WidgetTester tester) async {
    final api =
        _FakeTripsApiService(_trip(chat: _summary()), detail: _detail());
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue chat'));
    await tester.pumpAndSettle();
    expect(api.getChatCalls, 1);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // Memory beats server: refetching would discard anything mid-stream.
    expect(api.getChatCalls, 1);
    expect(_refineState(tester).messages, hasLength(2));
  });

  testWidgets('New chat clears the conversation only after confirmation',
      (WidgetTester tester) async {
    final api =
        _FakeTripsApiService(_trip(chat: _summary()), detail: _detail());
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue chat'));
    await tester.pumpAndSettle();
    expect(_refineState(tester).messages, hasLength(2));

    await tester.tap(find.byTooltip('New chat'));
    await tester.pumpAndSettle();
    expect(find.text('Start a new chat?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_refineState(tester).messages, hasLength(2));
    expect(api.deleteCalls, 0);

    await tester.tap(find.byTooltip('New chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
    await tester.pumpAndSettle();

    expect(_refineState(tester).messages, isEmpty);
    expect(api.deleteCalls, 1);
  });
}
