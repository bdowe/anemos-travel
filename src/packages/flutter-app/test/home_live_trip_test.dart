import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/screens/home_screen.dart';
import 'package:travel_route_planner/widgets/live_trip_card.dart';

import 'support/l10n_test_app.dart';

/// Home-screen slotting of the "Happening now" card (specs/happening-now):
/// the live card takes the recent-trip slot, and the recent-trip tile only
/// renders below it — inside the "Continue where you left off" section —
/// when it points at a *different* trip.
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

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Trip _liveTrip(String id) => Trip(
      id: id,
      title: 'Athens Trip',
      status: 'planned',
      startDate: _iso(DateTime.now().subtract(const Duration(days: 1))),
      endDate: _iso(DateTime.now().add(const Duration(days: 1))),
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
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

Future<void> _pumpHome(WidgetTester tester, Trip? liveTrip) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
        liveTripProvider.overrideWithValue(liveTrip),
        // Signed-in fake auth would otherwise trigger a real chats fetch
        // behind the home ContinueChatsSection.
        resumableChatsProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: HomeScreen()),
    ),
  );
  // Extra pumps flush the SharedPreferences read behind recentTripProvider.
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('live card shows in the recent-trip slot',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHome(tester, _liveTrip('t1'));

    expect(find.byType(LiveTripCard), findsOneWidget);
    expect(find.text('HAPPENING NOW'), findsOneWidget);
    expect(find.text('Day 2 of 3'), findsOneWidget);
  });

  testWidgets('recent-trip tile hides when it is the live trip',
      (WidgetTester tester) async {
    _seedRecentTrip('t1', 'Athens Trip');
    await _pumpHome(tester, _liveTrip('t1'));

    expect(find.byType(LiveTripCard), findsOneWidget);
    // No chats and the recent trip is the live trip, so the whole
    // "Continue where you left off" section collapses.
    expect(find.text('Continue where you left off'), findsNothing);
  });

  testWidgets('both cards show when the recent trip is a different trip',
      (WidgetTester tester) async {
    _seedRecentTrip('t2', 'Lisbon Trip');
    await _pumpHome(tester, _liveTrip('t1'));

    expect(find.byType(LiveTripCard), findsOneWidget);
    expect(find.text('Continue where you left off'), findsOneWidget);
    expect(find.text('Lisbon Trip'), findsOneWidget);

    // The live card leads the slot; the recent tile sits below it under the
    // continue header.
    expect(
      tester.getTopLeft(find.byType(LiveTripCard)).dy,
      lessThan(tester.getTopLeft(find.text('Lisbon Trip')).dy),
    );
  });

  testWidgets('no live trip leaves the recent-trip tile alone',
      (WidgetTester tester) async {
    _seedRecentTrip('t2', 'Lisbon Trip');
    await _pumpHome(tester, null);

    expect(find.byType(LiveTripCard), findsNothing);
    expect(find.text('Continue where you left off'), findsOneWidget);
    expect(find.text('Lisbon Trip'), findsOneWidget);
  });
}
