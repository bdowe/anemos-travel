import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart' show LinkDelegate;
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:travel_route_planner/models/hotel_stay.dart';
import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/models/source_link.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';
import 'package:travel_route_planner/widgets/place_photo_card.dart';
import 'package:travel_route_planner/widgets/source_links_card.dart';

import 'support/l10n_test_app.dart';

/// The hotel photo-card rail (SSE `hotels`, specs/hotel-search).
///
/// The invariant worth a test: a rates-tier result and a discovery-tier result
/// look identical apart from the price, so the tier has to be VISIBLE. A
/// discovery result that silently omits prices reads as "these are the ones we
/// found" and a traveler cannot tell that nothing was priced.

class _StubPlanService extends PlanService {
  _StubPlanService() : super('http://unused');

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

const _priced = HotelStay(
  name: 'Moxy Athens City',
  kind: 'hotel',
  starClass: 3,
  rating: 4.5,
  reviews: 1255,
  ratePerNight: 154,
  totalRate: 614,
  currency: 'USD',
  address: 'Falirou 3, Athens',
  imageUrl: 'https://lh3.googleusercontent.com/hotel',
  bookingUrl: 'https://www.booking.com/searchresults.html?ss=Moxy+Athens&aid=42',
);

const _rental = HotelStay(
  name: 'Duplex with terrace',
  kind: 'vacation_rental',
  rating: 4.7,
  reviews: 132,
  ratePerNight: 133,
  totalRate: 532,
  currency: 'USD',
  bookingUrl: 'https://www.booking.com/searchresults.html?ss=Duplex&aid=42',
);

const _unpriced = HotelStay(
  name: 'Hotel Grande Bretagne',
  kind: 'hotel',
  rating: 4.8,
  reviews: 6749,
  address: 'Syntagma, Athens',
  photoRef: 'GB-PHOTO-REF',
  bookingUrl: 'https://www.booking.com/searchresults.html?ss=Grande+Bretagne',
);

PlanState _stateWith(HotelStayResults? hotels) => PlanState(
      messages: [
        PlanMessage(role: MessageRole.user, content: 'where should we stay?'),
      ],
      hotels: hotels,
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
  testWidgets('rates rail shows the city and a per-night price per card',
      (tester) async {
    await _pumpSeeded(
      tester,
      _stateWith(const HotelStayResults(
        city: 'Athens',
        checkIn: '2026-09-03',
        checkOut: '2026-09-07',
        stays: [_priced, _rental],
        ratesLive: true,
      )),
    );

    expect(find.byType(PlacePhotoStrip), findsOneWidget);
    expect(find.text('2 stays · Athens'), findsOneWidget);
    expect(find.text('Moxy Athens City'), findsOneWidget);
    // The price rides the meta row beside the rating, never replacing it.
    expect(find.text('4.5'), findsOneWidget);
    expect(find.textContaining('154'), findsOneWidget);
    expect(find.textContaining('/night'), findsNWidgets(2));
    // A vacation rental is visibly not a hotel.
    expect(find.byIcon(Icons.house_outlined), findsOneWidget);
  });

  testWidgets('discovery rail says prices were not checked and shows none',
      (tester) async {
    await _pumpSeeded(
      tester,
      _stateWith(const HotelStayResults(
        city: 'Athens',
        stays: [_unpriced],
        ratesLive: false,
        ratesNote: 'no_dates',
      )),
    );

    // The caveat is on the header, where there is room for it.
    expect(find.text('1 stay · Athens · no live prices'), findsOneWidget);
    expect(find.text('Hotel Grande Bretagne'), findsOneWidget);
    expect(find.text('4.8'), findsOneWidget);
    // The whole point: not one number a traveler could read as a rate.
    expect(find.textContaining('/night'), findsNothing);
    expect(find.textContaining('\$'), findsNothing);
  });

  testWidgets('card tap opens the booking link with its affiliate id',
      (tester) async {
    final launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;

    await _pumpSeeded(
        tester,
        _stateWith(const HotelStayResults(
            city: 'Athens', stays: [_priced], ratesLive: true)));
    await tester.tap(find.text('Moxy Athens City'));
    await tester.pump();

    expect(launcher.launched, hasLength(1));
    expect(launcher.launched.single, contains('booking.com'));
    // The affiliate id is the only reason this handoff earns anything.
    expect(launcher.launched.single, contains('aid=42'));
  });

  testWidgets('cards keep the fixed 200x160 geometry when an image fails',
      (tester) async {
    await _pumpSeeded(
        tester,
        _stateWith(const HotelStayResults(
            city: 'Athens', stays: [_priced], ratesLive: true)));

    // The de-jank invariant: a price string of variable width must not be
    // able to resize a card and reflow the chat tail.
    final size = tester.getSize(find.byType(PlacePhotoCard).first);
    expect(size, const Size(kPlaceCardWidth, kPlaceCardHeight));
  });

  testWidgets('lays out without overflow in the 400px refine dock',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpSeeded(
      tester,
      _stateWith(const HotelStayResults(
        city: 'a very long city label that must ellipsize somewhere sensible',
        stays: [_priced, _rental, _unpriced],
        ratesLive: true,
      )),
    );
    expect(tester.takeException(), isNull);
  });

  // docs/friction-log.md: suggest_stays emitted a `stays` SSE event that had
  // NO case in the client switch, so the tool produced a chip that vanished
  // leaving no artifact at all. These links ARE the result, so they render as
  // openable chips rather than a summary chip pointing at the trip.
  testWidgets('suggest_stays browse links render and open', (tester) async {
    final launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;

    await _pumpSeeded(
      tester,
      PlanState(
        messages: [
          PlanMessage(role: MessageRole.user, content: 'find me a place'),
        ],
        stayLinks: const [
          SourceLink(provider: 'airbnb', url: 'https://airbnb.com/s/Athens'),
          SourceLink(provider: 'booking', url: 'https://booking.com/x'),
        ],
        stayLinksWhere: 'Athens',
      ),
    );

    expect(find.byType(SourceLinksCard), findsOneWidget);
    expect(find.text('Browse stays · Athens'), findsOneWidget);
    await tester.tap(find.text('airbnb'));
    await tester.pump();
    expect(launcher.launched.single, 'https://airbnb.com/s/Athens');
  });
}
