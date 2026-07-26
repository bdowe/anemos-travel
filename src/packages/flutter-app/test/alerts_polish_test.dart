import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/notification.dart';
import 'package:travel_route_planner/models/price_alert.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/alerts_provider.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/notifications_provider.dart';
import 'package:travel_route_planner/screens/alerts_screen.dart';
import 'package:travel_route_planner/screens/flight_search_screen.dart';
import 'package:travel_route_planner/screens/notification_center_screen.dart';
import 'package:travel_route_planner/services/alerts_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/notifications_api_service.dart';
import 'package:travel_route_planner/widgets/create_alert_sheet.dart';

import 'support/l10n_test_app.dart';

class _FakeAuthNotifier extends StateNotifier<AuthState>
    implements AuthNotifier {
  _FakeAuthNotifier(UserModel? user)
      : super(AuthState(user: user, initialized: true));

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

class _FakeAlertsApiService extends AlertsApiService {
  final List<PriceAlert> alerts;
  _FakeAlertsApiService(this.alerts) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<PriceAlert>> list() async => alerts;
}

class _FakeNotificationsApiService extends NotificationsApiService {
  final List<AppNotification> notifications;
  _FakeNotificationsApiService(this.notifications)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<AppNotification>> list({int limit = 50}) async => notifications;

  @override
  Future<void> markRead() async {}

  @override
  Future<int> unreadCount() async =>
      notifications.where((n) => n.isUnread).length;
}

UserModel _user() => UserModel(
      id: 'user-1',
      email: 'test@example.com',
      displayName: 'Test',
      createdAt: DateTime(2026, 1, 1),
    );

Future<void> _pumpAlerts(
  WidgetTester tester, {
  List<PriceAlert> alerts = const [],
  Locale? locale,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
        alertsApiServiceProvider
            .overrideWithValue(_FakeAlertsApiService(alerts)),
        notificationsUnreadCountProvider.overrideWith((ref) async => 0),
      ],
      child: localizedTestApp(home: const AlertsScreen(), locale: locale),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'create-alert sheet survives 360x640 with the keyboard up and the '
      'target-price field enabled', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          supportedLocales: const [Locale('en'), Locale('es')],
          // Simulated soft keyboard: modal sheets resolve viewInsets from the
          // app-level MediaQuery, so overriding it here raises the keyboard
          // for everything the Navigator pushes.
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(viewInsets: const EdgeInsets.only(bottom: 280)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => CreateAlertSheet.show(
                  context,
                  const CreateAlertSheet(
                    origin: 'JFK',
                    destination: 'CDG',
                    departDate: '2026-09-01',
                    returnDate: '2026-09-10',
                    adults: 2,
                    cabinClass: 'business',
                    currentPrice: 842,
                    currency: 'USD',
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Enable the target-price field — exactly the branch that grows the
    // sheet and summons the keyboard.
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
    // The Create button stays reachable inside the scrollable sheet.
    // bySubtype: FilledButton.icon builds a private FilledButton subtype.
    expect(
      find.ancestor(
        of: find.text('Create alert'),
        matching: find.bySubtype<FilledButton>(),
      ),
      findsOneWidget,
    );
  });

  testWidgets('alert card renders the localized cabin label in Spanish',
      (tester) async {
    await _pumpAlerts(
      tester,
      locale: const Locale('es'),
      alerts: const [
        PriceAlert(
          id: 'a1',
          origin: 'BOS',
          destination: 'CDG',
          departDate: '2026-09-01',
          cabinClass: 'premium_economy',
          status: 'active',
        ),
      ],
    );

    // The shared cabinClassLabel path: es shows the translated label, never
    // the raw backend enum.
    expect(find.textContaining('Económica premium'), findsOneWidget);
    expect(find.textContaining('premium_economy'), findsNothing);
    expect(find.textContaining('premium economy'), findsNothing);
  });

  testWidgets('a malformed createdAt renders the row without a timestamp',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
          notificationsApiServiceProvider.overrideWithValue(
            _FakeNotificationsApiService(const [
              AppNotification(
                id: 'g1',
                type: 'trip_reminder',
                payload: {'title': 'Paris trip starts soon'},
                createdAt: 'garbage',
              ),
            ]),
          ),
        ],
        child: localizedTestApp(home: const NotificationCenterScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // No FormatException red screen; the row itself still renders.
    expect(tester.takeException(), isNull);
    expect(find.text('Paris trip starts soon'), findsOneWidget);
  });

  testWidgets('alerts empty state CTA pushes the flight search screen',
      (tester) async {
    // Tall surface: the (pre-rework) flight search form is a fixed column
    // that needs phone-plus height to lay out without overflow.
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpAlerts(tester);

    // bySubtype: FilledButton.icon builds a private FilledButton subtype.
    final cta = find.ancestor(
      of: find.text('Search flights'),
      matching: find.bySubtype<FilledButton>(),
    );
    expect(cta, findsOneWidget);

    await tester.tap(cta);
    await tester.pumpAndSettle();

    expect(find.byType(FlightSearchScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
