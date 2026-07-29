import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart' show LinkDelegate;
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:travel_route_planner/models/agent_place.dart';
import 'package:travel_route_planner/models/event.dart';
import 'package:travel_route_planner/models/flight_offer.dart';
import 'package:travel_route_planner/models/local_recommendation.dart';
import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';
import 'package:travel_route_planner/widgets/place_photo_card.dart';
import 'package:travel_route_planner/widgets/result_summary_chip.dart';

import 'support/l10n_test_app.dart';

/// The chat photo-card strips (places / local picks / events): rails replace
/// the corresponding summary chips, photo failures fall back to the category
/// icon box, attribution shows, cards act (maps launch, add-to-trip), and the
/// 400px refine dock lays out without overflow.

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
  _SeededPlanNotifier(PlanState seeded, PlanService service, {String? tripId})
      : super(service, ApiClient(), tripId: tripId) {
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

const _place = AgentPlace(
  name: 'Bar El Comercio',
  placeId: 'p1',
  address: 'Calle Lineros 9',
  lat: 37.39,
  lng: -5.99,
  rating: 4.5,
  priceLevel: 2,
  category: 'restaurant',
  photoRef: 'REF-1',
  photoAttribution: 'Jane D',
);

const _rec = LocalRecommendation(
  id: 'r1',
  name: 'Ta Karamanlidika',
  city: 'Athens',
  neighborhood: 'Psiri',
  category: 'restaurant',
  sourceName: 'Eleni',
  sourceCredibility: 'Athens chef',
  photoRef: 'REF-venue',
  photoAttribution: 'Local Snapper',
);

const _event = Event(
  id: 'e1',
  name: 'Rooftop Jazz Night',
  venue: 'Half Note',
  startDate: '2026-08-14',
  startTime: '21:00',
  url: 'https://tickets.example.com/jazz',
  imageUrl: 'https://images.example.com/jazz.jpg',
);

PlanState _stateWith({
  List<AgentPlace>? places,
  String? placesQuery,
  List<LocalRecommendation>? localRecs,
  String? localRecsCity,
  List<Event>? events,
  String? eventsCity,
  List<FlightOffer>? flights,
}) =>
    PlanState(
      messages: [
        PlanMessage(role: MessageRole.user, content: 'where should I eat?'),
      ],
      places: places,
      placesQuery: placesQuery,
      localRecs: localRecs,
      localRecsCity: localRecsCity,
      eventResults: events,
      eventsCityLabel: eventsCity,
      flightOffers: flights,
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
  testWidgets('strips render for all three sources; their chips are gone',
      (tester) async {
    await _pumpSeeded(
      tester,
      _stateWith(
        places: const [_place],
        placesQuery: 'tapas in seville',
        localRecs: const [_rec],
        localRecsCity: 'Athens',
        events: const [_event],
        eventsCity: 'Athens',
        flights: const [],
      ),
    );

    expect(find.byType(PlacePhotoStrip), findsNWidgets(3));
    expect(find.text('Bar El Comercio'), findsOneWidget);
    expect(find.text('Ta Karamanlidika'), findsOneWidget);
    expect(find.text('Rooftop Jazz Night'), findsOneWidget);
    expect(find.text('1 place · tapas in seville'), findsOneWidget);
    expect(find.text('1 local pick · Athens'), findsOneWidget);
    expect(find.text('1 event · Athens'), findsOneWidget);

    // The rails replaced the local-picks/events chips outright.
    expect(find.byType(ResultSummaryChip), findsNothing);
  });

  testWidgets('flights keep their summary chip alongside a strip',
      (tester) async {
    await _pumpSeeded(
      tester,
      _stateWith(
        places: const [_place],
        flights: const [
          FlightOffer(
            id: 'f1',
            price: 120,
            currency: 'EUR',
            stops: 0,
            durationMinutes: 150,
            airlines: ['A1'],
            departTime: '2026-08-01T08:00',
            arriveTime: '2026-08-01T10:30',
            segments: [],
          ),
        ],
      ),
    );

    expect(find.byType(PlacePhotoStrip), findsOneWidget);
    expect(find.byType(ResultSummaryChip), findsOneWidget);
    expect(find.textContaining('flight option'), findsOneWidget);
  });

  testWidgets(
      'failed photo falls back to the category icon; attribution overlays',
      (tester) async {
    // The flutter_test HttpClient 400s every request, so Image.network's
    // errorBuilder path IS the default path here — no mocking needed.
    await _pumpSeeded(tester, _stateWith(places: const [_place]));
    await tester.pump();

    expect(find.byIcon(Icons.restaurant), findsOneWidget);
    expect(find.text('Jane D'), findsOneWidget);
    // Rating row renders with the price level.
    expect(find.text('4.5'), findsOneWidget);
    expect(find.textContaining('\$\$'), findsOneWidget);
  });

  testWidgets('local pick card shows the verified badge with credit tooltip',
      (tester) async {
    await _pumpSeeded(tester, _stateWith(localRecs: const [_rec]));

    final tooltip = tester.widget<Tooltip>(find.ancestor(
      of: find.byIcon(Icons.verified).last,
      matching: find.byType(Tooltip),
    ));
    expect(tooltip.message, 'Eleni · Athens chef');
  });

  testWidgets('card tap opens Google Maps with the place id', (tester) async {
    final launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;

    await _pumpSeeded(tester, _stateWith(places: const [_place]));
    await tester.tap(find.text('Bar El Comercio'));
    await tester.pump();

    expect(launcher.launched, hasLength(1));
    // Uri.encodeQueryComponent form-encodes spaces as '+'.
    expect(launcher.launched.single, contains('query=Bar+El+Comercio'));
    expect(launcher.launched.single, contains('query_place_id=p1'));
  });

  testWidgets('event card tap opens the ticket URL', (tester) async {
    final launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;

    await _pumpSeeded(tester, _stateWith(events: const [_event]));
    expect(find.byIcon(Icons.open_in_new), findsOneWidget);

    await tester.tap(find.text('Rooftop Jazz Night'));
    await tester.pump();
    expect(launcher.launched.single, 'https://tickets.example.com/jazz');
  });

  // Two separate trees: re-pumping one tree with different overrides would
  // keep the first ProviderScope's cached auth notifier.
  testWidgets('add-to-trip is hidden for anonymous sessions', (tester) async {
    await _pumpSeeded(tester, _stateWith(places: const [_place]));
    expect(find.byIcon(Icons.add_location_alt_outlined), findsNothing);
  });

  testWidgets('add-to-trip opens the trip picker when signed in',
      (tester) async {
    await _pumpSeeded(tester, _stateWith(places: const [_place]),
        signedIn: true);
    await tester.tap(find.byIcon(Icons.add_location_alt_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The trip-picker bottom sheet is open (its title renders even while the
    // trips list is still loading/erroring in the test environment).
    expect(find.text('Add to trip'), findsWidgets);
  });

  testWidgets('lays out without overflow in the 400px refine dock and 760px tab',
      (tester) async {
    for (final width in [400.0, 760.0]) {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpSeeded(
        tester,
        _stateWith(
          places: const [_place, _place, _place],
          placesQuery: 'a very long search query label that must ellipsize',
          localRecs: const [_rec],
          events: const [_event],
        ),
      );
      expect(tester.takeException(), isNull,
          reason: 'overflow at ${width.toInt()}px');
    }
  });
}
