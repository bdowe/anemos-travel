import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/constants/app_info.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/navigation/shell_scope.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/screens/home_screen.dart';
import 'package:travel_route_planner/widgets/brand_logo.dart';

import 'support/l10n_test_app.dart';

/// Home polish regressions (UI polish wave 2, PR 9):
/// - the app bar's brand ladder: the wordmark is always on screen, and it is
///   the MARK that yields when the title slot narrows (the priority
///   used to be the other way round, back when only Home carried the brand);
/// - the compact plan strip's tagline wraps to two lines instead of
///   truncating ("Plan less. Trav…").
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

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
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

Future<void> _pumpHome(
  WidgetTester tester, {
  Trip? liveTrip,
  Size? surface,
  Locale? locale,
}) async {
  if (surface != null) {
    // physicalSize (not setSurfaceSize): the app bar's AccountMenu gates on
    // MediaQuery width, which setSurfaceSize does not update.
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
        liveTripProvider.overrideWithValue(liveTrip),
        resumableChatsProvider.overrideWith((ref) async => const []),
      ],
      // Inside a ShellScope, because in the app Home always is: it is a tab
      // root. GradientAppBar reads it to know whether there is a rail out
      // there carrying the mark — pumped bare, Home would (correctly, but
      // unrepresentatively) keep its own mark at every width.
      child: localizedTestApp(
          locale: locale, home: const ShellScope(child: HomeScreen())),
    ),
  );
  // Extra pumps flush the SharedPreferences read behind recentTripProvider
  // and the resumable-chats future.
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
      'narrow app bar fits the short wordmark next to the mark — '
      'no ellipsis', (WidgetTester tester) async {
    await _pumpHome(tester, surface: const Size(360, 690));

    expect(find.text(AppInfo.name.toUpperCase()), findsOneWidget);
    expect(find.byType(BrandLogo), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'tiny app bar keeps BOTH — the mark is not in the title row to drop',
      (WidgetTester tester) async {
    // This used to assert the opposite. The mark was rung 3 of the title row's
    // ladder and yielded first at widths like this; it now sits in the leading
    // slot, which the title row cannot spend, so it no longer yields to width
    // at all. What absorbs the squeeze here is the wordmark's FittedBox
    // backstop — whole, just smaller — and brand_everywhere_test owns that.
    await _pumpHome(tester, surface: const Size(230, 690));

    expect(find.text(AppInfo.name.toUpperCase()), findsOneWidget);
    expect(find.byType(BrandLogo), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'wide app bar shows the wordmark only — the rail carries the '
      'mark', (WidgetTester tester) async {
    await _pumpHome(tester, surface: const Size(1200, 800));

    expect(find.text(AppInfo.name.toUpperCase()), findsOneWidget);
    expect(find.byType(BrandLogo), findsNothing);
  });

  testWidgets('mid width (no rail) keeps mark and wordmark together',
      (WidgetTester tester) async {
    await _pumpHome(tester, surface: const Size(700, 800));

    expect(find.text(AppInfo.name.toUpperCase()), findsOneWidget);
    expect(find.byType(BrandLogo), findsOneWidget);
  });

  testWidgets(
      'plan-strip tagline may wrap to two lines instead of '
      'truncating', (WidgetTester tester) async {
    await _pumpHome(tester,
        liveTrip: _liveTrip(), surface: const Size(360, 690));

    final tagline = tester.widget<Text>(find.text('Plan less. Travel more.'));
    expect(tagline.maxLines, 2);
    expect(tester.takeException(), isNull);
  });

  // Logo-links-home for the WORDMARK, not just the mark: at rail
  // widths the wordmark is the only brand in the app bar, and it used to be
  // inert (no InkWell at all). These two pin the goHome WIRING at the widths
  // that render each shape — in the real shell Home's app bar only ever shows
  // at the Home root, so the visible half of the tap is the scroll-to-top
  // case below.
  testWidgets('wide app bar: tapping the wordmark goes Home',
      (WidgetTester tester) async {
    await _pumpHome(tester, surface: const Size(1200, 800));

    expect(
      find.ancestor(
          of: find.text(AppInfo.name.toUpperCase()), matching: find.byType(InkWell)),
      findsOneWidget,
    );

    final container =
        ProviderScope.containerOf(tester.element(find.byType(HomeScreen)));
    container.read(navIndexProvider.notifier).state = AppTab.plan.index;

    await tester.tap(find.text(AppInfo.name.toUpperCase()));
    await tester.pump();

    expect(container.read(navIndexProvider), AppTab.home.index);
  });

  testWidgets('mid width: the wordmark beside the mark is the same target',
      (WidgetTester tester) async {
    await _pumpHome(tester, surface: const Size(700, 800));

    final container =
        ProviderScope.containerOf(tester.element(find.byType(HomeScreen)));
    container.read(navIndexProvider.notifier).state = AppTab.plan.index;

    // The wordmark text, NOT the mark — the half of the lockup that used to
    // be dead space.
    await tester.tap(find.text(AppInfo.name.toUpperCase()));
    await tester.pump();

    expect(container.read(navIndexProvider), AppTab.home.index);
  });

  testWidgets('the brand is two targets side by side, not one nested in '
      'another', (WidgetTester tester) async {
    await _pumpHome(tester, surface: const Size(700, 800));

    // The brand is split across two AppBar slots now — the rose leads, the
    // word follows — so "one target over the whole lockup" is no longer the
    // shape. What still must not happen is NESTING: an InkWell inside an
    // InkWell hit-tests and ripples twice over the same pixels. One ancestor
    // each is the assertion, and it is why the rose has no onTap of its own
    // inside the wordmark's target.
    expect(
      find.ancestor(of: find.byType(BrandLogo), matching: find.byType(InkWell)),
      findsOneWidget,
    );
    expect(
      find.ancestor(
          of: find.text(AppInfo.name.toUpperCase()), matching: find.byType(InkWell)),
      findsOneWidget,
    );

    // ...and both halves do the same thing, which is the point of splitting
    // them without splitting the behaviour.
    final container =
        ProviderScope.containerOf(tester.element(find.byType(HomeScreen)));
    container.read(navIndexProvider.notifier).state = AppTab.plan.index;
    await tester.tap(find.byType(BrandLogo));
    await tester.pump();
    expect(container.read(navIndexProvider), AppTab.home.index);
  });

  testWidgets('tapping the brand scrolls Home back to the top',
      (WidgetTester tester) async {
    await _pumpHome(tester, surface: const Size(360, 690));

    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -240));
    await tester.pumpAndSettle();
    final position =
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(position.pixels, greaterThan(0));

    await tester.tap(find.byType(BrandLogo));
    await tester.pumpAndSettle();

    expect(position.pixels, 0);
  });

  testWidgets('overflow floor: home with the plan strip at 360x690 in es',
      (WidgetTester tester) async {
    await _pumpHome(tester,
        liveTrip: _liveTrip(),
        surface: const Size(360, 690),
        locale: const Locale('es'));

    expect(tester.takeException(), isNull);
  });
}
