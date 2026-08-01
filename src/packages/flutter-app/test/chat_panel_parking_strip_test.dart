import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart' show LinkDelegate;
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:travel_route_planner/models/agent_place.dart';
import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';
import 'package:travel_route_planner/widgets/place_photo_card.dart';

import 'support/l10n_test_app.dart';

/// The parking photo-card rail (SSE `parking`, specs/find-parking-near-beach):
/// free-flagged cards show the "Free (listed)" marker (heuristic honesty —
/// never plain "Free"), taps open Google Maps, and Add-to-trip stays
/// signed-in-only like the other rails.

class _StubPlanService extends PlanService {
  _StubPlanService() : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
  }) async* {}
}

class _SeededPlanNotifier extends PlanNotifier {
  _SeededPlanNotifier(PlanState seeded, PlanService service)
      : super(service, ApiClient()) {
    state = seeded;
  }
}

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

class _FakeUrlLauncher extends UrlLauncherPlatform {
  final launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

UserModel _user() => UserModel(
      id: 'user-1',
      email: 'test@example.com',
      displayName: 'Traveler',
      createdAt: DateTime(2026, 1, 1),
    );

const _freeSpot = AgentPlace(
  name: 'Free Beach Parking',
  placeId: 'pk-free',
  address: 'Passeig Marítim 1',
  lat: 41.379,
  lng: 2.192,
  category: 'parking',
  photoRef: 'PARK-REF-1',
  photoAttribution: 'Snapper',
  freeListed: true,
);

const _paidSpot = AgentPlace(
  name: 'Central Parking BCN',
  placeId: 'pk-paid',
  address: 'Carrer de la Marina 19',
  lat: 41.3786,
  lng: 2.1925,
  rating: 4.1,
  category: 'parking',
  freeListed: false,
);

PlanState _stateWith({List<AgentPlace>? parkingSpots, String? parkingBeach}) =>
    PlanState(
      messages: [
        PlanMessage(role: MessageRole.user, content: 'where can we park?'),
      ],
      parkingSpots: parkingSpots,
      parkingBeach: parkingBeach,
    );

Future<void> _pumpSeeded(
  WidgetTester tester,
  PlanState seeded, {
  bool signedIn = false,
}) async {
  final provider = StateNotifierProvider<PlanNotifier, PlanState>(
      (ref) => _SeededPlanNotifier(seeded, _StubPlanService()));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider
            .overrideWith((ref) => _FakeAuthNotifier(signedIn ? _user() : null)),
      ],
      child: localizedTestApp(
        home: Scaffold(
          body: ChatPanel(state: provider, notifier: provider.notifier),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('parking rail renders with beach label and free marker',
      (tester) async {
    await _pumpSeeded(
      tester,
      _stateWith(
        parkingSpots: const [_freeSpot, _paidSpot],
        parkingBeach: 'Barceloneta Beach',
      ),
    );

    expect(find.byType(PlacePhotoStrip), findsOneWidget);
    expect(find.text('2 parking options · Barceloneta Beach'), findsOneWidget);
    expect(find.text('Free Beach Parking'), findsOneWidget);
    expect(find.text('Central Parking BCN'), findsOneWidget);
    // Exactly the flagged card carries the heuristic marker; the unflagged
    // one keeps its rating row instead.
    expect(find.text('Free (listed)'), findsOneWidget);
    expect(find.text('4.1'), findsOneWidget);
    // Header + both photo-less card fallbacks use the parking glyph.
    expect(find.byIcon(Icons.local_parking), findsNWidgets(3));
  });

  testWidgets('card tap opens Google Maps with the place id', (tester) async {
    final launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;

    await _pumpSeeded(
        tester, _stateWith(parkingSpots: const [_freeSpot]));
    await tester.tap(find.text('Free Beach Parking'));
    await tester.pump();

    expect(launcher.launched, hasLength(1));
    expect(launcher.launched.single, contains('query=Free+Beach+Parking'));
    expect(launcher.launched.single, contains('query_place_id=pk-free'));
  });

  testWidgets('add-to-trip is hidden for anonymous sessions', (tester) async {
    await _pumpSeeded(tester, _stateWith(parkingSpots: const [_freeSpot]));
    expect(find.byIcon(Icons.add_location_alt_outlined), findsNothing);
  });

  // Separate tree per auth state: re-pumping with different overrides would
  // keep the first ProviderScope's cached auth notifier.
  testWidgets('add-to-trip shows when signed in', (tester) async {
    await _pumpSeeded(tester, _stateWith(parkingSpots: const [_freeSpot]),
        signedIn: true);
    expect(find.byIcon(Icons.add_location_alt_outlined), findsOneWidget);
  });

  testWidgets('lays out without overflow in the 400px refine dock',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpSeeded(
      tester,
      _stateWith(
        parkingSpots: const [_freeSpot, _paidSpot, _freeSpot],
        parkingBeach: 'a very long beach name label that must ellipsize',
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
