import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/chat_session.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/recent_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/screens/home_screen.dart';
import 'package:travel_route_planner/widgets/continue_chats_section.dart';

import 'support/l10n_test_app.dart';

/// Home-screen slotting of the "Continue where you left off" section
/// (specs/continue-where-you-left-off): one merged surface holding the
/// recently viewed trip card and in-progress plan chats under a single
/// header; the section collapses to nothing when there is nothing to resume.
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

UserModel _user() => UserModel(
      id: 'user-1',
      email: 'test@example.com',
      displayName: 'Brian',
      createdAt: DateTime(2026, 1, 1),
    );

ChatSessionSummary _chat(String id, String title) => ChatSessionSummary(
      chatId: id,
      title: title,
      preview: 'Thinking about a week of island hopping.',
      messageCount: 4,
      createdAt: '2026-07-01T10:00:00Z',
      updatedAt: '2026-07-02T10:00:00Z',
    );

/// Seeds the persisted recent-trip snapshot the way the detail screen would
/// have recorded it (recent_trip_provider storage format, keyed by user).
void _seedRecentTrip(String tripId, String title) {
  SharedPreferences.setMockInitialValues({
    'recent_trip.user-1': jsonEncode({
      'id': tripId,
      'title': title,
      'status': 'planned',
    }),
  });
}

Future<void> _pumpHome(
  WidgetTester tester, {
  List<ChatSessionSummary> chats = const [],
  ContinueTrip? continueTrip,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
        liveTripProvider.overrideWithValue(null),
        resumableChatsProvider.overrideWith((ref) async => chats),
        // Left un-overridden by default so the seeded-prefs cases above still
        // exercise the real derivation (empty trips list => the stored
        // snapshot). Supplied only where the point is a trip the device has
        // no record of.
        if (continueTrip != null)
          continueTripProvider.overrideWithValue(continueTrip),
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: HomeScreen()),
    ),
  );
  // Extra pumps flush the SharedPreferences read behind recentTripProvider
  // and the resumable-chats future.
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('in-progress chats surface on home', (WidgetTester tester) async {
    await _pumpHome(tester, chats: [_chat('c1', 'Greek islands in September')]);

    expect(find.text('Continue where you left off'), findsOneWidget);
    expect(find.byType(ContinueChatCard), findsOneWidget);
    expect(find.text('Greek islands in September'), findsOneWidget);
  });

  testWidgets('section collapses when there is nothing to resume',
      (WidgetTester tester) async {
    await _pumpHome(tester);

    expect(find.text('Continue where you left off'), findsNothing);
    expect(find.byType(ContinueChatCard), findsNothing);
  });

  testWidgets('recent trip alone still renders the section',
      (WidgetTester tester) async {
    _seedRecentTrip('t1', 'Lisbon Trip');
    await _pumpHome(tester);

    expect(find.text('Continue where you left off'), findsOneWidget);
    expect(find.text('Lisbon Trip'), findsOneWidget);
    expect(find.byType(ContinueChatCard), findsNothing);
  });

  testWidgets('a trip this device has no record of still carries the section',
      (WidgetTester tester) async {
    // No seeded prefs — the post-cutover state: origin-scoped storage is
    // empty, but the account still has trips, so the section must not
    // collapse the way it did on anemos.travel launch day.
    await _pumpHome(tester, continueTrip: (
      tripId: 't9',
      title: 'Athens & the islands',
      dateRange: 'Sep 1 – Sep 8',
      startDate: null,
    ));

    expect(find.text('Continue where you left off'), findsOneWidget);
    expect(find.text('Athens & the islands'), findsOneWidget);
    expect(find.text('Sep 1 – Sep 8'), findsOneWidget);
    expect(find.byType(ContinueChatCard), findsNothing);
  });

  testWidgets('recent trip and chats share one header, trip card first',
      (WidgetTester tester) async {
    _seedRecentTrip('t1', 'Lisbon Trip');
    await _pumpHome(tester, chats: [_chat('c1', 'Greek islands in September')]);

    expect(find.text('Continue where you left off'), findsOneWidget);
    expect(find.byType(ContinueChatCard), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Lisbon Trip')).dy,
      lessThan(tester.getTopLeft(find.byType(ContinueChatCard)).dy),
    );
  });
}
