import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/suggestions_provider.dart';
import 'package:travel_route_planner/screens/home_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/near_me_chip.dart';

import 'support/l10n_test_app.dart';

/// Home entry points for "What's near me?": the chip renders in both hero
/// branches, and (on the VM's no-geolocation stub path) a typed place lands in
/// the plan chat with the tab switched — the same startPlanning contract as
/// the suggestion chips.
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

/// Records sendMessage calls instead of streaming; no network.
class _RecordingPlanNotifier extends PlanNotifier {
  final List<(String, String?)> sent = [];

  _RecordingPlanNotifier() : super(PlanService('http://unused'), ApiClient());

  @override
  Future<void> sendMessage(String text,
      {String? displayLabel, List<PlanAttachment> attachments = const []}) async {
    sent.add((text, displayLabel));
  }
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

void main() {
  late ProviderContainer container;
  late _RecordingPlanNotifier plan;

  Future<void> pumpHome(WidgetTester tester, {Trip? liveTrip}) async {
    SharedPreferences.setMockInitialValues({});
    plan = _RecordingPlanNotifier();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
          liveTripProvider.overrideWithValue(liveTrip),
          resumableChatsProvider.overrideWith((ref) async => const []),
          planProvider.overrideWith((ref) => plan),
          // Pin the random picks to the legacy trio so the literal chip
          // assertions below stay deterministic.
          suggestionPickerProvider.overrideWithValue(() => const [0, 1, 2]),
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
  }

  testWidgets('new-user hero leads its chips with the near-me starter',
      (WidgetTester tester) async {
    await pumpHome(tester);
    expect(find.byType(NearMeChip), findsOneWidget);
    expect(find.text("What's near me?"), findsOneWidget);
    expect(find.text('2 days in Paris'), findsOneWidget); // hero branch
  });

  testWidgets('returning-user strip keeps a near-me chip beneath it',
      (WidgetTester tester) async {
    await pumpHome(tester, liveTrip: _liveTrip());
    expect(find.text('2 days in Paris'), findsNothing); // strip branch
    expect(find.byType(NearMeChip), findsOneWidget);
  });

  testWidgets('typed place switches to the Plan tab and seeds the chat',
      (WidgetTester tester) async {
    await pumpHome(tester, liveTrip: _liveTrip());

    // VM stub has no geolocation → the manual dialog is the expected path.
    await tester.tap(find.text("What's near me?"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Lisbon');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();

    expect(container.read(navIndexProvider), AppTab.plan.index);
    expect(plan.sent, hasLength(1));
    expect(plan.sent.single.$1, contains('Lisbon'));
    expect(plan.sent.single.$2, isNull);
  });
}
