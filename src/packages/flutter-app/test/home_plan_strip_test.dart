import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/suggestions_provider.dart';
import 'package:travel_route_planner/screens/home_screen.dart';

import 'support/l10n_test_app.dart';

/// Home hero split (home declutter): brand-new accounts get the full photo
/// hero with suggestion chips; returning users (any trip or in-progress
/// chat) get the compact one-row plan strip so trips sit above the fold.
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

Trip _liveTrip() => Trip(
      id: 't1',
      title: 'Athens Trip',
      startDate: _iso(DateTime.now().subtract(const Duration(days: 1))),
      endDate: _iso(DateTime.now().add(const Duration(days: 1))),
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

Future<void> _pumpHome(WidgetTester tester, {Trip? liveTrip}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
        liveTripProvider.overrideWithValue(liveTrip),
        resumableChatsProvider.overrideWith((ref) async => const []),
        // Pin the random picks to the legacy trio so the literal chip
        // assertions below stay deterministic.
        suggestionPickerProvider.overrideWithValue(() => const [0, 1, 2]),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const HomeScreen()),
    ),
  );
  // Extra pumps flush the SharedPreferences read behind recentTripProvider.
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('empty account keeps the full photo hero',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHome(tester);

    expect(find.text('Plan less. Travel more.'), findsOneWidget);
    // Scoped to the chip: the inspiration rail below the hero draws from the
    // same pool, so the bare text could also appear on a destination card.
    expect(find.widgetWithText(ActionChip, '2 days in Paris'), findsOneWidget);
    expect(find.byType(Image), findsWidgets); // photo hero present
  });

  testWidgets('live trip swaps the hero for the compact plan strip',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHome(tester, liveTrip: _liveTrip());

    // Same headline + CTA, no photo, no suggestion chips.
    expect(find.text('Plan less. Travel more.'), findsOneWidget);
    expect(find.text("Let's go"), findsOneWidget);
    expect(find.text('2 days in Paris'), findsNothing);
    expect(find.byIcon(Icons.flight_takeoff), findsOneWidget);
  });

  testWidgets('strip CTA still switches to the Plan tab',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    late final ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
          liveTripProvider.overrideWithValue(_liveTrip()),
          resumableChatsProvider.overrideWith((ref) async => const []),
        ],
        child: Builder(builder: (context) {
          container = ProviderScope.containerOf(context);
          return MaterialApp(
              localizationsDelegates: testLocalizationsDelegates,
              home: const HomeScreen());
        }),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text("Let's go"));
    await tester.pump();
    expect(container.read(navIndexProvider), AppTab.plan.index);
  });
}
