import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/notification.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/notifications_provider.dart';
import 'package:travel_route_planner/screens/notification_center_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/notifications_api_service.dart';

import 'support/l10n_test_app.dart';

/// Minimal auth stub — the notification providers only read `isSignedIn`.
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

class _FakeNotificationsApiService extends NotificationsApiService {
  final List<AppNotification> notifications;
  bool markReadCalled = false;
  _FakeNotificationsApiService(this.notifications)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<AppNotification>> list({int limit = 50}) async => notifications;

  @override
  Future<void> markRead() async {
    markReadCalled = true;
  }

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

AppNotification _priceDrop({
  String id = 'n1',
  String origin = 'BOS',
  String destination = 'CDG',
  double price = 412,
  double? previousPrice = 498,
  String? matchedDate,
  String? returnDate,
  String createdAt = '2026-07-15T12:00:00Z',
  String? readAt,
}) =>
    AppNotification(
      id: id,
      type: 'price_drop',
      payload: {
        'origin': origin,
        'destination': destination,
        'price': price,
        'currency': 'USD',
        'previous_price': previousPrice,
        'depart_date': '2026-09-01',
        'return_date': returnDate,
        'matched_date': matchedDate,
        'alert_status': 'active',
      },
      createdAt: createdAt,
      readAt: readAt,
    );

/// An ops health row as the API writes it: the payload carries only
/// `{degraded, reasons[]}` — no title/message — which is why these rows used to
/// fall through to the generic body and render a bare "Ops Alert".
AppNotification _ops({
  String id = 'ops-1',
  String type = 'ops_alert',
  Object? reasons = const [
    'backups stale',
    'AI provider failing: credit balance'
  ],
  String createdAt = '2026-07-15T12:00:00Z',
  String? readAt,
}) =>
    AppNotification(
      id: id,
      type: type,
      payload: {
        'degraded': type == 'ops_alert',
        if (reasons != null) 'reasons': reasons,
      },
      createdAt: createdAt,
      readAt: readAt,
    );

Future<_FakeNotificationsApiService> _pump(
  WidgetTester tester,
  List<AppNotification> notifications,
) async {
  final service = _FakeNotificationsApiService(notifications);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
        notificationsApiServiceProvider.overrideWithValue(service),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: NotificationCenterScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return service;
}

void main() {
  testWidgets('price_drop tile renders route + delta from payload',
      (tester) async {
    await _pump(tester, [
      _priceDrop(price: 412, previousPrice: 498),
    ]);
    expect(find.text('BOS → CDG'), findsOneWidget);
    expect(find.textContaining('\$412, down from \$498'), findsOneWidget);
  });

  testWidgets('price_drop with no previous price shows just the new price',
      (tester) async {
    await _pump(tester, [_priceDrop(price: 300, previousPrice: null)]);
    expect(find.textContaining('\$300'), findsOneWidget);
    expect(find.textContaining('down from'), findsNothing);
  });

  testWidgets('flexible price_drop names the best-in-window date',
      (tester) async {
    await _pump(tester, [_priceDrop(matchedDate: '2026-08-31')]);
    expect(find.textContaining('2026-08-31'), findsOneWidget);
    expect(find.textContaining('best in window'), findsOneWidget);
  });

  testWidgets('newest-first ordering is preserved from the feed',
      (tester) async {
    await _pump(tester, [
      _priceDrop(id: 'new', origin: 'JFK', destination: 'LAX'),
      _priceDrop(id: 'old', origin: 'BOS', destination: 'CDG'),
    ]);
    final firstY = tester.getTopLeft(find.text('JFK → LAX')).dy;
    final secondY = tester.getTopLeft(find.text('BOS → CDG')).dy;
    expect(firstY, lessThan(secondY));
  });

  testWidgets('unknown type renders a generic tile from payload title',
      (tester) async {
    await _pump(tester, [
      const AppNotification(
        id: 'g1',
        type: 'trip_reminder',
        payload: {
          'title': 'Paris trip starts in 3 days',
          'message': 'Time to finalize your bookings.',
        },
        createdAt: '2026-07-16T12:00:00Z',
      ),
    ]);
    expect(find.text('Paris trip starts in 3 days'), findsOneWidget);
    expect(find.text('Time to finalize your bookings.'), findsOneWidget);
  });

  testWidgets('collab_edit renders "<who> edited <trip>"', (tester) async {
    await _pump(tester, [
      const AppNotification(
        id: 'c1',
        type: 'collab_edit',
        payload: {'actor_name': 'Alice', 'trip_title': 'Athens'},
        createdAt: '2026-07-16T12:00:00Z',
      ),
    ]);
    expect(find.text('Alice edited "Athens"'), findsOneWidget);
  });

  testWidgets('invite_accepted renders "<who> joined <trip>"', (tester) async {
    await _pump(tester, [
      const AppNotification(
        id: 'i1',
        type: 'invite_accepted',
        payload: {'accepter_name': 'Bob', 'trip_title': 'Lisbon'},
        createdAt: '2026-07-16T12:00:00Z',
      ),
    ]);
    expect(find.text('Bob joined "Lisbon"'), findsOneWidget);
  });

  testWidgets('share_joined viewer renders "<who> is now following <trip>"',
      (tester) async {
    await _pump(tester, [
      const AppNotification(
        id: 's1',
        type: 'share_joined',
        payload: {
          'joiner_name': 'Cara',
          'trip_title': 'Naxos',
          'role': 'viewer',
        },
        createdAt: '2026-07-16T12:00:00Z',
      ),
    ]);
    expect(find.text('Cara is now following "Naxos"'), findsOneWidget);
  });

  testWidgets('share_joined editor renders "<who> joined <trip>"',
      (tester) async {
    await _pump(tester, [
      const AppNotification(
        id: 's2',
        type: 'share_joined',
        payload: {
          'joiner_name': 'Dan',
          'trip_title': 'Naxos',
          'role': 'editor',
        },
        createdAt: '2026-07-16T12:00:00Z',
      ),
    ]);
    expect(find.text('Dan joined "Naxos"'), findsOneWidget);
  });

  testWidgets('unknown type with no title humanizes the type name',
      (tester) async {
    await _pump(tester, [
      const AppNotification(
        id: 'g2',
        type: 'weekly_digest',
        payload: {},
        createdAt: '2026-07-16T12:00:00Z',
      ),
    ]);
    expect(find.text('Weekly Digest'), findsOneWidget);
  });

  testWidgets('ops_alert names what is wrong instead of a bare type name',
      (tester) async {
    await _pump(tester, [_ops()]);
    expect(find.text('System degraded'), findsOneWidget);
    expect(find.text('• backups stale'), findsOneWidget);
    expect(find.text('• AI provider failing: credit balance'), findsOneWidget);
    // The regression this whole change exists to prevent.
    expect(find.text('Ops Alert'), findsNothing);
  });

  testWidgets('ops_recovered reads as all clear', (tester) async {
    await _pump(tester, [_ops(type: 'ops_recovered', reasons: const [])]);
    expect(find.text('System recovered'), findsOneWidget);
    expect(find.textContaining('•'), findsNothing);
    expect(find.text('Ops Recovered'), findsNothing);
  });

  testWidgets('an ops row with a missing reasons list still renders',
      (tester) async {
    await _pump(tester, [_ops(reasons: null)]);
    expect(find.text('System degraded'), findsOneWidget);
    expect(find.text('View system health'), findsOneWidget);
  });

  testWidgets('an ops row with a malformed reasons payload still renders',
      (tester) async {
    // Not a list, and a list with non-string members: neither may throw in a
    // feed row.
    await _pump(tester, [
      _ops(id: 'ops-a', reasons: 'backups stale'),
      _ops(id: 'ops-b', reasons: const [42, 'backups stale']),
    ]);
    expect(find.text('System degraded'), findsNWidgets(2));
    expect(find.text('• backups stale'), findsOneWidget);
  });

  testWidgets('ops rows are tappable; other rows are not', (tester) async {
    // The affordance is what this screen lacked; the destination is asserted
    // in admin_metrics_screen_test.dart, since pushOnActiveTab needs mounted
    // tab navigators this harness deliberately doesn't build.
    await _pump(tester, [_ops()]);
    expect(
      find.byWidgetPredicate((w) => w is InkWell && w.onTap != null),
      findsOneWidget,
    );

    await _pump(tester, [_priceDrop()]);
    expect(
      find.byWidgetPredicate((w) => w is InkWell && w.onTap != null),
      findsNothing,
    );
  });

  testWidgets('tapping an ops row does not throw without a nav host',
      (tester) async {
    await _pump(tester, [_ops()]);
    await tester.tap(find.text('System degraded'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty feed shows the how-to empty state', (tester) async {
    await _pump(tester, const []);
    expect(find.text('No notifications yet'), findsOneWidget);
  });

  testWidgets('opening the center marks all notifications read',
      (tester) async {
    final service = await _pump(tester, [_priceDrop()]);
    expect(service.markReadCalled, isTrue);
  });

  testWidgets('a malformed createdAt renders the row without a timestamp',
      (tester) async {
    await _pump(tester, const [
      AppNotification(
        id: 'g1',
        type: 'trip_reminder',
        payload: {'title': 'Paris trip starts soon'},
        createdAt: 'garbage',
      ),
    ]);

    // No FormatException red screen; the row itself still renders.
    expect(tester.takeException(), isNull);
    expect(find.text('Paris trip starts soon'), findsOneWidget);
  });
}
