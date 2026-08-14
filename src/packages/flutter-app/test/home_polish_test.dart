import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/constants/app_info.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/screens/home_screen.dart';
import 'package:travel_route_planner/widgets/brand_logo.dart';

import 'support/l10n_test_app.dart';

/// Home polish regressions (UI polish wave 2, PR 9):
/// - the app bar drops the wordmark for the brand mark alone when the
///   title slot can't fit it, instead of ellipsizing the brand;
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
      child: localizedTestApp(locale: locale, home: const HomeScreen()),
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
      'narrow app bar fits the short wordmark next to the badge — '
      'no ellipsis', (WidgetTester tester) async {
    await _pumpHome(tester, surface: const Size(360, 690));

    expect(find.text(AppInfo.name), findsOneWidget);
    expect(find.byType(BrandLogo), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'tiny app bar drops the wordmark for the brand mark alone — '
      'no ellipsized wordmark', (WidgetTester tester) async {
    await _pumpHome(tester, surface: const Size(230, 690));

    expect(find.text(AppInfo.name), findsNothing);
    expect(find.byType(BrandLogo), findsOneWidget);
  });

  testWidgets(
      'wide app bar shows the wordmark only — the rail carries the '
      'mark', (WidgetTester tester) async {
    await _pumpHome(tester, surface: const Size(1200, 800));

    expect(find.text(AppInfo.name), findsOneWidget);
    expect(find.byType(BrandLogo), findsNothing);
  });

  testWidgets('mid width (no rail) keeps badge and wordmark together',
      (WidgetTester tester) async {
    await _pumpHome(tester, surface: const Size(700, 800));

    expect(find.text(AppInfo.name), findsOneWidget);
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

  testWidgets('overflow floor: home with the plan strip at 360x690 in es',
      (WidgetTester tester) async {
    await _pumpHome(tester,
        liveTrip: _liveTrip(),
        surface: const Size(360, 690),
        locale: const Locale('es'));

    expect(tester.takeException(), isNull);
  });
}
