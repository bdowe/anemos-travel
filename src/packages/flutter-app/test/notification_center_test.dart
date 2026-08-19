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
import 'package:travel_route_planner/widgets/account_menu.dart';

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

  /// Flip to make the NEXT list() throw — the shape of a feed that loaded
  /// once and then failed to refresh (pull-to-refresh, retry, the on-open
  /// mark-read invalidate). Set it after the first load has settled so the
  /// failure lands on top of real data.
  Exception? failNextList;

  /// While set, EVERY list() throws — the shape of a feed that cannot load at
  /// all (the failed-open path, where mark-read must not fire).
  bool failLists = false;

  bool markReadCalled = false;
  bool clearAllCalled = false;
  Exception? clearAllError; // set to make clearAll throw

  _FakeNotificationsApiService(this.notifications)
      : super(ApiClient(baseUrl: 'http://test'));

  // Post-clear refetches observe the cleared feed, matching the real
  // contract (the client re-lists to see post-state).
  @override
  Future<List<AppNotification>> list({int limit = 50}) async {
    if (failLists) throw Exception('list down');
    final err = failNextList;
    if (err != null) {
      failNextList = null;
      throw err;
    }
    return clearAllCalled ? const [] : notifications;
  }

  @override
  Future<void> clearAll() async {
    final err = clearAllError;
    if (err != null) throw err;
    clearAllCalled = true;
  }

  @override
  Future<void> markRead() async {
    markReadCalled = true;
  }

  // Mirrors list(): a cleared feed has nothing unread, so the badge a
  // post-clear refetch observes is 0.
  @override
  Future<int> unreadCount() async =>
      clearAllCalled ? 0 : notifications.where((n) => n.isUnread).length;
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
    // tab navigators this harness deliberately doesn't build. Scoped to the
    // row's own text so the footer button's internal InkWell can't match.
    Finder rowInk(String text) => find.ancestor(
          of: find.text(text),
          matching:
              find.byWidgetPredicate((w) => w is InkWell && w.onTap != null),
        );

    await _pump(tester, [_ops()]);
    expect(rowInk('System degraded'), findsOneWidget);

    await _pump(tester, [_priceDrop()]);
    expect(rowInk('BOS → CDG'), findsNothing);
  });

  testWidgets('unread and read rows split into New and Earlier sections',
      (tester) async {
    await _pump(tester, [
      _priceDrop(id: 'u1'),
      _priceDrop(
          id: 'r1',
          origin: 'JFK',
          destination: 'LAX',
          readAt: '2026-07-15T13:00:00Z'),
    ]);
    expect(find.text('New'), findsOneWidget);
    expect(find.text('Earlier'), findsOneWidget);
    // The unread row sits under New, above the read row under Earlier.
    final newY = tester.getTopLeft(find.text('New')).dy;
    final unreadY = tester.getTopLeft(find.text('BOS → CDG')).dy;
    final earlierY = tester.getTopLeft(find.text('Earlier')).dy;
    final readY = tester.getTopLeft(find.text('JFK → LAX')).dy;
    expect(newY, lessThan(unreadY));
    expect(unreadY, lessThan(earlierY));
    expect(earlierY, lessThan(readY));
  });

  testWidgets('an all-read feed renders flat, with no section headers',
      (tester) async {
    await _pump(tester, [_priceDrop(readAt: '2026-07-15T13:00:00Z')]);
    expect(find.text('New'), findsNothing);
    expect(find.text('Earlier'), findsNothing);
    expect(find.text('BOS → CDG'), findsOneWidget);
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

  testWidgets('a failed load does not mark notifications read',
      (tester) async {
    // Marking read on a failed open would clear the badge for rows the user
    // never saw — the open sequence marks read only after rows actually load.
    final service = _FakeNotificationsApiService([_priceDrop()]);
    service.failLists = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
          notificationsApiServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: const NotificationCenterScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not load notifications'), findsOneWidget);
    expect(service.markReadCalled, isFalse);
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

  group('clear all', () {
    testWidgets('clear-all footer hidden on an empty feed, shown with rows',
        (tester) async {
      // Nothing to clear → no destructive affordance.
      await _pump(tester, const []);
      expect(find.text('Clear all'), findsNothing);

      await _pump(tester, [_priceDrop()]);
      expect(find.text('Clear all'), findsOneWidget);
    });

    testWidgets('cancel keeps the feed and calls nothing', (tester) async {
      final service = await _pump(tester, [_ops()]);
      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();
      expect(find.text('Clear all notifications?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(service.clearAllCalled, isFalse);
      expect(find.text('Clear all notifications?'), findsNothing);
      expect(find.text('System degraded'), findsOneWidget);
    });

    testWidgets('confirm clears, shows the empty state, and drops the footer',
        (tester) async {
      final service = await _pump(tester, [_ops(), _priceDrop()]);
      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(service.clearAllCalled, isTrue);
      expect(find.text('No notifications yet'), findsOneWidget);
      // The visibility rule holds post-clear: nothing left to clear, no
      // footer.
      expect(find.text('Clear all'), findsNothing);
    });

    testWidgets('a failed refresh hides the footer along with the feed',
        (tester) async {
      // An error that FOLLOWS a successful load still carries the previous
      // rows (AsyncError.copyWithPrevious), so a valueOrNull-based gate would
      // leave the destructive footer sitting over the error panel. The footer
      // must track the rendered body.
      final service = await _pump(tester, [_ops()]);
      // Assert the precondition rather than assume it: the feed really is
      // AsyncData-with-rows before the refresh fails, so this can never pass
      // vacuously through an error that carried no previous value.
      expect(find.text('Clear all'), findsOneWidget);

      service.failNextList = Exception('refresh failed');
      ProviderScope.containerOf(
              tester.element(find.byType(NotificationCenterScreen)))
          .invalidate(notificationsProvider);
      await tester.pumpAndSettle();

      expect(find.text('Could not load notifications'), findsOneWidget);
      expect(find.text('Clear all'), findsNothing);
    });

    testWidgets('clearing refreshes the unread badge', (tester) async {
      // The screen only invalidates the badge provider; nothing else watches
      // it, so this harness watches it explicitly — otherwise dropping that
      // invalidate would leave a count standing over an empty feed.
      final service = _FakeNotificationsApiService([_priceDrop()]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
            notificationsApiServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: Column(children: [
              Consumer(
                builder: (context, ref, _) => Text(
                  'badge:${ref.watch(notificationsUnreadCountProvider).valueOrNull ?? -1}',
                  textDirection: TextDirection.ltr,
                ),
              ),
              const Expanded(child: NotificationCenterScreen()),
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('badge:1'), findsOneWidget);

      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(service.clearAllCalled, isTrue);
      expect(find.text('badge:0'), findsOneWidget);
    });

    testWidgets('a failed clear shows a snackbar and keeps the rows',
        (tester) async {
      final service = await _pump(tester, [_ops()]);
      service.clearAllError = Exception('boom');
      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      // The feed must never show a false empty state on failure.
      expect(find.textContaining('Could not clear notifications'),
          findsOneWidget);
      expect(find.text('System degraded'), findsOneWidget);
      expect(find.text('No notifications yet'), findsNothing);
    });
  });

  group('popover', () {
    Future<_FakeNotificationsApiService> pumpPanel(
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
            home: Scaffold(
              body: Center(child: NotificationsPanel(onClose: () {})),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return service;
    }

    testWidgets('panel renders header, rows and the clear-all footer',
        (tester) async {
      await pumpPanel(tester, [_priceDrop()]);
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      expect(find.text('BOS → CDG'), findsOneWidget);
      expect(find.text('Clear all'), findsOneWidget);
    });

    testWidgets('empty panel shows the caught-up state without a footer',
        (tester) async {
      await pumpPanel(tester, const []);
      expect(find.text('No notifications yet'), findsOneWidget);
      expect(find.text('Clear all'), findsNothing);
    });

    testWidgets('rail bell opens the panel and marks notifications seen',
        (tester) async {
      final service = _FakeNotificationsApiService([_priceDrop()]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
            notificationsApiServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: const Scaffold(
              body: Align(
                  alignment: Alignment.bottomLeft, child: RailAccountButton()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The unread badge rides the bell, and only the bell.
      expect(
        find.descendant(
            of: find.byTooltip('Notifications'),
            matching: find.byType(Badge)),
        findsOneWidget,
      );
      expect(find.byType(Badge), findsOneWidget);
      expect(service.markReadCalled, isFalse);

      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();

      // The panel is open with the feed, and opening was the read action.
      expect(find.text('BOS → CDG'), findsOneWidget);
      expect(find.text('Clear all'), findsOneWidget);
      expect(service.markReadCalled, isTrue);
    });
  });
}
